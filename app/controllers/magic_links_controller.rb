# Unified create-or-login email magic link (replaces the password UI).
#
#   POST /magic_link        — request a link (email [, contest, picks, return_to])
#   GET  /magic_link/:token — "Confirm sign-in" interstitial (does NOT consume —
#                             scanner-safe; see #confirm)
#   POST /magic_link/:token — consume it: log in OR create the account
#
# create-or-login: clicking the link IS proof of email ownership, so an email
# that collides with a Google/wallet-only account that was never email-verified
# is safely logged in here and stamped email_verified_at (unlike from_omniauth,
# which refuses that collision precisely because it lacked this proof).
class MagicLinksController < ApplicationController
  skip_before_action :require_authentication

  # Respond uniformly for any well-formed email. Under create-or-login every
  # address is "valid" (it logs in or signs up), so there is nothing to
  # enumerate — but staying uniform keeps it that way if invite-only is ever
  # added. A malformed email gets the same response with no mail sent.
  def create
    email = params[:email].to_s.strip.downcase
    if email.match?(URI::MailTo::EMAIL_REGEXP)
      token = MagicLink.generate(email: email, return_to: resolved_return_to)
      UserMailer.magic_link(email, token, contest: @magic_contest).deliver_later
    end
    respond_to do |format|
      format.json { render json: { success: true } }
      format.html { redirect_to signin_path, notice: "Check your inbox — we just emailed you a sign-in link." }
    end
  end

  # GET /magic_link/:token — the "Confirm sign-in" interstitial.
  #
  # This action is DELIBERATELY INERT: it does NOT consume the token. It only
  # renders a one-button page whose button POSTs back to #consume. This is the
  # scanner-safe core of the flow: email link-scanners (Outlook SafeLinks,
  # Mimecast, corporate AV), the Gmail image proxy, and link-preview prefetchers
  # all issue a GET/HEAD against the emailed URL. If that GET consumed the
  # single-use token, the burn would land BEFORE the human's first real click,
  # and the human would see "link already used" on a link they never used — the
  # operator's "hard time creating an account" symptom and a real tester risk.
  # Because the GET is inert, a scanner's pre-fetch is a no-op; only the human's
  # POST burns the token.
  #
  # The token never leaves the URL here, so keep it out of Referer on this
  # page's subresource loads (logo, fonts, analytics).
  def confirm
    response.set_header("Referrer-Policy", "no-referrer")
    @token = params[:token]
    # We render WITHOUT verifying the signature: a verify here would have to
    # decode + check expiry, and surfacing "expired" vs "invalid" on a GET adds
    # nothing — the POST does the authoritative check and shows the same error.
    # Keeping confirm signature-free also means a malformed/garbage token still
    # gets a friendly page instead of a 500.
  end

  # POST /magic_link/:token — the authoritative consume. This is the ONLY place
  # the single-use token is burned, and it only runs on the human's button press
  # (a scanner won't POST a CSRF-protected form). Mirrors the prior GET behavior.
  def consume
    response.set_header("Referrer-Policy", "no-referrer")
    result = MagicLink.consume(params[:token])
    user = User.find_by(email: result.email)
    user ? sign_in_existing(user, result) : sign_up_new(result)
  rescue MagicLink::InvalidToken
    redirect_to signin_path, alert: "That sign-in link is invalid or has expired. Request a fresh one below."
  end

  private

  # Hard-reset any prior session BEFORE establishing the magic-link user's.
  # A magic link is a fresh WEB2 (email) login: if the browser already held a
  # web3/Phantom-linked session, its state (onchain flag, sso_* awareness,
  # geo override, return_to, etc.) must not bleed into the new session — that
  # bleed is what made a web2 magic-link user still look phantom-linked and
  # triggered the Phantom unlock probe on the landing. reset_session rotates
  # the session id and drops every key; we then explicitly clear the onchain
  # privilege flag (set_app_session also deletes it, but be belt-and-braces
  # in case the engine helper changes) and Current so no request-scoped
  # identity from the old session lingers. The layout's user-change cleanup
  # (compares data-user-id) clears stale phantom_dl_* + wallet localStorage on
  # the landing render, completing the client side.
  def reset_prior_session!
    reset_session
    session.delete(:onchain)
    Current.reset
  end

  def sign_in_existing(user, result)
    reset_prior_session!
    set_app_session(user)
    user.update!(email_verified_at: Time.current) if user.email_verified_at.blank?
    redirect_to magic_link_landing_path(result),
                flash: { magic_link_welcome: {
                  message:  "Signed in — your 6 picks are saved.",
                  username: user.username,
                  next:     tokens_buy_path
                } }
  end

  # Mirrors RegistrationsController#create: build → configure_new_user → save!
  # (fires generate_managed_wallet! + enqueue_onchain_account_setup) → land on
  # the entry-tokens upsell. There is no password — email auth is magic-link
  # only across the whole app (the password_digest column is dormant).
  def sign_up_new(result)
    reset_prior_session!
    user = User.new(email: result.email, reference: cookies[:reference].presence&.to_s&.first(64))
    Studio.configure_new_user.call(user)
    rescue_and_log(target: user) do
      user.save!
      cookies.delete(:reference)
      user.update!(email_verified_at: Time.current)
      set_app_session(user)
      # Land on the contest (return_to) and show the welcome SUCCESS MODAL,
      # which auto-advances to the entry-tokens upsell after ~2.5s. The old
      # straight redirect to tokens_buy_path with a :notice toast skipped the
      # celebratory beat and dropped the user past the contest they came from.
      redirect_to magic_link_landing_path(result),
                  flash: { magic_link_welcome: {
                    message:  "You're in! Your 6 picks are saved.",
                    username: user.username,
                    next:     tokens_buy_path
                  } }
    end
  rescue ActiveRecord::RecordNotUnique
    # Two valid tokens for the same brand-new email consumed near-simultaneously
    # both miss the find_by and race to save!; the loser hits the unique index.
    # That's benign — the account now exists, so just log the winner in.
    existing = User.find_by(email: result.email)
    return sign_in_existing(existing, result) if existing

    redirect_to signin_path, alert: "We couldn't finish creating your account. Please try again."
  rescue StandardError => e
    Rails.logger.error("[MagicLinksController#consume] signup failed #{e.class}: #{e.message}")
    redirect_to signin_path, alert: "We couldn't finish creating your account. Please try again."
  end

  # Derives the post-consume landing path server-side (so it rides inside the
  # signed token and can't be tampered). A contest slug becomes the contest
  # page; validated picks ride along as ?picks= so the board can rehydrate a
  # guest's lineup even across a different browser/tab (where localStorage is
  # unavailable).
  def resolved_return_to
    @magic_contest = Contest.find_by(slug: params[:contest].presence)
    if @magic_contest
      picks = sanitized_picks
      picks.present? ? "#{contest_path(@magic_contest)}?picks=#{picks.join(',')}" : contest_path(@magic_contest)
    else
      safe_path(params[:return_to])
    end
  end

  # Digits only, max 6, intersected with the contest's real matchups so a
  # tampered query can't smuggle arbitrary ids back into the board.
  def sanitized_picks
    ids = params[:picks].to_s.split(",").map(&:to_i).select(&:positive?).first(6)
    return [] if ids.empty? || @magic_contest.nil?

    valid = @magic_contest.matchups.where(id: ids).pluck(:id)
    ids & valid
  end

  def safe_path(path)
    p = path.to_s
    p.start_with?("/") && !p.start_with?("//") ? p : nil
  end

  # Where the welcome modal opens. The signed return_to is normally the
  # contest the link came from (resolved_return_to bakes the contest slug +
  # picks in at request time); fall back to root, which redirects to the
  # current contest's show page. The modal itself then transfers the user to
  # the entry-tokens upsell after its countdown.
  def magic_link_landing_path(result)
    safe_path(result.return_to) || root_path
  end
end
