class Contest < ApplicationRecord
  include Sluggable

  has_many :entries, dependent: :destroy
  belongs_to :slate
  belongs_to :user, optional: true
  has_one_attached :contest_image

  validates :name, presence: true

  enum :status, { pending: "pending", open: "open", locked: "locked", settled: "settled" }

  scope :ranked, -> { where.not(rank: nil).order(rank: :asc) }

  def self.target
    ranked.find_by(status: :open)
  end

  def matchups
    slate.slate_matchups
  end

  def picks_required
    6
  end

  def max_entries_per_user
    3
  end

  def entry_fee_dollars
    entry_fee_cents / 100.0
  end

  def guaranteed_prize_cents
    payouts.values.sum
  end

  def guaranteed_prize_dollars
    guaranteed_prize_cents / 100.0
  end

  def pool_cents
    entries.where(status: [:active, :complete]).count * entry_fee_cents
  end

  def pool_dollars
    pool_cents / 100.0
  end

  # GTM contest tiers (defined 2026-05-17). All at $19 entry fee.
  # Margin per filled contest = gross revenue (entries × fee) − total payouts.
  #   tiny     :  3 entries → $57   gross / $45   payout / $12 margin (78.9%)
  #   small    :  5 entries → $95   gross / $75   payout / $20 margin (78.9%)
  #   medium   :  9 entries → $171  gross / $140  payout / $31 margin (81.9%)
  #   standard : 29 entries → $551  gross / $500  payout / $51 margin (90.7%)
  #   large    : 99 entries → $1881 gross / $1800 payout / $81 margin (95.7%)
  FORMATS = {
    "tiny"     => { entry_fee_cents: 19_00, max_entries: 3,  payouts: { 1 => 45_00 } },
    "small"    => { entry_fee_cents: 19_00, max_entries: 5,  payouts: { 1 => 75_00 } },
    "medium"   => { entry_fee_cents: 19_00, max_entries: 9,  payouts: { 1 => 100_00, 2 => 40_00 } },
    "standard" => { entry_fee_cents: 19_00, max_entries: 29, payouts: { 1 => 300_00, 2 => 50_00, 3 => 50_00, 4 => 50_00, 5 => 50_00 } },
    "large"    => { entry_fee_cents: 19_00, max_entries: 99, payouts: { 1 => 1000_00, 2 => 100_00, 3 => 100_00, 4 => 100_00, 5 => 100_00, 6 => 100_00, 7 => 100_00, 8 => 100_00, 9 => 100_00 } }
  }.freeze

  def format_config
    FORMATS[contest_type] || FORMATS["standard"]
  end

  def payouts
    format_config[:payouts]
  end

  def grade!
    with_lock do
      raise "Contest is already settled" if settled?
      score_entries!

      ranked = entries.where(status: [:active, :complete]).order(score: :desc).includes(:user).to_a
      ranked.each { |e| e.update!(status: "complete") if e.active? }
      ranked = entries.complete.order(score: :desc).includes(:user).to_a

      return update!(status: "settled") if ranked.empty?

      # Build ranks (ties get same rank)
      ranks = []
      ranked.each_with_index do |entry, i|
        rank = if i == 0
          1
        elsif entry.score < ranked[i - 1].score
          i + 1
        else
          ranks.last
        end
        ranks << rank
      end

      # Pay out based on format payouts
      max_paid_rank = payouts.keys.max || 0
      ranked.each_with_index do |entry, i|
        rank = ranks[i]
        share = 0

        if rank <= max_paid_rank
          tied_indices = ranks.each_index.select { |j| ranks[j] == rank }
          tied_count = tied_indices.size
          spanned_ranks = (rank..(rank + tied_count - 1)).to_a
          total_prize = spanned_ranks.sum { |r| payouts[r] || 0 }
          base_share = total_prize / tied_count
          remainder = total_prize % tied_count
          position_in_tie = tied_indices.index(i)
          share = position_in_tie < remainder ? base_share + 1 : base_share
          if share > 0
            TransactionLog.record!(user: entry.user, type: "payout", amount_cents: share, direction: "credit", source: self, description: "Payout rank ##{rank} for #{name}")
          end
        end

        entry.update!(rank: rank, payout_cents: share)
      end

      update!(status: "settled")

      # Attempt onchain settlement (non-blocking)
      settle_onchain! if onchain?
    end
  end

  def jump!
    raise "Contest is already settled" if settled?

    transaction do
      # Simulate all pending games
      matchups.pending.includes(:game).each do |matchup|
        game = matchup.game
        next unless game

        unless game.status == "completed"
          home_score = rand(0..5)
          away_score = rand(0..5)
          game.update!(home_score: home_score, away_score: away_score, status: "completed")
        end

        if matchup.team_slug == game.home_team_slug
          matchup.update!(goals: game.home_score, status: "completed")
        elsif matchup.team_slug == game.away_team_slug
          matchup.update!(goals: game.away_score, status: "completed")
        end
      end

      update!(status: :locked) if open?
      grade!
    end
  end

  def fill!(users:)
    raise "Contest is not open" unless open?

    matchup_ids = matchups.pluck(:id)
    raise "Need at least #{picks_required} matchups" if matchup_ids.size < picks_required

    active_count = entries.where(status: [:active, :complete]).count
    slots = (max_entries || format_config[:max_entries]) - active_count
    return if slots <= 0

    existing_combos = entries.where(status: [:active, :complete]).includes(:selections).map do |entry|
      entry.selections.map(&:slate_matchup_id).sort
    end.to_set

    user_cycle = users.cycle
    attempts = 0

    slots.times do
      combo = nil
      loop do
        attempts += 1
        break if attempts > slots * 100
        # Pick 5 random non-locked matchups
        available = matchups.reject(&:locked?).map(&:id)
        next if available.size < picks_required
        combo = available.sample(picks_required).sort
        break unless existing_combos.include?(combo)
        combo = nil
      end
      break unless combo

      existing_combos << combo
      user = user_cycle.next
      entry = entries.create!(user: user, contest: self)
      combo.each do |matchup_id|
        entry.selections.create!(slate_matchup_id: matchup_id)
      end
      entry.confirm!
    end
  end

  def reset!
    transaction do
      entries.destroy_all
      matchups.update_all(goals: nil, status: "pending")
      matchups.includes(:game).find_each do |matchup|
        matchup.game&.update!(home_score: nil, away_score: nil, status: "scheduled")
      end
      update!(status: :open)
    end
  end

  def simulate_games!(count)
    simulated = 0
    count.times do
      break if matchups.pending.includes(:game).none? { |m| m.game.present? }
      simulate_next_game!
      simulated += 1
    end
    simulated
  end

  def simulate_next_game!
    raise "Contest is already settled" if settled?

    # Find next unplayed game (by kickoff_at)
    matchup = matchups.pending.includes(:game).select { |m| m.game.present? }
      .sort_by { |m| m.game.kickoff_at || Time.current }
      .first

    raise "No pending games to simulate" unless matchup

    game = matchup.game
    home_score = rand(0..5)
    away_score = rand(0..5)
    game.update!(home_score: home_score, away_score: away_score, status: "completed")

    # Update all matchups for this game
    game_matchups = matchups.where(game_slug: game.slug)
    game_matchups.each do |m|
      # Figure out which team's goals to record
      if m.team_slug == game.home_team_slug
        m.update!(goals: home_score, status: "completed")
      elsif m.team_slug == game.away_team_slug
        m.update!(goals: away_score, status: "completed")
      end
    end

    # Recompute points for all entries with selections on these matchups
    score_entries!
    game
  end

  def score_entries!
    entries.where(status: [:active, :complete]).includes(selections: :slate_matchup).find_each do |entry|
      entry.selections.each(&:compute_points!)
      total = entry.selections.reload.sum { |s| s.points || 0 }
      entry.update!(score: total)
    end
    touch # Bust show page cache after scoring
  end

  # --- Onchain ---

  def onchain?
    onchain_contest_id.present?
  end

  def onchain_params
    fee_cents = entry_fee_cents.to_i
    guaranteed = guaranteed_prize_cents
    # Payout amounts in USDC lamports (6 decimals) — human-readable onchain
    payout_amounts = payouts.values.map { |c| Solana::Config.dollars_to_lamports(c / 100.0) }

    {
      entry_fee: Solana::Config.dollars_to_lamports(fee_cents / 100.0),
      max_entries: max_entries || format_config[:max_entries],
      payout_amounts: payout_amounts,
      prizes: Solana::Config.dollars_to_lamports(guaranteed / 100.0)
    }
  end

  def settle_onchain!
    return unless onchain? && !onchain_settled?

    winners = entries.complete.where("payout_cents > 0").includes(:user).map do |entry|
      {
        wallet: entry.user.solana_address,
        entry_num: entry.entry_number || 0,
        rank: entry.rank || 0,
        payout: Solana::Config.dollars_to_lamports(entry.payout_cents / 100.0)
      }
    end.select { |w| w[:wallet].present? }

    return update!(onchain_settled: true) if winners.empty?

    # Build partially-signed TX for multisig cosigning
    vault = Solana::Vault.new
    # Use first non-admin signer as default cosigner placeholder
    cosigner = Solana::Config::MULTISIG_COSIGNER rescue Solana::Keypair.admin.to_base58
    result = vault.build_settle_contest(slug, winners, cosigner_pubkey: cosigner)

    PendingTransaction.create!(
      tx_type: "settle_contest",
      serialized_tx: result[:serialized_tx],
      target: self,
      initiator_address: Solana::Keypair.admin.to_base58,
      metadata: { settlements: winners }.to_json
    )
  rescue => e
    ErrorLog.capture!(e)
    # Don't block DB settlement — onchain can be retried
  end

  def locks_at
    starts_at
  end

  def lock_time_display
    return "TBD" unless starts_at
    starts_at.strftime("Locks %B %-d, %Y @ %-I:%M %p")
  end

  def active_entry_count
    entries.where(status: [:active, :complete]).count
  end

  def name_slug
    name.parameterize
  end
end
