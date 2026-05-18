class ContestsController < ApplicationController
  include Solana::SessionAuth

  skip_before_action :require_authentication, only: [:index, :show, :my, :world_cup, :lobby, :leaderboard_poll]
  before_action :set_contest, only: [:show, :edit, :update, :toggle_selection, :enter, :clear_picks, :grade, :fill, :lock, :jump, :simulate_game, :simulate_batch, :reset, :payout_entry, :prepare_entry, :confirm_onchain_entry, :prepare_onchain_contest, :confirm_onchain_contest, :lobby, :leaderboard_poll]
  before_action :require_admin, only: [:new, :create, :edit, :update, :generator, :grade, :fill, :lock, :jump, :simulate_game, :simulate_batch, :reset, :payout_entry, :prepare_onchain_contest, :confirm_onchain_contest]
  before_action :require_geo_allowed, only: [:toggle_selection, :enter, :prepare_entry]

  def index
    @contests = Contest.where(status: [:open, :locked, :settled]).includes(:slate, :entries).with_attached_contest_image.order(created_at: :desc)
  end

  def my
    @contests = Contest.where(status: [:open, :locked, :settled]).order(created_at: :desc)
    if logged_in?
      @my_entries = current_user.entries.where(status: [:active, :complete]).includes(:contest, selections: { slate_matchup: [:team, :opponent_team] }).group_by(&:contest_id)
    else
      @my_entries = {}
    end
  end

  def new
    # Pre-fill from query params (used by the contest generator matrix at /contests/generator).
    # Validates contest_type against FORMATS so an invalid query string can't poison the form.
    requested_type = params[:contest_type].presence
    contest_type = Contest::FORMATS.key?(requested_type) ? requested_type : "medium"

    @contest = Contest.new(contest_type: contest_type)
    if params[:slate_id].present? && (prefilled_slate = Slate.find_by(id: params[:slate_id]))
      @contest.slate_id = prefilled_slate.id
      @default_sport = sport_for_slate(prefilled_slate)
    end
  end

  # Admin matrix view: slates × contest types. Each cell shows how many
  # contests of that combo exist, and clicks through to /contests/new
  # pre-filled with that slate + tier. Makes it visually obvious which
  # slate/tier combinations are missing contests.
  def generator
    @slates = Slate.where.not(name: "Default").where.not(starts_at: nil).order(:starts_at)
    @contest_counts = Contest.group(:slate_id, :contest_type).count   # → {[slate_id, "medium"] => 2, ...}
    @contests_by_cell = Contest.includes(:entries).order(created_at: :desc).group_by { |c| [c.slate_id, c.contest_type] }
  end

  def create
    @contest = Contest.new(contest_params)
    config = @contest.format_config
    @contest.entry_fee_cents = config[:entry_fee_cents]
    @contest.max_entries = config[:max_entries]
    @contest.status = :open
    # UI runs its own Phantom-as-creator on-chain handshake via the
    # prepare/confirm_onchain_contest endpoints. Suppress the after_create
    # auto-on-chain callback so the two flows don't fight each other.
    @contest.skip_onchain_callback = true

    rescue_and_log(target: @contest) do
      @contest.save!

      respond_to do |format|
        format.html { redirect_to @contest, notice: "Contest created!" }
        format.json { render json: { success: true, slug: @contest.slug } }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { render :new, status: :unprocessable_entity }
      format.json { render json: { success: false, error: e.message }, status: :unprocessable_entity }
    end
  end

  def edit
  end

  def update
    rescue_and_log(target: @contest) do
      @contest.update!(contest_update_params)
      redirect_to root_path, notice: "Contest updated."
    end
  rescue StandardError => e
    render :edit, status: :unprocessable_entity
  end

  # Build a partially-signed create_contest transaction for Phantom co-signing.
  # Admin signs (pays rent), returns base64 tx for creator to co-sign client-side.
  def prepare_onchain_contest
    rescue_and_log(target: @contest) do
      raise "Already onchain" if @contest.onchain?
      raise "Phantom wallet required" unless current_user.phantom_wallet?

      vault = Solana::Vault.new
      result = vault.build_create_contest(
        current_user.web3_solana_address,
        @contest.slug,
        **@contest.onchain_params
      )

      render json: {
        success: true,
        serialized_tx: result[:serialized_tx],
        contest_slug: @contest.slug,
        contest_pda: result[:contest_pda]
      }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  # Confirm an onchain contest after the creator has co-signed and submitted the tx.
  def confirm_onchain_contest
    rescue_and_log(target: @contest) do
      raise "Already onchain" if @contest.onchain?

      verify_solana_transaction!(params[:tx_signature])

      @contest.update!(
        onchain_contest_id: params[:contest_pda],
        onchain_tx_signature: params[:tx_signature]
      )

      invalidate_usdc_cache if logged_in?

      render json: { success: true, tx: params[:tx_signature], pda: params[:contest_pda] }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def payout_entry
    entry = @contest.entries.find_by(id: params[:entry_id])
    return render json: { success: false, error: "Entry not found" }, status: :not_found unless entry

    rescue_and_log(target: entry, parent: @contest) do
      raise "Contest not settled" unless @contest.settled?
      raise "No payout for this entry" if entry.payout_cents.to_i == 0
      raise "Already paid" if entry.payout_tx_signature.present?
      raise "User has no Solana wallet" unless entry.user.solana_connected?

      vault = Solana::Vault.new
      amount = Solana::Config.dollars_to_lamports(entry.payout_cents / 100.0)
      result = vault.transfer_spl(entry.user.solana_address, amount, mint: Solana::Config::USDC_MINT)

      entry.update!(payout_tx_signature: result[:signature])
      invalidate_usdc_cache

      render json: { success: true, tx: result[:signature], entry_id: entry.id }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def world_cup
    @contest = Contest.where(status: [:open, :locked, :settled]).order(created_at: :desc).first
    return redirect_to contests_path unless @contest
    redirect_to contest_path(@contest)
  end

  def show
    @creator = @contest.user
    @has_entry = logged_in? && @contest.entries.where(user: current_user, status: [:active, :complete]).exists?
    @seeds_data = load_seeds_data

    load_contest_board_data

    # "More Contests" selector at the bottom of the page.
    @other_contests = Contest.where(status: [:open, :locked]).ranked.where.not(id: @contest.id).includes(:slate)

    if @contest.onchain?
      begin
        @onchain_contest = Solana::Vault.new.read_contest(@contest.slug)
      rescue => e
        Rails.logger.warn "Failed to read onchain contest: #{e.message}"
      end
    end
  end

  # Legacy lobby route — kept for permalinks shared before the show/lobby
  # merge. Redirects to the canonical /contests/:slug.
  def lobby
    redirect_to contest_path(@contest), status: :moved_permanently
  end

  def leaderboard_poll
    version = params[:version].to_i
    current_version = @contest.updated_at.to_i

    if version == current_version
      render json: { changed: false }
    else
      load_contest_board_data
      html = render_to_string(partial: "contests/turf_totals_leaderboard", locals: { compact: true })
      render json: { changed: true, version: current_version, html: html }
    end
  end

  def enter
    entry = @contest.entries.cart.find_by(user: current_user)
    return redirect_to root_path, alert: "No cart entry found" unless entry

    # Onchain sessions MUST provide a wallet signature proof
    if onchain_session?
      raise "Wallet signature required" unless params[:signature].present?

      verify_solana_signature!(
        message: params[:message],
        signature_b58: params[:signature],
        pubkey_b58: params[:pubkey],
        session: session
      )

      raise "Wallet mismatch" unless params[:pubkey] == current_user.web3_solana_address
    end

    rescue_and_log(target: entry, parent: @contest) do
      @contest.with_lock do
        active_count = @contest.entries.where(status: [:active, :complete]).count
        raise "Contest is full" if @contest.max_entries && active_count >= @contest.max_entries

        tx_signature = nil
        onchain_entry_id = nil

        if @contest.onchain? && @contest.entry_fee_cents > 0 && current_user.managed_wallet? && !current_user.phantom_wallet?
          # Managed wallet: server-side transfer (blocking)
          vault = Solana::Vault.new
          usdc_mint = Solana::Config::USDC_MINT
          amount = @contest.entry_fee_cents * 10_000 # cents → USDC lamports (6 decimals)
          result = vault.transfer_from_user(current_user, amount, mint: usdc_mint)
          tx_signature = result[:signature]
        elsif @contest.onchain? && !onchain_session?
          # Offchain session entering onchain contest: blocking vault entry
          entry.entry_number ||= @contest.entries.where(user: current_user).where.not(entry_number: nil).count
          entry.save! if entry.entry_number_changed?

          vault = Solana::Vault.new
          vault.ensure_user_account(current_user.solana_address) if current_user.solana_connected?
          result = vault.enter_contest(current_user.solana_address, @contest.slug, entry.entry_number)
          tx_signature = result[:signature]
          onchain_entry_id = result[:entry_pda]
        end

        entry.confirm!(tx_signature: tx_signature, onchain_entry_id: onchain_entry_id)
      end

      respond_to do |format|
        format.html { redirect_to contest_path(@contest), notice: "#{current_user.display_name} entered the contest!" }
        format.json {
          render json: {
            success: true,
            redirect: contest_path(@contest),
            tx_signature: entry.onchain_tx_signature
          }
        }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to root_path, alert: e.message }
      format.json { render json: { success: false, error: e.message }, status: :unprocessable_entity }
    end
  end

  # Build a partially-signed enter_contest_direct transaction for Phantom users.
  # Admin signs (pays rent), returns base64 tx for user to co-sign client-side.
  def prepare_entry
    entry = @contest.entries.cart.find_by(user: current_user)
    return render json: { error: "No cart entry found" }, status: :unprocessable_entity unless entry

    # Verify Phantom wallet signature
    verify_solana_signature!(
      message: params[:message],
      signature_b58: params[:signature],
      pubkey_b58: params[:pubkey],
      session: session
    )

    rescue_and_log(target: entry, parent: @contest) do
      raise "Contest is not onchain" unless @contest.onchain?
      raise "Phantom wallet required" unless current_user.phantom_wallet?

      active_count = @contest.entries.where(status: [:active, :complete]).count
      raise "Contest is full" if @contest.max_entries && active_count >= @contest.max_entries

      # Validate selections
      raise "Exactly #{@contest.picks_required} selections required" unless entry.selections.count == @contest.picks_required
      entry.selections.includes(slate_matchup: :game).each do |s|
        raise "#{s.slate_matchup.team.name}'s game has already started" if s.slate_matchup.locked?
      end

      # Assign entry number
      entry.entry_number ||= @contest.entries.where(user: current_user).where.not(entry_number: nil).count
      entry.save! if entry.entry_number_changed?

      vault = Solana::Vault.new

      # Ensure user's onchain account exists and is current (auto-migrate if needed)
      vault.ensure_user_account(current_user.web3_solana_address)

      result = vault.build_enter_contest_direct(
        current_user.web3_solana_address,
        @contest.slug,
        entry.entry_number
      )

      render json: {
        success: true,
        serialized_tx: result[:serialized_tx],
        entry_id: entry.id,
        entry_pda: result[:entry_pda]
      }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  # Confirm an onchain direct entry after the user has co-signed and submitted the tx.
  def confirm_onchain_entry
    entry = @contest.entries.find_by(id: params[:entry_id], user: current_user, status: :cart)
    return render json: { error: "Entry not found" }, status: :not_found unless entry

    rescue_and_log(target: entry, parent: @contest) do
      verify_solana_transaction!(params[:tx_signature])
      raise "Wallet not linked" unless current_user.web3_solana_address.present?

      entry.confirm_onchain!(
        tx_signature: params[:tx_signature],
        entry_pda: params[:entry_pda]
      )

      seeds_earned = User::SEEDS_PER_ENTRY
      seeds_total = 0
      if current_user.solana_connected?
        begin
          onchain = Solana::Vault.new.sync_balance(current_user.solana_address)
          seeds_total = onchain&.dig(:seeds) || 0
        rescue => e
          Rails.logger.warn "Failed to read seeds after entry: #{e.message}"
        end
      end

      render json: {
        success: true,
        redirect: contest_path(@contest),
        tx_signature: params[:tx_signature],
        seeds_earned: seeds_earned,
        seeds_total: seeds_total,
        seeds_level: User.level_for(seeds_total)
      }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def clear_picks
    entry = @contest.entries.cart.find_by(user: current_user)

    rescue_and_log(target: entry, parent: @contest) do
      if entry
        entry.update!(status: :abandoned)
      end

      respond_to do |format|
        format.html { redirect_to root_path, notice: "Picks cleared" }
        format.json { render json: { success: true } }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to root_path, alert: e.message }
      format.json { render json: { success: false, error: e.message }, status: :unprocessable_entity }
    end
  end

  def toggle_selection
    unless @contest.open?
      return render json: { error: "Contest is not open" }, status: :unprocessable_entity
    end

    matchup = @contest.matchups.find_by(id: params[:matchup_id])
    return render json: { error: "Matchup not found" }, status: :not_found unless matchup

    entry = @contest.entries.find_or_create_by!(user: current_user, status: :cart)

    rescue_and_log(target: entry, parent: @contest) do
      selections_hash = entry.toggle_selection!(matchup)

      if selections_hash.nil?
        render json: { selections: {}, selection_count: 0 }
      else
        render json: { selections: selections_hash, selection_count: selections_hash.size }
      end
    end
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def simulate_game
    rescue_and_log(target: @contest) do
      game = @contest.simulate_next_game!
      redirect_to @contest, notice: "Simulated #{game.home_team.name} vs #{game.away_team.name}: #{game.home_score}-#{game.away_score}"
    end
  rescue StandardError => e
    redirect_to @contest || root_path, alert: e.message
  end

  def grade
    rescue_and_log(target: @contest) do
      @contest.grade!

      respond_to do |format|
        format.html { redirect_to @contest, notice: "Contest graded and settled!" }
        format.json {
          render json: {
            success: true,
            redirect: contest_path(@contest),
            tx_signature: @contest.onchain_tx_signature
          }
        }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to @contest || root_path, alert: e.message }
      format.json { render json: { success: false, error: e.message }, status: :unprocessable_entity }
    end
  end

  def fill
    rescue_and_log(target: @contest) do
      @contest.fill!(users: User.where(email: [
        "alex@mcritchie.studio", "mason@mcritchie.studio",
        "mack@mcritchie.studio", "turf@mcritchie.studio"
      ]))
      redirect_to @contest, notice: "Contest filled with #{@contest.entries.where(status: [:active, :complete]).count} entries!"
    end
  rescue StandardError => e
    redirect_to @contest || root_path, alert: e.message
  end

  def lock
    rescue_and_log(target: @contest) do
      @contest.update!(status: :locked)
      redirect_to @contest, notice: "Contest locked!"
    end
  rescue StandardError => e
    redirect_to @contest || root_path, alert: e.message
  end

  def jump
    rescue_and_log(target: @contest) do
      @contest.jump!
      redirect_to @contest, notice: "Contest jumped! Results simulated and settled."
    end
  rescue StandardError => e
    redirect_to @contest || root_path, alert: e.message
  end

  def reset
    rescue_and_log(target: @contest) do
      @contest.reset!
      redirect_to root_path, notice: "Contest reset!"
    end
  rescue StandardError => e
    redirect_to root_path, alert: e.message
  end

  def simulate_batch
    count = params[:count].to_i
    count = 5 if count <= 0

    rescue_and_log(target: @contest) do
      simulated = @contest.simulate_games!(count)
      redirect_to @contest, notice: "Simulated #{simulated} game(s)."
    end
  rescue StandardError => e
    redirect_to @contest || root_path, alert: e.message
  end

  private

  # Verify a Solana transaction signature exists on-chain and was successful.
  # Prevents fake TX submissions from marking entries/contests as onchain.
  def verify_solana_transaction!(signature)
    raise "Transaction signature required" if signature.blank?

    client = Solana::Vault.new.client
    tx_info = client.get_transaction(signature)
    raise "Transaction not found on-chain" unless tx_info
    raise "Transaction failed on-chain" if tx_info.dig("meta", "err")
  end

  def set_contest
    @contest = Contest.find_by(slug: params[:id])
    return if @contest

    respond_to do |format|
      format.html { redirect_to root_path, alert: "Contest not found" }
      format.json { render json: { error: "Contest not found" }, status: :not_found }
    end
  end

  def load_contest_board_data
    if @contest.locked? || @contest.settled?
      cache_key = "contest/#{@contest.slug}/v#{@contest.updated_at.to_i}/show_data"
      cached = Rails.cache.fetch(cache_key, expires_in: 1.hour) do
        {
          matchups: @contest.matchups.ranked.includes(:team, :opponent_team, :game).to_a,
          entries: @contest.entries.where(status: [:active, :complete]).includes(:user, selections: { slate_matchup: [:team, :game] }).order(score: :desc).to_a
        }
      end
      @matchups = cached[:matchups]
      @entries = cached[:entries]
    else
      @matchups = @contest.matchups.ranked.includes(:team, :opponent_team, :game)
      @entries = @contest.entries.where(status: [:active, :complete]).includes(:user, selections: { slate_matchup: [:team, :game] }).order(score: :desc)
    end
    @cart_entry = @contest.entries.cart.find_by(user: current_user) if logged_in?
  end

  def load_seeds_data
    return unless logged_in? && current_user.solana_connected?

    begin
      onchain = Solana::Vault.new.sync_balance(current_user.solana_address)
      seeds = onchain&.dig(:seeds) || 0
    rescue => e
      Rails.logger.warn "Failed to read on-chain seeds: #{e.message}"
      seeds = 0
    end

    {
      seeds: seeds,
      level: User.level_for(seeds),
      toward_next: User.seeds_toward_next_level(seeds),
      progress: User.seeds_progress_percent(seeds),
      seeds_to_next: User::SEEDS_PER_LEVEL - User.seeds_toward_next_level(seeds)
    }
  end

  def contest_params
    params.require(:contest).permit(:name, :slate_id, :contest_type, :starts_at, :contest_image, :locks_at_date_selected, :locks_at_time_selected, :locks_at_timezone_selected)
  end

  # Best-effort sport derivation from a slate's name. Slate/Team don't carry
  # a sport column in this app yet; matching the name string is sufficient
  # since slate names are operator-controlled and consistent.
  #   "World Cup 2026 Group 1" → "fifa"
  #   "NFL 2026 Week 1"        → "nfl"
  def sport_for_slate(slate)
    return "fifa" unless slate
    name = slate.name.to_s.downcase
    return "nfl"  if name.match?(/\bnfl\b|\bweek\s+\d/)
    return "fifa" if name.include?("world cup") || name.include?("fifa") || name.include?("uefa") || name.include?("group")
    "fifa"
  end

  def contest_update_params
    params.require(:contest).permit(:name, :tagline, :rank, :contest_image, :starts_at, :locks_at_date_selected, :locks_at_time_selected, :locks_at_timezone_selected)
  end
end
