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

    price_cents = StripePurchase.pack_price_cents(quantity)

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
        success_url: "#{tokens_processing_url}?session_id={CHECKOUT_SESSION_ID}",
        cancel_url:  "#{tokens_buy_url}?purchase=cancelled",
        metadata: {
          kind: "tokens",
          user_id: current_user.id,
          quantity: quantity,
          wallet_address: current_user.solana_address
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
    return if current_user&.admin? && Solana::Config.devnet?
    redirect_to tokens_buy_path, alert: "Dev mint is admin + devnet only."
  end
end
