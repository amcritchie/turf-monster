class Entry < ApplicationRecord
  after_create :update_slug_with_id

  belongs_to :user
  belongs_to :contest
  has_many :selections, dependent: :destroy
  has_many :survivor_picks, dependent: :destroy

  enum :status, { cart: "cart", active: "active", complete: "complete", abandoned: "abandoned" }

  def toggle_selection!(slate_matchup)
    raise "Game has already started" if slate_matchup.locked?

    existing = selections.find_by(slate_matchup: slate_matchup)

    if existing
      existing.destroy!
    elsif selections.count < contest.picks_required
      selections.create!(slate_matchup: slate_matchup)
    else
      # Replace oldest selection
      selections.order(created_at: :asc).first.destroy!
      selections.create!(slate_matchup: slate_matchup)
    end

    reload
    if selections.empty?
      destroy!
      return nil
    end

    selections.each_with_object({}) { |s, h| h[s.slate_matchup_id.to_s] = true }
  end

  # Activate a cart entry. A paid contest's entry may only be activated with
  # proof of payment: `tx_signature` is the on-chain signature returned by a
  # consumed entry token or a vault entry, set server-side in
  # ContestsController#enter. Without it we refuse rather than hand out a free
  # entry — this is the gate that closes the off-chain-paid-contest hole.
  #
  # `comped: true` is the admin-seed escape hatch (Contest#fill! only): it
  # activates entries for seeded users without payment. Real user entries
  # always pass through the gate.
  def confirm!(tx_signature: nil, onchain_entry_id: nil, comped: false)
    raise "Contest is not open" unless contest.open?
    raise "Exactly #{contest.picks_required} selections required" unless selections.count == contest.picks_required

    # Check no locked games
    selections.includes(slate_matchup: :game).each do |s|
      raise "#{s.slate_matchup.team.name}'s game has already started" if s.slate_matchup.locked?
    end

    user.with_lock do
      # Per-user entry limit
      user_active_count = contest.entries.where(user: user, status: [:active, :complete]).count
      raise "Maximum #{contest.max_entries_per_user} entries per contest" if user_active_count >= contest.max_entries_per_user

      # Sybil check (inside lock to prevent concurrent duplicate entries)
      my_combo = selections.map(&:slate_matchup_id).sort
      contest.entries.where(user: user, status: [:active, :complete]).find_each do |other|
        other_combo = other.selections.map(&:slate_matchup_id).sort
        raise "You already have an entry with this exact selection combination" if other_combo == my_combo
      end

      transaction do
        # Payment gate: never activate a paid entry without proof of payment —
        # a tx_signature from a consumed entry token or a vault entry. `comped`
        # exempts admin-seeded fills. This closes the free-entry hole where an
        # off-chain paid contest skipped every payment branch in #enter.
        if contest.entry_fee_cents.to_i.positive? && tx_signature.blank? && !comped
          raise "Entry payment required — no entry token consumed or on-chain payment recorded"
        end

        if contest.entry_fee_cents > 0
          TransactionLog.record!(user: user, type: "entry_fee", amount_cents: contest.entry_fee_cents, direction: "debit", source: contest, description: "Entry fee for #{contest.name}")
        end
        update!(status: :active, onchain_tx_signature: tx_signature, onchain_entry_id: onchain_entry_id)
      end
    end

    # Attempt onchain entry (non-blocking) — skip if already transferred on-chain
    enter_onchain! unless tx_signature
  end

  def selection_data
    selections.includes(slate_matchup: :team).map do |s|
      { slate_matchup_id: s.slate_matchup_id, team_slug: s.slate_matchup.team_slug }
    end
  end

  private

  def update_slug_with_id
    update_column(:slug, name_slug)
  end

  public

  # --- Onchain ---

  # Confirm entry via direct onchain payment (Phantom wallet users).
  # No DB balance deduction — USDC was transferred onchain directly.
  def confirm_onchain!(tx_signature:, entry_pda:)
    raise "Contest is not open" unless contest.open?
    raise "Exactly #{contest.picks_required} selections required" unless selections.count == contest.picks_required

    # Check no locked games
    selections.includes(slate_matchup: :game).each do |s|
      raise "#{s.slate_matchup.team.name}'s game has already started" if s.slate_matchup.locked?
    end

    # Lock user row to prevent concurrent entry limit bypass
    user.with_lock do
      # Per-user entry limit
      user_active_count = contest.entries.where(user: user, status: [:active, :complete]).count
      raise "Maximum #{contest.max_entries_per_user} entries per contest" if user_active_count >= contest.max_entries_per_user

      # Sybil check
      my_combo = selections.map(&:slate_matchup_id).sort
      contest.entries.where(user: user, status: [:active, :complete]).find_each do |other|
        other_combo = other.selections.map(&:slate_matchup_id).sort
        raise "You already have an entry with this exact selection combination" if other_combo == my_combo
      end

      update!(
        status: :active,
        onchain_tx_signature: tx_signature,
        onchain_entry_id: entry_pda
      )
    end

    # Seeds (25 per entry) are awarded on-chain by the turf_vault Anchor program
  end

  def enter_onchain!
    return unless contest.onchain? && user.solana_connected?

    # Assign entry number (per-user, per-contest counter)
    self.entry_number ||= contest.entries.where(user: user).where.not(entry_number: nil).count
    save! if entry_number_changed?

    vault = Solana::Vault.new

    # Ensure user's onchain account exists before entering
    vault.ensure_user_account(user.solana_address)

    result = vault.enter_contest(user.solana_address, contest.slug, entry_number)
    update!(
      onchain_entry_id: result[:entry_pda],
      onchain_tx_signature: result[:signature]
    )
  rescue => e
    ErrorLog.capture!(e)
    # Don't block DB entry — onchain can be retried
  end

  def onchain?
    onchain_entry_id.present?
  end

  # --- Survivor ---

  def survivor?
    contest.world_cup_survivor?
  end

  def eliminated?
    eliminated_round.present?
  end

  def alive?
    survivor? && !eliminated?
  end

  # Rounds successfully survived — every round before elimination, or every
  # surviving pick so far for an entry still alive.
  def rounds_survived
    eliminated_round ? eliminated_round - 1 : survivor_picks.survived.count
  end

  def pick_for(survivor_round)
    survivor_picks.find_by(survivor_round: survivor_round)
  end

  # Team slugs already used — no team may be picked twice across the tournament.
  def used_team_slugs
    survivor_picks.pluck(:team_slug)
  end

  def to_param
    slug
  end

  def name_slug
    "#{user.display_name.parameterize}-#{contest.name_slug}-#{id}"
  end
end
