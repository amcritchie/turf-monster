// Cosign transaction — admin treasury co-signing via Phantom
// Extracted from admin/pending_transactions/index.html.erb
//
// Drives the shared on-chain transaction modal (Alpine.store('solanaModal'))
// so co-signing shows the same "Confirming…" → success/error experience as the
// contest create/entry flows. Uses the GENERIC success variant (admin treasury
// action — no entry-celebration confetti) and stays tx-type agnostic so every
// PendingTransaction type (settle_contest / sweep_operator_revenue / register_
// currency / …) gets the same copy. txTypeLabel is the already-titleized type
// string the view passes through (e.g. "Settle Contest", "Sweep Operator
// Revenue"); it falls back to a generic noun when absent.
//
// Confirmation is HTTP-polled via window.pollConfirmation (getSignatureStatuses)
// — never connection.confirmTransaction (the WebSocket "unknown" timeout bug
// Carl removed). Don't reintroduce it here.

window.cosignTransaction = async function(slug, serializedTx, txTypeLabel) {
  var label = (txTypeLabel && String(txTypeLabel).trim()) || 'Transaction';
  var modal = window.Alpine && Alpine.store('solanaModal');

  // Surface failures through the modal when it's available, else fall back to
  // alert() (e.g. modal store not yet registered). A blockhash-expired / send
  // failure tells the operator to hit Rebuild — that's the recovery for the
  // recent-blockhash expiry on this flow.
  var fail = function(rawMsg, opts) {
    opts = opts || {};
    var friendly = (window.parseSolanaError ? window.parseSolanaError(rawMsg) : rawMsg) || 'Unknown error';
    var title = opts.title || (label + ' Failed');
    var body = opts.body || friendly;
    if (modal) {
      if (!modal.visible) modal.show(title, '');
      modal.error(body, title);
    } else {
      alert(body);
    }
  };

  var provider = window.solana;
  if (!provider || !provider.isPhantom) {
    fail('Phantom wallet is required to co-sign transactions.', {
      title: 'Wallet Required',
      body: 'Phantom wallet is required to co-sign transactions.'
    });
    return;
  }

  var configEl = document.getElementById('cosign-config');
  var rpcUrl = configEl ? configEl.dataset.rpcUrl : 'https://api.devnet.solana.com';
  var csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;

  try {
    if (modal) modal.show('Co-signing ' + label, 'Approve the transaction in Phantom…');
    await provider.connect();

    // Decode the partially-signed TX from base64.
    var txBytes = Uint8Array.from(atob(serializedTx), function(c) { return c.charCodeAt(0); });
    var tx = solanaWeb3.Transaction.from(txBytes);

    // Phantom signs (adds cosigner signature). A user-reject throws here →
    // clean "Cancelled" message (parseSolanaError maps "user rejected").
    var signed;
    try {
      signed = await provider.signTransaction(tx);
    } catch (rejectErr) {
      var rejMsg = rejectErr && rejectErr.message ? rejectErr.message : String(rejectErr);
      if (/user rejected/i.test(rejMsg) || /user declined/i.test(rejMsg) || (rejectErr && rejectErr.code === 4001)) {
        fail(rejMsg, { title: 'Cancelled', body: 'You declined the co-signature in Phantom.' });
        return;
      }
      throw rejectErr;
    }

    // Broadcast, then HTTP-poll getSignatureStatuses (no WebSocket subscription,
    // no misleading "unknown" timeout) instead of confirmTransaction.
    if (modal) modal.show('Confirming Onchain', 'Submitting the transaction to Solana…');
    var connection = new solanaWeb3.Connection(rpcUrl);

    var signature;
    try {
      signature = await connection.sendRawTransaction(signed.serialize());
    } catch (sendErr) {
      // A send failure is most often an expired recent blockhash — tell the
      // operator the recovery is Rebuild, then retry. Don't leave the modal on
      // "Confirming…".
      var sendMsg = sendErr && sendErr.message ? sendErr.message : String(sendErr);
      fail(sendMsg, {
        title: label + ' Failed',
        body: 'Broadcast failed (the transaction blockhash may have expired). Close this, hit Rebuild on the transaction to refresh its blockhash, then co-sign again.'
      });
      return;
    }

    // Show the signature on the modal as soon as we have it (so the operator can
    // follow it on the explorer even while confirmation is still polling).
    if (modal) modal.txSignature = signature;

    try {
      await window.pollConfirmation(rpcUrl, signature);
    } catch (confirmErr) {
      var confMsg = confirmErr && confirmErr.message ? confirmErr.message : String(confirmErr);
      // Blockhash / expiry / timeout → Rebuild guidance; on-chain program error
      // → the parsed message.
      if (/blockhash/i.test(confMsg) || /block height exceeded/i.test(confMsg) || /timed out/i.test(confMsg)) {
        fail(confMsg, {
          title: label + ' Failed',
          body: 'The transaction did not confirm (its blockhash may have expired). Close this, hit Rebuild to refresh the blockhash, then co-sign again.'
        });
      } else {
        fail(confMsg, { title: label + ' Failed' });
      }
      return;
    }

    // Report back to the server — it semantic-verifies the on-chain TX before
    // flipping DB state (OPSEC-010/011).
    if (modal) modal.show('Recording ' + label, 'Confirming with the server…');
    var resp = await fetch('/admin/pending_transactions/' + slug + '/confirm', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken },
      body: JSON.stringify({
        tx_signature: signature,
        cosigner_address: provider.publicKey.toBase58()
      })
    });

    if (resp.ok) {
      if (modal) {
        // Generic success variant — admin treasury action, so NO entry
        // confetti. The "Back to Treasury" CTA reloads so the now-confirmed
        // row refreshes to its green Confirmed badge (the generic card's CTA
        // is a plain link with no auto-redirect drain). We also reload on a
        // bare Dismiss / backdrop close via onClose, but the CTA is the
        // reliable path across every dismiss route.
        modal.success(signature, 'Transaction confirmed on-chain.', {
          variant: 'generic',
          title: label + ' Confirmed',
          subtitle: 'The treasury transaction landed on-chain and has been recorded.',
          ctaLabel: 'Back to Treasury',
          ctaHref: window.location.pathname
        });
        modal.onClose = function() { window.location.reload(); };
      } else {
        window.location.reload();
      }
    } else {
      var data = {};
      try { data = await resp.json(); } catch (e) { /* non-JSON error body */ }
      fail(data.error || 'Server confirmation failed.', { title: label + ' Failed' });
    }
  } catch (err) {
    console.error('Co-sign failed:', err);
    fail(err && err.message ? err.message : String(err));
  }
};
