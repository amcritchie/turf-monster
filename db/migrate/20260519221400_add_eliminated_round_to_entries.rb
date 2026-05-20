class AddEliminatedRoundToEntries < ActiveRecord::Migration[7.2]
  def change
    # The round number a survivor entry was eliminated in; nil = still alive
    # (or a non-survivor entry).
    add_column :entries, :eliminated_round, :integer
  end
end
