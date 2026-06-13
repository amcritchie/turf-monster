require "test_helper"

# Render-gating coverage for the COINBASE-FORWARD Top Up Wallet modal
# (modals/_wallet_topup), its ungated registration in the application layout,
# the entry-blocker re-route in contests/_turf_totals_board, and the Add Funds
# hub's returnModal back-branching. Companion to onramp_hub_test.rb.
#
# Since unified funding (operator 2026-06-13), a web2/managed USDC entry works
# (server-signed enter_contest) when ENABLE_WEB2_USDC_ENTRY is on, so USDC is the
# cash funding rail again: the primary CTA buys USDC with Coinbase and there are
# NO entry-token links in the default arrangement. The flag-off kill-switch
# degrades — client-side — to the entry-token rail for web2 viewers who can't pay
# with USDC. That branching is Alpine-runtime (tokenFallback reads $store.session),
# so it's asserted at the render level via the gating expressions only; the live
# modal handoff is a tracked Playwright e2e gap (mirrors the on-chain
# success-modal coverage-gap precedent).
class WalletTopupTest < ActionDispatch::IntegrationTest
  # --- modal registration (ungated, like onramp-hub) ---

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

  # --- header: USDC balance (the funding currency) ---

  test "the header shows the USDC balance, not a hardcoded token count" do
    get contests_path
    assert_response :success
    # USDC is the funding currency again, so the default header surfaces the USDC
    # balance (em-dash when the navbar cache is cold) from $store.session.usdcCents.
    assert_includes response.body, "USDC balance:"
    assert_includes response.body, "get usdcDisplay()"
    assert_includes response.body, "$store.session.usdcCents"
    # The token-count header survives ONLY as the flag-off (tokenFallback) degrade,
    # gated behind x-show, not the default line.
    assert_includes response.body, %(x-show="tokenFallback")
  end

  # --- primary CTA: Buy USDC with Coinbase (cdp-ramp buy preflight) ---

  test "the primary CTA buys USDC with Coinbase via the cdp-ramp buy preflight" do
    get contests_path
    assert_response :success
    body = response.body
    # Coinbase-forward: the bordered primary CTA hands off to the existing
    # cdp-ramp buy preflight (the same handoff /wallet Buy USDC + the hub use).
    assert_includes body, %(data-topup-rail="coinbase")
    assert_includes body, "Buy USDC with Coinbase"
    assert_includes body,
                     "$store.modals.swap('cdp-ramp', { flow: 'buy', step: 'preflight' })"
    # The Coinbase pitch is hidden for the web2 kill-switch audience that can't
    # pay with USDC.
    assert_match(/x-if="!tokenFallback">\s*<button type="button" data-topup-rail="coinbase"/m, body,
                 "the Coinbase CTA must be gated behind !tokenFallback")
  end

  # --- flag-aware degrade: web2 + ENABLE_WEB2_USDC_ENTRY off -> token rail ---

  test "the token rail is the kill-switch degrade, gated behind tokenFallback" do
    get contests_path
    assert_response :success
    body = response.body
    # The entry-token CTA exists ONLY inside the tokenFallback branch (web2 +
    # flag off); it is NOT the default primary action.
    assert_includes body, %(data-topup-rail="tokens")
    assert_includes body, "Buy Entry Tokens"
    assert_match(/x-if="tokenFallback">\s*<button type="button" data-topup-rail="tokens"/m, body,
                 "the token rail must be gated behind tokenFallback")
    # tokenFallback fires for web2 viewers ONLY when the web2-USDC kill-switch is
    # off — web3 and flag-on web2 always see the Coinbase pitch.
    assert_includes body,
                    "get tokenFallback() { return $store.session.mode === 'web2' && !$store.session.web2UsdcEntry }"
  end

  test "ENABLE_WEB2_USDC_ENTRY off emits web2UsdcEntry false so a web2 viewer degrades" do
    log_in_as users(:jordan)
    AppFlags.stub :web2_usdc_entry?, false do
      get contest_path(contests(:one))
    end
    assert_response :success
    body = response.body
    # The session payload (Carl's wiring) carries the kill-switch state the
    # modal's tokenFallback getter reads. A logged-in managed user is web2 mode,
    # so with the flag off this viewer flips to the entry-token rail.
    assert_includes body, %("web2UsdcEntry":false),
                    "flag-off must emit web2UsdcEntry:false into #session-context"
    assert_includes body, %("mode":"web2"),
                    "a magic-link login is a web2 session"
  end

  test "ENABLE_WEB2_USDC_ENTRY on (default) emits web2UsdcEntry true" do
    log_in_as users(:jordan)
    AppFlags.stub :web2_usdc_entry?, true do
      get contest_path(contests(:one))
    end
    assert_response :success
    assert_includes response.body, %("web2UsdcEntry":true),
                    "flag-on must emit web2UsdcEntry:true so web2 sees the Coinbase pitch"
  end

  # --- quiet secondary: the Add Funds hub ---

  test "the quiet link opens the hub flagged as opened-from wallet-topup" do
    get contests_path
    assert_response :success
    assert_includes response.body, "More ways to add funds"
    assert_includes response.body,
                     "$store.modals.swap('onramp-hub', { returnModal: 'wallet-topup' })"
  end

  # --- hub returnModal back-branching (unchanged) ---

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
  end

  # --- entry-blocker re-route (render level; e2e gap noted above) ---

  test "the board entry blocker routes the funds-needed wall to showWalletTopup" do
    get contest_path(contests(:one))
    assert_response :success
    body = response.body
    # The showWalletTopup method exists on the board component.
    assert_includes body, "showWalletTopup()"
    # The 'no_funding' eligibility-blocker case (renamed from 'no_tokens' in the
    # unified-funding refactor) opens the Top Up Wallet modal.
    assert_match(/case 'no_funding':\s+this\.showWalletTopup\(\);/, body,
                 "the no_funding entry wall must reroute to showWalletTopup")
    refute_match(/case 'no_tokens':/, body,
                 "the legacy no_tokens blocker case must be gone (renamed no_funding)")
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
