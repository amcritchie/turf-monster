// Phantom deep link protocol for mobile browsers
// Uses signIn deep link — ONE trip to Phantom (connect + sign combined)
// Flow: generate keypair → fetch nonce → build SIWS input → redirect to Phantom signIn

function startPhantomDeepLink(linkMode, currentUserId) {
  var cluster = document.body.dataset.solanaCluster || 'devnet';
  var callbackUrl = window.location.origin + '/auth/phantom/callback';

  // Generate x25519 keypair for decrypting Phantom's response
  var dappKeyPair = nacl.box.keyPair();

  // Fetch nonce from server, then redirect to Phantom signIn
  fetch('/auth/solana/nonce')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      // OPSEC-005: when linking a wallet to a logged-in user, embed
      // `User-ID: <id>` so the server can refuse signatures captured
      // against a different session's nonce. Login (no currentUserId)
      // skips the binding line.
      var statement = 'Sign in to Turf Monster';
      if (linkMode && currentUserId) {
        statement = statement + '\nUser-ID: ' + currentUserId;
      }

      // Build SIWS input (CAIP-122 / Sign In With Solana format)
      // Note: chainId omitted — optional per spec, avoids mismatch warning
      // when app is on devnet but user's wallet is on mainnet
      var signInInput = {
        domain: window.location.host,
        statement: statement,
        uri: window.location.origin,
        version: '1',
        nonce: data.nonce,
        issuedAt: new Date().toISOString()
      };

      // Save state to localStorage (persists across redirect)
      localStorage.setItem('phantom_dl_secret', encodeBase58(dappKeyPair.secretKey));
      localStorage.setItem('phantom_dl_pubkey', encodeBase58(dappKeyPair.publicKey));
      localStorage.setItem('phantom_dl_nonce', data.nonce);
      localStorage.setItem('phantom_dl_nonce_at', Date.now().toString());
      localStorage.setItem('phantom_dl_step', 'signIn');
      localStorage.setItem('phantom_dl_link_mode', linkMode ? 'true' : 'false');
      localStorage.setItem('phantom_dl_cluster', cluster);
      if (currentUserId) {
        localStorage.setItem('phantom_dl_user_id', String(currentUserId));
      } else {
        localStorage.removeItem('phantom_dl_user_id');
      }

      // Base58-encode the SIWS input JSON (NOT encrypted — per Phantom signIn protocol)
      var payloadB58 = encodeBase58(new TextEncoder().encode(JSON.stringify(signInInput)));

      // Build Phantom signIn deep link
      var params = new URLSearchParams({
        dapp_encryption_public_key: encodeBase58(dappKeyPair.publicKey),
        cluster: cluster,
        app_url: window.location.origin,
        redirect_link: callbackUrl,
        payload: payloadB58
      });

      window.location.href = 'https://phantom.app/ul/v1/signIn?' + params.toString();
    })
    .catch(function(err) {
      alert('Failed to start Phantom connection: ' + err.message);
    });
}

window.startPhantomDeepLink = startPhantomDeepLink;
