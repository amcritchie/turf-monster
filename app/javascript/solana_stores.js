// Solana Alpine stores — module supplement
// The solanaModal store, solanaWalletConnect, and fireSuccessConfetti are registered
// inline in application.html.erb (before Alpine) to avoid module timing issues.
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
