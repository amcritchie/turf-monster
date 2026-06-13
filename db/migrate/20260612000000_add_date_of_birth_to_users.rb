class AddDateOfBirthToUsers < ActiveRecord::Migration[7.2]
  # Age-gate-at-first-entry (2026-06-12): we now collect a real date of birth
  # the first time a user enters a contest, validate it against their state's
  # minimum age, and stamp `age_attested_at` (existing column) on success.
  # DOB is the audit-grade upgrade over the old signup checkbox. Nullable —
  # only populated once a user actually enters a paid contest.
  def change
    add_column :users, :date_of_birth, :date
  end
end
