class AddAddressToArenas < ActiveRecord::Migration[7.2]
  def change
    add_column :arenas, :address, :string
  end
end
