class CreateContestSlates < ActiveRecord::Migration[8.1]
  # A Turf Totals contest may span several consecutive NFL weeks (e.g. "NFL
  # Week 1-3"). One Slate is still exactly one NFL week — the slate_matchups
  # unique index on [slate_id, team_slug] guarantees a team appears once per
  # slate, so weeks MUST stay separate slates. This join is what lets one
  # contest reach across them.
  #
  # `contests.slate_id` is NOT dropped: it stays the ANCHOR (the position-1
  # week). Every existing query, validation, and the pickable matchup set still
  # read through it, so single-week contests are untouched by this change.
  def up
    create_table :contest_slates do |t|
      t.references :contest, null: false, foreign_key: true
      t.references :slate, null: false, foreign_key: true

      # 1-based week ordinal WITHIN the contest (1, 2, 3), not the NFL week
      # number. Position 1 is the anchor and mirrors contests.slate_id.
      t.integer :position, null: false, default: 1

      t.timestamps
    end

    add_index :contest_slates, [:contest_id, :slate_id], unique: true
    add_index :contest_slates, [:contest_id, :position], unique: true

    # Backfill every existing slate-backed contest as a single-week span, so
    # `contest.slates` is uniform across old and new rows and `multi_week?`
    # reduces to a plain count. Written in SQL (not the model) so the backfill
    # can never drift with later model validations.
    execute <<~SQL
      INSERT INTO contest_slates (contest_id, slate_id, position, created_at, updated_at)
      SELECT id, slate_id, 1, NOW(), NOW()
      FROM contests
      WHERE slate_id IS NOT NULL
    SQL
  end

  def down
    drop_table :contest_slates
  end
end
