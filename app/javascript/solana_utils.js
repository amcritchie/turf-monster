// Shared Solana/crypto utilities — fetch helpers, balance refresh, confetti colors
// Base58 encode/decode lives in base58.js (canonical source, loaded before this module)

// Deduplication-safe fetch — prevents concurrent requests for the same key
const _lockedKeys = {};
export function lockedFetch(key, url, opts) {
  if (_lockedKeys[key]) return Promise.resolve(null);
  _lockedKeys[key] = true;
  return fetch(url, opts).finally(function() { delete _lockedKeys[key]; });
}

// Auth-aware fetch — wraps fetch() and surfaces server-side logouts.
// If the server returns 401 (cookie expired, CSRF mismatch, session cleared
// in another tab), the client's $store.session still thinks we're logged in.
// authedFetch flips $store.session to guest, closes any pending solanaModal,
// and opens the auth modal at the login step. Returns null on 401 so
// callers can short-circuit with `if (!resp) return;` instead of trying to
// parse a 401 body as a normal response.
//
// Debounced: a burst of parallel 401s only triggers one modal open.
var _sessionExpiredHandled = false;
var _rateLimitHandled = false;
export async function authedFetch(url, opts) {
  var resp = await fetch(url, opts);

  // Tier-1 "general" rate limit (rack-attack, rate-limit epic Phase 1): surface
  // the friendly wait modal with a Retry-After countdown and return null so the
  // caller short-circuits with `if (!resp) return;`. "auth"-tier 429s fall
  // through to the caller's own inline UX (they don't open this modal).
  // Debounced like the 401 path so a burst opens one modal.
  if (resp.status === 429 && (resp.headers.get('X-RateLimit-Tier') || 'general') === 'general') {
    if (!_rateLimitHandled) {
      _rateLimitHandled = true;
      setTimeout(function() { _rateLimitHandled = false; }, 1500);
      var retryAfter = parseInt(resp.headers.get('Retry-After'), 10) || 60;
      try {
        var rlModals = window.Alpine && Alpine.store && Alpine.store('modals');
        if (rlModals && rlModals.open) rlModals.open('rate-limit-general', { secondsLeft: retryAfter });
      } catch (e) {}
    }
    return null;
  }

  if (resp.status !== 401) return resp;
  if (_sessionExpiredHandled) return null;
  _sessionExpiredHandled = true;
  setTimeout(function() { _sessionExpiredHandled = false; }, 1500);
  try {
    var session = window.Alpine && Alpine.store && Alpine.store('session');
    if (session) { session.loggedIn = false; session.mode = 'guest'; }
  } catch (e) {}
  try {
    var sm = window.Alpine && Alpine.store && Alpine.store('solanaModal');
    if (sm && sm.close) sm.close();
  } catch (e) {}
  try {
    var modals = window.Alpine && Alpine.store && Alpine.store('modals');
    if (modals && modals.open) modals.open('auth', { mode: 'login' });
  } catch (e) {}
  return null;
}

// Poll getSignatureStatuses over HTTP until confirmed/finalized or error.
// Replaces web3.js connection.confirmTransaction, which opens a WebSocket
// signature subscription (auto-derived ws:// at port+1) and surfaces a
// misleading 30s "unknown" timeout. turf-monster has NO RPC proxy — the
// client already holds the api-keyed Helius URL (data-solana-rpc-url), so we
// POST JSON-RPC straight to it. ~1.5s interval, ~60s ceiling.
//   confirmed/finalized → resolves with the status object
//   st.err              → throws (tx failed on-chain)
//   timeout             → throws (tx may still land — check explorer)
export async function pollConfirmation(rpcUrl, sig, opts) {
  opts = opts || {};
  var intervalMs = opts.intervalMs || 1500;
  var timeoutMs  = opts.timeoutMs  || 60000;
  var deadline   = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    var resp = await fetch(rpcUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0', id: 1, method: 'getSignatureStatuses',
        params: [[sig], { searchTransactionHistory: true }]
      })
    });
    if (resp.ok) {
      var out = await resp.json();
      if (out.error) throw new Error('getSignatureStatuses RPC error: ' + JSON.stringify(out.error));
      var st = out.result && out.result.value && out.result.value[0];
      if (st) {
        if (st.err) throw new Error('Transaction failed on-chain: ' + JSON.stringify(st.err));
        var status = st.confirmationStatus;
        if (status === 'confirmed' || status === 'finalized') return st;
      }
    }
    await new Promise(function(r) { setTimeout(r, intervalMs); });
  }
  throw new Error('Confirmation timed out after ' + (timeoutMs / 1000) + 's (the transaction may still land — check the explorer).');
}
window.pollConfirmation = pollConfirmation;

// Balance display refresh
export function refreshBalance() {
  return lockedFetch('balance', '/admin/usdc_balance', {
    headers: { 'Accept': 'application/json' }, cache: 'no-store'
  })
    .then(function(r) { return r && r.json(); })
    .then(function(data) {
      if (!data) return;
      var formatted = '$' + Math.floor(parseFloat(data.balance));
      var isZero = formatted === '$0';
      var badge = document.querySelector('[data-free-entry-badge]');
      var badgeVisible = badge && !badge.classList.contains('hidden');
      document.querySelectorAll('[data-balance-display]').forEach(function(el) {
        el.textContent = formatted;
        // Same rule as server-side render: hide $0 when the user has
        // at least one free-entry token. _user_nav's 🎟️ badge already
        // signals their next-step affordance.
        if (isZero && badgeVisible) el.classList.add('hidden');
        else                        el.classList.remove('hidden');
      });
    })
    .catch(function() {});
}

export function refreshBalanceDelayed(ms) {
  var delay = ms || 10000;
  if (window.showNavSpinner) window.showNavSpinner();
  setTimeout(function() {
    refreshBalance().finally(function() {
      if (window.hideNavSpinner) window.hideNavSpinner();
    });
  }, delay);
}

// Single-call refresh of every on-chain piece the navbar shows: USDC
// balance, free-entry token count, and the seeds bar (count + level +
// progress). Server-side route is /account/session_refresh which fans
// the four Solana RPCs out in parallel; client-side this function then
// drives the existing UI updaters so the navbar converges to truth
// from one place.
//
// Call after any on-chain success path (entry confirm, token mint,
// token consume, withdrawal, payout) instead of stitching together
// refreshBalance + updateNavTokens + seedsNavbar/localStorage by hand.
// Returns a Promise so callers can chain a spinner around it.
export function refreshSession() {
  return lockedFetch('session', '/account/session_refresh', {
    headers: { 'Accept': 'application/json' }, cache: 'no-store'
  })
    .then(function(r) { return r && r.json(); })
    .then(function(data) {
      if (!data) return null;

      // Mirror the on-chain values into $store.session so the synchronous
      // entry-eligibility check (runHoldValidations / confirmEntry) sees
      // fresh state without an extra fetch. Dollars → cents at the boundary.
      // null in the response means "preload RPC flaked" — preserve the
      // store's prior value rather than overwriting with 0 (false-positive
      // block); see ApplicationController#wallet_field_cents.
      try {
        var sess = window.Alpine && Alpine.store && Alpine.store('session');
        if (sess) {
          if (data.usdc != null) sess.usdcCents = Math.round(parseFloat(data.usdc) * 100);
          if (data.usdt != null) sess.usdtCents = Math.round(parseFloat(data.usdt) * 100);
          sess.tokensAvailable = parseInt(data.tokens, 10) || 0;
        }
      } catch (_) {}

      // USDC balance — reuse the same data-balance-display selector +
      // hide-on-$0-with-token rule that refreshBalance applies, so the
      // two helpers agree on what the navbar shows.
      try {
        var formatted = '$' + Math.floor(parseFloat(data.usdc || 0));
        var isZero    = formatted === '$0';
        var hasTokens = (parseInt(data.tokens, 10) || 0) > 0;
        document.querySelectorAll('[data-balance-display]').forEach(function(el) {
          el.textContent = formatted;
          if (isZero && hasTokens) el.classList.add('hidden');
          else                     el.classList.remove('hidden');
        });
      } catch (_) {}

      // 🎟️ token badge — reuse updateNavTokens for the visibility
      // toggle + data-token-count + 'entry-tokens-updated' broadcast.
      try { updateNavTokens(data.tokens); } catch (_) {}

      // Seeds bar — write the canonical localStorage payload the
      // _seeds_bar Alpine factory reads on level-up animations, then
      // dispatch the same 'navbar-seeds-update' event the entry-confirm
      // flow uses so the bar transitions smoothly to the new value
      // instead of snapping on next reload.
      try {
        localStorage.setItem('seedsNavbar', JSON.stringify({
          seeds_total: data.seeds,
          level:       data.level,
          toward_next: data.toward_next,
          progress:    data.progress
        }));
        window.dispatchEvent(new CustomEvent('navbar-seeds-update', {
          detail: { levelUp: false, level: data.level, progress: data.progress }
        }));
      } catch (_) {}

      return data;
    })
    .catch(function() { return null; });
}

// Toggle the navbar's 🎟️ free-entry badge based on the new token count.
// Called after a mint (count increases) or a token-funded entry submit
// (count decrements). Also re-applies the "hide $0 balance when the
// user has any free-entry tokens" rule so the live state matches the
// server-side render.
export function updateNavTokens(balance) {
  var n = parseInt(balance, 10) || 0;
  var badge = document.querySelector('[data-free-entry-badge]');
  if (badge) {
    if (n > 0) badge.classList.remove('hidden');
    else       badge.classList.add('hidden');
    // Keep data-token-count in sync as a fallback for any consumer that
    // hasn't migrated to the reactive entryTokenBadge factory yet.
    badge.dataset.tokenCount = n;
  }
  // Broadcast so the entryTokenBadge Alpine factory (and any future
  // subscriber) updates its reactive count without polling the dataset.
  try {
    window.dispatchEvent(new CustomEvent('entry-tokens-updated', { detail: { count: n } }));
  } catch (_) {}
  // Balance link visibility — match the server-side rule.
  document.querySelectorAll('[data-balance-display]').forEach(function(el) {
    var isZero = (el.textContent || '').trim() === '$0';
    if (isZero && n > 0) el.classList.add('hidden');
    else                 el.classList.remove('hidden');
  });
}

// Fires the .free-entry-punch CSS animation on the 🎟️ badge — wired
// from confirmEntry's success path when the server reports the entry
// was funded by a consumed token (data.token_consumed === true).
export function animateFreeEntryBadge() {
  var badge = document.querySelector('[data-free-entry-badge]');
  if (!badge) return;
  badge.classList.remove('free-entry-punch'); // reset so a 2nd consume re-fires
  void badge.offsetWidth;                     // force reflow
  badge.classList.add('free-entry-punch');
  setTimeout(function() { badge.classList.remove('free-entry-punch'); }, 700);
}

// Confetti burst that originates from the 🎟️ Entry badge in the navbar.
// Used instead of the centered fireSuccessConfetti for token-flow
// celebrations (mint + entry confirmed) so the streamers shoot out of
// the badge the user just earned / consumed. Falls back to the top-
// right of the viewport when the badge isn't on screen (e.g. after a
// consume that dropped the count to 0 and hid the badge).
export function fireConfettiFromBadge() {
  if (typeof confetti === 'undefined') return;
  var badge  = document.querySelector('[data-free-entry-badge]');
  var rect   = badge && badge.getBoundingClientRect();
  var hidden = !rect || (rect.width === 0 && rect.height === 0);
  var origin = hidden
    ? { x: 0.92, y: 0.08 } // approximate badge slot in the top-right nav
    : {
        x: (rect.left + rect.width  / 2) / window.innerWidth,
        y: (rect.top  + rect.height / 2) / window.innerHeight
      };
  var colors = window.CONFETTI_COLORS || ['#4BAF50', '#8E82FE', '#06D6A0', '#FF7C47', '#FFD700', '#00BFFF', '#FF6B9D', '#C084FC'];
  // Radial pop from the badge center — spread:360 fires particles in
  // every direction (up, down, sideways), low startVelocity + low
  // gravity keep them clustered around the badge rather than blasting
  // off-screen. Reads like an "out of the ticket" celebration.
  confetti({ particleCount: 90, angle: 90, spread: 360, origin: origin, colors: colors, zIndex: 9999, startVelocity: 22, gravity: 0.55, ticks: 180, scalar: 0.9 });
  // Smaller follow-up shell, even tighter, for layered texture.
  setTimeout(function() {
    confetti({ particleCount: 45, angle: 90, spread: 360, origin: origin, colors: colors, zIndex: 9999, startVelocity: 14, gravity: 0.75, ticks: 140, scalar: 0.7 });
  }, 160);
}

// Confetti color palette — shared across solana modal & seeds bar
export const CONFETTI_COLORS = ['#4BAF50', '#8E82FE', '#06D6A0', '#FF7C47', '#FFD700', '#00BFFF', '#FF6B9D', '#C084FC'];

// Attach to window for backward compatibility with inline scripts/onclick handlers
window.lockedFetch = lockedFetch;
window.authedFetch = authedFetch;
window.refreshBalance = refreshBalance;
window.refreshBalanceDelayed = refreshBalanceDelayed;
window.refreshSession = refreshSession;
// Confetti burst that originates from the currently-open modal card —
// used for the entry-confirmation celebration where the user is looking
// at the modal, not the navbar badge. Targets the modal_host's
// max-w-sm card (role="dialog"); falls back to screen center if no
// modal is mounted.
export function fireConfettiFromModal() {
  if (typeof confetti === 'undefined') return;
  var card   = document.querySelector('[role="dialog"] > div') ||
               document.querySelector('[role="dialog"]');
  var rect   = card && card.getBoundingClientRect();
  var hidden = !rect || (rect.width === 0 && rect.height === 0);
  var origin = hidden
    ? { x: 0.5, y: 0.5 }
    : {
        x: (rect.left + rect.width  / 2) / window.innerWidth,
        y: (rect.top  + rect.height / 2) / window.innerHeight
      };
  var colors = window.CONFETTI_COLORS || ['#4BAF50', '#8E82FE', '#06D6A0', '#FF7C47', '#FFD700', '#00BFFF', '#FF6B9D', '#C084FC'];
  // Bigger, more spread-out burst than the badge version — the modal
  // is the focal point of the moment, give the celebration room.
  confetti({ particleCount: 140, angle: 90, spread: 360, origin: origin, colors: colors, zIndex: 9999, startVelocity: 30, gravity: 0.7, ticks: 220, scalar: 1.0 });
  // Sweep-up follow shells from the bottom corners for theatre.
  setTimeout(function() {
    confetti({ particleCount: 60, angle: 60, spread: 70, origin: { x: Math.max(0, origin.x - 0.18), y: Math.min(1, origin.y + 0.05) }, colors: colors, zIndex: 9999, startVelocity: 40, gravity: 0.9, ticks: 200, scalar: 0.9 });
    confetti({ particleCount: 60, angle: 120, spread: 70, origin: { x: Math.min(1, origin.x + 0.18), y: Math.min(1, origin.y + 0.05) }, colors: colors, zIndex: 9999, startVelocity: 40, gravity: 0.9, ticks: 200, scalar: 0.9 });
  }, 180);
}

// Synchronous entry-eligibility check against the running $store.session.
// Returns null if the viewer can submit, or { reason, mode, data } describing
// the blocker. The board's hold + submit paths use this immediately after
// their loggedIn / isGuest gate so we never let the user complete a hold
// against state we already know will fail server-side.
//
// neededCents is the contest entry fee. session is Alpine.store('session').
// Either-or USDC/USDT semantics for web3 — pass if EITHER mint covers fee.
export function eligibilityBlocker(session, neededCents) {
  if (!session) return null;            // store missing — let server decide
  if (!session.loggedIn) return { reason: 'not_logged_in', mode: 'guest', data: {} };
  if ((neededCents | 0) <= 0) return null;  // free contest

  if (session.mode === 'web2') {
    if ((session.tokensAvailable | 0) >= 1) return null;
    return { reason: 'no_tokens', mode: 'web2', data: {} };
  }
  if (session.mode === 'web3') {
    // Fail open when balances are unknown — the server-side enter is the
    // authoritative gate. preload_navbar_solana_data's balances_thread
    // returns nil on RPC flake, which client_session_payload now emits
    // as null (not 0). Without this branch the falsy-coalesce would
    // treat a flaky page-load as "user has $0" and false-positive block.
    if (session.usdcCents == null && session.usdtCents == null) return null;
    var usdc = session.usdcCents | 0;
    var usdt = session.usdtCents | 0;
    if (usdc >= neededCents || usdt >= neededCents) return null;
    return { reason: 'insufficient_balance', mode: 'web3',
             data: { usdcCents: usdc, usdtCents: usdt, neededCents: neededCents | 0 } };
  }
  return null;
}
window.eligibilityBlocker = eligibilityBlocker;

window.updateNavTokens = updateNavTokens;
window.animateFreeEntryBadge = animateFreeEntryBadge;
window.fireConfettiFromBadge = fireConfettiFromBadge;
window.fireConfettiFromModal = fireConfettiFromModal;
window.CONFETTI_COLORS = CONFETTI_COLORS;
