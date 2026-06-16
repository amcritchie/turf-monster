class AddMetadataAndHomeArenaToTeams < ActiveRecord::Migration[7.2]
  def change
    add_column :teams, :color_text_light, :boolean, default: false, null: false
    add_column :teams, :sport, :string
    add_column :teams, :league, :string
    add_column :teams, :conference, :string
    add_column :teams, :division, :string
    add_column :teams, :rivals, :jsonb, default: [], null: false
    add_column :teams, :team_website, :string
    add_column :teams, :coaches_url, :string
    add_column :teams, :hashtag, :string
    add_column :teams, :hashtag2, :string
    add_column :teams, :x_handle, :string
    add_column :teams, :home_arena_slug, :string

    add_index :teams, [:sport, :league]
    add_index :teams, :home_arena_slug
  end
end
