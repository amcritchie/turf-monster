require "test_helper"

# Render-gating coverage for the token-first Top Up Wallet modal
# (modals/_wallet_topup), its ungated registration in the application layout,
# the entry-blocker re-route in contests/_turf_totals_board, and the Add Funds
# hub's returnModal back-branching. Companion to onramp_hub_test.rb; the
# client-side JS trigger (showWalletTopup vs showTokensPanel) is asserted at the
# render level only — the live modal handoff is a tracked Playwright e2e gap
# (mirrors the on-chain success-modal coverage-gap precedent).
class WalletTopupTest < ActionDispatch::IntegrationTest
  # --- modal registration + content (ungated, like onramp-hub) ---

  test "the wallet-topup modal is registered ungated in the layout for a guest" do
    get contests_path
    assert_response :success
    assert_includes response.body, "$store.modals.current().id === 'wallet-topup'",
                     "wallet-topup must be registered in the layout (ungated, like onramp-hub)"
    assert_includes response.body, "Top Up Wallet"
  end

  test "the wallet-topup modal stays registered when logged in" do
    log_in_as users(:jordan)
    get contests_path
    assert_response :success
    assert_includes response.body, "$store.modals.current().id === 'wallet-topup'"
    assert_includes response.body, "Top Up Wallet"
  end

  test "the wallet-topup modal shows the entry-token count from the session payload" do
    get contests_path
    assert_response :success
    # This trigger fires only for managed (web2) players, who pay by consuming an
    # entry token — so the header surfaces the token count, not a USDC balance.
    # Sourced from $store.session.tokensAvailable (coerced to a number, 0 cold).
    assert_includes response.body, "Entry tokens:"
    assert_includes response.body, "$store.session.tokensAvailable"
    # The misleading USDC balance line is gone from this token-buying audience.
    refute_includes response.body, "$store.session.usdcCents === null"
  end

  test "the primary CTA buys entry tokens via the pack picker, not USDC" do
    get contests_path
    assert_response :success
    # Token-first: the bordered primary CTA opens the existing tokens-picker step
    # of the auth wizard (the same props showTokensPanel uses) via swap().
    assert_includes response.body, %(data-topup-rail="tokens")
    assert_includes response.body, "Buy Entry Tokens"
    assert_includes response.body,
                     "$store.modals.swap('auth', { step: 'tokens-picker'"
    # The Coinbase/USDC button must NO LONGER be the primary action here — it is
    # demoted to the hub's "More ways to add funds" fallback (asserted below).
    refute_includes response.body, %(data-topup-rail="coinbase"),
                    "the Coinbase-primary button must be gone from wallet-topup"
  end

  test "the quiet link opens the hub flagged as opened-from wallet-topup" do
    get contests_path
    assert_response :success
    assert_includes response.body, "More ways to add funds"
    assert_includes response.body,
                     "$store.modals.swap('onramp-hub', { returnModal: 'wallet-topup' })"
  end

  # --- hub returnModal back-branching ---

  test "the hub Back link routes by returnModal, differing for wallet-topup vs the picker" do
    get contests_path
    assert_response :success
    body = response.body
    # When opened from wallet-topup, Back slides back to the Top Up Wallet modal.
    assert_includes body,
                    "props.returnModal === 'wallet-topup' ? $store.modals.swap('wallet-topup', {})",
                    "hub Back must return to wallet-topup when opened from there"
    # Otherwise (the existing tokens-picker path) Back returns to the picker —
    # the unchanged default that keeps the _tokens / _paypal_tokens link working.
    assert_includes body,
                    "$store.modals.swap('auth', { step: (props.returnStep || 'tokens-picker') })",
                    "hub Back must default to the tokens picker"
    # The two back targets must be distinct branches of one expression.
    refute_equal "$store.modals.swap('wallet-topup', {})",
                 "$store.modals.swap('auth', { step: (props.returnStep || 'tokens-picker') })"
  end

  # --- entry-blocker re-route (render level; e2e gap noted above) ---

  test "the board entry blocker routes the funds-needed wall to showWalletTopup" do
    get contest_path(contests(:one))
    assert_response :success
    body = response.body
    # The showWalletTopup method exists on the board component.
    assert_includes body, "showWalletTopup()"
    # The 'no_tokens' eligibility-blocker case now opens the Top Up Wallet modal
    # (was showTokensPanel — the pack picker).
    assert_match(/case 'no_tokens':\s+this\.showWalletTopup\(\);/, body,
                 "the no_tokens entry wall must reroute to showWalletTopup")
    refute_match(/case 'no_tokens':\s+this\.showTokensPanel\(\);/, body,
                 "the no_tokens entry wall must no longer open the pack picker")
  end

  test "the board keeps showTokensPanel for the post-signup pack-picker resume" do
    get contest_path(contests(:one))
    assert_response :success
    body = response.body
    # showTokensPanel stays intact (the picker, reached via the hub's Stripe
    # card + the post-signup pendingAuthStep resume), so the deferred buy-tokens
    # step is unchanged.
    assert_includes body, "showTokensPanel()"
    assert_includes body, "board.showTokensPanel();"
  end
end
