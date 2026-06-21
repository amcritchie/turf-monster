# Installs the engine's Studio::Link table (copy of the studio-engine reference
# migration). Generalizes turf-monster's app-local magic_links table into the
# shared store (magic links + referral links).
class CreateStudioLinks < ActiveRecord::Migration[7.2]
  def change
    create_table :studio_links do |t|
      t.string :token, null: false
      t.string :kind, null: false
      t.references :linkable, polymorphic: true, index: false
      t.jsonb :metadata, null: false, default: {}
      t.datetime :expires_at
      t.datetime :consumed_at

      t.timestamps
    end

    add_index :studio_links, :token, unique: true
    add_index :studio_links, :kind
    add_index :studio_links, [:linkable_type, :linkable_id, :kind],
              name: "idx_studio_links_owner_kind"
  end
end
