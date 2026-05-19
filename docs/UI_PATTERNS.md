# UI Patterns & Branding

## Branding & Theme

- **Theme**: Dynamic — engine-generated CSS custom properties from 7 role colors (see top-level `CLAUDE.md` for full theme docs)
- **Theme config**: `theme_primary = "#4BAF50"` (green), `theme_accent = "#8E82FE"` (violet) in `studio.rb`
- **Admin theme page**: `/admin/theme` — color editor + styleguide (from engine)
- **Primary**: `#4BAF50` Green — brand text, CTAs, buttons, nav hovers, money displays, balances, checkmarks, hold button idle state
- **Mint**: `#06D6A0` — win badges, contest status (open), hold button success glow. Reserved for game mechanics (win), not general selection UI.
- **Accent**: `#8E82FE` Violet — scores, draft badges, `.btn-secondary`, Phantom wallet badge. NOT for CTA-intent elements (use `primary` instead). NOT for turf scores (use `primary`).
- **Primary for selection UI**: Selection count badges, cart slot borders, matchup selection rings/tints, turf score values, links, sort toggle active state, and FAB buttons all use `primary` (green), not mint or violet.
- **Warning**: `#FF7C47` Orange — warning states, `.btn-warning`
- **Negative**: Red (Tailwind default) — losses
- **Font**: Montserrat (all weights 400-900)
- **Logo**: Two files exist — `/public/logo.png` (1.3MB, used in layout navbar) and `/public/logo.jpeg` (272KB, used in auth pages). Both are the green monster mascot. Should be consolidated to one file.

### Semantic Tokens (required)
- **Surfaces**: Use `bg-page`, `bg-surface`, `bg-surface-alt`, `bg-inset` — never hardcode `bg-navy-*`
- **Text**: Use `text-heading`, `text-body`, `text-secondary`, `text-muted` — never hardcode `text-white` for headings or `text-gray-*` for body text
- **Borders**: Use `border-subtle`, `border-strong` — never hardcode `border-navy-*`
- **CSS var naming**: `--color-cta` / `--color-cta-hover` for singular CTA color. Full `--color-primary-{50..900}` palette with RGB variants for Tailwind `primary-*` utilities.
- **Tailwind config**: `primary` palette is dynamic from shared studio config (CSS vars). `warning` palette defined locally in `config/tailwind.config.js`. Safelist includes `bg`, `text`, `border`, `ring` utilities for brand colors.

### Status Badges
mint=open, yellow=locked, gray=settled, violet=draft

## Button System

CSS component classes in `application.tailwind.css`:
- `.btn` (base), `.btn-primary` (green/white), `.btn-secondary` (violet/white), `.btn-outline` (border/transparent), `.btn-warning` (orange/white), `.btn-danger` (red), `.btn-google` (white/hardcoded gray-700 — uses `color: #374151` for dark mode compat)
- Size modifiers: `.btn-sm`, `.btn-lg`
- Disabled state built into `.btn` base
- Combine: `class="btn btn-primary btn-lg w-full"`

## Component Classes
`.card`, `.card-hover`, `.input-field`, `.empty-state`, `.json-debug`, `.label-upper`, `.badge`, `.matchup-selected`

## Matchup Grid

`_turf_totals_board.html.erb` — two sort modes toggled via Alpine (`sortMode`/`sortDir`):

- **Game view** (default): Paired cards with "vs" divider (`color-mix` background), sorted by lowest turf score. Uses `_matchup_game_pair.html.erb` partial (locals: `left`, `right`, `locked`). Both-selected: outer `outline` + `box-shadow` glow in primary, "vs" div gets primary tint.
- **Turf Score view**: Flat grid (`grid-cols-2 md:grid-cols-4`) of individual cards sorted by turf score. Uses `_matchup_card.html.erb` partial (local: `matchup`). Double-click "Turf Score" toggles asc/desc (arrow indicator). Two server-rendered orderings toggled via `x-show` (no JS re-sorting).
- Both views share the same Alpine `selections` state — selections persist across view switches.
- **Filter input**: Text input in the sort toolbar filters matchup cards by team name (both teams). Uses `matchesFilter()` Alpine method with `x-show` on wrapper divs. Clear X button appears when text is entered.

### Matchup Card Layout
Flag emoji (3xl) → Team name (bold, lg/xl) → Turf Score number (primary, 2xl/3xl, no prefix, integers without decimal) → "Points / Goal" label (singular "Point" when turf score is 1) → Game info line (tiny, both teams' emojis + short names, e.g. "🇪🇸 ESP vs CPV 🇨🇻"). Cards use `rounded-2xl`. Standalone cards have `w-full` to fill grid cells. Auto-shrink JS for long team names.

### `.matchup-selected` class
Uses `outline` (not border) for selection highlight — avoids layout shift. Dynamic primary color via `rgb(var(--color-primary-rgb))`. Includes `box-shadow` glow. Double-selected game pairs use inline `outline` + `box-shadow` on the wrapper div.

## Cart
- **Cart slot cards** (`_turf_totals_cart_slots.html.erb`): Emoji + Team Name + "vs OPP" on first line, "Goals" + turf score on second line.
- `pickOrder` array in Alpine state controls display order (insertion order)
- "Clear All" button clears selections locally + abandons entry server-side
- Blur overlay fires once per page load (`blurUsed` flag)

## Long-Press Button

`_hold_button.html.erb` — reusable partial with four states:
- **idle** (green) → **holding** (`.process`, mint glow builds) → **success** (`.success`, mint gradient + checkmark) or **error** (`.error`, red background)
- After hold completes, stays in `.process` for 500ms while resolving before transitioning to success or error
- Params: `default_text`, `hold_text`, `success_text`, `error_text`, `duration`, `hold_id`, `guard`, `on_success`, `validate`, `validate_at`
- The `on_success` callback sets the final state via `setHoldSuccess()` or `setHoldError()`
- Renders in both desktop + mobile cart (2 DOM elements, differentiated by `hold_id`)
- **CSS**: All hold button styles (`.hold-btn`, state classes, keyframes) live in `application.tailwind.css` using CSS variables (`--color-cta`, `--color-danger`, `--color-page`). Duration passed via inline `style="--duration: Xms"`.
- **JS**: Inline in the partial (uses ERB interpolation for callbacks). Not extracted to importmap.

### Hold Validation
Optional mid-hold validation via `validate`/`validate_at` params. `validate` is a JS expression returning `Promise<boolean>`, called at `validate_at` ms (default 1000). If false, hold aborts. Both buttons use `validate: "d.runHoldValidations()"` which checks geo-blocking (fresh `GET /geo/check`) then login status.

### Nudge Animation
JS-driven, big nudge at 3s then soft nudge every 10s. Resets on hold, soft-only after release.

## Pick Slot Animations
- `pick-pulse` (gentle glow, picks 3-4)
- `pick-pulse-shimmer` (glow + sweep, picks 2 and 5)
- `pick-pulse-urgent` (fast intense glow + scale + sweep, pick 5 after removal)
- `pickUrgent` flag set when going from 5→4 selections, cleared when reaching 5 again or clearing all

## Redirect Modal
When hold-to-confirm hits a blocker (geo-blocked, not logged in, insufficient funds), a centered modal appears with icon, title, message, progress bar countdown (5s), and CTA button. Hold button flips to red `.error` state ("Entry Blocked").
- Geo-blocked → "Location Restricted" → `/`
- Not logged in → "Log In Required" → `/login`
- Insufficient funds → "Insufficient Funds" / "Top Up Wallet" → `/wallet`
- `showRedirectModal(title, message, icon, url, seconds, cta)` method on Alpine component

## Navbar

Extracted to `layouts/_navbar.html.erb` partial. Sticky, scroll-responsive. Full-width `sticky top-0 z-50 bg-page` with Alpine `scrolled` state using hysteresis (scrolls past 30px to compact, back below 5px to expand — prevents jittery toggling). On scroll: header adds `is-scrolled` class + `shadow-lg border-b border-subtle`, logo shrinks `w-12→w-8` (mobile: `w-10`), title `text-3xl→text-xl`, padding `py-6→py-2`. All transitions 300ms via `transition-all duration-300`.

### Partial locals
- `show_logged_in` — override `logged_in?` (default: real session). Used by admin preview to force logged-in/out views.
- `preview` — disables scroll handler and sticky positioning. Uses static Tailwind classes instead of Alpine `x-bind:class` bindings.

### Responsive breakpoints
Custom `<style>` block in `<header>` with three tiers. Mobile title stacks "Turf"/"Totals" vertically via `flex-direction: column` with `-4px` bottom margin on "Turf" to tighten spacing. "Totals" renders larger than "Turf" on mobile.

| Range | `.user-nav-col` | `.nav-title` | `.nav-title span:last-child` | Notes |
|---|---|---|---|---|
| **< 400px** | 14rem | 1.1rem | 1.3rem | Gap 0.25rem on logo link |
| **400–767px** | 15rem | 1.25rem | 1.5rem | Gap 0.5rem on logo link |
| **768px+** | 20rem | Alpine `text-3xl`/`text-xl` | — | Side-by-side title, no stacking |

Scrolled state on mobile (via `.is-scrolled` ancestor):
| Range | `.nav-title` | `span:last-child` | `.nav-logo` |
|---|---|---|---|
| **< 400px** | 0.9rem | 1rem | 2.5rem (w-10) |
| **400–767px** | 1rem | 1.15rem | 2.5rem (w-10) |

### Left side
Logo (`.nav-logo`) + "Turf Totals" brand title (`.nav-title` with two `<span>`s), desktop nav links (`hidden md:flex`: Contests, Rules, geo badge).

### Mobile sub-navbar
`flex md:hidden` compact row below main nav with `bg-surface-alt border-t border-subtle`. Contains: Contests, Rules, geo badge. Admin dropdown + theme toggle morph pushed right via `ml-auto`.

### Environment banner
Lives in `application.html.erb`, **not** in the navbar partial. Conditional on `Solana::Config.devnet?`. Full-width yellow bar (`bg-yellow-500 text-black`) above the sticky header. Contains: centered "X Environment" label, right-aligned DEV MODE toggle + DEVNET badge. Not sticky — scrolls away naturally. The DEV MODE toggle uses `$store.devMode` (see Dev Mode section).

### Geo badge
Extracted to `_geo_badge.html.erb` partial — shared by desktop nav and mobile sub-navbar. State flag image uses inline styles for reliable sizing (`height: 12px; width: 16px; object-fit: cover`). Badge shape is `rounded-lg`.

### Right side — logged in: two-row block + avatar
- **Row 1 (Div 1)**: balance, gear + theme toggle morph (left of username, `hidden md:flex`), username. On mobile, gear + morph shown in sub-navbar instead. `padding-right: 6px` via inline style.
- **Row 2 (Div 2)**: 5-section seeds progress bar via `render "components/seeds_bar", compact: true` (turf-vault v0.9.0+ refactor — replaced the old `.seeds-bar`/`.seeds-fill`/`.seeds-text` classes). The partial uses the `.seeds-bar-continuous` class + CSS-registered `--bar-progress` custom property so all 5 segment widths interpolate from a single transition (one ease curve, not 5 chained). Per-section shimmer overlays positioned in bar coordinates (`left: -(i-1)*100%, width: 500%`) keep the wave continuous across segments. Wallet address (left) + Level X (right) overlaid via two-layer clip-path text technique (muted underneath, white on top revealed by `clip-path: inset(0 (100-displaySeeds)% 0 0)`). Level-up: `bar → 100% → bump level (.nav-level-pop) → drain → refill`. Listens for `navbar-replay-level` and `navbar-seeds-update` window events.
- **Avatar**: `_avatar.html.erb` partial (size "nav" = `w-8 h-8`), outside the two-row block. Links to `/account`.
- Balance shows whole dollars only (no cents) — JS `refreshBalance` uses `Math.floor`, ERB uses `.to_i`.
- Username and balance link to `/account` and `/wallet` respectively. Both use `transition-all duration-300` for smooth scroll-responsive font-size changes.
- **Username overflow fade**: `.username-cap` class sets responsive `max-width` (5rem tiny, 6rem small, 7rem desktop). When text overflows, Alpine applies a CSS `mask-image` gradient to fade the trailing edge. Overflow is recalculated when the navbar review page's username input changes.
- User nav column has `pl-0 pr-4 md:px-4` — no left padding on mobile.

### Right side — logged out
- Theme toggle morph (`hidden md:flex`) + green "Log in" button, right-aligned. Theme toggle morph appears in mobile sub-navbar instead.

## Theme Toggle Morph (Spinner Swap)

`components/_theme_toggle_morph.html.erb` (engine partial) — dark mode toggle and loading spinner share the same 16x16 space. Two absolutely-positioned elements with `transition-all duration-300` cross-fade via `transform: scale() rotate()` + `opacity`.

- **Default state**: Toggle visible (`scale(1) rotate(0deg) opacity(1)`), spinner hidden (`scale(0) rotate(-90deg) opacity(0)`)
- **Loading state**: Toggle hidden, spinner visible — triggered by `showNavSpinner()` global function
- **After loading**: Spinner hides, toggle returns — triggered by `hideNavSpinner()` with 2.5s minimum display time

**Global JS** (in engine `_head.html.erb`): `showNavSpinner()` records `Date.now()`, `hideNavSpinner()` calculates remaining time from the 2.5s minimum and uses `setTimeout` to delay the hide. Both target `.nav-toggle-icon` and `.nav-spinner-icon` class elements.

**Usage**: Gear dropdown "Refresh Balance" calls `showNavSpinner(); refreshBalance().finally(function() { hideNavSpinner(); })`. Auto-refresh on devnet uses the same pattern.

## Leaderboard (Contest Show)
Selection badges are fixed-width (`w-28`), sorted by game kickoff time, showing turf score (e.g., `x4`) before game completes and points (goals x turf score) after. Badges float right with score rightmost (`min-width: 4.5rem`). Non-integer values show decimal portion in smaller font. Payout label (`$40.00`) appears on left (after player name) only before settling. Admin payout button says "Payout $X". After settling — paid rows get primary ring, divider line after last paid position, unpaid rows dimmed. Rank column shows actual rank (from entry.rank) when settled.

## Faucet Page (`/faucet`)
Public marketing page with hero, "How It Works" cards, and USDC claim form. Mints SPL USDC tokens directly to user's Phantom wallet via `Vault#mint_spl(to: wallet)`. Three view states: wallet connected (amount picker + claim), logged in no wallet (connect CTA), logged out (login/signup CTAs). Preset amounts $10/$50/$100/$500, custom input $1-$500.

## Solana Modal
`shared/_solana_modal.html.erb` — Alpine.js store (`Alpine.store('solanaModal')`) for onchain operation feedback. Three states: processing (spinner), success (checkmark + TX link + confetti), error (red icon + message). Uses `canvas-confetti` CDN library (`confetti.browser.min.js`) — `fireSuccessConfetti()` fires 4 bursts (center, left cannon, right cannon, delayed shower) on success state via `$watch`.

## Admin Dropdowns
- **Soccer dropdown** (`components/_soccer_dropdown.html.erb`): Soccer ball emoji trigger, links to Teams and Games pages.
- **Admin dropdown** (`components/_admin_dropdown.html.erb`): Gear icon. Links: Faucet (non-prod only), Refresh Balance (triggers spinner morph), Slates, Slate Manager, Teams, Games, Formula, Formula Defaults, Treasury, Transactions, Navbar, Theme, Toast Test, Schema, Geo Settings, Error Logs, Jobs, Simulate WA, Replay Level (dispatches `navbar-replay-level` event), Reset Contest.

## Dev Mode
- **Toggle**: DEV MODE button in the environment banner (top of page, devnet only). Highlights `bg-primary text-white` when active, subtle `bg-black/20` when off.
- **Store**: Global `Alpine.store('devMode')` persisted to `localStorage`, initialized on `alpine:init`
- **Body class**: `<body>` gets `.dev-mode` class when active — use `.dev-mode .your-class` for CSS-only debug visuals

### Debug Color Classes (`dm-*`)
Reusable CSS classes in `application.tailwind.css` that show colored backgrounds only when dev mode is active. Each uses 75% opacity so overlapping components blend visually. Just add the class to any element — no Alpine bindings needed.

| Class | Color | RGB |
|-------|-------|-----|
| `.dm-blue` | Cornflowerblue | `rgba(100, 149, 237, 0.75)` |
| `.dm-green` | Lightgreen | `rgba(144, 238, 144, 0.75)` |
| `.dm-orange` | Sandybrown | `rgba(244, 164, 96, 0.75)` |
| `.dm-salmon` | Lightsalmon | `rgba(250, 128, 114, 0.75)` |
| `.dm-purple` | Purple | `rgba(128, 0, 128, 0.75)` |
| `.dm-coral` | Lightcoral | `rgba(240, 128, 128, 0.75)` |
| `.dm-yellow` | Khaki | `rgba(240, 230, 140, 0.75)` |
| `.dm-teal` | Paleturquoise | `rgba(175, 238, 238, 0.75)` |

**Current assignments** (navbar only):
- `_navbar.html.erb`: "Turf"=`dm-salmon`, "Totals"=`dm-yellow`, desktop nav=`dm-teal`, user-nav-col=`dm-purple`, mobile sub-nav=`dm-coral`, balance=`dm-blue`
- `_user_nav.html.erb`: gear+morph=`dm-teal`, username=`dm-coral`, seeds bar container=`dm-orange`, avatar link=`dm-green`
- `_navbar_seeds_bar.html.erb`: seeds bar wrapper=`dm-orange`

- **Current uses**:
  - Debug color classes (`dm-*`): layout boundary visualization on navbar/user nav components (see table above)
  - Hidden UI reveals: leaderboard entry debug details, seeds bar "Replay" link, XP slate "Replay" link (all via `x-show="$store.devMode"`)
  - CSS hook: `.dev-mode .nudge-debug { display: block; }` in `application.tailwind.css`
- **Adding new debug tools**: Use `x-show="$store.devMode" x-cloak` for Alpine-toggled elements. For layout debugging, add a `dm-*` class to the element — no other changes needed.

## Seeds XP Bar (`_slate_progress_xp.html.erb`)
- Progress bar showing seeds toward next level with animated fill, shimmer, and glow
- Bar fill uses 6px border-radius (not fully rounded)
- Level badge pops on level-up (3.2x scale bounce) with firework burst animation
- Firework: 72 particles explode radially from badge center using branding colors (green, violet, mint, orange, red)
- Level-up data stored in `localStorage('seedsLevelUp')` as JSON, consumed on next page load
- Sequence: fill bar to 100% → level pop + firework → reset bar → fill to new progress
- Dev mode "Replay" link simulates level-up for testing
- Contest show page saves seeds data to `seedsNavbar` localStorage for navbar bar
- Entry confirmation dispatches `navbar-seeds-update` custom event with seeds detail

## Login Page SSO
When SSO session available, blur overlay covers the entire card (`absolute inset-0 z-10, rounded-2xl`). The SSO "Continue as" button sits above the blur (`relative z-20`). Click-to-reveal fades out the blur (500ms transition) and focuses the email field. Uses `.backdrop-overlay` CSS class (defined in `application.tailwind.css`).

## Contest Show Layout
- Seeds progress bar and invite card rendered side-by-side on desktop (`flex gap-4 flex-wrap items-stretch` with `flex-1 basis-[300px]`), stacked on mobile.
- "+ Add Another Entry" button appears in the admin actions row (next to Lock Contest, Jump, Rank Matchups) rather than as a standalone section.

## Admin Preview Tools

### Navbar Review (`/admin/navbar`)
Admin page for visually comparing the navbar at all key breakpoints without resizing the browser. Route: `get "admin/navbar"` → `admin#navbar`. Linked from admin dropdown.

**Architecture**: Renders the `layouts/navbar` partial (with `preview: true`) inside `.navbar-preview` wrapper divs. Container-scoped CSS classes simulate responsive breakpoints at any viewport width — this is necessary because Tailwind/CSS media queries respond to the viewport, not the container.

**Breakpoint simulation classes** (on the `.navbar-preview` wrapper):
| Class | Range | Overrides |
|---|---|---|
| `.is-mobile .bp-tiny` | 320–399px | Hide `md:flex`, show `md:hidden`, stack title, 1.1rem font |
| `.is-mobile .bp-small` | 400–767px | Same visibility, stack title, 1.25rem font |
| `.is-desktop` | 768–1200px | Default responsive behavior |

**Interactive controls per breakpoint**:
- Width slider with range min/max matching the breakpoint range
- Device marker (vertical line at the device width: iPhone 15 390px, iPhone 16 Pro Max 430px, iPad Pro 13" 1032px)
- Reset button to snap to device width
- **Scrolled toggle**: Adds/removes `is-scrolled-preview` class on the wrapper with CSS transitions (0.3s). All scroll effects (padding, logo size, title size, balance size, header shadow) are CSS-only overrides — no DOM swapping. This ensures smooth animated transitions.

**Username override**: Text input at the top of the page temporarily overrides the displayed username in all previews (not persisted). Uses `data-username-display` attribute on the username link for targeting. On change, recalculates the overflow fade mask (`overflows` flag) so the gradient fade activates/deactivates at the correct `.username-cap` max-width per breakpoint.

**Sections**: Logged-In View + Pre-Login View, each with all three breakpoints. Deduplicated via loop over `[{ title:, show_logged_in: }]`.

**Key pattern**: When simulating responsive behavior in a preview container, use container-scoped CSS class selectors with `!important` rather than media queries. Add `transition` properties to the preview elements so state changes (like scrolled toggle) animate smoothly.

## CSS Refactoring Standards

### Inline style consolidation
- **2+ occurrences** → extract to a named CSS class in a `<style>` block (e.g., `font-size: 10px` × 4 → `.seeds-text`)
- **Component-scoped names**: Use descriptive prefixes tied to the component (e.g., `seeds-bar`, `seeds-fill`, `seeds-text` for the seeds progress bar)
- **One-off layout values** can stay inline (e.g., `max-width: 6rem`, `padding-right: 6px`) — don't create a class for a single use

### Dynamic vs static styles
- **Static properties**: Use CSS classes or Tailwind utilities
- **Alpine-controlled state**: Use `:style` bindings, but split from static properties. Don't mix static padding and conditional devMode background in one `:style` — use `style="..."` for static + `:style="..."` for dynamic
- **Scroll-responsive sizes**: Use Alpine `x-bind:class` with Tailwind size classes (e.g., `scrolled ? 'text-lg' : 'text-xl'`). Pair with `transition-all duration-300` to animate the change.

### Transitions
- **Matching durations**: All scroll-responsive elements use `0.3s` / `duration-300` — keep consistent across logo, title, padding, balance, username
- **`transition` vs `transition-all`**: Tailwind's `transition` only covers color/opacity/shadow/transform — does NOT include `font-size` or `width`. Use `transition-all duration-300` when Alpine toggles size classes, or explicit `transition: font-size 0.3s` in CSS.
- **Preview transitions**: Define transitions in the admin preview CSS (`.navbar-preview .nav-logo { transition: width 0.3s, height 0.3s; }`) since preview mode skips the Tailwind transition classes

### Admin preview CSS pattern
When building a component preview that needs to simulate responsive behavior:
1. Render the real partial with a `preview` flag that disables dynamic behavior (scroll handlers, sticky positioning)
2. Wrap in a container with breakpoint-simulation classes (e.g., `.is-mobile`, `.bp-tiny`)
3. Override Tailwind responsive utilities with `!important` on the container-scoped selectors
4. For state toggles (scrolled, hover), use CSS class toggling with transitions — never swap between two separate DOM renders (kills transitions)
5. Use higher-specificity selectors for state + breakpoint combinations (e.g., `.bp-tiny.is-scrolled-preview .nav-title` beats `.is-scrolled-preview .nav-title`)
