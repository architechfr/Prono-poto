-- ════════════════════════════════════════════════════════════
-- MISE À JOUR — Système de JETONS de boost (remplace le quota "1 par journée")
-- À exécuter UNE FOIS dans Supabase : Dashboard > SQL Editor > New query
-- > coller tout ce fichier > Run.
--
-- 50 jetons par phase (groupes / finale). ⚡×2 = 5 jetons · ⭐×3 = 15 jetons.
-- On regagne des jetons en jouant : +2 par bon résultat, +5 par score exact.
-- Le contrôle fin se fait dans l'app ; ce trigger est le garde-fou anti-abus
-- (marge +20 pour absorber les états transitoires d'une publication groupée).
-- ════════════════════════════════════════════════════════════

create or replace function check_boost_budget()
returns trigger language plpgsql as $$
declare v_is_group boolean; v_cost int; v_gain int;
begin
  if coalesce(new.boost,1) <= 1 then return new; end if;
  select (stage like 'Groupe %') into v_is_group from matches where id = new.match_id;
  select coalesce(sum(case p.boost when 2 then 5 when 3 then 15 else 0 end),0) into v_cost
  from predictions p join matches m on m.id = p.match_id
  where p.user_id = new.user_id and (m.stage like 'Groupe %') = v_is_group
    and p.match_id <> new.match_id;
  v_cost := v_cost + (case new.boost when 2 then 5 when 3 then 15 else 0 end);
  select coalesce(sum(case
      when m.score1 is null or m.score2 is null then 0
      when p.score1 = m.score1 and p.score2 = m.score2 then 5
      when sign(p.score1 - p.score2) = sign(m.score1 - m.score2) then 2
      else 0 end),0) into v_gain
  from predictions p join matches m on m.id = p.match_id
  where p.user_id = new.user_id and (m.stage like 'Groupe %') = v_is_group;
  if v_cost > 50 + v_gain + 20 then
    raise exception 'Jetons insuffisants pour ce boost (coût %, budget %)', v_cost, 50+v_gain;
  end if;
  return new;
end $$;

drop trigger if exists trg_boost_quota on predictions;
drop trigger if exists trg_boost_budget on predictions;
create trigger trg_boost_budget
before insert or update on predictions
for each row execute function check_boost_budget();

-- Vérif : le trigger budget doit être listé
select tgname from pg_trigger where tgrelid = 'predictions'::regclass and not tgisinternal;
