class Slate < ApplicationRecord
  include Sluggable

  FORMULA_DEFAULTS = {
    formula_a: 1.65, formula_line_exp: 1.24, formula_prob_exp: 1.18,
    formula_mult_base: 1.0, formula_mult_scale: 2.0,
    formula_goal_base: 0.2, formula_goal_scale: 4.3
  }.freeze

  FORMULA_COLUMNS = FORMULA_DEFAULTS.keys.freeze

  has_many :slate_matchups, dependent: :destroy
  has_many :contests

  validates :name, presence: true

  def self.default_record
    find_by(name: "Default")
  end

  def resolved_formula
    defaults = self.class.default_record
    FORMULA_DEFAULTS.each_with_object({}) do |(key, hardcoded), hash|
      hash[key] = read_attribute(key) || (defaults&.id != id ? defaults&.read_attribute(key) : nil) || hardcoded
    end
  end

  def name_slug
    name.parameterize
  end
end
