// Shared Solana/crypto utilities — fetch helpers, balance refresh, confetti colors
// Base58 encode/decode lives in base58.js (canonical source, loaded before this module)

// Deduplication-safe fetch — prevents concurrent requests for the same key
const _lockedKeys = {};
export function lockedFetch(key, url, opts) {
  if (_lockedKeys[key]) return Promise.resolve(null);
  _lockedKeys[key] = true;
  return fetch(url, opts).finally(function() { delete _lockedKeys[key]; });
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

// Confetti color palette — shared across solana modal & seeds bar
export const CONFETTI_COLORS = ['#4BAF50', '#8E82FE', '#06D6A0', '#FF7C47', '#FFD700', '#00BFFF', '#FF6B9D', '#C084FC'];

// Attach to window for backward compatibility with inline scripts/onclick handlers
window.lockedFetch = lockedFetch;
window.refreshBalance = refreshBalance;
window.refreshBalanceDelayed = refreshBalanceDelayed;
window.updateNavTokens = updateNavTokens;
window.animateFreeEntryBadge = animateFreeEntryBadge;
window.CONFETTI_COLORS = CONFETTI_COLORS;
