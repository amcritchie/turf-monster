class AdminController < ApplicationController
  before_action :require_admin, except: [:usdc_balance]

  # Manifest of every modal partial + interesting internal state, used by
  # the /admin/modals gallery (see views/admin/modals.html.erb). Each
  # variant is rendered in an iframe via #modal_preview. Keep this in
  # sync with app/views/modals/* and the host registrations in
  # layouts/application.html.erb.
  MODAL_VARIANTS = [
    # === Templates ===========================================================
    # Reference implementations new modal work should copy. Each pairs a
    # visual archetype (form / action / status / wizard) with a complete
    # working modal under app/views/modals/templates/. Registered in the
    # modal host gated to !production. The :partial key tells the gallery
    # to render the variant INLINE (no iframe) — the templates are pure
    # local x-data with no props dependency, so they drop in anywhere.
    # Open ↗ still pushes them onto the live host for full interactive
    # testing (backdrop, escape, click-outside).
    { group: "Templates",
      label: "Wizard (Step N of M + nav)", key: "template-wizard",
      modal_id: "template-wizard", file: "app/views/modals/templates/_wizard.html.erb",
      partial: "modals/templates/wizard",
      props: {} },
    { group: "Templates",
      label: "Success (large title — celebration)", key: "template-success",
      modal_id: "template-success", file: "app/views/modals/templates/_success.html.erb",
      partial: "modals/templates/success",
      props: {} },
    { group: "Templates",
      label: "Status (small title — in-flight)", key: "template-status",
      modal_id: "template-status", file: "app/views/modals/templates/_status.html.erb",
      partial: "modals/templates/status",
      props: {} },
    { group: "Templates",
      label: "Action (icon + question + dual CTA)", key: "template-action",
      modal_id: "template-action", file: "app/views/modals/templates/_action.html.erb",
      partial: "modals/templates/action",
      props: {} },
    { group: "Templates",
      label: "Form (title + body + CTA)", key: "template-form",
      modal_id: "template-form", file: "app/views/modals/templates/_form.html.erb",
      partial: "modals/templates/form",
      props: {} },

    { group: "Auth — credentials",
      label: "Credentials (Google / wallet / magic link)", key: "auth-credentials",
      modal_id: "auth", file: "app/views/modals/_auth.html.erb",
      props: { mode: "signup", step: "credentials" } },
    { group: "Auth — credentials",
      label: "Magic link sent", key: "auth-magic-link-sent",
      modal_id: "auth", file: "app/views/modals/_auth.html.erb",
      props: { step: "magic-link-sent", sentEmail: "you@example.com" } },
    { group: "Auth — credentials",
      label: "Connect Wallet (picker)", key: "wallet-connect",
      modal_id: "wallet-connect", file: "app/views/modals/_wallet_connect.html.erb",
      props: {} },

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
      # redirectUrl: nil — the cta_redirect partial sees null and skips
      # the timer-end window.location, so the gallery preview keeps the
      # drain animation but never navigates the iframe.
      props: { step: "tokens-submitted",
               txSignature: "5KJp2N6abc123demoTxSignatureForPreview7xYz8wQrSt",
               redirectUrl: nil, seedsEarned: 13, seedsTotal: 13 } },
    { group: "Auth — token purchase sub-flow",
      label: "Error (poll timed out)", key: "auth-tokens-error",
      modal_id: "auth", file: "app/views/modals/auth/_tokens.html.erb",
      props: { step: "tokens-error",
               errorText: "Your purchase is taking longer than expected. Refresh to try again." } },

    { group: "Wallet deposit",
      label: "Picker (insufficient USDC/USDT)", key: "wallet-deposit-picker",
      modal_id: "wallet-deposit", file: "app/views/modals/_wallet_deposit.html.erb",
      props: { neededCents: 1900, usdcCents: 300, usdtCents: 0 } },

    { group: "Auth — redirect",
      label: "Redirect countdown", key: "auth-redirect",
      modal_id: "auth", file: "app/views/modals/_auth.html.erb",
      # url: nil — cta_redirect drains the bar but skips the actual
      # window.location at timer-end, so the gallery preview stays put.
      props: { step: "redirect", icon: "⏱️", title: "Heading to the lobby",
               message: "We're sending you to the contest lobby.",
               url: nil, cta: "Go now" } },

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

    { group: "Username",
      label: "Change username", key: "username",
      modal_id: "username", file: "app/views/modals/_username.html.erb",
      props: {} },

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
      url:  "/tokens/processing?preview_state=errored" },

    # === Crop Photo (avatar cropper) ====================================
    # Now ships from studio-engine — see studio/modals/_crop_photo (v0.4.12)
    # and components/_avatar_cropper (v0.4.13; no longer a local override).
    { group: "Crop Photo",
      label: "Crop Photo (placeholder image)", key: "crop-photo",
      modal_id: "crop-photo", file: "studio/modals/_crop_photo.html.erb",
      props: { imageUrl: "/logo.png" } },

    # === Quest / Newsletter (feat/quest-mailing-list) ====================
    # The quest-success + newsletter join + unsubscribe modal chain. All gate
    # on current_user in the host; quest-success reads display_seeds_data
    # (server) for its bar, so the gallery preview shows the viewing admin's seeds.
    { group: "Quest / Newsletter",
      label: "Quest success (+25 + subscribe CTA)", key: "quest-success",
      modal_id: "quest-success", file: "app/views/modals/_quest_success.html.erb",
      props: { seeds_earned: 25, seeds_total: 75, seeds_level: 1 } },
    { group: "Quest / Newsletter",
      label: "Newsletter subscribe (consent-gated)", key: "newsletter-subscribe",
      modal_id: "newsletter-subscribe", file: "app/views/modals/_newsletter_subscribe.html.erb",
      props: {} },
    { group: "Quest / Newsletter",
      label: "Newsletter success (+25 — you're in)", key: "newsletter-success",
      modal_id: "newsletter-success", file: "app/views/modals/_newsletter_success.html.erb",
      props: {} },
    { group: "Quest / Newsletter",
      label: "Unsubscribe — are you sure?", key: "unsubscribe-confirm",
      modal_id: "unsubscribe-confirm", file: "app/views/modals/_unsubscribe_confirm.html.erb",
      props: {} },
    { group: "Quest / Newsletter",
      label: "Unsubscribe — see you later", key: "unsubscribe-goodbye",
      modal_id: "unsubscribe-goodbye", file: "app/views/modals/_unsubscribe_goodbye.html.erb",
      props: {} }
  ].freeze

  def navbar
  end

  def level_badges
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

  # Read-only navbar-hydrate endpoint (NOT admin-gated — see the
  # `except: [:usdc_balance]` on require_admin). The client calls this on page
  # load and after on-chain successes to fill the navbar that now renders
  # cache-first (display_balance / display_seeds_data read Rails.cache only).
  #
  # One round-trip hydrates everything: USDC + USDT balances + seeds payload.
  # It fetches fresh (blocking is fine — runs after first paint), WARMS the
  # navbar caches (usdc/usdt/seeds), and returns them. `{ balance: }` is kept
  # for back-compat (refreshBalance reads data.balance). current_user only.
  def usdc_balance
    return render json: { error: "Not logged in" }, status: :unauthorized unless logged_in?
    return render json: { balance: 0, usdc: 0, usdt: 0, seeds: nil } unless current_user.solana_connected?

    hydrate = fetch_navbar_hydrate(current_user)
    seeds   = hydrate[:seeds]
    balance = hydrate[:usdc] || 0

    render json: {
      balance:     balance,                 # back-compat (refreshBalance reads this)
      usdc:        balance,
      usdt:        hydrate[:usdt],
      seeds:       seeds,
      level:       (User.level_for(seeds) if seeds),
      toward_next: (User.seeds_toward_next_level(seeds) if seeds),
      progress:    (User.seeds_progress_percent(seeds) if seeds),
      seeds_to_next: (User::SEEDS_PER_LEVEL - User.seeds_toward_next_level(seeds) if seeds)
    }
  rescue => e
    Rails.logger.warn("[usdc_balance] hydrate failed: #{e.message}")
    render json: { balance: 0, usdc: 0, usdt: 0, seeds: nil }
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
