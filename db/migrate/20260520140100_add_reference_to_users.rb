class AddReferenceToUsers < ActiveRecord::Migration[7.2]
  # Funnel/campaign attribution string captured from a `?reference=` URL
  # param (or a landing page's slug) and written to the user at signup.
  # First-touch only — never overwritten. See ApplicationController#capture_reference.
  def change
    add_column :users, :reference, :string
    add_index  :users, :reference
  end
end
