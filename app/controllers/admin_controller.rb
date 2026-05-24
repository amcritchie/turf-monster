class AdminController < ApplicationController
  before_action :require_admin, except: [:usdc_balance]

  # Manifest of every modal partial + interesting internal state, used by
  # the /admin/modals gallery (see views/admin/modals.html.erb). Each
  # variant is rendered in an iframe via #modal_preview. Keep this in
  # sync with app/views/modals/* and the host registrations in
  # layouts/application.html.erb.
  MODAL_VARIANTS = [
    { group: "Auth — credentials",
      label: "Signup", key: "auth-signup",
      modal_id: "auth", file: "app/views/modals/_auth.html.erb",
      props: { mode: "signup", step: "credentials" } },
    { group: "Auth — credentials",
      label: "Login", key: "auth-login",
      modal_id: "auth", file: "app/views/modals/_auth.html.erb",
      props: { mode: "login", step: "credentials" } },

    { group: "Auth — token purchase sub-flow",
      label: "Picker", key: "auth-tokens-picker",
      modal_id: "auth", file: "app/views/modals/auth/_tokens.html.erb",
      props: { mode: "signup", step: "tokens-picker" } },
    { group: "Auth — token purchase sub-flow",
      label: "Waiting (Stripe tab open)", key: "auth-tokens-waiting",
      modal_id: "auth", file: "app/views/modals/auth/_tokens.html.erb",
      # lastPackId pre-set so the Re-open Checkout CTA renders enabled
      # in the preview (in the real flow, the picker click sets this).
      props: { step: "tokens-waiting", lastPackId: "single" } },
    { group: "Auth — token purchase sub-flow",
      label: "Confirming (polling mint)", key: "auth-tokens-confirming",
      modal_id: "auth", file: "app/views/modals/auth/_tokens.html.erb",
      props: { step: "tokens-confirming" } },
    { group: "Auth — token purchase sub-flow",
      label: "Minted (Hold to Confirm)", key: "auth-tokens-minted",
      modal_id: "auth", file: "app/views/modals/auth/_tokens.html.erb",
      props: { step: "tokens-minted", mintedCount: 1, mintedBalance: 1 } },
    { group: "Auth — token purchase sub-flow",
      label: "Minted (3 tokens, plural)", key: "auth-tokens-minted-3",
      modal_id: "auth", file: "app/views/modals/auth/_tokens.html.erb",
      props: { step: "tokens-minted", mintedCount: 3, mintedBalance: 3 } },
    { group: "Auth — token purchase sub-flow",
      label: "Submitted (entry confirmed)", key: "auth-tokens-submitted",
      modal_id: "auth", file: "app/views/modals/auth/_tokens.html.erb",
      # redirectUrl: '#' (not '/') so the success card's auto-redirect
      # is a harmless hash-change instead of navigating the iframe away.
      props: { step: "tokens-submitted",
               txSignature: "5KJp2N6abc123demoTxSignatureForPreview7xYz8wQrSt",
               redirectUrl: "#", seedsEarned: 13, seedsTotal: 13 } },
    { group: "Auth — token purchase sub-flow",
      label: "Error (poll timed out)", key: "auth-tokens-error",
      modal_id: "auth", file: "app/views/modals/auth/_tokens.html.erb",
      props: { step: "tokens-error",
               errorText: "Your purchase is taking longer than expected. Refresh to try again." } },

    { group: "Auth — redirect",
      label: "Redirect countdown", key: "auth-redirect",
      modal_id: "auth", file: "app/views/modals/_auth.html.erb",
      props: { step: "redirect", icon: "⏱️", title: "Heading to the lobby",
               message: "We're sending you to the contest lobby.",
               countdown: 3, seconds: 5, cta: "Go now" } },

    { group: "Check email",
      label: "Default", key: "check-email",
      modal_id: "check-email", file: "app/views/modals/_check_email.html.erb",
      props: { email: "you@example.com" } },
    { group: "Check email",
      label: "With resend error", key: "check-email-error",
      modal_id: "check-email", file: "app/views/modals/_check_email.html.erb",
      props: { email: "you@example.com",
               sendError: "Failed to resend — please try again in a moment." } },
    { group: "Check email",
      label: "Resending (loader)", key: "check-email-resending",
      modal_id: "check-email", file: "app/views/modals/_check_email.html.erb",
      props: { email: "you@example.com", state: "resending" } },
    { group: "Check email",
      label: "Confirmation Resent", key: "check-email-resent",
      modal_id: "check-email", file: "app/views/modals/_check_email.html.erb",
      props: { email: "you@example.com", state: "resent" } },

    { group: "On-chain TX (Solana)",
      label: "Processing", key: "onchain-processing",
      modal_id: "onchain-tx", file: "app/views/modals/_onchain_tx.html.erb",
      props: { state: "processing", title: "Confirming entry",
               message: "Waiting for Phantom signature…" } },
    { group: "On-chain TX (Solana)",
      label: "Success (Entry Confirmed)", key: "onchain-success",
      modal_id: "onchain-tx", file: "app/views/modals/blocks/_entry_confirmed.html.erb",
      # lobbyUrl: '#' so the success card's 5s auto-redirect is a
      # harmless hash-change instead of navigating the iframe away.
      props: { state: "success",
               txSignature: "5KJp2N6abc123demoTxSignatureForPreview7xYz8wQrSt",
               lobbyUrl: "#", seedsEarned: 13, seedsTotal: 78 } },
    { group: "On-chain TX (Solana)",
      label: "Success — level up (Free Entry)", key: "onchain-success-levelup",
      modal_id: "onchain-tx", file: "app/views/modals/blocks/_entry_confirmed.html.erb",
      props: { state: "success",
               txSignature: "5KJp2N6abc123demoTxSignatureForPreview7xYz8wQrSt",
               lobbyUrl: "#", seedsEarned: 70, seedsTotal: 130 } },
    { group: "On-chain TX (Solana)",
      label: "Error (no recovery)", key: "onchain-error",
      modal_id: "onchain-tx", file: "app/views/modals/_onchain_tx.html.erb",
      props: { state: "error", title: "Entry failed",
               errorMessage: "Insufficient SOL to pay network fee." } },
    { group: "On-chain TX (Solana)",
      label: "Error + Phantom recovery", key: "onchain-error-recovery",
      modal_id: "onchain-tx", file: "app/views/modals/_onchain_tx.html.erb",
      props: { state: "error", title: "Insufficient USDC",
               errorMessage: "You need $19 USDC to enter this contest.",
               recoveryLabel: "Mint $500 Test USDC", recoveryPhantom: false } },

    { group: "Profile",
      label: "Edit profile", key: "profile",
      modal_id: "profile", file: "app/views/modals/_profile.html.erb",
      props: {} },

    # NOTE — `_username.html.erb` and `_crop_photo.html.erb` entries
    # were removed from this manifest during the modal-preview restore
    # (the partials don't exist on main yet). Re-add the corresponding
    # MODAL_VARIANTS entries when those modal partials land.

    # === Standalone modal-style views ====================================
    # Full Rails pages (not modal partials) that render the same card
    # idiom. The :url field bypasses #modal_preview and iframes the page
    # directly — usually with a preview-state query param that pins one
    # branch of the page's internal state machine without live behavior.
    { group: "Standalone — Stripe return (/tokens/processing)",
      label: "Loading (waiting on mint)", key: "tokens-processing-loading",
      file: "app/views/tokens/processing.html.erb",
      url:  "/tokens/processing?preview_state=loading" },
    { group: "Standalone — Stripe return (/tokens/processing)",
      label: "Ready (mint complete)", key: "tokens-processing-ready",
      file: "app/views/tokens/processing.html.erb",
      url:  "/tokens/processing?preview_state=ready" },
    { group: "Standalone — Stripe return (/tokens/processing)",
      label: "Errored (poll timed out)", key: "tokens-processing-errored",
      file: "app/views/tokens/processing.html.erb",
      url:  "/tokens/processing?preview_state=errored" }
  ].freeze

  def navbar
  end

  def modals
    @variants = MODAL_VARIANTS
  end

  def modal_preview
    @modal_id    = params[:modal_id].to_s
    @modal_props = params[:props].present? ? (JSON.parse(params[:props]) rescue {}) : {}
    render layout: "modal_preview"
  end

  # Legacy preview route from when the avatar cropper had its own
  # bespoke z-[110] overlay. Now that the cropper goes through the
  # shared modal host, this route is unused — keep it pointing at the
  # same minimal layout for back-compat with any bookmarked URL.
  def modal_preview_crop
    render layout: "modal_preview"
  end

  def hub
    @active_slate   = Slate.joins(:slate_matchups).distinct.order(created_at: :desc).first
    @latest_contest = Contest.order(created_at: :desc).first
  end

  def usdc_balance
    return render json: { error: "Not logged in" }, status: :unauthorized unless logged_in?
    return render json: { balance: 0 } unless current_user.solana_connected?

    # Always fetch fresh, then cache for server-side renders
    balance = fetch_user_usdc
    Rails.cache.write(usdc_cache_key, balance, expires_in: 60.seconds)

    render json: { balance: balance }
  rescue => e
    render json: { balance: 0 }
  end

  def mint_usdc
    rescue_and_log(target: current_user) do
      raise "Admin mint is production-disabled" if Rails.env.production?  # OPSEC-020
      raise "Mint only available on Devnet" unless Solana::Config.devnet?

      vault = Solana::Vault.new
      admin = Solana::Keypair.admin

      vault.ensure_ata(admin.to_base58, mint: Solana::Config::USDC_MINT)
      amount = Solana::Config.dollars_to_lamports(500)
      result = vault.mint_spl(amount, mint: Solana::Config::USDC_MINT)

      invalidate_usdc_cache
      redirect_back fallback_location: root_path, notice: "Minted $500.00 USDC. TX: #{result[:signature]}"
    end
  rescue StandardError => e
    redirect_back fallback_location: root_path, alert: "Mint failed: #{e.message}"
  end
end
