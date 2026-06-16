# Centralized Formulas & Slate System

## Formula Source of Truth (SlateMatchup Model)

All scoring/ranking formulas live as class methods on `SlateMatchup` — single source of truth. JS mirrors in `slates/show.html.erb` and `slates/formula_report.html.erb` with comments noting the model as authoritative.

- **Turf Score**: `SlateMatchup.turf_score_for(rank, n)` — `1.0 + 2.0 * Math.log(rank) / Math.log(n)`. Logarithmic curve, x1.0 at rank 1 to x3.0 at rank N. (Scale `2.0` is `Slate::FORMULA_DEFAULTS[:formula_mult_scale]`; per-slate overridable.)
- **Goals Distribution**: `SlateMatchup.goals_distribution_for(rank, n)` — `0.2 + 4.3 * Math.log(n / rank) / Math.log(n)`.

## Formula Color System

Chart/formula visualization colors are defined once at the top of `slates/show.html.erb`:
- **CSS custom properties** (`--fc-mult`, `--fc-goals`, `--fc-dk-total`) for inline styles
- **JS `FC` object** (`FC.mult`, `FC.goals`, `FC.dkTotal`) for Chart.js datasets
- Colors: Turf Score = violet `#8E82FE`, Goals Distribution = light violet `#B8B0FF`, DK Expectation = green `#4BAF50`

## Slate Show Page (`/slates/:id`)

Admin-only interactive page for tuning multiplier formulas. Key sections:

1. **Slate tabs** — navigate between slates (shown when multiple exist)
2. **Turf Score Formula chart** — Chart.js line chart with 5 datasets (Turf Score, Goals Distribution, DK Total Score, DK Total, DK Total Odds). Updates live as sliders change.
3. **Formula variable sliders** — 7 interactive Alpine.js sliders (A, lineExp, probExp, multBase, multScale, goalBase, goalScale) grouped into formula variable cards with colored left accent bars and math notation.
4. **Ranking list** — sortable table of all slate matchups. Score/Turf Score columns update dynamically when sliders change. Drag-to-reorder via SortableJS library.
5. **Save buttons** — "Save Rankings" (persists rank order + computed turf scores), "Save Turf Scores" (persists arbitrary slider-computed values), and "Save Formula" (persists current slider values to this slate's DB columns). All appear at top and bottom of the rank list.

### Chart.js + Alpine.js Proxy Avoidance Pattern (Critical)

Chart.js instances **must not** be stored as Alpine reactive properties. Alpine wraps objects in ES6 Proxies, which triggers infinite re-render loops when Chart.js reads/writes its internal state. Solution: store Chart.js instances and shared state as plain globals outside Alpine:

```javascript
var _fcChart = null;       // Chart.js instance
var _fcLastData = null;    // last dataset snapshot
var _fcSliders = {};       // current slider values
```

Alpine components read/write these globals directly. Never use `this.chart` or `$data.chart` for Chart.js objects.

> **Same gotcha applies to DOM refs used with `scrollIntoView`.** Alpine wraps the element in a Proxy, which silently breaks the scroll API. Keep `scrollIntoView` element refs in plain `var`s outside Alpine and call the method from a plain function (see the Slate Manager simulate-all flow below for a working example).

### Cross-Component Communication Pattern

Two Alpine components on the slate show page (`formulaCurves` for the chart/sliders, `rankManager` for the ranking list) communicate via global functions:

- `_fcUpdateRankList(sliders)` — called by `formulaCurves` when sliders change, updates rank list scores
- `_fcSliders` — global object holding current slider values, readable by `rankManager` for save

This avoids Alpine `$dispatch`/`$store` complexity for components that need to share computed state.

### Persisted Formula Variables

7 nullable float columns on `slates`: `formula_a`, `formula_line_exp`, `formula_prob_exp`, `formula_mult_base`, `formula_mult_scale`, `formula_goal_base`, `formula_goal_scale`. Resolution chain (3-tier, like ThemeSetting):

1. **Slate column** — per-slate override (nullable)
2. **Default slate record** — `Slate.find_by(name: "Default")` — global defaults
3. **Hardcoded constant** — `Slate::FORMULA_DEFAULTS`

`Slate#resolved_formula` returns a hash with resolved values. Sliders on the show page initialize from this. "Save Formula" button persists current slider values to the slate. "Default" slate is a config record (filtered out of index/tabs via `where.not(name: "Default")`).

**Admin Formula Defaults page** (`/slates/admin_formula`) — number inputs for editing the Default slate's formula variables. Linked from the admin Link Hub.

## Slate Manager (`/admin/slates/:id/manage`)

Admin page for managing game results within a slate. Each game renders as a card with score table, goal timeline, add goal form, and simulation controls.

### Game Simulation
- **10 ticks** per game, each tick gives both teams a goal chance: `P(goal) = dkGoalsExpectation / 10`
- Goals POST to the server as real Goal records, assigned to a random player with a random minute (90 min / 10 ticks = 9-minute windows)
- Progress bar animates smoothly via `requestAnimationFrame`
- Toast notifications fire for each goal and at full time
- Two speed options per game card: **Sim 10s** (1s ticks) and **30s** (3s ticks)
- **Simulate All** button at the top: runs all unplayed games sequentially using 10s mode, auto-scrolls to each game card with a 500ms pause before starting
- `simulateGame()` returns a Promise for sequential chaining
- DOM element references kept outside Alpine's Proxy to ensure `scrollIntoView` works correctly

## Slate Routes

- `/slates` — redirects to next upcoming slate (or most recent)
- `/slates/:id` — show (chart + sliders + rank list)
- `/slates/:id/update_rankings` — PATCH, save drag-reordered ranks + recalculated multipliers
- `/slates/:id/update_turf_scores` — PATCH, save slider-computed turf score values
- `/slates/:id/update_formula` — PATCH, save formula slider values to this slate
- `/slates/formula_report` — DK Score formula iterations page with comparison charts + playground
- `/slates/admin_formula` — GET, admin page for editing Default slate formula variables
- `/slates/update_admin_formula` — PATCH, save Default slate formula variables
