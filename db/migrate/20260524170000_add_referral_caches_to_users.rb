class AddReferralCachesToUsers < ActiveRecord::Migration[7.2]
  # Adds three caches used by the referral nudge UI + admin/users view:
  #
  #   contest_entered            — master flag, flips false → true the
  #                                first time this user lands a confirmed
  #                                entry (active or complete). One-way
  #                                ratchet; no decrement when entries are
  #                                later abandoned.
  #   invitees_count             — how many users have this user as their
  #                                inviter (invited_by_id). Maintained by
  #                                User#after_save on invited_by_id change.
  #   invitees_in_contest_count  — how many of those invitees have
  #                                contest_entered = true. Bumped by
  #                                ReferralProgress.mark_entered! when an
  #                                invitee first enters a contest. Drives
  #                                the "2 friends entered → free entry
  #                                token" reward + the inviter nudge email.
  def up
    add_column :users, :contest_entered, :boolean, default: false, null: false
    add_column :users, :invitees_count, :integer, default: 0, null: false
    add_column :users, :invitees_in_contest_count, :integer, default: 0, null: false
    add_index :users, :contest_entered, where: "contest_entered = true",
              name: "index_users_on_contest_entered_true"

    # Backfill from existing state. Uses raw SQL so this is one round-trip
    # per cache rather than N user rows × callback overhead.
    User.reset_column_information

    execute <<~SQL.squish
      UPDATE users
      SET contest_entered = true
      WHERE id IN (
        SELECT DISTINCT user_id FROM entries
        WHERE status IN ('active', 'complete')
      )
    SQL

    execute <<~SQL.squish
      UPDATE users AS inviter
      SET invitees_count = sub.count
      FROM (
        SELECT invited_by_id, COUNT(*) AS count
        FROM users
        WHERE invited_by_id IS NOT NULL
        GROUP BY invited_by_id
      ) AS sub
      WHERE inviter.id = sub.invited_by_id
    SQL

    execute <<~SQL.squish
      UPDATE users AS inviter
      SET invitees_in_contest_count = sub.count
      FROM (
        SELECT invited_by_id, COUNT(*) AS count
        FROM users
        WHERE invited_by_id IS NOT NULL AND contest_entered = true
        GROUP BY invited_by_id
      ) AS sub
      WHERE inviter.id = sub.invited_by_id
    SQL
  end

  def down
    remove_index :users, name: "index_users_on_contest_entered_true"
    remove_column :users, :invitees_in_contest_count
    remove_column :users, :invitees_count
    remove_column :users, :contest_entered
  end
end
