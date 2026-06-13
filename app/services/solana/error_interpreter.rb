module Solana
  # Layer 2 of the entry-blocker design: translates raw on-chain / RPC /
  # Phantom errors into the same { reason, mode, data } blocker shape the
  # JS preflight check (window.eligibilityBlocker) returns. Callers in the
  # entry-flow controllers thread the result into their JSON error response
  # so the client can route through showEligibilityBlockerModal — meaning
  # the user sees identical UX whether the block was caught pre-flight or
  # surfaced from a transaction the chain rejected.
  #
  # Returns:
  #   { message:, blocker: { reason:, mode:, data: } | nil, toast: bool, log: bool }
  #
  # - blocker:nil — error has no actionable retry path (the client falls
  #   back to whatever generic error UI it already had)
  # - toast:true — user intent failure (e.g. they declined the wallet
  #   prompt). Client should show a transient toast, not a modal.
  # - log:true  — operationally interesting; client / server side should
  #   alert (e.g. AccountDidNotDeserialize hints at IDL drift)
  module ErrorInterpreter
    extend self

    def interpret(err, contest: nil, mode: nil)
      msg = err.is_a?(Exception) ? err.message.to_s : err.to_s
      stripped = msg.strip
      mode = mode.to_s

      # Phantom — user declined the signature. Not a real failure.
      if stripped.match?(/user rejected|user declined/i)
        return ok(message: "Transaction canceled.", toast: true)
      end

      # web2 — managed wallet can't fund the entry by ANY enabled method
      # (no entry token, and USDC entry off or insufficient). Server-side raise
      # from ContestsController#resolve_web2_entry_funding! when the flag is off
      # / token-only. Maps to the no_funding blocker → board opens Top Up Wallet.
      if stripped.match?(/no entry tokens/i)
        return ok(
          message: stripped,
          blocker: { reason: "no_funding", mode: "web2", data: {} }
        )
      end

      # InsufficientBalance (6002 / 0x1772). Raised by enter_contest when the
      # wallet's USDC/USDT ATA can't cover the entry fee. mode-aware: a web2 /
      # managed USDC entry that underfunds maps to no_funding/web2 (Top Up
      # Wallet, Coinbase-forward), NOT the web3 deposit/currency picker. web3
      # (Phantom) keeps the insufficient_balance/web3 deposit modal.
      if stripped.match?(/0x1772|\b6002\b|insufficientbalance|insufficient (usdc|onchain|balance|funds)/i)
        if mode == "web2"
          return ok(
            message: "Not enough USDC to enter. Top up your wallet and try again.",
            blocker: {
              reason: "no_funding",
              mode: "web2",
              data: { neededCents: (contest&.entry_fee_cents.to_i || 0) }
            }
          )
        end
        return ok(
          message: "Insufficient balance. Top up your wallet to enter.",
          blocker: {
            reason: "insufficient_balance",
            mode: "web3",
            data: { neededCents: (contest&.entry_fee_cents.to_i || 0) }
          }
        )
      end

      # ContestNotOpen (6003 / 0x1773).
      if stripped.match?(/0x1773|\b6003\b|contest is not open|contestnotopen/i)
        return ok(
          message: "Contest is no longer open.",
          blocker: { reason: "contest_locked", mode: nil, data: {} }
        )
      end

      # ContestFull (6004 / 0x1774).
      if stripped.match?(/0x1774|\b6004\b|contest is full|contestfull/i)
        return ok(
          message: "Contest is full.",
          blocker: { reason: "contest_full", mode: nil, data: {} }
        )
      end

      # AccountDidNotDeserialize (3003 / 0xbbb) — IDL drift. Operational
      # smoke alarm. User can't fix it; we log and show a generic message.
      if stripped.match?(/0xbbb|\b3003\b|accountdidnotdeserialize/i)
        return ok(
          message: "Your account needs a one-time upgrade. Please try again shortly.",
          log: true
        )
      end

      # ── v0.15.1 username codes (6020-6022, audit C2) ─────────────────
      # Raised by create_user_account / set_username when the username fails
      # on-chain validation. The Rails mirror (User::RESERVED_USERNAME_PREFIXES
      # + the username validations) should make these unreachable for normal
      # users — log:true so a hit flags mirror drift.

      # UsernameReserved (6020 / 0x1784) — reserved prefix (admin/turf/mod/…).
      if stripped.match?(/0x1784|\b6020\b|usernamereserved/i)
        return ok(
          message: "Your username can't be registered on-chain — it starts with a reserved word. Change it on your account page (/account) and try again.",
          log: true
        )
      end

      # UsernameInvalidChars (6021 / 0x1785) — bytes outside printable ASCII.
      if stripped.match?(/0x1785|\b6021\b|usernameinvalidchars/i)
        return ok(
          message: "Your username contains unsupported characters and can't be registered on-chain. Change it on your account page (/account) and try again.",
          log: true
        )
      end

      # UsernameTooShort (6022 / 0x1786) — fewer than 3 characters.
      if stripped.match?(/0x1786|\b6022\b|usernametooshort/i)
        return ok(
          message: "Your username is too short to register on-chain (3 characters minimum). Change it on your account page (/account) and try again.",
          log: true
        )
      end

      # ── v0.16 codes (6023-6033) ──────────────────────────────────────

      # InvalidCurrencyIndex (6025 / 0x1789) — currency_idx in enter_contest
      # points at an unused slot. Almost certainly a stale client.
      if stripped.match?(/0x1789|\b6025\b|invalidcurrencyindex/i)
        return ok(
          message: "Currency option is unavailable. Refresh and try again.",
          blocker: { reason: "currency_unavailable", mode: nil, data: {} }
        )
      end

      # CurrencyNotActive (6026 / 0x178a) — currency was active at page load
      # but deactivated before the user submitted.
      if stripped.match?(/0x178a|\b6026\b|currencynotactive/i)
        return ok(
          message: "This currency is no longer accepted. Refresh and try a different one.",
          blocker: { reason: "currency_unavailable", mode: nil, data: {} }
        )
      end

      # EntryFeeNotSet (6027 / 0x178b) — this contest's entry_fee_by_currency
      # has a zero in the selected slot (e.g. a USDT entry against a contest
      # created before slot 1 was funded — see Contest#accepts_usdt).
      # Effectively wrong-currency-picked. JS mirror: solana_errors.js.
      if stripped.match?(/0x178b|\b6027\b|entryfeenotset/i)
        return ok(
          message: "This contest doesn't accept that currency — try USDC.",
          blocker: { reason: "currency_unavailable", mode: nil, data: {} }
        )
      end

      # Operator-only codes — shouldn't reach a user. If they do (bug or
      # admin UI flow), surface a clean message and log so it doesn't
      # vanish into a generic 500.
      if stripped.match?(/0x1787|\b6023\b|currencyalreadyregistered/i)
        return ok(message: "Currency is already registered.", log: true)
      end
      if stripped.match?(/0x1788|\b6024\b|currencyregistryfull/i)
        return ok(message: "Currency registry is full.", log: true)
      end
      if stripped.match?(/0x178c|\b6028\b|contestnotlocked/i)
        return ok(message: "Contest is not locked.", log: true)
      end
      if stripped.match?(/0x178d|\b6029\b|contestnotcancellable/i)
        return ok(message: "Contest cannot be cancelled in its current status.", log: true)
      end
      if stripped.match?(/0x178e|\b6030\b|prizepoolnotempty/i)
        return ok(message: "Prize pool still has tokens — settle or refund first.", log: true)
      end
      if stripped.match?(/0x178f|\b6031\b|emptyrevenueaccount/i)
        return ok(message: "Operator revenue account is empty.", log: true)
      end
      # OPSEC: a sweep aimed at the wrong destination — log loud.
      if stripped.match?(/0x1790|\b6032\b|treasuryauthoritymismatch/i)
        return ok(message: "Treasury ATA does not belong to the pinned treasury authority.", log: true)
      end
      if stripped.match?(/0x1791|\b6033\b|feeandprizebothzero/i)
        return ok(message: "Contest must have at least one entry fee or a non-zero prize pool.", log: true)
      end

      # ── v0.19 codes (6036-6038, audit highs #3/#5/#9) ────────────────
      # Loud — a redirected payout is a fund-safety signal.
      if stripped.match?(/0x1794|\b6036\b|invalidpayoutdestination/i)
        return ok(message: "Settlement payout destination is not the winner's associated token account.", log: true)
      end
      if stripped.match?(/0x1795|\b6037\b|invalidtimestamp/i)
        return ok(message: "Invalid contest time — must be in the future, and the lock must precede the conclusion.", log: true)
      end
      if stripped.match?(/0x1796|\b6038\b|entrytokenseedmismatch/i)
        return ok(message: "Entry token reference hash mismatch — retry the mint.", log: true)
      end

      # Network / RPC flakes — transient, user can just retry.
      if stripped.match?(/blockhash not found|block height exceeded|connection refused|timed out|connection reset/i)
        return ok(message: "Network blip — please try again.", toast: true)
      end

      # Unmapped — pass through, no blocker.
      ok(message: stripped)
    end

    private

    def ok(message:, blocker: nil, toast: false, log: false)
      { message: message, blocker: blocker, toast: toast, log: log }
    end
  end
end
