class CreateSlates < ActiveRecord::Migration[7.2]
  def change
    create_table :slates do |t|
      t.string :name, null: false
      t.datetime :starts_at
      t.float :formula_a
      t.float :formula_line_exp
      t.float :formula_prob_exp
      t.float :formula_mult_base
      t.float :formula_mult_scale
      t.float :formula_goal_base
      t.float :formula_goal_scale
      t.string :slug
      t.timestamps null: false

      t.index :slug, unique: true
    end
  end
end
