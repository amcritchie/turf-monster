// StateFanout — standardized bridge from "server confirmed an on-chain state
// change" to "client UI catches up". One call site, three things happen:
//
//   1. localStorage write — keeps the cached value the navbar/seeds-bar/etc.
//      read on the NEXT page render in sync with the chain.
//   2. window event dispatch — lets long-lived Alpine components animate to
//      the new value WITHOUT a page reload.
//   3. Structured console log — pairs with the server-side
//      `[entry][confirmed]` (or whichever action triggered the fanout) so
//      LogRocket replays + Sentry breadcrumbs make staleness triage tractable
//      in prod. The `source` discriminator says which code path triggered it
//      (e.g. `phantom-direct` vs `managed-wallet` for the seeds handler).
//
// Each on-chain state type registers a handler keyed by name. Adding a new
// type (tokens, usdc, username, …) means writing one new handler — the
// surface stays `window.StateFanout.apply(stateType, payload, opts)` for
// every caller.
//
// See CLAUDE.md → "State fanout pattern" for the full handler contract and
// the table of currently-registered keys.

const _handlers = {};

export function register(stateType, handler) {
  _handlers[stateType] = handler;
}

export function apply(stateType, payload, opts) {
  opts = opts || {};
  const handler = _handlers[stateType];
  if (!handler) {
    console.warn(
      "[state-fanout] unknown state type:", stateType,
      "(known:", Object.keys(_handlers).join(", ") + ")"
    );
    return;
  }
  const source = opts.source || "unknown";
  handler(payload, source, opts);
}

// ── seeds handler ─────────────────────────────────────────────────────────
// Triggers: /contests/:id/enter (managed-wallet), /confirm_onchain_entry
//   (phantom-direct), and any future flow that awards seeds (e.g.
//   level-up promos, referral rewards).
// Payload (from the server JSON response):
//   { seeds_earned, seeds_total, seeds_level? }
//   - `seeds_level` is optional; the handler derives it when missing.
// Required opts:
//   - seedsPerLevel — currently 100 (User::SEEDS_PER_LEVEL). Passed through
//     instead of hardcoded so the handler can survive a model-constant bump.
// localStorage writes:
//   - seedsNavbar     — read by the seeds_bar normalStart() self-heal path
//   - seedsLevelUp    — written ONLY when the entry crosses a level
//                       threshold; read once + cleared by the bar on next
//                       init() to play the level-up confetti animation.
// Event dispatched:
//   navbar-seeds-update — detail varies by level-up flag; the seeds_bar's
//   handleSeedsUpdate() handler reads `levelUp`, `level`/`oldLevel`/
//   `newLevel`, `oldPct`, and `progress`.
register("seeds", function (d, source, opts) {
  if (!d || !d.seeds_earned) {
    console.log("[state-fanout][seeds] skipped", {
      source: source,
      reason: "no seeds_earned",
      payload: d
    });
    return;
  }

  const perLevel = opts.seedsPerLevel || 100;
  const total = d.seeds_total || 0;
  const earned = d.seeds_earned || 0;
  const level = d.seeds_level || (Math.floor(total / perLevel) + 1);
  const oldSeeds = Math.max(0, total - earned);
  const oldLevel = Math.floor(oldSeeds / perLevel) + 1;
  const newPct = Math.round((total % perLevel) / perLevel * 100);
  const towardNext = total % perLevel;
  const oldPct = Math.round((oldSeeds % perLevel) / perLevel * 100);
  const leveledUp = level > oldLevel;

  console.log("[state-fanout][seeds]", {
    source: source,
    earned: earned,
    total: total,
    oldLevel: oldLevel,
    newLevel: level,
    leveledUp: leveledUp,
    newPct: newPct
  });

  try {
    localStorage.setItem("seedsNavbar", JSON.stringify({
      seeds_total: total,
      level:       level,
      toward_next: towardNext,
      progress:    newPct
    }));
    if (leveledUp) {
      localStorage.setItem("seedsLevelUp", JSON.stringify({
        oldLevel:  oldLevel,
        newLevel:  level,
        oldPct:    oldPct,
        oldToward: oldSeeds % perLevel
      }));
    }
  } catch (e) {
    console.warn("[state-fanout][seeds] localStorage write failed", e);
  }

  // Defer the navbar animation so the success modal's "+N seeds" card gets
  // its solo moment first; the navbar then plays catch-up. Override with
  // opts.dispatchDelay = 0 for tests / flows that don't show a modal.
  const dispatchDelay = opts.dispatchDelay !== undefined ? opts.dispatchDelay : 2000;
  setTimeout(function () {
    const detail = leveledUp
      ? { levelUp: true,  oldLevel: oldLevel, oldPct: oldPct, newLevel: level, progress: newPct }
      : { levelUp: false, level:    level,    progress: newPct };
    window.dispatchEvent(new CustomEvent("navbar-seeds-update", { detail: detail }));
  }, dispatchDelay);
});

// Attached to window so inline x-data callers (selectionBoard etc.) can
// reach it. Alpine processes x-data before importmap modules load, but the
// handlers here are only INVOKED from event callbacks (e.g. confirmEntry
// after Hold-to-Confirm completes), so the module is reliably loaded by
// the time apply() runs.
window.StateFanout = { apply, register };
