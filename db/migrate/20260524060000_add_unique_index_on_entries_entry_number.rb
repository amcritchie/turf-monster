class AddUniqueIndexOnEntriesEntryNumber < ActiveRecord::Migration[7.2]
  # H2 (Stage 2 audit): close the entry_number TOCTOU window. The pattern
  # `entry.entry_number ||= user.next_entry_number_for(contest)` reads the
  # current count outside any per-user lock, so two concurrent enters for
  # the same (user, contest) both compute the same next number. Anchor's PDA
  # `init` constraint catches the on-chain collision, but the DB happily
  # writes two rows with the same (user_id, contest_id, entry_number).
  #
  # Partial because entry_number is nil for cart entries that never got far
  # enough to be assigned one; many rows can coexist with NULL.
  INDEX_NAME = "index_entries_on_user_contest_entry_number".freeze

  def change
    return if connection.indexes(:entries).any? { |i| i.name == INDEX_NAME }

    add_index :entries, [:user_id, :contest_id, :entry_number],
              unique: true,
              where:  "entry_number IS NOT NULL",
              name:   INDEX_NAME
  end
end
