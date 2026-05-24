class AddUniqueIndexOnUsersLowerUsername < ActiveRecord::Migration[7.2]
  # H1 (Stage 2 audit): close the signup TOCTOU window. `User` validates
  # `username` with `case_sensitive: false`, but the validation runs in Ruby
  # — two concurrent signups picking the same username can both pass and both
  # INSERT. A `LOWER(username)` partial unique index matches the validation's
  # semantics and lets Postgres catch the race.
  #
  # Partial (WHERE username IS NOT NULL) because the column is nullable —
  # wallet-only / pre-profile-completion users have no username yet.
  # Idempotent: an environment may already have this index from a manual
  # ad-hoc add, with schema_migrations not yet caught up. Skip if present.
  # `index_exists?` can't introspect expression indexes, so check by name.
  INDEX_NAME = "index_users_on_lower_username".freeze

  def change
    return if connection.indexes(:users).any? { |i| i.name == INDEX_NAME }

    add_index :users, "LOWER(username)",
              unique: true,
              where:  "username IS NOT NULL",
              name:   INDEX_NAME
  end
end
