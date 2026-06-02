// Cosign transaction — admin treasury co-signing via Phantom
// Extracted from admin/pending_transactions/index.html.erb

window.cosignTransaction = async function(slug, serializedTx) {
  const provider = window.solana;
  if (!provider?.isPhantom) {
    alert("Phantom wallet is required to co-sign transactions.");
    return;
  }

  var configEl = document.getElementById('cosign-config');
  var rpcUrl = configEl ? configEl.dataset.rpcUrl : 'https://api.devnet.solana.com';
  var csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;

  try {
    await provider.connect();

    // Decode the partially-signed TX from base64
    const txBytes = Uint8Array.from(atob(serializedTx), c => c.charCodeAt(0));
    const tx = solanaWeb3.Transaction.from(txBytes);

    // Phantom signs (adds cosigner signature)
    const signed = await provider.signTransaction(tx);

    // Submit to Solana, then HTTP-poll getSignatureStatuses (no WebSocket
    // subscription, no misleading "unknown" timeout) instead of confirmTransaction.
    const connection = new solanaWeb3.Connection(rpcUrl);
    const signature = await connection.sendRawTransaction(signed.serialize());
    await window.pollConfirmation(rpcUrl, signature);

    // Report back to server
    const resp = await fetch('/admin/pending_transactions/' + slug + '/confirm', {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
      body: JSON.stringify({
        tx_signature: signature,
        cosigner_address: provider.publicKey.toBase58()
      })
    });

    if (resp.ok) {
      window.location.reload();
    } else {
      const data = await resp.json();
      alert("Server confirmation failed: " + (data.error || "Unknown error"));
    }
  } catch (err) {
    console.error("Co-sign failed:", err);
    alert("Co-signing failed: " + err.message);
  }
};
