class AddMainContestIdToSeasonConfigs < ActiveRecord::Migration[7.2]
  # Singleton pointer to the "main" contest used as the default target
  # across the app — root redirect, /account referral widget, faucet
  # CTA. Nullable + on_delete: :nullify so deleting a contest doesn't
  # break the row; consumers fall back to "most recent open contest"
  # via SeasonConfig.main_contest.
  def change
    add_reference :season_configs, :main_contest,
                  foreign_key: { to_table: :contests, on_delete: :nullify },
                  null: true
  end
end
