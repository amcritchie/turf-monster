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
// See docs/UI_PATTERNS.md → "State Fanout Pattern" for the handler contract
// and the table of currently-registered keys.

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
//   { seeds_earned?, seeds_total, seeds_level? }
//   - `seeds_earned` is preferred for a precise animation delta.
//   - `seeds_total` alone is accepted as a reconciliation snapshot; the handler
//     derives a positive delta from the cached navbar total when possible.
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
function cachedSeedsTotal() {
  try {
    var cached = JSON.parse(localStorage.getItem("seedsNavbar") || "null");
    if (!cached || cached.seeds_total === undefined || cached.seeds_total === null) return null;
    var total = Number(cached.seeds_total);
    return Number.isFinite(total) ? total : null;
  } catch (e) {
    return null;
  }
}

register("seeds", function (d, source, opts) {
  d = d || {};
  const hasEarned = d.seeds_earned !== undefined && d.seeds_earned !== null;
  const hasTotal = d.seeds_total !== undefined && d.seeds_total !== null;

  if (!hasEarned && !hasTotal) {
    console.log("[state-fanout][seeds] skipped", {
      source: source,
      reason: "no seed payload",
      payload: d
    });
    return;
  }

  const perLevel = opts.seedsPerLevel || 100;
  const total = Number(d.seeds_total || 0);
  const cachedTotal = cachedSeedsTotal();
  const earned = hasEarned
    ? Number(d.seeds_earned || 0)
    : Math.max(0, total - (cachedTotal === null ? total : cachedTotal));
  const level = d.seeds_level || (Math.floor(total / perLevel) + 1);
  const oldSeeds = earned > 0
    ? Math.max(0, total - earned)
    : Math.max(0, cachedTotal === null ? total : cachedTotal);
  const oldLevel = Math.floor(oldSeeds / perLevel) + 1;
  const newPct = Math.round((total % perLevel) / perLevel * 100);
  const towardNext = total % perLevel;
  const oldPct = Math.round((oldSeeds % perLevel) / perLevel * 100);
  const leveledUp = level > oldLevel;

  console.log("[state-fanout][seeds]", {
    source: source,
    earned: earned,
    total: total,
    cachedTotal: cachedTotal,
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
    // levelUp:true means a free entry was earned (crossed a SEEDS_PER_LEVEL
    // threshold). The LAYOUT owns the modal store and listens for this to pop
    // the free-entry-earned modal — state fanout stays UI-store-agnostic and
    // only signals the crossing here.
    const detail = leveledUp
      ? { levelUp: true,  oldLevel: oldLevel, oldPct: oldPct, newLevel: level, progress: newPct }
      : { levelUp: false, level:    level,    progress: newPct };
    window.dispatchEvent(new CustomEvent("navbar-seeds-update", { detail: detail }));
  }, dispatchDelay);
});

// ── cdp_ramp handler ──────────────────────────────────────────────────────
// Triggers: the cdp-ramp modal (cdpRampFlow._finish) and the /cdp/*/return
//   pages when a Coinbase onramp/offramp session reaches a terminal local
//   status (success / failed / expired / abandoned).
// Payload: { direction, status, partner_user_ref, tx_hash?, sent_signature? }
// localStorage: none — the navbar USDC pill is server-cache-backed;
//   refreshBalance() owns both the pill ([data-balance-display]) and
//   $store.session.usdcCents, so there is no client cache key to write.
// Balance refresh: a successful onramp landed USDC in the wallet; a sent
//   offramp moved USDC out (even a late send that CDP marks failed —
//   sent_signature present means the transfer happened). The server-side
//   USDC read is cached for 60s and has no bust hook from this path, so a
//   second refresh fires after the TTL to converge the navbar to truth.
// Event dispatched:
//   cdp-ramp-update — detail { direction, status, partnerUserRef, txHash }
//   for any long-lived component that wants to react without a reload.
register("cdp_ramp", function (d, source, opts) {
  d = d || {};
  console.log("[state-fanout][cdp_ramp]", {
    source: source,
    direction: d.direction,
    status: d.status,
    partner_user_ref: d.partner_user_ref,
    tx_hash: d.tx_hash
  });

  var movedFunds = d.status === "success" || !!d.sent_signature;
  if (movedFunds && typeof window.refreshBalance === "function") {
    window.refreshBalance();
    setTimeout(function () { window.refreshBalance(); }, 61000); // server cache TTL 60s
  }

  const dispatchDelay = opts.dispatchDelay !== undefined ? opts.dispatchDelay : 0;
  setTimeout(function () {
    window.dispatchEvent(new CustomEvent("cdp-ramp-update", {
      detail: {
        direction: d.direction,
        status: d.status,
        partnerUserRef: d.partner_user_ref,
        txHash: d.tx_hash
      }
    }));
  }, dispatchDelay);
});

// Attached to window so inline x-data callers (selectionBoard etc.) can
// reach it. Alpine processes x-data before importmap modules load, but the
// handlers here are only INVOKED from event callbacks (e.g. confirmEntry
// after Hold-to-Confirm completes), so the module is reliably loaded by
// the time apply() runs.
window.StateFanout = { apply, register };
