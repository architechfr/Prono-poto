-- ============================================================
-- PRONO POTO — Schéma Supabase v1
-- Pronos entre amis · Mondial 2026 (générique multi-compétitions)
-- À exécuter dans Supabase Dashboard > SQL Editor (une seule fois)
-- ============================================================

-- ─── COMPÉTITIONS (prêt pour Ligue 1, Euro... plus tard) ─────
create table competitions (
  id         int primary key,
  name       text not null,
  starts_at  date,
  ends_at    date
);
insert into competitions values (1, 'Coupe du Monde 2026', '2026-06-11', '2026-07-19');

-- ─── MATCHS (mêmes ids que Foot Flash) ───────────────────────
create table matches (
  id             int primary key,
  competition_id int not null references competitions(id),
  kickoff        timestamptz not null,   -- UTC (saisi avec offset +02:00 Paris)
  stage          text not null,          -- 'Groupe A' ... '16e de finale' ... 'FINALE'
  team1          text,                   -- code 3 lettres, null si TBD (phase KO)
  team2          text,
  stadium        text,
  city           text,
  score1         int,                    -- null tant que non joué
  score2         int,
  scored_at      timestamptz,
  journey        text                    -- 'J1'/'J2'/'J3' (groupes) ou nom du tour KO
);
create index matches_kickoff_idx on matches(kickoff);

-- ⚠️ À exécuter APRÈS seed_matches.sql : calcule la journée de chaque match
-- (groupes : 2 premiers matchs du groupe = J1, suivants = J2, derniers = J3)
-- update matches m set journey = sub.j from (
--   select id, case when stage like 'Groupe %'
--     then 'J'||((((row_number() over (partition by stage order by kickoff, id))-1)/2)+1)::text
--     else stage end as j
--   from matches) sub
-- where sub.id = m.id;

-- ─── PROFILS ─────────────────────────────────────────────────
create table profiles (
  id         uuid primary key references auth.users on delete cascade,
  pseudo     text not null check (char_length(trim(pseudo)) between 2 and 20),
  created_at timestamptz default now()
);

-- ─── LIGUES ──────────────────────────────────────────────────
create table leagues (
  id             uuid primary key default gen_random_uuid(),
  competition_id int not null references competitions(id) default 1,
  name           text not null check (char_length(name) between 2 and 30),
  code           text unique not null,
  owner_id       uuid references profiles(id),
  created_at     timestamptz default now()
);

create table league_members (
  league_id  uuid references leagues(id) on delete cascade,
  user_id    uuid references profiles(id) on delete cascade,
  joined_at  timestamptz default now(),
  primary key (league_id, user_id)
);
create index league_members_user_idx on league_members(user_id);

-- ─── PRONOS (un par joueur et par match, toutes ligues) ──────
create table predictions (
  user_id    uuid references profiles(id) on delete cascade,
  match_id   int references matches(id),
  score1     int not null check (score1 between 0 and 20),
  score2     int not null check (score2 between 0 and 20),
  -- 1 = normal · 2 = ⚡ Capitaine (1/journée) · 3 = ⭐ Super capitaine (1/phase)
  boost      int not null default 1 check (boost in (1,2,3)),
  updated_at timestamptz default now(),
  primary key (user_id, match_id)
);

-- ============================================================
-- RLS — le cœur anti-triche
-- ============================================================
alter table competitions  enable row level security;
alter table matches       enable row level security;
alter table profiles      enable row level security;
alter table leagues       enable row level security;
alter table league_members enable row level security;
alter table predictions   enable row level security;

-- Lecture publique des référentiels
create policy comp_read  on competitions for select using (true);
create policy match_read on matches      for select using (true);
-- Écriture matches : AUCUNE policy → seul le service_role (dashboard / RPC admin) peut écrire.

-- Profils : lire tout le monde (pseudos), modifier le sien
create policy prof_read   on profiles for select using (true);
create policy prof_insert on profiles for insert with check (id = auth.uid());
create policy prof_update on profiles for update using (id = auth.uid());

-- ⚠️ Ne JAMAIS interroger league_members dans une policy de league_members
-- (ou via une policy en cascade) : "infinite recursion detected in policy".
-- Remède : fonctions SECURITY DEFINER (exécutées hors RLS) comme test d'appartenance.

create or replace function is_league_member(p_league uuid)
returns boolean
language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from league_members
    where league_id = p_league and user_id = auth.uid()
  );
$$;

create or replace function shares_league_with(p_user uuid)
returns boolean
language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from league_members me
    join league_members them on them.league_id = me.league_id
    where me.user_id = auth.uid() and them.user_id = p_user
  );
$$;

-- Ligues : visibles par leurs membres (l'accès par code passe par la RPC join_league)
create policy league_read on leagues for select using (is_league_member(id));

-- Membres : voir les membres de ses propres ligues
create policy member_read on league_members for select using (is_league_member(league_id));

-- PRONOS — règles clés :
-- 1. Je lis toujours mes pronos.
-- 2. Je lis ceux d'un autre SEULEMENT si on partage une ligue ET que le match a commencé.
create policy pred_read on predictions for select using (
  user_id = auth.uid()
  or (
    shares_league_with(user_id)
    and exists (select 1 from matches m where m.id = predictions.match_id and now() >= m.kickoff)
  )
);
-- 3. J'écris/modifie uniquement mes pronos, uniquement AVANT le coup d'envoi,
--    et uniquement sur un match dont les équipes sont connues.
create policy pred_insert on predictions for insert with check (
  user_id = auth.uid()
  and exists (select 1 from matches m where m.id = match_id
              and now() < m.kickoff and m.team1 is not null and m.team2 is not null)
);
create policy pred_update on predictions for update using (
  user_id = auth.uid()
  and exists (select 1 from matches m where m.id = match_id and now() < m.kickoff)
);

-- ============================================================
-- RPC (fonctions appelées par l'app)
-- ============================================================

-- Créer une ligue : génère un code unique à 6 caractères, inscrit le créateur.
create or replace function create_league(p_name text)
returns json language plpgsql security definer set search_path = public as $$
declare v_code text; v_id uuid;
begin
  if auth.uid() is null then raise exception 'non connecté'; end if;
  loop
    v_code := upper(substr(md5(random()::text), 1, 6));
    exit when not exists (select 1 from leagues where code = v_code);
  end loop;
  insert into leagues(name, code, owner_id) values (trim(p_name), v_code, auth.uid())
    returning id into v_id;
  insert into league_members(league_id, user_id) values (v_id, auth.uid());
  return json_build_object('id', v_id, 'code', v_code, 'name', trim(p_name));
end $$;

-- Rejoindre une ligue par code.
create or replace function join_league(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare v_league leagues%rowtype;
begin
  if auth.uid() is null then raise exception 'non connecté'; end if;
  select * into v_league from leagues where code = upper(trim(p_code));
  if not found then raise exception 'code de ligue inconnu'; end if;
  insert into league_members(league_id, user_id) values (v_league.id, auth.uid())
    on conflict do nothing;
  return json_build_object('id', v_league.id, 'code', v_league.code, 'name', v_league.name);
end $$;

-- Saisie admin des résultats : protégée par un code secret (à changer !).
-- Alternative : saisir directement dans Dashboard > Table editor.
create or replace function admin_set_score(p_admin_code text, p_match_id int, p_s1 int, p_s2 int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_admin_code <> 'Prono2026!A' then raise exception 'code admin invalide'; end if;
  update matches set score1 = p_s1, score2 = p_s2, scored_at = now() where id = p_match_id;
end $$;

-- ============================================================
-- QUOTAS CAPITAINE — garantis côté serveur (trigger)
-- ⚡ boost=2 : un seul par journée · ⭐ boost=3 : un seul par phase
-- ============================================================
create or replace function check_boost_quota()
returns trigger language plpgsql as $$
declare v_journey text; v_is_group boolean; cnt int;
begin
  if new.boost = 2 then
    select journey into v_journey from matches where id = new.match_id;
    select count(*) into cnt
    from predictions p join matches m on m.id = p.match_id
    where p.user_id = new.user_id and p.boost = 2
      and m.journey = v_journey and p.match_id <> new.match_id;
    if cnt > 0 then
      raise exception 'Capitaine déjà utilisé sur cette journée (un seul ⚡ par journée)';
    end if;
  elsif new.boost = 3 then
    select (stage like 'Groupe %') into v_is_group from matches where id = new.match_id;
    select count(*) into cnt
    from predictions p join matches m on m.id = p.match_id
    where p.user_id = new.user_id and p.boost = 3
      and (m.stage like 'Groupe %') = v_is_group and p.match_id <> new.match_id;
    if cnt > 0 then
      raise exception 'Super capitaine déjà utilisé sur cette phase (un seul ⭐)';
    end if;
  end if;
  return new;
end $$;
create trigger trg_boost_quota
before insert or update on predictions
for each row execute function check_boost_quota();

-- ============================================================
-- VUE CLASSEMENT — barème "gros points" :
-- bon résultat = 100 pts · score exact = 300 pts · × boost (⚡2/⭐3)
-- + bonus 🎯 "Seul au monde" : +200 si unique score exact de la ligue
-- (max : 300 × 3 + 200 = 1100 pts sur un match)
-- ============================================================
create or replace view league_standings
with (security_invoker = true) as
with base as (
  select lm.league_id, lm.user_id, p.match_id, p.boost,
    (p.score1 = m.score1 and p.score2 = m.score2) as is_exact,
    case
      when p.score1 = m.score1 and p.score2 = m.score2 then 300 * p.boost
      when sign(p.score1 - p.score2) = sign(m.score1 - m.score2) then 100 * p.boost
      else 0 end as pts
  from league_members lm
  join predictions p on p.user_id = lm.user_id
  join matches m on m.id = p.match_id
  where m.score1 is not null
), lonely as (
  select league_id, match_id
  from base where is_exact
  group by league_id, match_id
  having count(*) = 1
)
select
  lm.league_id,
  lm.user_id,
  pr.pseudo,
  coalesce(sum(b.pts + case when b.is_exact and l.match_id is not null then 200 else 0 end), 0)::int as points,
  count(b.match_id)::int as played,
  count(*) filter (where b.is_exact)::int as exacts
from league_members lm
join profiles pr on pr.id = lm.user_id
left join base b on b.user_id = lm.user_id and b.league_id = lm.league_id
left join lonely l on l.league_id = b.league_id and l.match_id = b.match_id
group by lm.league_id, lm.user_id, pr.pseudo;

-- ============================================================
-- VUES AJOUTÉES POUR LE DESIGN (export Claude Design 07/06/2026)
-- ============================================================

-- Pronos des potos sur un match (écran détail match).
-- security_invoker → la RLS de predictions s'applique : les pronos des autres
-- ne sortent qu'après le kickoff, automatiquement.
create or replace view match_predictions
with (security_invoker = true) as
select p.match_id, p.user_id, pr.pseudo, p.score1, p.score2, p.boost
from predictions p
join profiles pr on pr.id = p.user_id;

-- Série en cours (🔥 streak) : nb de matchs notés consécutifs avec points > 0,
-- du plus récent vers le passé. Utilisé par le classement du design.
create or replace view user_streaks
with (security_invoker = true) as
with scored as (
  select p.user_id, m.kickoff,
    (case
      when p.score1 = m.score1 and p.score2 = m.score2 then 3 * p.boost
      when sign(p.score1 - p.score2) = sign(m.score1 - m.score2) then 1 * p.boost
      else 0 end) as pts
  from predictions p
  join matches m on m.id = p.match_id
  where m.score1 is not null
), ranked as (
  select user_id, pts,
         row_number() over (partition by user_id order by kickoff desc) as rn
  from scored
)
select user_id,
  coalesce(min(rn) filter (where pts = 0) - 1, count(*))::int as streak
from ranked
group by user_id;

-- Nombre de membres par ligue (header "8 potos")
create or replace view league_sizes
with (security_invoker = true) as
select league_id, count(*)::int as members
from league_members
group by league_id;
