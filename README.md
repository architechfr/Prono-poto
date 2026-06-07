# ⚽ Prono Poto — Pronos entre amis (Mondial 2026)

App indépendante, HTML mono-fichier (vanilla JS), backend Supabase.
Spécifications complètes : voir `../CDC_LIGUES_AMIS.md` (mêmes décisions, app standalone).

## Démarrage rapide

**Sans rien configurer** : ouvre `index.html` dans un navigateur → MODE DÉMO
(faux potos, données locales). Parfait pour valider l'UX.

## Brancher Supabase (15 min)

1. **Créer le projet** : https://supabase.com → New project (tier gratuit).
2. **SQL Editor** → coller et exécuter `supabase/schema.sql` (tables + RLS + RPC + vues + trigger quotas).
3. **SQL Editor** → coller et exécuter `supabase/seed_matches.sql` (les 104 matchs).
3bis. **SQL Editor** → exécuter le bloc `update matches ... journey` commenté dans
   schema.sql (calcule les journées J1/J2/J3, nécessaire aux quotas Capitaine).
4. **Authentication > Sign In / Up** → activer **Anonymous sign-ins**.
5. **Settings > API** → copier `Project URL` et `anon public key` dans `index.html` :
   ```js
   var SUPA_URL = "https://xxxx.supabase.co";
   var SUPA_ANON_KEY = "eyJ...";
   ```
6. ⚠️ Dans `schema.sql`, la fonction `admin_set_score` contient le code admin
   `CHANGE_MOI_VITE` → **le changer avant d'exécuter** (ou saisir les scores
   directement dans Table Editor > matches).
7. Déployer : pousser le dossier sur GitHub Pages / Vercel. Le lien d'invitation
   `...index.html?ligue=CODE` pré-remplit le code pour les potos.

## Saisir un résultat (admin)

Option A — Dashboard : Table Editor > `matches` → remplir `score1`/`score2`.
Option B — SQL : `select admin_set_score('TON_CODE', 49, 2, 1);`
Le classement se recalcule automatiquement (vue dérivée, aucun point stocké).

## Quand les qualifiés des 16es sont connus

```sql
update matches set team1='FRA', team2='ESP' where id=73;
```
(tant que team1/team2 sont null, les pronos sont refusés par RLS)

## Anti-triche (garanties serveur, pas client)

- Prono modifiable **uniquement avant le kickoff** (policy RLS, horloge Postgres).
- Pronos des autres membres **invisibles avant le coup d'envoi**.
- Points calculés par la vue SQL (`league_standings`) : exact = 3, bon résultat = 1,
  × Capitaine ⚡2 / Super ⭐3, bonus 🎯 "Seul au monde" +2 (unique score exact de la ligue).
- Quotas Capitaine garantis par trigger : un seul ⚡ par journée, un seul ⭐ par phase.
- Écriture de `matches` impossible avec la clé `anon` (aucune policy d'écriture).

## Pièges connus

- **Heures** : seed en heure française (`+02:00`). Si un kickoff semble faux,
  corriger dans `seed_matches.sql` et re-seeder (3 matchs à minuit `T00:00` hérités
  de Foot Flash sont suspects — ids 75, 79, 83, 87, 91, 95 — à vérifier).
- **Compte anonyme** : si l'utilisateur vide son cache sans avoir lié d'email,
  il repart de zéro (v2 : linkIdentity email).
- **Pseudo** : unique nulle part en v1 — deux "Max" possibles dans une ligue.

## Structure

```
prono-poto/   (repo GitHub : architechfr/Prono-poto)
├── index.html                ← ⭐ L'APP (skin or/marine Foot Flash, vanilla JS,
│                                démo sans clés / Supabase avec clés)
├── prototype-v1.html         ← 1er prototype (vert) — conservé pour référence
├── README.md
└── supabase/
    ├── schema.sql            ← tables + RLS + RPC + vues + trigger quotas capitaine
    └── seed_matches.sql      ← 104 matchs (mêmes ids que Foot Flash)
```

## Écrans de la version finale (issus du design Claude Design)

Onboarding (héros + 3 arguments + créer/rejoindre en bottom-sheet), Pronos
(bandeau ligue avec ton rang, filtres par phase, matchs groupés par jour avec
états ouvert/EN DIRECT/terminé/TBD, steppers + boost ⚡, dock "Publier" collant),
Détail match (tableau d'affichage, ton prono, pronos des potos triés par points,
boîte "verrouillé" avant kickoff), Classement (podium 🥇🥈🥉 + liste avec barres
et 🔥 streaks), Ma ligue (code + QR réel + lien d'invitation ?ligue=CODE,
avatars des potos, règles, quitter). Confettis aux grands moments 🎉.
