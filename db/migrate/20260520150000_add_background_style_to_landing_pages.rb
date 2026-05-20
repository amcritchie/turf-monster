class AddBackgroundStyleToLandingPages < ActiveRecord::Migration[7.2]
  # Which animated background a landing page's splash renders.
  # See app/views/landing_pages/backgrounds/.
  def change
    add_column :landing_pages, :background_style, :string, null: false, default: "gradient"
  end
end
