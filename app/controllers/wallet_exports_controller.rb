# Wallet self-custody export (task #11).
#
# Stage 1 (live now): initiate_wallet_export lives on AccountsController. It
# verifies eligibility, stamps export_initiated_at, mints a 30-min signed
# token, and emails the user a magic link that points at #show below.
#
# Stage 2 (this controller — STUB until Stage 2 lands):
#   show     — render the reveal page: decrypt and display the keypair as
#              both Solana CLI JSON array and base58, alongside a server-
#              issued Phantom-sign nonce.
#   complete — verify the Phantom signature over the nonce. Set
#              users.self_custodied_at; from that moment downstream
#              call sites refuse to server-sign on this user's behalf.
#
# Stage 3 (separate PR): enforce self_custodied? in ContestsController#enter
# and Solana::Vault#build_enter_contest_with_token. Today, Stage 1 just
# proves we can produce a valid signed link; Stages 2+3 follow.
class WalletExportsController < ApplicationController
  WALLET_EXPORT_TOKEN_KEY = AccountsController::WALLET_EXPORT_TOKEN_KEY

  # The reveal page is reached via a one-shot email magic link. A user
  # opening their inbox on a different device than the one they're logged
  # in on must still be able to land on the page — the signed token IS the
  # auth boundary. The token verifier binds it to the user it was issued
  # for (verify_export_token), so an attacker without the token sees a 410.
  skip_before_action :require_authentication, only: [:show, :complete]

  before_action :verify_export_token, only: [:show, :complete]

  def show
    # STUB — Stage 2 will render the reveal page.
    render plain: "Wallet export Stage 2 not implemented yet — token verified for user #{@export_user.id}.", status: 503
  end

  def complete
    # STUB — Stage 2 will Phantom-verify a signed nonce, then:
    #   @export_user.update!(self_custodied_at: Time.current)
    render json: { success: false, error: "Stage 2 not implemented yet." }, status: 503
  end

  private

  def verify_export_token
    payload = Rails.application.message_verifier(WALLET_EXPORT_TOKEN_KEY).verify(params[:token]).with_indifferent_access
    @export_user = User.find_by(id: payload[:user_id])

    raise "Unknown account" unless @export_user
    # If the user changed their email after the token was minted, refuse —
    # the token is bound to the original email.
    raise "Token issued for a different email" unless @export_user.email.to_s.downcase == payload[:email].to_s.downcase
    # If the user re-initiated after this token was minted, only the freshest
    # initiate's token resolves — refuse stale tokens to keep magic-link
    # leakage windows tight.
    raise "A newer export link was issued — use the most recent one" unless @export_user.export_initiated_at.to_i == payload[:initiated_at].to_i
    raise "Wallet is already self-custodied"                          if @export_user.self_custodied?
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    render plain: "This export link is invalid or expired. Request a fresh one from your account page.", status: 410
  rescue StandardError => e
    Rails.logger.warn "[wallet-export] token verify failed: #{e.class}: #{e.message}"
    render plain: e.message, status: 410
  end
end
