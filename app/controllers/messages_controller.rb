class MessagesController < ApplicationController
  # require_authentication is inherited from ApplicationController — both
  # actions need a logged-in user, so nothing is skipped here.
  before_action :set_contest
  before_action :require_chat_enabled, only: [:create, :toggle_reaction]

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

  # POST /contests/:contest_id/messages/:id/toggle_reaction
  # Body: { emoji: "❤️" }. Adds the reaction if the viewer hasn't used it on
  # this message, removes it if they have (Slack/Discord toggle). The updated
  # reactions row broadcasts to everyone via Reaction's after-commit hooks.
  def toggle_reaction
    unless @contest.chat_participant?(current_user)
      return render json: { error: "Enter the contest to react." }, status: :forbidden
    end

    emoji = params[:emoji].to_s
    unless Reaction::ALLOWED.include?(emoji)
      return render json: { error: "Unsupported reaction." }, status: :unprocessable_entity
    end

    message = @contest.messages.visible.find(params[:id])

    rescue_and_log(target: message, parent: @contest) do
      existing = message.reactions.find_by(user_id: current_user.id, emoji: emoji)
      reacted =
        if existing
          existing.destroy!
          false
        else
          message.reactions.create!(user: current_user, emoji: emoji)
          true
        end
      # Return the re-rendered pills so the actor's own page updates instantly
      # (no wait on the cable round-trip — which can race a WS reconnect). The
      # Reaction broadcast still keeps OTHER viewers in sync; that replace is
      # idempotent against this same markup.
      render json: { ok: true, reacted: reacted, html: reactions_html(message) }
    end
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue ActiveRecord::RecordNotUnique
    # Lost a double-click race against an identical concurrent add — the row
    # the other request created is the desired end state, so report success.
    message = @contest.messages.visible.find_by(id: params[:id])
    render json: { ok: true, reacted: true, html: (message && reactions_html(message)) }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  # The same partial Reaction#broadcast_reactions sends over the cable, rendered
  # for the toggling request so the actor's DOM updates immediately.
  def reactions_html(message)
    render_to_string(partial: "messages/reactions", locals: { message: message }, formats: [:html])
  end

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
