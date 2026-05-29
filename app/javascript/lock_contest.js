// Lock a contest via Phantom (web3). Admin-only. set_contest_lock_time is a
// 1-of-3 vault op and the admin's Phantom wallet is itself a vault signer, so a
// single Phantom signature authorizes it — no co-signer needed (unlike the
// 2-of-3 cosign flow). Mirrors the entry sign flow: the server builds a TX
// (bot pays the fee, our Phantom signs the admin slot), we sign + broadcast,
// then tell the server to mirror starts_at (chain is master).
//
// Status + errors render through the shared transaction modal
// (Alpine.store('solanaModal')), the same one the entry flow uses — never alert().
//
// Usage from a button: onclick="lockContestViaPhantom('<slug>', 30)"
//   inSeconds = 0 → "lock now"; 30 → schedule the lock 30s out (testing aid).
window.lockContestViaPhantom = async function (slug, inSeconds) {
  const modal = window.Alpine && Alpine.store("solanaModal");
  const fail = (msg, title) => {
    if (modal) {
      if (!modal.visible) modal.show(title || "Lock Failed", "");
      modal.error(msg, title || "Lock Failed");
    } else {
      alert(msg);
    }
  };

  const provider = window.solana;
  if (!provider?.isPhantom) {
    fail("Phantom wallet is required to set a contest lock.", "Wallet Required");
    return;
  }

  const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
  const rpcUrl = document.body.dataset.solanaRpcUrl || "https://api.devnet.solana.com";

  try {
    if (modal) modal.show("Preparing Lock", "Building the lock transaction...");

    const resp = await provider.connect();
    const pubkeyB58 = resp.publicKey.toBase58();
    const sessAddr = window.Alpine && Alpine.store("session") && Alpine.store("session").address;
    if (sessAddr && pubkeyB58 !== sessAddr) {
      fail(
        "Wrong wallet connected. Switch to " + sessAddr.substring(0, 8) + "..., or reconnect on the Account page.",
        "Wrong Wallet"
      );
      return;
    }

    // 1. Server builds the set_contest_lock_time TX (bot fee payer + Phantom
    //    admin-signer placeholder). Returns the lock_timestamp it encoded.
    const prep = await fetch(`/contests/${slug}/prepare_lock_time`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
      body: JSON.stringify({ in_seconds: inSeconds }),
    });
    const prepData = await prep.json();
    if (!prep.ok || !prepData.success) {
      fail(prepData.error || prep.statusText || "Failed to prepare lock");
      return;
    }

    // 2. Phantom fills its signature slot.
    if (modal) modal.show("Sign Transaction", "Approve the lock in your wallet...");
    const txBytes = Uint8Array.from(atob(prepData.serialized_tx), (c) => c.charCodeAt(0));
    const tx = solanaWeb3.Transaction.from(txBytes);
    const signed = await provider.signTransaction(tx);

    // 3. Broadcast + confirm.
    if (modal) modal.show("Confirming Onchain", "Submitting transaction to Solana...");
    const connection = new solanaWeb3.Connection(rpcUrl, "confirmed");
    const signature = await connection.sendRawTransaction(signed.serialize(), {
      skipPreflight: true,
      maxRetries: 3,
    });

    if (modal) modal.show("Confirming Onchain", "Waiting for Solana confirmation...");
    await Promise.race([
      connection.confirmTransaction(signature, "confirmed"),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error("Confirmation timed out after 60s")), 60000)
      ),
    ]);

    // 4. Mirror starts_at server-side — only after the chain confirms.
    if (modal) modal.show("Saving Lock", "Recording the lock time...");
    const conf = await fetch(`/contests/${slug}/confirm_lock_time`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
      body: JSON.stringify({ tx_signature: signature, lock_timestamp: prepData.lock_timestamp }),
    });
    const confData = await conf.json();
    if (!conf.ok || !confData.success) {
      fail(confData.error || "Server confirmation failed", "Lock Failed");
      return;
    }

    // Success — reload so the live countdown + admin controls reflect the new
    // lock. (The shared modal's success card is entry-specific — seeds + lobby
    // CTA — so we don't use it here; the ticking countdown is the confirmation.)
    if (modal) modal.show("Lock Set", "Refreshing…");
    window.location.reload();
  } catch (err) {
    console.error("Lock failed:", err);
    fail(err.message || String(err), "Lock Failed");
  }
};
