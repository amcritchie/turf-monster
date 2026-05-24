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
export async function authedFetch(url, opts) {
  var resp = await fetch(url, opts);
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
    // Keep data-token-count in sync so the click-to-show popover (Alpine
    // x-data in _user_nav.html.erb) reads the live count on each open
    // instead of the server-rendered snapshot from page load.
    badge.dataset.tokenCount = n;
  }
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

window.updateNavTokens = updateNavTokens;
window.animateFreeEntryBadge = animateFreeEntryBadge;
window.fireConfettiFromBadge = fireConfettiFromBadge;
window.fireConfettiFromModal = fireConfettiFromModal;
window.CONFETTI_COLORS = CONFETTI_COLORS;
