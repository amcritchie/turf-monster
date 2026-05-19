# Validates an incoming Stripe checkout.session.completed event against Stripe's
# own authoritative state before we mint anything.
#
# The webhook payload is signature-verified, but we go one step further: we
# re-fetch the session from the Stripe API and confirm payment_status,
# amount_total, environment, and metadata kind match what we expect.
#
# Usage:
#   result = StripeCheckoutValidator.new(session_id, kind: "tokens").call
#   if result.ok?
#     TokenPurchaseJob.perform_later(stripe_session_id: session_id, ...metadata pulled from result.session...)
#   else
#     Rails.logger.warn "skipping: #{result.reason}"
#   end
class StripeCheckoutValidator
  Result = Struct.new(:ok, :reason, :session, keyword_init: true) do
    def ok?; ok; end
  end

  def initialize(session_id, kind:)
    @session_id = session_id
    @kind = kind
  end

  def call
    sid_short = @session_id[0, 24]
    Rails.logger.info "[tokens] validator.start sid=#{sid_short}... kind=#{@kind}"

    if already_processed?
      Rails.logger.info "[tokens] validator.skip already_processed"
      return fail!(:already_processed)
    end

    session = Stripe::Checkout::Session.retrieve(@session_id)
    Rails.logger.info "[tokens] validator.fetched payment_status=#{session.payment_status} amount=#{session.amount_total} livemode=#{session.livemode} kind=#{session.metadata["kind"]}"
    # Full Stripe response dump — what their API gave us back, for diagnostics.
    TokensLogger.dump("validator.stripe_response", {
      id:              session.id,
      status:          session.status,
      payment_status:  session.payment_status,
      amount_total:    session.amount_total,
      amount_subtotal: session.amount_subtotal,
      currency:        session.currency,
      mode:            session.mode,
      livemode:        session.livemode,
      created:         session.created,
      expires_at:      session.expires_at,
      payment_intent:  session.payment_intent,
      customer_email:  session.customer_email,
      customer:        session.customer,
      metadata:        session.metadata.to_h,
      success_url:     session.success_url,
      cancel_url:      session.cancel_url
    })

    unless session.payment_status == "paid"
      Rails.logger.warn "[tokens] validator.fail not_paid payment_status=#{session.payment_status}"
      return fail!(:not_paid, session)
    end
    unless session.livemode == Rails.env.production?
      Rails.logger.warn "[tokens] validator.fail livemode_mismatch session=#{session.livemode} env_prod=#{Rails.env.production?}"
      return fail!(:livemode_mismatch, session)
    end
    unless session.metadata["kind"] == @kind
      Rails.logger.warn "[tokens] validator.fail kind_mismatch expected=#{@kind} got=#{session.metadata["kind"]}"
      return fail!(:kind_mismatch, session)
    end
    unless amount_matches?(session)
      Rails.logger.warn "[tokens] validator.fail amount_mismatch session_amount=#{session.amount_total} quantity=#{session.metadata["quantity"]}"
      return fail!(:amount_mismatch, session)
    end

    Rails.logger.info "[tokens] validator.ok sid=#{sid_short}..."
    Result.new(ok: true, session: session)
  rescue Stripe::InvalidRequestError => e
    Rails.logger.warn "[tokens] validator.fail session_not_found stripe_error=#{e.message}"
    fail!(:session_not_found)
  end

  private

  # Only a "minted" StripePurchase (or a recorded TransactionLog) counts as truly
  # done. "pending" / "failed" rows are mid-recovery and should not block reprocess.
  def already_processed?
    StripePurchase.for_session(@session_id).where(status: "minted").exists? ||
      TransactionLog.exists?(stripe_session_id: @session_id)  # OPSEC-022: indexed column
  end

  def amount_matches?(session)
    case @kind
    when "tokens"
      quantity = session.metadata["quantity"].to_i
      expected = StripePurchase.pack_price_cents(quantity)
      session.amount_total == expected
    else
      true # other kinds (deposits) have variable amounts — skip
    end
  rescue KeyError
    false # unknown pack quantity
  end

  def fail!(reason, session = nil)
    Result.new(ok: false, reason: reason, session: session)
  end
end
