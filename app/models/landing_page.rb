class LandingPage < ApplicationRecord
  include Sluggable

  # The CTA target. Optional so a page can be drafted before a contest
  # exists; `contest_required_when_active` blocks publishing without one.
  belongs_to :contest, optional: true

  # Which animated background the splash renders — partials live in
  # app/views/landing_pages/backgrounds/.
  enum :background_style, { gradient: "gradient", blobs: "blobs", circles: "circles" }

  # Populate the slug before validation so uniqueness can be checked on it.
  # (Sluggable also re-runs set_slug before_save — idempotent once set.)
  before_validation :set_slug

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
  validate  :contest_required_when_active

  scope :active, -> { where(active: true) }

  # Sluggable hook. An explicit slug wins; otherwise derive from the name.
  # Referencing `slug` keeps the funnel URL stable across name edits —
  # clear the slug field to re-derive it.
  def name_slug
    slug.presence || name.to_s.parameterize
  end

  def cta_label_display
    cta_label.presence || "Enter the Contest"
  end

  # Background partial to render, under landing_pages/backgrounds/.
  # All backgrounds are dark splashes (the funnel always renders dark).
  def background_partial
    self.class.background_styles.key?(background_style) ? background_style : "gradient"
  end

  # Signups attributed to this funnel (User#reference == this page's slug).
  def signup_count
    User.where(reference: slug).count
  end

  private

  def contest_required_when_active
    return unless active? && contest_id.blank?

    errors.add(:active, "can't be enabled without a contest selected")
  end
end
