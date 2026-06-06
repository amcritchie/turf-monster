// Username rename form — modal x-data factory.
//
// Mixes three wire paths the previous inline version blurred:
//   1. POST updateUrl → server decides custodial vs phantom path
//   2. (phantom only) deserialize + sign + broadcast + confirm the TX
//   3. POST confirmUrl with the resulting tx_signature
//
// The Phantom path now uses document.body.dataset.solanaRpcUrl (same
// env-driven source as the entry-flow boards — see Tier 1 audit fix).
// Fetches go through authedFetch so a 401 surfaces the login modal
// instead of throwing a generic error into the form.
//
// opts:
//   initialUsername: server-rendered current username
//   updateUrl:       POST endpoint that returns either { success } (server-
//                    cosigned custodial flow) or { needs_signature,
//                    serialized_tx, token } (Phantom flow)
//   confirmUrl:      POST endpoint to call after Phantom sign + broadcast
//                    with { token, tx_signature }
//   initialSaving:   gallery-only — start in the "Saving…" state for the
//                    modals-index preview (no real request runs)

function usernameRenameForm(opts) {
  opts = opts || {};
  return {
    initial: opts.initialUsername || "",
    username: opts.initialUsername || "",
    saving: !!opts.initialSaving,
    // Phase-aware label shown beside the CTA spinner during a real save.
    savingLabel: "Saving…",
    error: null,

    get changed() {
      return this.username && this.username !== this.initial;
    },

    async save() {
      if (!this.changed || this.saving) return;
      this.saving = true;
      this.savingLabel = "Saving…";
      this.error = null;

      var csrf = document.querySelector("meta[name='csrf-token']")?.content || "";
      var fetcher = window.authedFetch || fetch;
      var headers = {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrf,
        "Accept": "application/json"
      };

      try {
        var resp = await fetcher(opts.updateUrl, {
          method: "POST",
          headers: headers,
          body: JSON.stringify({ username: this.username })
        });
        if (!resp) return; // 401 short-circuit
        var data = await resp.json();
        if (data.error) throw new Error(data.error);
        if (data.success) { window.location.reload(); return; }
        if (data.needs_signature) {
          // Phantom path — the rename is an on-chain TX. Reflect the two
          // multi-second phases (wallet approval, then on-chain confirm) in the
          // CTA label so a 5–10s wait isn't a silent static "Saving…".
          this.savingLabel = "Approve in Phantom…";
          var sig = await this._signAndBroadcast(data.serialized_tx);
          this.savingLabel = "Confirming…";
          var confirmResp = await fetcher(opts.confirmUrl, {
            method: "POST",
            headers: headers,
            body: JSON.stringify({ token: data.token, tx_signature: sig })
          });
          if (!confirmResp) return;
          var cdata = await confirmResp.json();
          if (cdata.error) throw new Error(cdata.error);
          window.location.reload();
        }
      } catch (e) {
        this.error = this._friendlyError(e);
        this.saving = false;
      }
    },

    async _signAndBroadcast(serializedTxB64) {
      var provider = window.walletProvider && window.walletProvider.detect();
      if (!provider) throw new Error("Connect your Phantom wallet to rename.");
      await provider.connect();
      var txBytes = Uint8Array.from(atob(serializedTxB64), function (c) { return c.charCodeAt(0); });
      var tx = solanaWeb3.Transaction.from(txBytes);
      var signed = await provider.signTransaction(tx);
      var rpcUrl = document.body.dataset.solanaRpcUrl;
      var conn = new solanaWeb3.Connection(rpcUrl, "confirmed");
      var sig = await conn.sendRawTransaction(signed.serialize(), { skipPreflight: true, maxRetries: 3 });
      // HTTP poll getSignatureStatuses instead of connection.confirmTransaction
      // (no WebSocket subscription, no misleading "unknown" timeout).
      await window.pollConfirmation(rpcUrl, sig);
      return sig;
    },

    _friendlyError(e) {
      if (e && e.code === 4001) return "Signature rejected";
      return (e && e.message) || "Could not save username";
    }
  };
}

window.usernameRenameForm = usernameRenameForm;
function registerUsernameRenameForm() {
  if (typeof Alpine === "undefined") return false;
  Alpine.data("usernameRenameForm", usernameRenameForm);
  return true;
}
if (!registerUsernameRenameForm()) {
  document.addEventListener("alpine:init", registerUsernameRenameForm);
}
