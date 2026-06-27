# FIFA World Cup 2026

## Overview

- **Hosts**: USA, Canada, Mexico (tri-host)
- **Teams**: 48 (expanded from 32 in 2022)
- **Dates**: June 11 – July 19, 2026
- **Venues**: 16 stadiums across 16 cities (11 US, 3 Mexico, 2 Canada)

## Group Stage Structure

- **12 groups** of 4 teams each (Groups A–L)
- **3 matchdays** per group (each team plays 3 matches)
- **24 matches per matchday** (72 total group stage matches)
- **Advancement**: Top 2 per group (24) + 8 best third-place teams = 32 to knockout round

### Matchday Schedule

| Matchday | Dates | Matches |
|----------|-------|---------|
| 1 | June 11–17 | 24 |
| 2 | June 18–23 | 24 |
| 3 | June 24–27 | 24 |

Each matchday, every team plays exactly once. Each match produces 2 "offensive matchups" (one per team).

### Group Play Round-Robin

Within each group of 4 teams (A, B, C, D):
- Matchday 1: A vs B, C vs D
- Matchday 2: A vs C, B vs D
- Matchday 3: A vs D, B vs C

## 2026 Groups (Confirmed Draw)

| Group | Teams |
|-------|-------|
| A | Qatar, Ecuador, Colombia, UEFA Playoff A |
| B | Canada, Morocco, Australia, UEFA Playoff B |
| C | USA, Serbia, Cameroon, New Zealand |
| D | Brazil, Nigeria, IC Playoff 1, UEFA Playoff C |
| E | Argentina, Peru, Egypt, IC Playoff 2 |
| F | Mexico, Honduras, Senegal, UEFA Playoff D |
| G | France, Colombia (TBC), Panama, Uzbekistan |
| H | Portugal, Iran, South Korea, Northern Ireland |
| I | Spain, Japan, Chile, Bolivia |
| J | England, Denmark, Paraguay, Ivory Coast |
| K | Germany, Uruguay, Costa Rica, Saudi Arabia |
| L | Italy, Belgium, Albania, Dominican Republic |

*UEFA Playoff and IC Playoff slots TBD (decided March 26-31, 2026)*

## Knockout Stage

- **Round of 32**: 32 teams, single elimination
- **Round of 16 → Quarterfinals → Semifinals → Final**
- **Third-place match**: Yes
- **Extra time + penalties**: For drawn knockout matches

## Key Format Change from 2022

2022 had 32 teams in 8 groups of 4. FIFA originally considered 16 groups of 3 for 48 teams but chose 12 groups of 4 to reduce collusion risk and maintain competitive integrity.

## Turf Monster Data

The app's seed data includes:
- **48 teams** with emoji, colors, group assignments
- **44 knockout-slot placeholder teams** for unresolved bracket positions
- **104 tournament games**: 72 group-stage games plus 32 elimination-round fixtures
- **67 notable players** across 21 teams
- **24 Matchday 1 props** with goal lines (1.5–2.5 range)

### Offensive Matchups Per Matchday

Each matchday produces **48 offensive matchups** (one per team). For Turf Totals contests, each matchup represents one team's goal-scoring opportunity in their specific game. Example:

- Game: USA vs Serbia (Matchday 1)
- Offensive matchup 1: USA's offense vs Serbia's defense
- Offensive matchup 2: Serbia's offense vs USA's defense

These are ranked by expected scoring output. Strong offenses against weak defenses rank high (low multiplier). Weak offenses against strong defenses rank low (high multiplier).

### Knockout Slates

`WorldCup2026KnockoutSeed` adds one slate per elimination stage:

- World Cup 2026 Round of 32
- World Cup 2026 Round of 16
- World Cup 2026 Quarter-finals
- World Cup 2026 Semi-finals
- World Cup 2026 Third Place
- World Cup 2026 Final

The fixture list is sourced from FIFA's FDCP season calendar for competition
`17`, season `285023`. Known teams use the existing team records by FIFA
abbreviation; unresolved bracket positions use placeholder teams such as
`W101` or `Best 3rd C/E/F/H/I` so games and slate matchups can be created
before the full bracket is settled.

## World Cup Survivor (parallel contest format)

Single-elimination survivor pick. Players pick ONE team per `SurvivorRound`; that team must win to advance. A wrong pick eliminates the entry permanently. Last survivor(s) take the prize.

### Format

- **Max entries per contest**: 59
- **Max entries per user per contest**: 1 (vs 3 for Turf Totals)
- **Picks required at entry confirm**: 0 — picks happen per-round, not up front
- **Team reuse**: not allowed across rounds within a single entry (enforced by unique index on `[team_slug, entry_id]` on `SurvivorPick`)

| Tier | Entry fee | Max entries | Winner takeall |
|------|----------:|------------:|---------------:|
| `survivor_wc_paid` | $19 | 59 | $1,000 |
| `survivor_wc_free` | $0  | 59 | $200 |

Both formats are defined in `Contest::FORMATS` alongside the Turf Totals tiers. Contest model exposes `game_type: :world_cup_survivor` for branching.

### Round structure

`SurvivorRound` is its own model: `number` (unique, ordered), `name`, `stage` (group/knockout), `status` (upcoming/locked/completed), `picks_lock_at` (nullable). Rounds align with the tournament's natural advancement gates — typically one round per matchday in the group stage, then per knockout fixture.

- Group stage rounds let players pick from any team playing in that round.
- Knockout rounds narrow to the surviving teams in the bracket.
- `SurvivorRound.current` returns the earliest unlocked round; `picks_locked?` predicates the cutoff.

### Lifecycle

Survivor contests share the standard `pending → open → settled` lifecycle from Turf Totals (`locked` is a derived time-gate, not a status; see `Contest#locked?` and the contest lifecycle notes in `docs/SOLANA.md`), plus a per-round `grade_round` admin action that scores the current `SurvivorRound`, marks each `SurvivorPick.result` as `survived` or `eliminated`, and transitions the round to `completed`. The contest fully settles when one entry remains (or all remaining entries tie out on a shared elimination round and split the prize).

### Key models + methods

- `SurvivorRound` — `has_many :games` (dependent: nullify), `has_many :survivor_picks` (dependent: destroy).
- `SurvivorPick` — `belongs_to :entry, :survivor_round, :team`. Unique `[survivor_round_id, entry_id]` + unique `[team_slug, entry_id]`.
- `Entry#survivor?` / `Entry#eliminated?` — predicates for branching the UI.

Kickoff memory: `project_turf_world_cup_survivor_kickoff` (2026-05-19, devnet soft launch).
