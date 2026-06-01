# OPSEC-041: Content-Security-Policy headers.
#
# Whitelist of asset sources to defang reflected/stored XSS. The site
# loads:
#   - Phantom wallet from injected window object (no external script)
#   - Solana web3 + Alpine via CDN (script-src https:)
#   - Stripe Checkout redirect (no embed; just redirect target — no CSP entry needed for navigation)
#   - Resend is server-side only
#
# Inline scripts/styles are used by Alpine and several inline blocks in the
# ERB layouts. Rails 7's `:strict_dynamic` + nonce approach would be ideal
# but requires a refactor of inline script use. For v1 we allow 'unsafe-inline'
# on script-src/style-src — narrowed via nonce in a follow-up. Report-only
# in dev so we surface accidental violations without blocking; enforced in
# production.

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self, :https
    policy.font_src    :self, :https, :data
    policy.img_src     :self, :https, :data, :blob
    policy.object_src  :none
    policy.script_src  :self, :https, :unsafe_inline, :unsafe_eval
    policy.style_src   :self, :https, :unsafe_inline
    policy.connect_src :self, :https, :wss   # XHR + Solana RPC + websockets
    policy.frame_src   :self, "https://js.stripe.com", "https://hooks.stripe.com"
    policy.frame_ancestors :none   # clickjacking protection — we never embed in iframes
    policy.base_uri    :self
    policy.form_action :self, "https://checkout.stripe.com"
  end

  config.content_security_policy_report_only = !Rails.env.production?
end
