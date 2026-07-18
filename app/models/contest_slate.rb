# Joins a Contest to the Slates (NFL weeks) it spans, in order.
#
# A single-week contest has exactly one of these at position 1, mirroring
# `contests.slate_id`. A "Week 1-3" contest has three, positions 1..3.
class ContestSlate < ApplicationRecord
  belongs_to :contest
  belongs_to :slate

  validates :position, numericality: { only_integer: true, greater_than: 0 }
  validates :slate_id, uniqueness: { scope: :contest_id }
  validates :position, uniqueness: { scope: :contest_id }
end
