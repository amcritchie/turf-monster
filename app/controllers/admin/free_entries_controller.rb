module Admin
  class FreeEntriesController < ApplicationController
    before_action :require_admin

    SEEDS_PER_LEVEL = User::SEEDS_PER_LEVEL # 100

    def index
      @users_data = compute_user_data
      @total_owed = @users_data.sum { |d| d[:owed] }
      @total_minted = @users_data.sum { |d| d[:minted] }
    end

    def mint
      user = User.find_by!(slug: params[:user_slug])
      rescue_and_log(target: user) do
        owed = compute_owed_for(user)
        raise "Nothing owed to #{user.display_name}" if owed.zero?
        count = params[:count].present? ? params[:count].to_i : owed
        count = [count, owed].min
        signatures = mint_n_tokens(user, count)
        flash[:notice] = "Minted #{signatures.length} free #{'entry'.pluralize(signatures.length)} for #{user.display_name}"
      end
      redirect_to admin_free_entries_path
    end

    def mint_all
      rescue_and_log do
        users = User.where.not(solana_address: nil)
        total = 0
        users.find_each do |user|
          owed = compute_owed_for(user)
          next if owed.zero?
          mint_n_tokens(user, owed)
          total += owed
        end
        flash[:notice] = "Minted #{total} free entries across all users"
      end
      redirect_to admin_free_entries_path
    end

    private

    def vault
      @vault ||= Solana::Vault.new
    end

    def compute_user_data
      User.where.not(solana_address: [nil, ""]).map do |user|
        seeds = (vault.sync_balance(user.solana_address) rescue nil)&.dig(:seeds) || 0
        tokens = (vault.list_entry_tokens(user.solana_address) rescue [])
        level = (seeds / SEEDS_PER_LEVEL) + 1
        minted = tokens.length
        unconsumed = tokens.count { |t| !t[:consumed] }
        owed = [(seeds / SEEDS_PER_LEVEL) - minted, 0].max
        { user: user, seeds: seeds, level: level, minted: minted, unconsumed: unconsumed, owed: owed }
      end.sort_by { |d| [-d[:owed], -d[:seeds]] }
    end

    def compute_owed_for(user)
      seeds = (vault.sync_balance(user.solana_address) rescue nil)&.dig(:seeds) || 0
      tokens = (vault.list_entry_tokens(user.solana_address) rescue [])
      [(seeds / SEEDS_PER_LEVEL) - tokens.length, 0].max
    end

    def mint_n_tokens(user, count)
      signatures = []
      count.times do
        result = vault.mint_entry_token(
          wallet_address: user.solana_address,
          source: :operator,
          source_ref: "operator_#{Time.now.to_i}"
        )
        signatures << result[:signature]
      end
      signatures
    end
  end
end
