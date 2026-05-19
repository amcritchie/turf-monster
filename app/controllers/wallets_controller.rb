class WalletsController < ApplicationController
  before_action :require_login
  before_action :require_geo_allowed, only: [:withdraw, :stripe_deposit, :moonpay_deposit, :topup]

  def show
    @user = current_user
    @pending_withdrawals = TransactionLog.where(user: current_user, transaction_type: "withdrawal", status: %w[pending approved]).order(created_at: :desc)
    @recent_transactions = TransactionLog.where(user: current_user).order(created_at: :desc).limit(10)

    # Fetch SOL balance if wallet connected and devnet
    if current_user.solana_connected? && Solana::Config.devnet?
      begin
        client = Solana::Client.new
        result = client.get_balance(current_user.solana_address)
        sol_lamports = result.is_a?(Hash) ? result["value"] : result
        @sol_balance = sol_lamports.to_f / 1_000_000_000
      rescue => e
        Rails.logger.warn "Failed to fetch SOL balance: #{e.message}"
      end
    end
  end

  def topup
    unless current_user.phantom_wallet?
      return redirect_to wallet_path, alert: "Top-up via MoonPay is only available for self-custody wallets."
    end
    @user = current_user
  end

  def stripe_deposit
    amount_dollars = params[:amount].to_f
    return redirect_to wallet_path, alert: "Amount must be between $1 and $500" unless amount_dollars >= 1 && amount_dollars <= 500

    amount_cents = (amount_dollars * 100).to_i

    rescue_and_log(target: current_user) do
      session = Stripe::Checkout::Session.create(
        payment_method_types: ["card"],
        line_items: [{
          price_data: {
            currency: "usd",
            product_data: { name: "Turf Monster Deposit" },
            unit_amount: amount_cents
          },
          quantity: 1
        }],
        mode: "payment",
        success_url: "#{wallet_url}?deposit=success",
        cancel_url: "#{wallet_url}?deposit=cancelled",
        metadata: {
          user_id: current_user.id,
          amount_cents: amount_cents,
          wallet_address: current_user.solana_address
        }
      )

      redirect_to session.url, allow_other_host: true
    end
  rescue StandardError => e
    redirect_to wallet_path, alert: "Stripe checkout failed: #{e.message}"
  end

  def moonpay_deposit
    rescue_and_log(target: current_user) do
      raise "No wallet connected" unless current_user.solana_connected?

      config = Rails.application.config.moonpay
      raise "MoonPay not configured" unless config[:api_key].present?

      params_hash = {
        apiKey: config[:api_key],
        currencyCode: "usdc_sol",
        walletAddress: current_user.solana_address,
        colorCode: "%234BAF50",
        redirectURL: wallet_url
      }

      query_string = params_hash.map { |k, v| "#{k}=#{v}" }.join("&")

      # Sign the URL if secret key is available
      if config[:secret_key].present?
        signature = Base64.strict_encode64(
          OpenSSL::HMAC.digest("SHA256", config[:secret_key], "?#{query_string}")
        )
        query_string += "&signature=#{CGI.escape(signature)}"
      end

      moonpay_url = "#{config[:base_url]}?#{query_string}"
      redirect_to moonpay_url, allow_other_host: true
    end
  rescue StandardError => e
    redirect_to wallet_path, alert: "MoonPay failed: #{e.message}"
  end

  def withdraw
    amount_dollars = params[:amount].to_f
    return redirect_to wallet_path, alert: "Invalid amount" if amount_dollars <= 0

    amount_cents = (amount_dollars * 100).to_i

    rescue_and_log(target: current_user) do
      raise "No wallet connected" unless current_user.solana_connected?

      TransactionLog.record!(
        user: current_user,
        type: "withdrawal",
        amount_cents: amount_cents,
        direction: "debit",
        description: "Withdrawal request $#{'%.2f' % amount_dollars}",
        status: "pending"
      )
      redirect_to wallet_path, notice: "Withdrawal of $#{'%.2f' % amount_dollars} submitted for review."
    end
  rescue StandardError => e
    redirect_to wallet_path, alert: "Withdrawal failed: #{e.message}"
  end

  def faucet
    rescue_and_log(target: current_user) do
      raise "Faucet is production-disabled" if Rails.env.production?  # OPSEC-020
      raise "Faucet only available on Devnet" unless Solana::Config.devnet?
      raise "No wallet connected" unless current_user.solana_connected?

      vault = Solana::Vault.new
      amount_lamports = Solana::Config.dollars_to_lamports(10.0) # $10 USDC
      vault.ensure_ata(current_user.solana_address, mint: Solana::Config::USDC_MINT)
      result = vault.fund_user(current_user.solana_address, amount_lamports)

      TransactionLog.record!(user: current_user, type: "faucet", amount_cents: 10_00, direction: "credit", description: "Devnet faucet $10.00", onchain_tx: result[:signature])
      invalidate_usdc_cache
      redirect_to wallet_path, notice: "Added $10.00 test USDC to your balance."
    end
  rescue StandardError => e
    redirect_to wallet_path, alert: "Faucet failed: #{e.message}"
  end

  def airdrop
    rescue_and_log(target: current_user) do
      raise "Airdrop is production-disabled" if Rails.env.production?  # OPSEC-020
      raise "Airdrop only available on Devnet" unless Solana::Config.devnet?
      raise "No Solana wallet connected" unless current_user.solana_connected?

      client = Solana::Client.new
      signature = client.request_airdrop(current_user.solana_address, 1_000_000_000) # 1 SOL
      redirect_to wallet_path, notice: "Airdropped 1 SOL! TX: #{signature}"
    end
  rescue StandardError => e
    redirect_to wallet_path, alert: "Airdrop failed: #{e.message}"
  end

  def sync
    rescue_and_log(target: current_user) do
      unless current_user.solana_connected?
        return redirect_to wallet_path, alert: "No Solana wallet connected."
      end

      vault = Solana::Vault.new
      onchain = vault.sync_balance(current_user.solana_address)

      if onchain
        @onchain_balance = onchain
        flash.now[:notice] = "Onchain balance: $#{'%.2f' % onchain[:balance_dollars]}"
      else
        flash.now[:alert] = "No onchain account found. Deposit to create one."
      end

      @user = current_user
      @pending_withdrawals = TransactionLog.where(user: current_user, transaction_type: "withdrawal", status: %w[pending approved]).order(created_at: :desc)
      @recent_transactions = TransactionLog.where(user: current_user).order(created_at: :desc).limit(10)
      render :show
    end
  rescue StandardError => e
    redirect_to wallet_path, alert: "Sync failed: #{e.message}"
  end

  private

  def require_login
    return if logged_in?
    redirect_to login_path, alert: "Please log in to access your wallet."
  end
end
