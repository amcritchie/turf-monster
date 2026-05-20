class Message < ApplicationRecord
  BODY_MAX_LENGTH = 500

  belongs_to :contest
  belongs_to :user

  before_validation { self.body = body.strip if body.is_a?(String) }

  validates :body, presence: true, length: { maximum: BODY_MAX_LENGTH }

  # hidden_at nil = visible. Admin soft-delete sets it (see #hide!).
  scope :visible, -> { where(hidden_at: nil) }

  # Real-time delivery (ActionCable + Turbo Streams). New messages append to
  # the panel; an admin hide removes the bubble for everyone. The partial is
  # rendered viewer-agnostically — see app/views/messages/_message.html.erb.
  after_create_commit :broadcast_new_message
  after_update_commit :broadcast_removal, if: -> { saved_change_to_hidden_at? && hidden? }

  # Last `limit` visible messages for a contest, oldest-first (initial render order).
  def self.recent_for(contest, limit: 50)
    visible.where(contest: contest)
           .order(created_at: :desc, id: :desc)
           .limit(limit)
           .to_a
           .reverse
  end

  def hidden?
    hidden_at.present?
  end

  # Admin soft-delete: keeps the row for audit, hides it from the live UI.
  def hide!(admin)
    update!(hidden_at: Time.current, hidden_by_id: admin&.id)
  end

  private

  def broadcast_new_message
    broadcast_append_to(
      [contest, :messages],
      target: "contest_#{contest_id}_messages",
      partial: "messages/message",
      locals: { message: self }
    )
  end

  def broadcast_removal
    broadcast_remove_to([contest, :messages], target: "message_#{id}")
  end
end
