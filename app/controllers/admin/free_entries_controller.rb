module Admin
  class FreeEntriesController < ApplicationController
    before_action :require_admin

    SEEDS_PER_LEVEL = User::SEEDS_PER_LEVEL # 100
    PER_PAGE        = 25

    def index
      scope         = users_with_wallet.order(:id)
      @total_users  = scope.count
      @page         = [params[:page].to_i, 1].max
      @total_pages  = [(@total_users.to_f / PER_PAGE).ceil, 1].max
      @page         = @total_pages if @page > @total_pages
      paged_users   = scope.limit(PER_PAGE).offset((@page - 1) * PER_PAGE)
      @users_data   = compute_user_data_for(paged_users)
      @page_owed    = @users_data.sum { |d| d[:owed] }
      @page_minted  = @users_data.sum { |d| d[:minted] }
    end

    def mint
      user = User.find_by!(slug: params[:user_slug])
      rescue_and_log(target: user) do
        # OPSEC-030: serialize per-user. Double-click previously raced both
        # requests past compute_owed_for and both minted N tokens. The
        # on-chain sequence-collision check is still the source-of-truth
        # protection against actual double-mint, but the lock prevents the
        # wasted admin SOL rent on a doomed second instruction.
        user.with_lock do
          owed = compute_owed_for(user)
          raise "Nothing owed to #{user.display_name}" if owed.zero?
          count = params[:count].present? ? params[:count].to_i : owed
          count = [count, owed].min
          signatures = mint_n_tokens(user, count)
          flash[:notice] = "Minted #{signatures.length} free #{'entry'.pluralize(signatures.length)} for #{user.display_name}"
        end
      end
      redirect_to admin_free_entries_path
    end

    def mint_all
      rescue_and_log do
        users = users_with_wallet
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

    # User has no `solana_address` column — the schema splits it into
    # `web2_solana_address` (managed) and `web3_solana_address` (Phantom).
    # `User#solana_address` (method) returns web3 || web2.
    def users_with_wallet
      User.where(
        "(web3_solana_address IS NOT NULL AND web3_solana_address != '') OR " \
        "(web2_solana_address IS NOT NULL AND web2_solana_address != '')"
      )
    end

    # Fans the 2 Solana reads (sync_balance + list_entry_tokens) per user
    # out across threads so wall time scales with the slowest single user
    # rather than the sum. Each thread gets its own Solana::Vault.new (the
    # Net::HTTP-backed client isn't safe to share) and is wrapped in
    # Rails.application.executor.wrap so the OutboundRequest audit write
    # gets a proper AR connection from the pool.
    def compute_user_data_for(users_scope)
      users = users_scope.to_a
      results = users.map do |user|
        seeds_thread = Thread.new do
          Rails.application.executor.wrap do
            (Solana::Vault.new.sync_balance(user.solana_address) rescue nil)&.dig(:seeds) || 0
          end
        end
        tokens_thread = Thread.new do
          Rails.application.executor.wrap do
            (Solana::Vault.new.list_entry_tokens(user.solana_address) rescue [])
          end
        end
        [user, seeds_thread, tokens_thread]
      end

      results.map do |user, seeds_t, tokens_t|
        seeds      = seeds_t.value
        tokens     = tokens_t.value
        level      = (seeds / SEEDS_PER_LEVEL) + 1
        minted     = tokens.length
        unconsumed = tokens.count { |t| !t[:consumed] }
        owed       = [(seeds / SEEDS_PER_LEVEL) - minted, 0].max
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
