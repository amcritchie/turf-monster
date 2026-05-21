class TokensController < ApplicationController
  before_action :require_login
  before_action :require_dev_mint_allowed, only: [:dev_mint]

  def buy
    @packs = StripePurchase::PACKS
  end

  def stripe_checkout
    quantity = params[:quantity].to_i
    unless StripePurchase::PACKS.key?(quantity)
      return redirect_to tokens_buy_path, alert: "Unknown pack quantity"
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

    price_cents = StripePurchase.pack_price_cents(quantity)
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

      redirect_to session.url, allow_other_host: true
    end
  rescue StandardError => e
    redirect_to tokens_buy_path, alert: "Checkout failed: #{e.message}"
  end

  def processing
    @session_id = params[:session_id].to_s
    redirect_to tokens_buy_path and return if @session_id.blank?
    # When checkout carried a contest, return the buyer there once tokens mint.
    @contest = Contest.find_by(slug: params[:contest].presence)
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
    quantity = params[:quantity].to_i
    unless StripePurchase::PACKS.key?(quantity)
      return redirect_to tokens_buy_path, alert: "Unknown pack quantity"
    end

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
