class ContestsController < ApplicationController
  include Solana::SessionAuth

  skip_before_action :require_authentication, only: [:index, :show, :my, :world_cup, :leaderboard_poll, :live]
  before_action :set_contest, only: [:show, :admin, :edit, :update, :update_banner, :toggle_selection, :enter, :clear_picks, :grade, :fill, :lock, :prepare_lock_time, :confirm_lock_time, :prepare_conclusion_time, :confirm_conclusion_time, :jump, :simulate_game, :simulate_batch, :reset, :close_onchain, :cancel_onchain, :prepare_entry, :stamp_entry_signature, :recover_pending_entry, :confirm_onchain_entry, :prepare_onchain_contest, :confirm_onchain_contest, :leaderboard_poll, :live, :pick, :grade_round]
  before_action :require_admin, only: [:new, :create, :rebuild_create_tx, :finalize, :admin, :edit, :update, :update_banner, :generator, :generate_bundle, :finalize_bundle, :grade, :fill, :lock, :prepare_lock_time, :confirm_lock_time, :prepare_conclusion_time, :confirm_conclusion_time, :jump, :simulate_game, :simulate_batch, :reset, :close_onchain, :cancel_onchain, :prepare_onchain_contest, :confirm_onchain_contest, :grade_round]
  before_action :require_geo_allowed, only: [:toggle_selection, :enter, :prepare_entry]
  # B4 / OPSEC-048: frozen accounts can browse but cannot spend or enter.
  before_action :require_unfrozen_account, only: [:enter, :prepare_entry, :confirm_onchain_entry, :toggle_selection]

  def index
    @contests = Contest.where(status: [:open, :settled])
                       .includes(:slate).with_attached_contest_image
                       .order(created_at: :desc).to_a
    # One grouped query for confirmed entry counts — avoids a per-card / per-row
    # N+1 across the My Contests grid + All Contests table.
    @entry_counts = Entry.confirmed.where(contest_id: @contests.map(&:id)).group(:contest_id).count
    # "My Contests" = contests the viewer has entered. Filter the already-loaded
    # list in Ruby so there's no extra Contest query.
    @entered_contest_ids = (logged_in? ? current_user.entries.confirmed.distinct.pluck(:contest_id) : []).to_set
    @my_contests = @contests.select { |c| @entered_contest_ids.include?(c.id) }
  end

  def my
    @contests = Contest.where(status: [:open, :settled]).order(created_at: :desc)
    if logged_in?
      @my_entries = current_user.entries.confirmed.includes(:contest, selections: { slate_matchup: [:team, :opponent_team] }).group_by(&:contest_id)
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

  # Phantom-driven provisioning of a curated contest + landing-page bundle.
  # Mirrors #create / #finalize: server builds a partially-signed create_contest
  # TX (admin pays rent, operator's Phantom signs the prize-pool USDC transfer),
  # client signs + broadcasts, then POST /contests/finalize_bundle persists the
  # Contest + LandingPage. Server-funded path (ContestBundle.generate!) needs
  # SOLANA_ADMIN_KEY and only runs locally / from Rails console.
  def generate_bundle
    return render_create_error("Phantom wallet required to provision bundles") unless current_user.phantom_wallet?
    return render_create_error("Unknown bundle: #{params[:key].inspect}") unless ContestBundle::ALL.key?(params[:key])

    contest = ContestBundle.build_unpersisted_contest(params[:key], current_user)
    if (err = onchain_create_precheck(contest, current_user))
      return render_create_error(err)
    end

    vault  = Solana::Vault.new
    result = vault.build_create_contest(
      current_user.web3_solana_address,
      contest.slug,
      **contest.onchain_params
    )

    render json: {
      success:       true,
      serialized_tx: result[:serialized_tx],
      contest_pda:   result[:contest_pda],
      slug:          contest.slug,
      params_token:  sign_bundle_payload(params[:key], contest, current_user)
    }
  rescue StandardError => e
    Rails.logger.error("[ContestsController#generate_bundle] #{e.class}: #{e.message}")
    render_create_error(e.message)
  end

  def finalize_bundle
    payload = verify_bundle_payload(params[:params_token])
    raise "User mismatch — token was issued to a different user" unless payload[:user_id] == current_user.id

    key = payload[:key]
    raise "Unknown bundle" unless ContestBundle::ALL.key?(key)

    derived_pda_b58 = Solana::Keypair.encode_base58(Solana::Vault.new.contest_pda(payload[:slug]).first)
    raise "Contest PDA mismatch — slug=#{payload[:slug]}" unless params[:contest_pda] == derived_pda_b58

    verify_solana_transaction!(
      params[:tx_signature],
      instruction: "create_contest",
      signer: payload[:creator_pubkey],
      writable: derived_pda_b58
    )

    result = ContestBundle.finalize_phantom!(key, current_user, derived_pda_b58, params[:tx_signature])
    render json: {
      success:  true,
      redirect: generator_contests_path,
      contest:  contest_path(result[:contest]),
      landing:  landing_page_path(result[:landing_page])
    }
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    render_create_error("Invalid or expired bundle token — restart the provision flow.")
  rescue StandardError => e
    Rails.logger.error("[ContestsController#finalize_bundle] #{e.class}: #{e.message}")
    render_create_error(e.message)
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
      contest.slug,
      **contest.onchain_params
    )

    render json: {
      success:       true,
      serialized_tx: result[:serialized_tx],
      contest_pda:   result[:contest_pda],
      slug:          contest.slug,
      params_token:  sign_onchain_create_payload(contest, current_user)
    }
  rescue StandardError => e
    Rails.logger.error("[ContestsController#create] #{e.class}: #{e.message}")
    render_create_error(e.message)
  end

  # Step 1.5 — re-issue the partially-signed create_contest TX with a FRESH
  # blockhash immediately before the Phantom sign. The blockhash baked at
  # #create time goes stale while the user dwells in the wallet UI, which
  # surfaces as "Transaction simulation failed: Blockhash not found" /
  # silent send failures. The client calls this right before
  # provider.signTransaction so the TX that gets signed + broadcast carries
  # a current blockhash.
  #
  # Because the admin co-signs server-side (build_partial_signed re-runs the
  # admin partial-sign over the new blockhash), the re-issue MUST go through
  # the server — we can't just overwrite the blockhash client-side without
  # invalidating the admin signature. We reconstruct the contest from the
  # already-issued, signed params_token (no client-trusted values) and rebuild
  # over a fresh blockhash. The original params_token stays valid for finalize.
  def rebuild_create_tx
    payload = verify_onchain_create_payload(params[:params_token])
    raise "User mismatch — token was issued to a different user" unless payload[:user_id] == current_user.id
    raise "Phantom wallet required to create contests" unless current_user.phantom_wallet?

    contest = build_contest_from_payload(payload)

    vault  = Solana::Vault.new
    result = vault.build_create_contest(
      current_user.web3_solana_address,
      payload[:slug],
      **contest.onchain_params
    )

    render json: {
      success:       true,
      serialized_tx: result[:serialized_tx],
      contest_pda:   result[:contest_pda]
    }
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    render_create_error("Invalid or expired form token — restart the contest creation flow.")
  rescue StandardError => e
    Rails.logger.error("[ContestsController#rebuild_create_tx] #{e.class}: #{e.message}")
    render_create_error(e.message)
  end

  def finalize
    payload = verify_onchain_create_payload(params[:params_token])
    raise "User mismatch — token was issued to a different user" unless payload[:user_id] == current_user.id

    derived_pda_b58 = Solana::Keypair.encode_base58(Solana::Vault.new.contest_pda(payload[:slug]).first)
    raise "Contest PDA mismatch — slug=#{payload[:slug]}" unless params[:contest_pda] == derived_pda_b58
    raise "A contest with that slug already exists" if Contest.exists?(slug: payload[:slug])

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
      # Mirror an edited lock time onto the chain (on-chain is master for
      # locking). nil starts_at sends 0 = clear the lock.
      if @contest.saved_change_to_starts_at? && @contest.onchain?
        Solana::Vault.new.set_contest_lock_time(@contest.slug, @contest.starts_at&.to_i || 0)
      end
      redirect_to root_path, notice: "Contest updated."
    end
  rescue StandardError => e
    render :edit, status: :unprocessable_entity
  end

  # Admin "Update banner" flow — swap just the contest's hero image. The admin
  # frames the image in the shared crop-photo modal (imageUploadHost +
  # cropPhotoModal, same cropper as the avatar) and the persistent uploader host
  # POSTs the cropped PNG here. Responds with a Turbo Stream that replaces
  # #contest-banner-preview on the edit screen. (A bad file 422s, but the crop
  # always yields a valid PNG, so that path is defensive — the picker has an
  # accept filter too.)
  def update_banner
    rescue_and_log(target: @contest) do
      file = params.dig(:contest, :contest_image)

      if valid_image?(file)
        @contest.contest_image.attach(file)
        respond_to do |format|
          # The crop modal saves immediately; refresh the preview on the edit
          # screen (the only caller). The contest show-page hero picks up the
          # new banner on its next full render.
          format.turbo_stream do
            render turbo_stream: turbo_stream.replace("contest-banner-preview", partial: "contests/banner_preview")
          end
          format.html { redirect_to edit_contest_path(@contest), notice: "Banner updated." }
        end
      else
        message = file.blank? ? "Choose an image to upload." : "Use a PNG, JPG, or WebP under 8 MB."
        redirect_to edit_contest_path(@contest), alert: message, status: :see_other
      end
    end
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
    @contest = Contest.featured
    return redirect_to contests_path unless @contest
    redirect_to contest_path(@contest)
  end

  def show
    @creator = @contest.user
    @has_entry = logged_in? && @contest.entries.where(user: current_user, status: [:active, :complete]).exists?
    @seeds_data = load_seeds_data
    # Quest card mission (username -> newsletter -> invite). Only for entered
    # users — the card is gated on @has_entry, so current_user is present.
    @quest_step = current_user.quest_step if @has_entry

    # Current user's entries on this contest — preloaded once so the contest
    # header (dropdown) and the "Your Entries" navigation card on the show
    # page don't re-query. Includes complete entries so the card still works
    # in settled state for read-only reference.
    @my_active_entries = if logged_in?
                           current_user.entries
                                       .where(contest: @contest, status: [:active, :complete])
                                       .includes(selections: { slate_matchup: [:team, :game] })
                                       .order(:entry_number, :id)
                                       .to_a
                         else
                           []
                         end

    # Resolve params[:edit_entry] → an active entry owned by current_user on
    # this contest. Picked up by the show template to swap the leaderboard
    # for the selection board in edit mode.
    if logged_in? && params[:edit_entry].present? && @contest.open?
      @edit_entry = @my_active_entries.find { |e| e.slug == params[:edit_entry] && e.active? }
    end

    load_contest_board_data

    # "More Contests" selector at the bottom of the page.
    @other_contests = Contest.where(status: [:open]).ranked.where.not(id: @contest.id).includes(:slate)

    if @contest.onchain?
      begin
        @onchain_contest = Solana::Vault.new.read_contest(@contest.slug)
      rescue => e
        Rails.logger.warn "Failed to read onchain contest: #{e.message}"
      end
    end
  end

  # Admin view of the contest show page — bypasses the "hide picks while
  # open" guard so operators can see every entry's selections for moderation.
  # Same render path as #show; @admin_view is the helper hook.
  def admin
    @admin_view = true
    show
    render :show
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

  # Live "active contest" page — real-time leaderboard + chat + games for an
  # in-progress contest, pushed over ActionCable (Contest::LiveBroadcast). New
  # dedicated route for now; we'll fold it into #show's live state later.
  # Turf Totals only for v1; Survivor + not-yet-live redirect to the show page.
  def live
    return redirect_to contest_path(@contest) unless @contest.turf_totals?
    return redirect_to contest_path(@contest), notice: "This contest isn't live yet." unless @contest.live?

    load_contest_board_data
    @games = @contest.games_by_phase
  end

  def enter
    # Cancelled contests are terminal — no new entries (the on-chain program
    # rejects enter_contest on a Cancelled Contest PDA; mirror it here so the
    # UI fails fast with a clear message).
    if @contest.cancelled?
      return render json: { success: false, error: "This contest was cancelled." },
                    status: :unprocessable_entity
    end

    # Self-custody guard (task #11 Stage 3). Runs FIRST so it catches
    # self-custodied users regardless of cart / contest state. The server
    # must not auto-sign for them; route to the Phantom-prepare path.
    # Clients catch this 422 + the self_custodied flag and walk the user
    # through Phantom sign-in if they aren't already in an onchain_session.
    if current_user.self_custodied?
      return render json: {
        success: false,
        error: "Your wallet is self-custodied. Sign in with Phantom (or your imported wallet) and re-enter — Turf Monster will not auto-sign for you.",
        self_custodied: true
      }, status: :unprocessable_entity
    end

    entry = @contest.entries.cart.find_by(user: current_user)
    # Survivor contests have no pick-building phase — entering creates the entry
    # directly. (Turf Totals' cart entry is created by toggle_selection.)
    entry ||= @contest.entries.find_or_create_by!(user: current_user, status: :cart) if @contest.world_cup_survivor?
    return redirect_to root_path, alert: "No cart entry found" unless entry

    # Attribute any RPC writes spawned by this action to the cart entry —
    # OutboundRequestLogger falls back to Current.outbound_source so future
    # audit-table hunts (cf. project_0xbc4_send_burst_2026_05_26) can trace
    # sendTransaction rows back to the specific entry instead of source:nil.
    Current.outbound_source = entry

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

          vault = Solana::Vault.new
          # Probe the chain for a free entry slot (handles orphaned PDAs left by
          # a contest Reset). See Entry#assign_onchain_entry_number!.
          entry.assign_onchain_entry_number!(current_user.solana_address, vault)

          vault.ensure_user_account(current_user.solana_address, username: current_user.username) if current_user.solana_connected?
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
          # The on-chain EntryTokenAccount.consumed flag just flipped to true.
          # Bust the 60s entry-tokens cache so a follow-up entry within the
          # same TTL doesn't re-pick this token and trip 0x177f
          # (EntryTokenAlreadyConsumed) when the chain rejects the consume.
          current_user.bust_entry_tokens_cache!
          token_consumed = true
        elsif @contest.onchain? && !onchain_session?
          # Offchain session entering onchain contest: blocking vault entry.
          # v0.16 unified enter_contest requires the user's keypair to sign
          # the SPL transfer; managed wallets supply it from the encrypted
          # `solana_keypair` column. Default to currency_idx 0 (USDC) for
          # Phase 1 — currency picker is a Phase 2 task.
          raise "Managed wallet missing keypair (cannot sign entry)" unless current_user.solana_keypair

          vault = Solana::Vault.new
          # Probe the chain for a free entry slot (handles orphaned PDAs left by
          # a contest Reset). See Entry#assign_onchain_entry_number!.
          entry.assign_onchain_entry_number!(current_user.solana_address, vault)

          vault.ensure_user_account(current_user.solana_address, username: current_user.username) if current_user.solana_connected?
          vault.ensure_ata(current_user.solana_address, mint: Solana::Config::USDC_MINT)

          result = vault.enter_contest(
            current_user.solana_address,
            @contest.slug,
            entry.entry_number,
            currency_idx: 0,
            user_keypair: current_user.solana_keypair,
            season_id: @contest.season_id
          )
          tx_signature = result[:signature]
          onchain_entry_id = result[:entry_pda]
        end

        entry.confirm!(tx_signature: tx_signature, onchain_entry_id: onchain_entry_id)
      end

      # Confirmed (managed/token path) — announce the join in chat once.
      announce_contest_join(entry)

      respond_to do |format|
        format.html { redirect_to contest_path(@contest), notice: "#{current_user.display_name} entered the contest!" }
        format.json {
          seeds = post_entry_seeds_payload(entry,
                                          path: "managed",
                                          tx_signature: entry.onchain_tx_signature,
                                          token_consumed: token_consumed)
          render json: {
            success: true,
            redirect: contest_path(@contest),
            tx_signature: entry.onchain_tx_signature,
            # Flag for the client: true iff this entry was paid for by
            # an on-chain EntryTokenAccount consumption. Drives the
            # navbar 🎟️ punch animation (animateFreeEntryBadge).
            token_consumed: token_consumed,
            **seeds
          }
        }
      end
    end
  rescue StandardError => e
    render_entry_error(e)
  end

  # Build a partially-signed enter_contest_direct transaction for Phantom users.
  # Admin signs (pays rent), returns base64 tx for user to co-sign client-side.
  def prepare_entry
    if @contest.cancelled?
      return render json: { success: false, error: "This contest was cancelled." },
                    status: :unprocessable_entity
    end

    entry = @contest.entries.cart.find_by(user: current_user)
    # Survivor contests have no pick-building phase — see #enter.
    entry ||= @contest.entries.find_or_create_by!(user: current_user, status: :cart) if @contest.world_cup_survivor?
    return render json: { error: "No cart entry found" }, status: :unprocessable_entity unless entry

    Current.outbound_source = entry  # audit-log attribution; see #enter

    # Single-signature entry flow (2026-05-24): the per-entry SIWS
    # signMessage check was removed because the on-chain TX signed in
    # confirm_onchain_entry below is itself the wallet-ownership proof —
    # Anchor rejects any enter_contest_direct whose signer doesn't match
    # the entry PDA's owner. We still require that this Rails session
    # was established via a Phantom signature at login (onchain_session?)
    # so a stolen email/password cookie can't pivot into the on-chain
    # entry flow.
    return render json: { success: false, error: "Phantom session required" }, status: :forbidden unless onchain_session?

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

      vault = Solana::Vault.new

      # Assign entry slot by probing the chain for a free index — guards against
      # the orphaned-PDA collision a contest Reset leaves behind (the System
      # `Allocate` "already in use" / 0x0 pre-flight failure). See
      # Entry#assign_onchain_entry_number!.
      entry.assign_onchain_entry_number!(current_user.web3_solana_address, vault)

      # Ensure user's onchain account exists and is current (auto-migrate if needed).
      # v0.16: username is required at PDA creation (validate_username on chain
      # enforces >= 3 chars). Pass current_user.username through.
      vault.ensure_user_account(current_user.web3_solana_address, username: current_user.username)
      # v0.16: user's USDC ATA must exist before they can transfer from it.
      # init_if_needed isn't used in the instruction so we create it here.
      vault.ensure_ata(current_user.web3_solana_address, mint: Solana::Config::USDC_MINT)

      # v0.16 collapsed `enter_contest` + `enter_contest_direct` into a
      # single unified `enter_contest` instruction. currency_idx 0 = USDC
      # (only currency surfaced in the UI for Phase 1).
      result = vault.build_enter_contest(
        current_user.web3_solana_address,
        @contest.slug,
        entry.entry_number,
        currency_idx: 0,
        season_id: @contest.season_id
      )

      # Persist a PendingTransaction so a refresh mid-flight (between Phantom's
      # sign and confirm_onchain_entry) leaves a server-side trail. In the
      # Phantom-FIRST flow (2026-06-05) broadcast is server-side, so the
      # signature + `confirmed` status are stamped in confirm_onchain_entry; this
      # row starts `pending` with no signature (nothing is broadcast until the
      # client returns Phantom's signed bytes to confirm_onchain_entry).
      ptx = PendingTransaction.create!(
        tx_type: "enter_contest",
        serialized_tx: result[:serialized_tx],
        status: "pending",
        target: entry,
        initiator_address: current_user.web3_solana_address,
        metadata: { entry_pda: result[:entry_pda], contest_slug: @contest.slug, currency_idx: 0 }.to_json
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
    render_entry_error(e)
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
  #                 PT marked confirmed, client redirects to the contest show page
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
    # Defense-in-depth (Lazarus audit #1): the target entry must belong to the
    # caller. Today this is implied by the initiator_address check above plus
    # the fact that prepare_entry is the only enter_contest PT creator, but
    # asserting entry ownership explicitly keeps that invariant from becoming
    # silently load-bearing if another PT-creation path is ever added.
    return render json: { error: "Not authorized" }, status: :forbidden unless entry.user_id == current_user&.id

    # Already-active entry → close the loop on the PT and short-circuit.
    if entry.active?
      ptx.update!(status: "confirmed")
      return render json: {
        status: "confirmed",
        redirect: contest_path(@contest),
        tx_signature: entry.onchain_tx_signature
      }
    end

    # No server-stamped signature scenario. In the Phantom-FIRST flow
    # (2026-06-05) broadcast is server-side INSIDE confirm_onchain_entry, and the
    # signature is stamped there IMMEDIATELY after broadcast, BEFORE verification
    # (A1). So a blank tx_signature here genuinely means broadcast never happened
    # — nothing landed on-chain — and it is SAFE to release the user to retry
    # (assign_onchain_entry_number! probes the chain for a free slot, so a retry
    # won't collide). A broadcast that SUCCEEDED but then failed verification
    # leaves a STAMPED PT (status "submitted", signature present), which skips this
    # branch and falls through to the RPC poll + verify_and_confirm below —
    # crediting the already-paid entry instead of re-charging the user.
    if ptx.tx_signature.blank?
      ptx.update!(status: "failed")
      return render json: { status: "failed", error: "Your last entry did not go through — try again." }
    end

    # Ask the RPC about the signature once. The client owns the polling
    # cadence; keeping this poll cheap (getSignatureStatuses) avoids tying up
    # a request thread while the TX propagates.
    vault = Solana::Vault.new
    status = vault.client.confirm_transaction(ptx.tx_signature).dig("value", 0)

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

    # TX landed. Run the SAME server-side verification the live path uses
    # before crediting — never trust ptx.metadata.entry_pda (client-supplied).
    # verify_and_confirm_onchain_entry! re-derives the PDA, asserts the
    # signature is a genuine enter_contest IX from this wallet, and activates
    # the entry; without it the recovery path would credit a paid entry from
    # ANY finalized signature. confirm_onchain! re-checks open/lock/limit/sybil
    # and the unique-signature index blocks replaying one tx across two rows.
    # (OPSEC-010 / Lazarus audit #1.)
    begin
      verify_and_confirm_onchain_entry!(entry, ptx.tx_signature, vault: vault)
      ptx.update!(status: "confirmed")
      render json: {
        status: "confirmed",
        redirect: contest_path(@contest),
        tx_signature: ptx.tx_signature
      }
    rescue StandardError => e
      ptx.update!(status: "failed")
      render json: { status: "failed", error: "Recovery failed: #{e.message}" }
    end
  rescue StandardError => e
    render json: { status: "error", error: e.message }, status: :unprocessable_entity
  end

  # Confirm an onchain entry. Phantom-FIRST flow (2026-06-05): the client now
  # sends the Phantom-SIGNED-but-not-broadcast wire bytes (`signed_tx`, base64,
  # requireAllSignatures:false). The SERVER cosigns with the admin keypair
  # (Transaction.cosign_wire), runs a simulateTransaction pre-flight, broadcasts,
  # waits for confirmation, THEN runs the existing on-chain verification.
  #
  # Why the order flipped: when the server pre-signs and Phantom signs second,
  # Phantom's Lighthouse heuristics flag the multi-signer ordering ("could be
  # malicious"). Phantom signing the fully-unsigned tx first clears that rule.
  # Broadcast moving server-side means the server now owns + stamps the tx
  # signature (the client no longer calls stamp_entry_signature before confirm).
  def confirm_onchain_entry
    if @contest.cancelled?
      return render json: { success: false, error: "This contest was cancelled." },
                    status: :unprocessable_entity
    end

    entry = @contest.entries.find_by(id: params[:entry_id], user: current_user, status: :cart)
    return render json: { error: "Entry not found" }, status: :not_found unless entry

    Current.outbound_source = entry  # audit-log attribution; see #enter

    rescue_and_log(target: entry, parent: @contest) do
      raise "Wallet not linked" unless current_user.web3_solana_address.present?
      raise "Missing signed transaction" if params[:signed_tx].blank?

      vault = Solana::Vault.new

      # Audit C1 (admin blind-cosign): SEMANTICALLY validate the Phantom-signed
      # wire BEFORE the admin signs anything. Decodes the client's tx and asserts
      # it is exactly the enter_contest we prepared — admin fee-payer, a single
      # enter_contest IX bound to THIS entry's PDA, and only the durable-nonce
      # advance / ComputeBudget hints alongside. Raises Solana::Vault::
      # UnsafeCosignError (rescued below) on anything else, so a crafted
      # SystemProgram.transfer{from: admin} / mint_entry_token / grant_seeds never
      # reaches the cosign. Validate-then-cosign: NO cosign, NO broadcast on reject.
      vault.assert_entry_cosign_safe!(params[:signed_tx],
                                      entry: entry,
                                      wallet_address: current_user.web3_solana_address)

      # Server-side: admin cosign (fills the empty admin slot in the
      # Phantom-signed wire tx) → simulateTransaction pre-flight → broadcast →
      # confirm. cosign_and_broadcast_entry re-asserts OPSEC-017 (fully signed)
      # and raises on a failed simulation before any broadcast.
      tx_signature = vault.cosign_and_broadcast_entry(params[:signed_tx])

      # A1 (double-charge guard): stamp the signature on the PendingTransaction
      # IMMEDIATELY after broadcast, BEFORE verification. The money has moved
      # on-chain at this point — if verify_and_confirm_onchain_entry! below raises
      # (e.g. a transient RPC error on getTransaction), the rescue must leave a PT
      # that CARRIES the signature so recover_pending_entry credits the already-
      # paid entry. A blank PT here would read as "never broadcast" and let the
      # user re-enter and pay twice (assign_onchain_entry_number! probes the chain
      # and would skip the already-paid PDA). Look up by target+initiator
      # (prepare_entry created the row pre-broadcast, before any signature).
      ptx = PendingTransaction.where(target: entry, status: %w[pending submitted],
                                     initiator_address: current_user.web3_solana_address)
                              .order(:created_at).last
      ptx&.update!(tx_signature: tx_signature, status: "submitted")

      # OPSEC-010 / Lazarus audit #1: server-derive the entry PDA, cross-check
      # the client-supplied one, assert the broadcast TX is the v0.16
      # enter_contest IX signed by the user's wallet writing to that PDA, then
      # activate. Shared with the crash-recovery path so neither can drift.
      verify_and_confirm_onchain_entry!(entry, tx_signature,
                                        expected_entry_pda: params[:entry_pda],
                                        vault: vault)

      ptx&.update!(status: "confirmed")

      # Confirmed (Phantom direct-USDC path) — announce the join in chat once.
      announce_contest_join(entry)

      seeds = post_entry_seeds_payload(entry,
                                      path: "phantom-direct",
                                      tx_signature: tx_signature)
      render json: {
        success: true,
        redirect: contest_path(@contest),
        tx_signature: tx_signature,
        **seeds
      }
    end
  rescue Solana::Vault::UnsafeCosignError
    # Audit C1: the submitted wire didn't match the entry we prepared, so the
    # admin never cosigned and nothing was broadcast. The detailed reason is
    # already logged server-side ([cosign][rejected] …) — return ONLY a generic,
    # non-revealing message + a stable `code` the frontend keys its retry UX off.
    render json: {
      success: false,
      code: "tx_rejected",
      error: "For your security we couldn't co-sign this transaction — it didn't match the entry we prepared. Please try again."
    }, status: :unprocessable_entity
  rescue StandardError => e
    render_entry_error(e)
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

  # Set the contest lock time (derived-lock model, v0.17). `in_seconds` defaults
  # to 0 = "lock now"; a positive value schedules a near-future lock (e.g. the
  # "Lock in 30s" testing button, to watch the countdown engage). On-chain is
  # master: flip the chain first (when on-chain), then mirror to starts_at so the
  # derived `locked?` + the page countdown agree.
  def lock
    rescue_and_log(target: @contest) do
      seconds = params[:in_seconds].to_i.clamp(0, 3600)
      lock_at = Time.current + seconds.seconds
      Solana::Vault.new.set_contest_lock_time(@contest.slug, lock_at.to_i) if @contest.onchain?
      @contest.update!(starts_at: lock_at)
      notice = seconds.positive? ? "Lock scheduled — entries close in #{seconds}s." : "Contest locked — entries closed."
      redirect_to @contest, notice: notice
    end
  rescue StandardError => e
    redirect_to @contest || root_path, alert: e.message
  end

  # Phantom-prepared lock (web3). set_contest_lock_time is 1-of-3 and the admin's
  # Phantom is a vault signer, so a single Phantom signature authorizes it.
  # prepare_lock_time builds the TX (bot pays the fee, Phantom signs the admin
  # slot); the client signs + broadcasts; confirm_lock_time verifies on-chain
  # then mirrors starts_at (chain is master — DB only moves post-confirm).
  def prepare_lock_time
    return render json: { success: false, error: "Phantom session required" }, status: :forbidden unless onchain_session?

    rescue_and_log(target: @contest) do
      raise "Contest is not onchain" unless @contest.onchain?
      raise "Phantom wallet required" unless current_user.phantom_wallet?
      raise "Contest already concluded — lock time can't change" if @contest.settled?

      seconds = params[:in_seconds].to_i.clamp(0, 3600)
      lock_at = Time.current + seconds.seconds

      result = Solana::Vault.new.build_set_contest_lock_time(
        @contest.slug, lock_at.to_i, admin_pubkey: current_user.web3_solana_address
      )

      render json: { success: true, serialized_tx: result[:serialized_tx], lock_timestamp: lock_at.to_i }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def confirm_lock_time
    rescue_and_log(target: @contest) do
      raise "Wallet not linked" unless current_user.web3_solana_address.present?
      lock_ts = params[:lock_timestamp].to_i
      raise "Missing lock timestamp" unless lock_ts.positive?

      contest_pda_b58 = Solana::Keypair.encode_base58(
        Solana::Vault.new.contest_pda(@contest.slug).first
      )
      verify_solana_transaction!(
        params[:tx_signature],
        instruction: "set_contest_lock_time",
        signer: current_user.web3_solana_address,
        writable: contest_pda_b58
      )

      # Chain is master — mirror starts_at only after the on-chain TX confirms.
      @contest.update!(starts_at: Time.at(lock_ts))

      render json: { success: true, redirect: contest_path(@contest), locks_at: @contest.locks_at&.iso8601 }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  # Phantom-prepared conclusion (web3), parallel to prepare/confirm_lock_time.
  # Sets the on-chain conclusion timestamp; after it passes, the lock time is
  # final (set_contest_lock_time rejects). Mirrors starts_at handling.
  def prepare_conclusion_time
    return render json: { success: false, error: "Phantom session required" }, status: :forbidden unless onchain_session?

    rescue_and_log(target: @contest) do
      raise "Contest is not onchain" unless @contest.onchain?
      raise "Phantom wallet required" unless current_user.phantom_wallet?
      raise "Contest already concluded — conclusion time can't change" if @contest.concluded?

      seconds = params[:in_seconds].to_i.clamp(0, 604_800) # up to a week out
      conclude_at = Time.current + seconds.seconds

      result = Solana::Vault.new.build_set_contest_conclusion_time(
        @contest.slug, conclude_at.to_i, admin_pubkey: current_user.web3_solana_address
      )

      render json: { success: true, serialized_tx: result[:serialized_tx], conclusion_timestamp: conclude_at.to_i }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def confirm_conclusion_time
    rescue_and_log(target: @contest) do
      raise "Wallet not linked" unless current_user.web3_solana_address.present?
      ts = params[:conclusion_timestamp].to_i
      raise "Missing conclusion timestamp" unless ts.positive?

      contest_pda_b58 = Solana::Keypair.encode_base58(
        Solana::Vault.new.contest_pda(@contest.slug).first
      )
      verify_solana_transaction!(
        params[:tx_signature],
        instruction: "set_contest_conclusion_time",
        signer: current_user.web3_solana_address,
        writable: contest_pda_b58
      )

      # Chain is master — mirror concludes_at only after the on-chain TX confirms.
      @contest.update!(concludes_at: Time.at(ts))

      render json: { success: true, redirect: contest_path(@contest), concludes_at: @contest.concludes_at&.iso8601 }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
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

  # Reclaim on-chain rent (close_contest, 1-of-3 server-signed). The program
  # only allows close once the Contest PDA is in a terminal state (Settled or
  # Cancelled — error 6005 otherwise), so we gate on the same. Single vault
  # signer = the bot's admin keypair signs + broadcasts itself; no
  # PendingTransaction / cosign needed.
  def close_onchain
    rescue_and_log(target: @contest) do
      raise "Contest must be settled or cancelled before closing on-chain" unless @contest.settled? || @contest.onchain_cancelled?
      raise "Contest is already closed on-chain" if @contest.onchain_closed?

      result = Solana::Vault.new.close_contest(@contest.slug)
      @contest.update!(onchain_closed: true)
      redirect_to @contest, notice: "On-chain rent reclaimed (close_contest: #{result[:signature]})."
    end
  rescue StandardError => e
    redirect_to @contest || root_path, alert: e.message
  end

  # Cancel an open contest + refund the creator's prize pool (cancel_contest,
  # 2-of-3). Builds a partially-signed TX and queues it for cosign in the
  # Treasury (mirrors Contest#settle_onchain!). The creator MUST be the
  # authoritative on-chain creator — the program constrains
  # creator_token_account.authority == contest.creator — so read it off-chain
  # rather than trusting contest.user.solana_address.
  def cancel_onchain
    rescue_and_log(target: @contest) do
      raise "Contest is not on-chain" unless @contest.onchain?
      raise "Only open contests can be cancelled" unless @contest.open?
      raise "Contest is already cancelled" if @contest.onchain_cancelled?

      vault = Solana::Vault.new
      onchain = vault.read_contest(@contest.slug)
      raise "Could not read on-chain contest" unless onchain
      creator_pubkey = onchain[:creator]
      raise "On-chain creator unavailable" if creator_pubkey.blank?

      result = vault.build_cancel_contest(
        @contest.slug,
        creator_pubkey: creator_pubkey,
        cosigner_pubkey: Solana::Config::MULTISIG_COSIGNER
      )

      PendingTransaction.create!(
        tx_type: "cancel_contest",
        serialized_tx: result[:serialized_tx],
        target: @contest,
        initiator_address: Solana::Keypair.admin.to_base58,
        metadata: { creator: creator_pubkey }.to_json
      )

      redirect_to admin_pending_transactions_path,
        notice: "Cancel queued for cosign — refunds #{creator_pubkey[0..7]}… in the Treasury."
    end
  rescue StandardError => e
    redirect_to @contest || root_path, alert: e.message
  end

  private

  # Build the post-confirm seeds payload for the entry-confirm JSON responses
  # in #enter (managed wallet) and #confirm_onchain_entry (Phantom direct).
  # Reads the seeds awarded for this entry's number off-chain (Season schedule
  # mirror) plus the user's current lifetime seeds via sync_balance, derives
  # the level, then handles the post-confirm fanout housekeeping:
  #
  #   1. `Rails.logger.info "[entry][confirmed] path=… seeds_earned=… …"` so
  #      production debugging has a grep-able trail (pair with the
  #      `[state-fanout][seeds]` console line on the client).
  #   2. invalidate_seeds_cache + invalidate_usdc_cache so the next page
  #      render sees fresh chain state without waiting for the 60s TTL.
  #
  # Returns `{ seeds_earned:, seeds_total:, seeds_level: }` for splat into
  # the JSON response.
  # Post the "🎉 <name> joined the contest" announcement to the contest chat
  # on a user's FIRST confirmed entry. Idempotent (Message.announce_join! is a
  # no-op for an already-announced user) so re-confirms / the 3-entries-per-user
  # allowance never double-post, and chat-disabled contests get nothing. The
  # Message's after_create_commit broadcast handles real-time delivery — no new
  # cable plumbing here. Best-effort: a chat hiccup must not fail the entry that
  # already confirmed (Message.announce_join! rescues internally).
  def announce_contest_join(entry)
    return unless entry&.user
    Message.announce_join!(contest: @contest, user: entry.user)
  end

  def post_entry_seeds_payload(entry, path:, tx_signature:, token_consumed: nil)
    seeds_earned = 0
    seeds_total  = 0
    seeds_level  = 0

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

    tx_prefix = tx_signature.to_s.first(8)
    token_part = token_consumed.nil? ? "" : " token_consumed=#{token_consumed}"
    Rails.logger.info(
      "[entry][confirmed] path=#{path} user_id=#{current_user.id} " \
      "entry_id=#{entry.id} contest=#{@contest.slug} tx=#{tx_prefix}... " \
      "seeds_earned=#{seeds_earned} seeds_total=#{seeds_total} " \
      "seeds_level=#{seeds_level}#{token_part}"
    )

    if current_user.solana_connected?
      invalidate_seeds_cache
      invalidate_usdc_cache
    end

    { seeds_earned: seeds_earned, seeds_total: seeds_total, seeds_level: seeds_level }
  end

  # Renders the JSON error response for every entry-flow endpoint (enter,
  # prepare_entry, confirm_onchain_entry). Runs the raw exception through
  # Solana::ErrorInterpreter so the client gets a structured `blocker` it
  # can route through the same showEligibilityBlockerModal dispatcher the
  # preflight check uses. When the interpreter flags log:true (currently
  # 0xbbb / AccountDidNotDeserialize — IDL drift signal), the exception is
  # escalated to Rails.logger.error so ops sees it; rescue_and_log has
  # already persisted an error_logs row with the full backtrace.
  def render_entry_error(exception)
    result = Solana::ErrorInterpreter.interpret(exception, contest: @contest)
    Rails.logger.error("[entry][escalate] #{exception.class}: #{exception.message}") if result[:log]

    if request.format.json?
      render json: { success: false, error: result[:message], blocker: result[:blocker] },
             status: :unprocessable_entity
    else
      redirect_to root_path, alert: result[:message]
    end
  end

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

  # Reconstruct an unpersisted Contest from the signed create payload so its
  # #onchain_params reproduce the exact instruction data #create built (fees,
  # max_entries, payouts, prize_pool, lock_timestamp). Used by #rebuild_create_tx
  # to re-issue the TX over a fresh blockhash without trusting client values.
  def build_contest_from_payload(payload)
    Contest.new(
      name:         payload[:name],
      slug:         payload[:slug],
      contest_type: payload[:contest_type],
      starts_at:    payload[:starts_at],
      entry_fee_cents: payload[:entry_fee_cents],
      max_entries:     payload[:max_entries],
      status:          :open
    )
  end

  def build_finalized_contest(payload, derived_pda_b58, tx_signature)
    Contest.new(
      name:                       payload[:name],
      slug:                       payload[:slug],
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
    # Slug is the manual, globally-unique key — it seeds the on-chain PDA
    # (contest_id = sha256(slug)). Validate the model first so a malformed slug
    # (spaces/uppercase/symbols, > 64 bytes, name > 96 bytes) is rejected before
    # we burn an RPC round-trip or a Phantom signature.
    contest.validate
    if (slug_errors = contest.errors[:slug]).any?
      return "Slug #{slug_errors.first}"
    end
    if (name_errors = contest.errors[:name]).any?
      return "Name #{name_errors.first}"
    end

    slug = contest.slug
    return "Slug is required" if slug.blank?
    return "A contest with that slug already exists" if Contest.exists?(slug: slug)

    vault   = Solana::Vault.new
    pda_b58 = Solana::Keypair.encode_base58(vault.contest_pda(slug).first)
    if vault.client.get_account_info(pda_b58)&.dig("value")
      # Catches the "stranded contest" case where a prior finalize attempt
      # failed AFTER the on-chain TX succeeded. Anchor's `init` constraint
      # would reject a re-mint anyway — fail loudly here instead of letting
      # the user waste a Phantom signature.
      return "On-chain Contest PDA #{pda_b58.first(8)}… already exists for this slug. Pick a different slug."
    end

    insufficient_usdc_error(contest, creator, vault)
  end

  def insufficient_usdc_error(contest, creator, vault)
    prize_cents = contest.guaranteed_prize_cents
    return nil unless prize_cents.positive?

    ata_b58 = Solana::Keypair.encode_base58(
      Solana::SplToken.find_associated_token_address(creator.web3_solana_address, Solana::Config::USDC_MINT).first
    )

    # FRESH read for the create decision — never the 60s-cached display_balance.
    # A nil/failed read (RPC flake, ATA-not-found edge) is NOT treated as a
    # pass and is NOT silently coerced to $0; it's a HARD BLOCK so a doomed TX
    # can't slip through on a transient read failure. We capture the raw read
    # exception separately from a legitimately-empty-but-readable ATA.
    read_error  = nil
    balance_info = begin
      vault.client.get_token_account_balance(ata_b58)
    rescue StandardError => e
      read_error = e
      nil
    end

    if read_error || balance_info.nil?
      Rails.logger.warn(
        "[ContestsController#insufficient_usdc_error] USDC balance read FAILED " \
        "ata=#{ata_b58} user=#{creator.id} prize_cents=#{prize_cents} " \
        "error=#{read_error&.class}: #{read_error&.message}"
      )
      return "We couldn't verify your USDC balance right now — please try again in a moment."
    end

    balance_cents = (balance_info.dig("value", "uiAmount").to_f * 100).round
    Rails.logger.info(
      "[ContestsController#insufficient_usdc_error] USDC balance read " \
      "ata=#{ata_b58} user=#{creator.id} balance_cents=#{balance_cents} prize_cents=#{prize_cents}"
    )
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
      slug:                       contest.slug,
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

  ONCHAIN_BUNDLE_TOKEN_KEY = :onchain_contest_bundle
  ONCHAIN_BUNDLE_TOKEN_TTL = 10.minutes

  # Bundle token is narrower than the generic create token — the bundle
  # `key` selects the full spec server-side from ContestBundle::ALL, so the
  # token only needs to bind (key, slug, user, pubkey) to the issued TX.
  def sign_bundle_payload(key, contest, creator)
    Rails.application.message_verifier(ONCHAIN_BUNDLE_TOKEN_KEY)
         .generate({
           key:            key,
           slug:           contest.slug,
           user_id:        creator.id,
           creator_pubkey: creator.web3_solana_address
         }, expires_in: ONCHAIN_BUNDLE_TOKEN_TTL)
  end

  def verify_bundle_payload(token)
    Rails.application.message_verifier(ONCHAIN_BUNDLE_TOKEN_KEY)
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

  # Shared on-chain entry confirmation, used by BOTH the live confirm path
  # (#confirm_onchain_entry) and the crash-recovery path (#recover_pending_entry).
  # Server-DERIVES the entry PDA from (contest slug, the session wallet, this
  # entry's entry_number) — never trusts a client-supplied PDA — asserts the
  # signature is a genuine `enter_contest` IX signed by this user and writing
  # to that derived PDA (OPSEC-010 / Lazarus audit #1), then activates the
  # entry. Keeping both callers on this one method stops the recovery path
  # from ever drifting back to the unverified-signature critical it just
  # closed. Returns the server-derived entry PDA (base58).
  #
  # `expected_entry_pda:` — the live path passes the client-supplied PDA to
  #   cross-check (mismatch raises, matching the prior inline guard); the
  #   recovery path omits it (default `false` = skip the cross-check) since it
  #   has no trustworthy client PDA — re-deriving is the whole point. A real
  #   PDA is always a non-empty base58 string, so `false` is an unambiguous
  #   "not provided" sentinel.
  # `vault:` — lets a caller reuse an already-instantiated Solana::Vault.
  def verify_and_confirm_onchain_entry!(entry, tx_signature, expected_entry_pda: false, vault: Solana::Vault.new)
    derived_entry_pda = Solana::Keypair.encode_base58(
      vault.entry_pda(@contest.slug, current_user.web3_solana_address, entry.entry_number).first
    )
    raise "Entry PDA mismatch" if expected_entry_pda != false && expected_entry_pda != derived_entry_pda

    verify_solana_transaction!(
      tx_signature,
      instruction: "enter_contest",
      signer: current_user.web3_solana_address,
      writable: derived_entry_pda
    )

    entry.confirm_onchain!(tx_signature: tx_signature, entry_pda: derived_entry_pda)
    derived_entry_pda
  end

  def set_contest
    @contest = Contest.find_by(slug: params[:id])
    return if @contest

    # Diagnostic — every "Contest not found" toast in the wild traces back
    # to this miss. Log enough forensics to identify the source: who, what
    # slug, what path, where they came from, browser vs Turbo, user-agent.
    # `grep '\[set_contest:miss\]' log/development.log` after the toast
    # appears to inspect.
    Rails.logger.warn(
      "[set_contest:miss] " \
      "slug=#{params[:id].inspect} " \
      "method=#{request.method} " \
      "path=#{request.fullpath.inspect} " \
      "referer=#{request.referer.inspect} " \
      "turbo_frame=#{request.headers['Turbo-Frame'].inspect} " \
      "xhr=#{request.xhr?} " \
      "format=#{request.format.to_s.inspect} " \
      "user=#{logged_in? ? current_user.id : 'guest'} " \
      "ua=#{request.user_agent.to_s.first(120).inspect}"
    )

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

  # Pre-rendered seeds payload used by the contest show page's slate
  # progress card. Cache-first (the navbar preload no longer blocks on the
  # seeds RPC — see ApplicationController): returns the warm cached payload
  # when available, otherwise a zero payload so the card still renders and
  # the seeds_bar self-heals from `seedsNavbar` localStorage + the
  # 'navbar-seeds-update' event that refreshBalance() fires on load. Returns
  # nil for guests / non-wallet users so the view's `<% if @seeds_data %>`
  # gate keeps the card hidden.
  def load_seeds_data
    return unless logged_in? && current_user.solana_connected?
    display_seeds_data || seeds_payload(0)
  end

  def contest_params
    params.require(:contest).permit(:name, :slug, :slate_id, :contest_type, :starts_at, :contest_image, :locks_at_date_selected, :locks_at_time_selected, :locks_at_timezone_selected)
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

  # :contest_image is intentionally NOT permitted here — the banner saves through
  # its own #update_banner action. Permitting it would let any future field on
  # the edit form submit an empty value and purge the existing attachment.
  def contest_update_params
    params.require(:contest).permit(:name, :tagline, :rank, :starts_at, :locks_at_date_selected, :locks_at_time_selected, :locks_at_timezone_selected, :chat_enabled)
  end
end
