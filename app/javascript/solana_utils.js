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
      document.querySelectorAll('[data-balance-display]').forEach(function(el) {
        el.textContent = formatted;
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

// Entry-token count navbar swap — called after a mint or a token-funded
// entry submission so the navbar's token/USDC pair reflects the new count
// without a page reload. The navbar (_navbar.html.erb, managed-wallet
// branch) renders both links and hides one with the Tailwind `hidden`
// class; this helper updates the count and flips the visibility.
export function updateNavTokens(balance) {
  var span = document.querySelector('[data-token-balance-display]');
  var tokenLink = document.querySelector('[data-token-balance-link]');
  var usdcLink = document.querySelector('[data-usdc-balance-link]');
  if (!span || !tokenLink || !usdcLink) return; // not on a managed-wallet navbar
  var n = parseInt(balance, 10) || 0;
  span.textContent = n;
  if (n > 0) {
    tokenLink.classList.remove('hidden');
    usdcLink.classList.add('hidden');
  } else {
    tokenLink.classList.add('hidden');
    usdcLink.classList.remove('hidden');
  }
}

// Confetti color palette — shared across solana modal & seeds bar
export const CONFETTI_COLORS = ['#4BAF50', '#8E82FE', '#06D6A0', '#FF7C47', '#FFD700', '#00BFFF', '#FF6B9D', '#C084FC'];

// Attach to window for backward compatibility with inline scripts/onclick handlers
window.lockedFetch = lockedFetch;
window.refreshBalance = refreshBalance;
window.refreshBalanceDelayed = refreshBalanceDelayed;
window.updateNavTokens = updateNavTokens;
window.CONFETTI_COLORS = CONFETTI_COLORS;
