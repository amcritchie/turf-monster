// Solana Alpine stores — module supplement
// The solanaModal store, solanaConnectAndVerify/postMagicLink, and
// fireSuccessConfetti are registered inline in application.html.erb (before
// Alpine) to avoid module timing issues.
// This module registers the wallet watcher store (fine to load late).

function registerWalletStore() {
  if (typeof Alpine === 'undefined') return false;
  if (Alpine.store('wallet')) return true;

  // --- Wallet Watcher Store ---
  // Detects wallet switches and re-authenticates silently
  Alpine.store('wallet', {
    address: null,
    watching: false,

    init: function() {
      // Only WEB3 (live Phantom-signature) sessions may engage Phantom. A
      // web2/managed/guest user has a server-held keypair (or no wallet), so
      // probing Phantom — even silently with onlyIfTrusted — pops the unlock
      // prompt on an installed+previously-trusted extension on EVERY page
      // load. Gate on the canonical session mode (the #session-context JSON,
      // the same source Alpine.store('session') hydrates from) read directly,
      // so this is correct regardless of alpine:init store-registration order.
      if (!this._isWeb3Session()) return;

      var provider = window.walletProvider.detect();
      var serverAddr = this._serverAddress();
      if (!provider || !serverAddr) return;

      var self = this;

      // Silent probe — detect current wallet without popup
      provider.connect({ onlyIfTrusted: true })
        .then(function(resp) {
          self.address = resp.publicKey.toBase58();
          if (self.address !== serverAddr) {
            self._reauth(self.address);
          }
        })
        .catch(function() {}); // Intentional: wallet not yet approved by user — no action needed

      // Listen for wallet switches (Phantom-specific, no-op for keypair)
      provider.on('accountChanged', function(publicKey) {
        if (publicKey) {
          var newAddr = publicKey.toBase58();
          self.address = newAddr;
          if (newAddr !== self._serverAddress()) {
            self._reauth(newAddr);
          }
        } else {
          window.location.href = '/logout';
        }
      });

      this.watching = true;
    },

    _serverAddress: function() { return document.body.dataset.walletAddress || ''; },

    // True only for a live Phantom-signature (web3) session. Reads the
    // canonical session mode from the server-rendered #session-context JSON
    // (SessionContext#to_h → { mode: 'web3' | 'web2' | 'guest', ... }) rather
    // than the Alpine session store, so it doesn't depend on which store
    // registered first during alpine:init. Falls back to the store, then to
    // false (never engage Phantom on unknown/managed sessions).
    _isWeb3Session: function() {
      try {
        var el = document.getElementById('session-context');
        if (el) return JSON.parse(el.textContent).mode === 'web3';
      } catch (e) { /* fall through to store / safe default */ }
      var s = (typeof Alpine !== 'undefined' && Alpine.store) ? Alpine.store('session') : null;
      return !!(s && s.mode === 'web3');
    },

    _reauth: function(pubkeyB58) {
      var provider = window.walletProvider.detect();
      if (!provider) return;
      fetch('/auth/solana/nonce')
        .then(function(r) { return r.json(); })
        .then(function(data) {
          var nonce = data.nonce;
          var domain = window.location.host;
          var message = domain + ' wants you to sign in with your Solana account:\n' + pubkeyB58 + '\n\nSign in to Turf Monster\n\nNonce: ' + nonce;
          var encoded = new TextEncoder().encode(message);
          return provider.signMessage(encoded, 'utf8').then(function(signed) {
            var signatureB58 = encodeBase58(signed.signature);
            var csrf = document.querySelector('meta[name="csrf-token"]')?.content || '';
            return fetch('/auth/solana/verify', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf },
              body: JSON.stringify({ message: message, signature: signatureB58, pubkey: pubkeyB58 })
            });
          });
        })
        .then(function(r) { return r.json(); })
        .then(function(result) {
          if (result.success) {
            window.handleSolanaVerifySuccess(result);
            window.location.reload();
          }
        })
        .catch(function(err) { console.warn('Wallet re-auth failed:', err); });
    }
  });

  return true;
}

// Register wallet store — Alpine is available by module execution time
if (!registerWalletStore()) {
  document.addEventListener('alpine:init', function() { registerWalletStore(); });
}
