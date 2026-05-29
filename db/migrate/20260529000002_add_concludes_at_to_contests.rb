class AddConcludesAtToContests < ActiveRecord::Migration[7.2]
  # v0.18: the on-chain Contest gains a conclusion_timestamp (when the contest
  # is considered done — after which the lock time can't change). Mirror it
  # Rails-side as `concludes_at`, exactly as `starts_at` mirrors lock_timestamp.
  # The chain stays master; this drives the UI countdown + advisory predicates.
  def change
    add_column :contests, :concludes_at, :datetime
  end
end
