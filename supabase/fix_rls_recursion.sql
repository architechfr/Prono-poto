-- ════════════════════════════════════════════════════════════
-- FIX — "infinite recursion detected in policy for relation league_members"
-- À exécuter UNE FOIS dans Supabase : Dashboard > SQL Editor > New query
-- > coller tout ce fichier > Run.
--
-- Cause : les policies member_read / league_read / pred_read interrogeaient
-- league_members, ce qui re-déclenchait la policy de league_members → boucle.
-- Remède : fonctions SECURITY DEFINER (exécutées hors RLS) qui répondent
-- "suis-je membre ?" sans re-déclencher les règles.
-- ════════════════════════════════════════════════════════════

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

drop policy if exists member_read on league_members;
create policy member_read on league_members for select
  using (is_league_member(league_id));

drop policy if exists league_read on leagues;
create policy league_read on leagues for select
  using (is_league_member(id));

drop policy if exists pred_read on predictions;
create policy pred_read on predictions for select using (
  user_id = auth.uid()
  or (
    shares_league_with(user_id)
    and exists (select 1 from matches m where m.id = predictions.match_id and now() >= m.kickoff)
  )
);

-- Vérification rapide (doit retourner les 3 policies sans erreur) :
select polname from pg_policy
where polrelid in ('league_members'::regclass,'leagues'::regclass,'predictions'::regclass);
