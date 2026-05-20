class AdminController < ApplicationController
  before_action :require_admin, except: [:usdc_balance]

  def navbar
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
