class ContestsController < ApplicationController
  include Solana::SessionAuth

  skip_before_action :require_authentication, only: [:index, :show, :my, :world_cup, :lobby, :leaderboard_poll]
  before_action :set_contest, only: [:show, :edit, :update, :toggle_selection, :enter, :clear_picks, :grade, :fill, :lock, :jump, :simulate_game, :simulate_batch, :reset, :prepare_entry, :stamp_entry_signature, :recover_pending_entry, :confirm_onchain_entry, :prepare_onchain_contest, :confirm_onchain_contest, :lobby, :leaderboard_poll, :pick, :grade_round]
  before_action :require_admin, only: [:new, :create, :finalize, :edit, :update, :generator, :generate_bundle, :grade, :fill, :lock, :jump, :simulate_game, :simulate_batch, :reset, :prepare_onchain_contest, :confirm_onchain_contest, :grade_round]
  before_action :require_geo_allowed, only: [:toggle_selection, :enter, :prepare_entry]
  # B4 / OPSEC-048: frozen accounts can browse but cannot spend or enter.
  before_action :require_unfrozen_account, only: [:enter, :prepare_entry, :confirm_onchain_entry, :toggle_selection]

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
    contest_type = Contest.selectable_formats.key?(requested_type) ? requested_type : "medium"

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

  # Provision a curated contest + landing-page bundle (see ContestBundle).
  # A newly created contest builds its on-chain PDA via the after_create callback.
  def generate_bundle
    rescue_and_log do
      result = ContestBundle.generate!(params[:key], creator: current_user)
      flash[:notice] = %(Provisioned "#{result[:contest].name}" + /l/#{result[:landing_page].slug}.)
    end
    redirect_to generator_contests_path
  rescue StandardError => e
    redirect_to generator_contests_path, alert: "Generate failed: #{e.message}"
  end

  # Phantom-driven contest creation:
  #
  #   step 1: POST /contests             → #create   — build partially-signed TX, no DB write
  #   step 2: client signs in Phantom    → broadcast + confirm via web3.js
  #   step 3: POST /contests/finalize    → #finalize — verify TX on-chain, create DB row
  #
  # Form params get signed into a token in step 1 and echoed back in step 3
  # so the server doesn't have to trust the client's re-posted values.
  ONCHAIN_CREATE_TOKEN_KEY = :onchain_contest_create
  ONCHAIN_CREATE_TOKEN_TTL = 10.minutes

  def create
    return render_create_error("Phantom wallet required to create contests") unless current_user.phantom_wallet?

    contest = build_unpersisted_contest_from_params
    unless Contest.selectable_formats.key?(contest.contest_type)
      return render_create_error("Unknown or unavailable contest format")
    end
    if (err = onchain_create_precheck(contest, current_user))
      return render_create_error(err)
    end

    vault  = Solana::Vault.new
    result = vault.build_create_contest(
      current_user.web3_solana_address,
      contest.name_slug,
      **contest.onchain_params
    )

    render json: {
      success:       true,
      serialized_tx: result[:serialized_tx],
      contest_pda:   result[:contest_pda],
      slug:          contest.name_slug,
      params_token:  sign_onchain_create_payload(contest, current_user)
    }
  rescue StandardError => e
    Rails.logger.error("[ContestsController#create] #{e.class}: #{e.message}")
    render_create_error(e.message)
  end

  def finalize
    payload = verify_onchain_create_payload(params[:params_token])
    raise "User mismatch — token was issued to a different user" unless payload[:user_id] == current_user.id

    derived_pda_b58 = Solana::Keypair.encode_base58(Solana::Vault.new.contest_pda(payload[:slug]).first)
    raise "Contest PDA mismatch — slug=#{payload[:slug]}" unless params[:contest_pda] == derived_pda_b58
    raise "A contest with that name already exists" if Contest.exists?(slug: payload[:slug])

    # OPSEC-010: assert the tx is the create_contest IX targeting THIS PDA,
    # signed by the original creator from the server-issued params_token.
    verify_solana_transaction!(
      params[:tx_signature],
      instruction: "create_contest",
      signer: payload[:creator_pubkey],
      writable: derived_pda_b58
    )

    contest = build_finalized_contest(payload, derived_pda_b58, params[:tx_signature])
    contest.contest_image.attach(params[:contest_image]) if params[:contest_image].present?
    contest.save!

    render json: { success: true, redirect: contest_path(contest), slug: contest.slug }
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    render_create_error("Invalid or expired form token — restart the contest creation flow.")
  rescue StandardError => e
    Rails.logger.error("[ContestsController#finalize] #{e.class}: #{e.message}")
    render_create_error(e.message)
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

      # OPSEC-010: server-derive the contest PDA from the (already-known)
      # contest slug; refuse to trust params[:contest_pda] without checking.
      derived_pda_b58 = Solana::Keypair.encode_base58(Solana::Vault.new.contest_pda(@contest.slug).first)
      raise "Contest PDA mismatch" unless params[:contest_pda] == derived_pda_b58

      verify_solana_transaction!(
        params[:tx_signature],
        instruction: "create_contest",
        signer: current_user.web3_solana_address,
        writable: derived_pda_b58
      )

      @contest.update!(
        onchain_contest_id: derived_pda_b58,
        onchain_tx_signature: params[:tx_signature]
      )

      invalidate_usdc_cache if logged_in?

      render json: { success: true, tx: params[:tx_signature], pda: derived_pda_b58 }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  # Audit H2 (2026-05-23): `payout_entry` was removed.
  #
  # It was a per-entry admin button that called `vault.transfer_spl` from
  # admin's USDC ATA → user's ATA. Combined with `Contest#grade!` ->
  # `settle_onchain!` (which credits on-chain UserAccount.balance via the
  # 2-of-3 settle_contest cosign flow), the two paths together produced a
  # **double payout**: settle credits the user's vault balance + admin then
  # transfers USDC directly to user ATA + user later withdraws the credited
  # balance = paid twice.
  #
  # The single source of truth for payouts is now on-chain settle. After
  # cosign confirms, winners' balances are credited automatically; users
  # withdraw on their own schedule via /wallet. No admin per-entry button.

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
      partial = @contest.world_cup_survivor? ? "contests/world_cup_survivor_leaderboard" : "contests/turf_totals_leaderboard"
      html = render_to_string(partial: partial, locals: { compact: true })
      render json: { changed: true, version: current_version, html: html }
    end
  end

  def enter
    entry = @contest.entries.cart.find_by(user: current_user)
    # Survivor contests have no pick-building phase — entering creates the entry
    # directly. (Turf Totals' cart entry is created by toggle_selection.)
    entry ||= @contest.entries.find_or_create_by!(user: current_user, status: :cart) if @contest.world_cup_survivor?
    return redirect_to root_path, alert: "No cart entry found" unless entry

    # Onchain sessions MUST provide a wallet signature proof
    if onchain_session?
      raise "Wallet signature required" unless params[:signature].present?

      verify_solana_signature!(
        message: params[:message],
        signature_b58: params[:signature],
        pubkey_b58: params[:pubkey],
        session: session,
        expected_user_id: current_user.id  # OPSEC-005
      )

      raise "Wallet mismatch" unless params[:pubkey] == current_user.web3_solana_address
    end

    # Declared here so the respond_to block below (outside the with_lock
    # transaction) can reference it for the JSON payload.
    token_consumed = false

    rescue_and_log(target: entry, parent: @contest) do
      @contest.with_lock do
        active_count = @contest.entries.where(status: [:active, :complete]).count
        raise "Contest is full" if @contest.max_entries && active_count >= @contest.max_entries

        # On-chain entries require a configured season (seed_schedule lives on its PDA).
        # Catch the missing-season case early with a clear error instead of a cryptic
        # Anchor AccountNotInitialized further down.
        if @contest.onchain?
          current_sid = SeasonConfig.current_season_id
          raise "No active season configured. Set one at /admin/seasons before users can enter on-chain contests." if current_sid.to_i.zero?
        end

        # A paid contest must be backed by an on-chain Contest PDA — that PDA is
        # where the entry token / USDC payment is recorded. An off-chain paid
        # contest has no payment rail, so refuse rather than create a free entry.
        # (Entry#confirm! enforces the same gate as a model-level backstop.)
        if @contest.entry_fee_cents.to_i.positive? && !@contest.onchain?
          raise "This contest isn't on-chain yet — paid entry is unavailable."
        end

        tx_signature = nil
        onchain_entry_id = nil

        if @contest.onchain? && @contest.entry_fee_cents > 0 && current_user.managed_wallet? && !current_user.phantom_wallet?
          # Web2 / managed wallet: consume an on-chain EntryTokenAccount via the new
          # enter_contest_with_token instruction. Atomic — entry creation + token consume
          # + seeds +65 happen in one TX. No USDC transfer (token IS the payment).
          token = current_user.next_unconsumed_entry_token
          raise "No entry tokens. Buy at /tokens/buy" unless token

          entry.entry_number ||= @contest.entries.where(user: current_user).where.not(entry_number: nil).count
          entry.save! if entry.entry_number_changed?

          vault = Solana::Vault.new
          vault.ensure_user_account(current_user.solana_address) if current_user.solana_connected?
          # OPSEC-004: pass the managed wallet's keypair — turf-vault v0.12.0
          # requires the token owner to sign the consume.
          result = vault.enter_contest_with_token(
            current_user.solana_address,
            @contest.slug,
            entry.entry_number,
            token[:pda],
            user_keypair: current_user.solana_keypair,
            season_id: @contest.season_id
          )
          tx_signature = result[:signature]
          onchain_entry_id = result[:entry_pda]
          token_consumed = true
        elsif @contest.onchain? && !onchain_session?
          # Offchain session entering onchain contest: blocking vault entry
          entry.entry_number ||= @contest.entries.where(user: current_user).where.not(entry_number: nil).count
          entry.save! if entry.entry_number_changed?

          vault = Solana::Vault.new
          vault.ensure_user_account(current_user.solana_address) if current_user.solana_connected?
          result = vault.enter_contest(current_user.solana_address, @contest.slug, entry.entry_number, season_id: @contest.season_id)
          tx_signature = result[:signature]
          onchain_entry_id = result[:entry_pda]
        end

        entry.confirm!(tx_signature: tx_signature, onchain_entry_id: onchain_entry_id)
      end

      respond_to do |format|
        format.html { redirect_to contest_lobby_path(@contest), notice: "#{current_user.display_name} entered the contest!" }
        format.json {
          seeds_earned = 0
          seeds_total = 0
          seeds_level = 0
          if entry.onchain_tx_signature.present? && entry.entry_number.present?
            begin
              seeds_earned = Solana::Vault.new.seeds_for_entry(entry.entry_number)
            rescue => e
              Rails.logger.warn "Failed to read seeds_for_entry: #{e.message}"
            end
            if current_user.solana_connected?
              begin
                onchain = Solana::Vault.new.sync_balance(current_user.solana_address)
                seeds_total = onchain&.dig(:seeds) || 0
              rescue => e
                Rails.logger.warn "Failed to read seeds after entry: #{e.message}"
              end
            end
            seeds_level = User.level_for(seeds_total)
          end

          render json: {
            success: true,
            redirect: contest_lobby_path(@contest),
            tx_signature: entry.onchain_tx_signature,
            # Flag for the client: true iff this entry was paid for by
            # an on-chain EntryTokenAccount consumption. Drives the
            # navbar 🎟️ punch animation (animateFreeEntryBadge).
            token_consumed: token_consumed,
            seeds_earned: seeds_earned,
            seeds_total: seeds_total,
            seeds_level: seeds_level
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
    # Survivor contests have no pick-building phase — see #enter.
    entry ||= @contest.entries.find_or_create_by!(user: current_user, status: :cart) if @contest.world_cup_survivor?
    return render json: { error: "No cart entry found" }, status: :unprocessable_entity unless entry

    # Verify Phantom wallet signature
    verify_solana_signature!(
      message: params[:message],
      signature_b58: params[:signature],
      pubkey_b58: params[:pubkey],
      session: session,
      expected_user_id: current_user.id  # OPSEC-005
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
        entry.entry_number,
        season_id: @contest.season_id
      )

      # Persist a PendingTransaction so a refresh mid-flight (between sign
      # and confirm_onchain_entry) leaves a server-side trail. Without it,
      # the user's first signature can be silently consumed on-chain while
      # the cart entry stays in `cart` status — and a retry hits Anchor's
      # `init` constraint, surfacing as a generic error. Status flips to
      # `submitted` via stamp_entry_signature after broadcast, then
      # `confirmed` in confirm_onchain_entry. Any pending/submitted PT
      # found on next page load is recoverable (admin can audit, or future
      # client logic can auto-retry confirm using the stamped signature).
      ptx = PendingTransaction.create!(
        tx_type: "enter_contest_direct",
        serialized_tx: result[:serialized_tx],
        status: "pending",
        target: entry,
        initiator_address: current_user.web3_solana_address,
        metadata: { entry_pda: result[:entry_pda], contest_slug: @contest.slug }.to_json
      )

      render json: {
        success: true,
        serialized_tx: result[:serialized_tx],
        entry_id: entry.id,
        entry_pda: result[:entry_pda],
        ptx_slug: ptx.slug
      }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  # Stamp the on-chain signature onto the PendingTransaction created by
  # prepare_entry. Called by the client immediately after Phantom's
  # sendRawTransaction resolves and before connection.confirmTransaction —
  # so a refresh during the confirmation wait still has a server-side
  # signature trail. The endpoint is cheap (single UPDATE) and adds one
  # round-trip to the critical entry path.
  def stamp_entry_signature
    return render json: { error: "Missing ptx_slug or tx_signature" }, status: :unprocessable_entity if params[:ptx_slug].blank? || params[:tx_signature].blank?
    ptx = PendingTransaction.where(status: %w[pending submitted]).find_by(slug: params[:ptx_slug])
    return render json: { error: "Pending transaction not found" }, status: :not_found unless ptx
    # Don't allow stamping a PT that belongs to a different user — initiator
    # is the only authorization signal we have here.
    return render json: { error: "Not authorized" }, status: :forbidden unless ptx.initiator_address == current_user&.web3_solana_address
    ptx.update!(tx_signature: params[:tx_signature], status: "submitted")
    render json: { success: true }
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  # Resolve a PendingTransaction stranded by a mid-flight refresh. The
  # client polls this when the contest page loads with a pending/submitted
  # PT belonging to the current user. Three outcomes:
  #   - confirmed:  signature finalized on-chain → entry promoted to active,
  #                 PT marked confirmed, client redirects to the lobby
  #   - processing: signature still unknown / propagating → client re-polls
  #                 after a short delay (handled by the board JS)
  #   - failed:     signature errored, never broadcast, or recovery threw
  #                 → PT marked failed, client closes modal and frees the
  #                 user to retry the entry flow
  def recover_pending_entry
    return render json: { error: "Missing ptx_slug" }, status: :unprocessable_entity if params[:ptx_slug].blank?
    ptx = PendingTransaction.where(status: %w[pending submitted]).find_by(slug: params[:ptx_slug])
    return render json: { status: "missing" } unless ptx
    return render json: { error: "Not authorized" }, status: :forbidden unless ptx.initiator_address == current_user&.web3_solana_address

    entry = ptx.target
    return render json: { error: "Invalid PT target" }, status: :unprocessable_entity unless entry.is_a?(Entry) && entry.contest_id == @contest.id

    # Already-active entry → close the loop on the PT and short-circuit.
    if entry.active?
      ptx.update!(status: "confirmed")
      return render json: {
        status: "confirmed",
        redirect: contest_lobby_path(@contest),
        tx_signature: entry.onchain_tx_signature
      }
    end

    # Signed-but-never-broadcast scenario: stamp_entry_signature never ran,
    # so we have nothing to look up. The signed TX can't be recovered;
    # release the user to retry.
    if ptx.tx_signature.blank?
      ptx.update!(status: "failed")
      return render json: { status: "failed", error: "Your last signature did not broadcast — try again." }
    end

    # Ask the RPC about the signature once. The client owns the polling
    # cadence; keeping this action cheap avoids tying up a request thread.
    status = Solana::Vault.new.send(:client).confirm_transaction(ptx.tx_signature).dig("value", 0)

    if status.nil?
      return render json: { status: "processing" }
    end

    if status["err"]
      ptx.update!(status: "failed")
      return render json: { status: "failed", error: "On-chain transaction failed." }
    end

    unless %w[confirmed finalized].include?(status["confirmationStatus"])
      return render json: { status: "processing" }
    end

    # TX landed. Promote the entry server-side (re-derive entry_pda from
    # the stored metadata, then call confirm_onchain! which runs the same
    # safety checks the live confirm_onchain_entry endpoint does — locked
    # games, per-user limit, sybil check).
    entry_pda = ptx.parsed_metadata["entry_pda"]
    begin
      entry.confirm_onchain!(tx_signature: ptx.tx_signature, entry_pda: entry_pda)
      ptx.update!(status: "confirmed")
      render json: {
        status: "confirmed",
        redirect: contest_lobby_path(@contest),
        tx_signature: ptx.tx_signature
      }
    rescue StandardError => e
      ptx.update!(status: "failed")
      render json: { status: "failed", error: "Recovery failed: #{e.message}" }
    end
  rescue StandardError => e
    render json: { status: "error", error: e.message }, status: :unprocessable_entity
  end

  # Confirm an onchain direct entry after the user has co-signed and submitted the tx.
  def confirm_onchain_entry
    entry = @contest.entries.find_by(id: params[:entry_id], user: current_user, status: :cart)
    return render json: { error: "Entry not found" }, status: :not_found unless entry

    rescue_and_log(target: entry, parent: @contest) do
      raise "Wallet not linked" unless current_user.web3_solana_address.present?

      # OPSEC-010: server-derive the entry PDA (we know contest slug, wallet,
      # and entry_number). Reject mismatched client-supplied PDAs, then assert
      # the on-chain TX is the enter_contest_direct IX writing to that PDA,
      # signed by the user's own wallet.
      derived_entry_pda = Solana::Keypair.encode_base58(
        Solana::Vault.new.entry_pda(@contest.slug, current_user.web3_solana_address, entry.entry_number).first
      )
      raise "Entry PDA mismatch" unless params[:entry_pda] == derived_entry_pda

      verify_solana_transaction!(
        params[:tx_signature],
        instruction: "enter_contest_direct",
        signer: current_user.web3_solana_address,
        writable: derived_entry_pda
      )

      entry.confirm_onchain!(
        tx_signature: params[:tx_signature],
        entry_pda: derived_entry_pda
      )

      # Mark the PendingTransaction confirmed. Use the stamped signature as
      # the lookup key (covers the case where prepare_entry created the row
      # and the client stamped it post-broadcast). Fall back to target+initiator
      # for any pre-stamp PTs (refresh-before-stamp legacy scenario).
      ptx = PendingTransaction.where(target: entry, status: %w[pending submitted])
                              .find_by(tx_signature: params[:tx_signature]) ||
            PendingTransaction.where(target: entry, status: %w[pending submitted],
                                     initiator_address: current_user.web3_solana_address).order(:created_at).last
      ptx&.update!(tx_signature: params[:tx_signature], status: "confirmed")

      # Seeds awarded are determined on-chain by the active Season's seed_schedule.
      # Mirror that schedule here so the modal shows the same number the program awarded.
      seeds_earned = Solana::Vault.new.seeds_for_entry(entry.entry_number)
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
        redirect: contest_lobby_path(@contest),
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

  # World Cup Survivor — submit or replace this entry's pick for a round.
  def pick
    raise "Not a survivor contest" unless @contest.world_cup_survivor?

    round = params[:round_id].present? ? SurvivorRound.find_by(id: params[:round_id]) : SurvivorRound.current
    entry = @contest.entries.where(user: current_user, status: [:active, :complete]).first

    rescue_and_log(target: entry, parent: @contest) do
      raise "Enter the contest before making a pick" unless entry
      raise "You've been eliminated from this contest" if entry.eliminated?
      raise "Round not found" unless round
      raise "#{round.name} is locked" if round.picks_locked?

      team = Team.find_by(slug: params[:team_slug].to_s)
      raise "Team not found" unless team
      unless round.games.where("home_team_slug = :s OR away_team_slug = :s", s: team.slug).exists?
        raise "#{team.name} is not playing in #{round.name}"
      end
      if entry.survivor_picks.where(team_slug: team.slug).where.not(survivor_round_id: round.id).exists?
        raise "You've already used #{team.name} — no team can be picked twice"
      end

      pick = entry.survivor_picks.find_or_initialize_by(survivor_round: round)
      pick.team_slug = team.slug
      pick.save!

      render json: { success: true, round_id: round.id, team_slug: team.slug, team_name: team.name }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
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

  # World Cup Survivor — grade a round across every survivor entry (rounds are
  # global). Admin-only; the round's games must be final first.
  def grade_round
    rescue_and_log(target: @contest) do
      raise "Not a survivor contest" unless @contest.world_cup_survivor?
      round = params[:round_id].present? ? SurvivorRound.find_by(id: params[:round_id]) : SurvivorRound.current
      raise "No round to grade" unless round
      Survivor::GradeRound.call(round)
      redirect_to @contest, notice: "#{round.name} graded."
    end
  rescue StandardError => e
    redirect_to @contest || root_path, alert: e.message
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

  # ── Phantom contest-create helpers ─────────────────────────────────────────

  def render_create_error(msg)
    render json: { success: false, error: msg }, status: :unprocessable_entity
  end

  def build_unpersisted_contest_from_params
    Contest.new(contest_params).tap do |c|
      config = c.format_config
      c.entry_fee_cents = config[:entry_fee_cents]
      c.max_entries     = config[:max_entries]
      c.status          = :open
    end
  end

  def build_finalized_contest(payload, derived_pda_b58, tx_signature)
    Contest.new(
      name:                       payload[:name],
      slate_id:                   payload[:slate_id],
      contest_type:               payload[:contest_type],
      starts_at:                  payload[:starts_at],
      locks_at_date_selected:     payload[:locks_at_date_selected],
      locks_at_time_selected:     payload[:locks_at_time_selected],
      locks_at_timezone_selected: payload[:locks_at_timezone_selected],
      entry_fee_cents:            payload[:entry_fee_cents],
      max_entries:                payload[:max_entries],
      status:                     :open,
      user:                       current_user,
      onchain_contest_id:         derived_pda_b58,
      onchain_tx_signature:       tx_signature
    ).tap { |c| c.skip_onchain_callback = true }
  end

  # Returns nil if it's safe to proceed, or an error message string explaining
  # why we should refuse to build a TX. The on-chain checks (PDA existence,
  # wallet USDC balance) make round-trips to devnet, so order them last.
  def onchain_create_precheck(contest, creator)
    slug = contest.name_slug
    return "Name is required" if slug.blank?
    return "A contest with that name already exists" if Contest.exists?(slug: slug)

    vault   = Solana::Vault.new
    pda_b58 = Solana::Keypair.encode_base58(vault.contest_pda(slug).first)
    if vault.client.get_account_info(pda_b58)&.dig("value")
      # Catches the "stranded contest" case where a prior finalize attempt
      # failed AFTER the on-chain TX succeeded. Anchor's `init` constraint
      # would reject a re-mint anyway — fail loudly here instead of letting
      # the user waste a Phantom signature.
      return "On-chain Contest PDA #{pda_b58.first(8)}… already exists for this name. Pick a different name."
    end

    insufficient_usdc_error(contest, creator, vault)
  end

  def insufficient_usdc_error(contest, creator, vault)
    prize_cents = contest.guaranteed_prize_cents
    return nil unless prize_cents.positive?

    ata_b58 = Solana::Keypair.encode_base58(
      Solana::SplToken.find_associated_token_address(creator.web3_solana_address, Solana::Config::USDC_MINT).first
    )
    balance_info  = vault.client.get_token_account_balance(ata_b58) rescue nil
    balance_cents = (balance_info&.dig("value", "uiAmount").to_f * 100).round
    return nil if balance_cents >= prize_cents

    "Insufficient USDC: prize pool needs $#{format('%.2f', prize_cents / 100.0)}, " \
      "your wallet has $#{format('%.2f', balance_cents / 100.0)}. " \
      "Top up or pick a smaller tier."
  end

  # Signed payload used to round-trip form params from #create → Phantom → #finalize
  # without trusting the client's re-posted values. JSON serialization downgrades
  # symbol keys to strings — #verify wraps the result in HashWithIndifferentAccess.
  def sign_onchain_create_payload(contest, creator)
    payload = {
      slug:                       contest.name_slug,
      name:                       contest.name,
      slate_id:                   contest.slate_id,
      contest_type:               contest.contest_type,
      starts_at:                  contest.starts_at&.iso8601,
      locks_at_date_selected:     contest.locks_at_date_selected,
      locks_at_time_selected:     contest.locks_at_time_selected,
      locks_at_timezone_selected: contest.locks_at_timezone_selected,
      entry_fee_cents:            contest.entry_fee_cents,
      max_entries:                contest.max_entries,
      user_id:                    creator.id,
      creator_pubkey:             creator.web3_solana_address
    }
    Rails.application.message_verifier(ONCHAIN_CREATE_TOKEN_KEY)
         .generate(payload, expires_in: ONCHAIN_CREATE_TOKEN_TTL)
  end

  def verify_onchain_create_payload(token)
    Rails.application.message_verifier(ONCHAIN_CREATE_TOKEN_KEY)
         .verify(token)
         .with_indifferent_access
  end

  # ── End Phantom contest-create helpers ─────────────────────────────────────

  # OPSEC-010: semantic verification of a confirmed Solana transaction.
  # Delegates to Solana::TxVerifier, which fetches the TX from chain and
  # asserts the instruction is the one we expected (program ID + Anchor
  # discriminator + optional signer + optional writable PDA). Prevents
  # `params[:tx_signature]` from being any successful TX the attacker has
  # ever seen — it has to be the create_contest/enter/settle/etc. for the
  # expected contest/entry/pubkey.
  #
  # `instruction:` is required; `signer:` and `writable:` are optional but
  # every production caller should pass both.
  def verify_solana_transaction!(signature, instruction:, signer: nil, writable: nil)
    Solana::TxVerifier.verify!(
      signature: signature,
      instruction_name: instruction,
      signer_pubkey: signer,
      writable_pubkey: writable
    )
  rescue Solana::TxVerifier::VerificationError => e
    raise e.message
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
    return load_survivor_board_data if @contest.world_cup_survivor?

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
    @pending_recovery_ptx = find_pending_recovery_ptx
  end

  # World Cup Survivor uses rounds + off-chain picks, not slate matchups.
  def load_survivor_board_data
    @survivor_rounds = SurvivorRound.ordered.to_a
    @current_round = @survivor_rounds.find { |r| !r.completed? }
    @entries = @contest.entries.where(status: [:active, :complete])
                       .includes(:user, survivor_picks: [:survivor_round, :team])
                       .to_a
    @my_entry = current_user && @entries.find { |e| e.user_id == current_user.id }
    @pending_recovery_ptx = find_pending_recovery_ptx
  end

  # Stranded onchain entry from a refresh between sign-and-confirm. The
  # board JS reads this on init and POSTs /recover_pending_entry to either
  # auto-promote the entry (TX landed) or release it (TX failed). Returns
  # nil for guests, web2 users, off-chain contests, and the common case
  # where no PT is stranded.
  def find_pending_recovery_ptx
    return nil unless current_user&.web3_solana_address.present? && @contest.onchain?
    PendingTransaction.where(status: %w[pending submitted],
                             initiator_address: current_user.web3_solana_address,
                             target_type: "Entry")
                      .where(target_id: @contest.entries.where(user_id: current_user.id).select(:id))
                      .order(created_at: :desc).first
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
    params.require(:contest).permit(:name, :tagline, :rank, :contest_image, :starts_at, :locks_at_date_selected, :locks_at_time_selected, :locks_at_timezone_selected, :chat_enabled)
  end
end
