class MessagesController < ApplicationController
  # require_authentication is inherited from ApplicationController — both
  # actions need a logged-in user, so nothing is skipped here.
  before_action :set_contest
  before_action :require_chat_enabled, only: [:create]

  # POST /contests/:contest_id/messages
  def create
    unless @contest.chat_participant?(current_user)
      return render json: { error: "Only contest entrants can post in the chat." }, status: :forbidden
    end

    if posting_too_fast?
      return render json: { error: "You're posting too fast — give it a few seconds." }, status: :too_many_requests
    end

    message = @contest.messages.new(user: current_user, body: params.dig(:message, :body))

    # Validation failures are routine user input, not errors worth logging.
    unless message.valid?
      return render json: { error: message.errors.full_messages.first }, status: :unprocessable_entity
    end

    rescue_and_log(target: message, parent: @contest) do
      message.save!
      render json: { ok: true }
    end
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # DELETE /contests/:contest_id/messages/:id — admin soft-delete (moderation).
  def destroy
    return head :forbidden unless current_user&.admin?

    message = @contest.messages.find(params[:id])

    rescue_and_log(target: message, parent: @contest) do
      message.hide!(current_user) unless message.hidden?
      render json: { ok: true }
    end
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_contest
    @contest = Contest.find_by(slug: params[:contest_id])
    head :not_found unless @contest
  end

  def require_chat_enabled
    return if @contest&.chat_enabled?
    render json: { error: "Chat is closed for this contest." }, status: :forbidden
  end

  # Per-user cooldown: at most 5 messages per 15 seconds. The rack-attack
  # rule is a coarse per-IP flood backstop; this is the precise per-user one.
  def posting_too_fast?
    return false unless current_user
    Message.where(user_id: current_user.id)
           .where(created_at: 15.seconds.ago..)
           .count >= 5
  end
end
