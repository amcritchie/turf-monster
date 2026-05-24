class TokensController < ApplicationController
  before_action :require_login
  before_action :require_dev_mint_allowed, only: [:dev_mint]
  # B4 / OPSEC-048: frozen accounts can't buy tokens.
  before_action :require_unfrozen_account, only: [:stripe_checkout]

  def buy
    @packs = StripePurchase.available_packs
  end

  def stripe_checkout
    pack_id = params[:pack].to_s
    unless StripePurchase.available_packs.key?(pack_id)
      return redirect_to tokens_buy_path, alert: "Unknown or unavailable token pack"
    end
    unless current_user.solana_connected?
      return redirect_to tokens_buy_path, alert: "Connect a wallet first."
    end
    unless Rails.application.config.x.stripe_enabled
      return redirect_to tokens_buy_path, alert: "Card checkout isn't configured yet. Set STRIPE_SECRET_KEY and restart."
    end
    # OPSEC-036: a prior chargeback flagged this account — block further card
    # purchases so a stolen-card buyer can't keep racking up disputes.
    if current_user.payment_risk_flag
      return redirect_to tokens_buy_path, alert: "Card purchases are disabled on this account. Please contact support."
    end

    pack        = StripePurchase.pack(pack_id)
    quantity    = pack[:quantity]
    price_cents = pack[:price_cents]
    # Optional contest context — when present, checkout returns the buyer to
    # that contest (lineup preserved) instead of the generic token page.
    contest = Contest.find_by(slug: params[:contest].presence)

    rescue_and_log(target: current_user) do
      session_params = {
        payment_method_types: ["card"],
        line_items: [{
          price_data: {
            currency: "usd",
            product_data: { name: "Turf Monster — #{quantity} entry token#{'s' if quantity != 1}" },
            unit_amount: price_cents
          },
          quantity: 1
        }],
        mode: "payment",
        success_url: contest ?
          "#{tokens_processing_url}?session_id={CHECKOUT_SESSION_ID}&contest=#{contest.slug}" :
          "#{tokens_processing_url}?session_id={CHECKOUT_SESSION_ID}",
        cancel_url:  contest ? contest_url(contest) : "#{tokens_buy_url}?purchase=cancelled",
        metadata: {
          kind: "tokens",
          user_id: current_user.id,
          pack_id: pack_id,
          quantity: quantity,
          wallet_address: current_user.solana_address,
          contest_slug: contest&.slug
        }
      }
      # Pre-fill the email field if we have one. Stripe rejects the request if
      # both `customer` and `customer_email` are passed, so we only set this
      # when there's no Stripe customer attached yet.
      session_params[:customer_email] = current_user.email if current_user.email.present?

      session = Stripe::Checkout::Session.create(session_params)

      respond_to do |format|
        # Same-tab HTML submit (e.g. /tokens/buy) → server-side redirect.
        format.html { redirect_to session.url, allow_other_host: true }
        # XHR / fetch from the in-modal pack button → return the URL
        # as JSON so the client navigates the already-open tab itself.
        # If we redirected here, fetch would follow the 302 to Stripe
        # and consume the checkout session before the user got to it
        # (Stripe shows "page not found" on second visit).
        format.json { render json: { url: session.url } }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to tokens_buy_path, alert: "Checkout failed: #{e.message}" }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def processing
    @session_id = params[:session_id].to_s
    redirect_to tokens_buy_path and return if @session_id.blank?
    # When checkout carried a contest, return the buyer there once tokens mint.
    @contest = Contest.find_by(slug: params[:contest].presence)
    # Fallback CTA for the standalone success card: send the buyer to
    # the current "main" open contest (lowest rank). Falls back to the
    # most-recent contest, then to the contests index, all so the
    # success card always has a working "Enter contest" link.
    @next_contest = Contest.target ||
                    Contest.where(status: :open).order(created_at: :desc).first
  end

  def status
    session_id = params[:session_id].to_s
    return render json: { ready: false }, status: :bad_request if session_id.blank?

    purchase = current_user.stripe_purchases.for_session(session_id).first
    render json: {
      ready: purchase&.status == "minted",
      minted: purchase&.tx_signatures&.length.to_i,
      balance: current_user.entry_token_balance
    }
  end

  # Dev-only helper: mint tokens directly on-chain with source="dev" instead of going through Stripe.
  def dev_mint
    pack_id = params[:pack].to_s
    unless StripePurchase.available_packs.key?(pack_id)
      return redirect_to tokens_buy_path, alert: "Unknown or unavailable token pack"
    end
    quantity = StripePurchase.pack_quantity(pack_id)

    rescue_and_log(target: current_user) do
      vault = Solana::Vault.new
      quantity.times do |i|
        vault.mint_entry_token(
          wallet_address: current_user.solana_address,
          source: :operator,
          source_ref: "dev:#{SecureRandom.hex(4)}:#{i}"
        )
      end
      redirect_to tokens_buy_path, notice: "Minted #{quantity} test token#{'s' if quantity != 1} on-chain."
    end
  rescue StandardError => e
    redirect_to tokens_buy_path, alert: "Dev mint failed: #{e.message}"
  end

  private

  def require_login
    return if logged_in?
    redirect_to login_path, alert: "Please log in to buy entry tokens."
  end

  def require_dev_mint_allowed
    # OPSEC-020: triple gate — admin AND devnet config AND non-production Rails
    # env. dev_mint mints real on-chain entry tokens for free; one
    # mis-configured env var (or one stolen admin session) on mainnet would
    # be unlimited free tokens. The route should also be removed from
    # config/routes.rb when Rails.env.production?; this is defense-in-depth.
    return if current_user&.admin? && Solana::Config.devnet? && !Rails.env.production?
    redirect_to tokens_buy_path, alert: "Dev mint is admin + devnet only."
  end
end
