class AddBadgeToLandingPages < ActiveRecord::Migration[7.2]
  # Optional badge label shown under the funnel headline. Blank/null = no badge.
  def change
    add_column :landing_pages, :badge, :string
  end
end
