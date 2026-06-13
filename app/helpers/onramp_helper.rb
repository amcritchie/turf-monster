module OnrampHelper
  # Visibility gate for an individual onramp rail in the "Add Funds" hub
  # (modals/_onramp_hub). Policy: show EVERY rail locally (dev/test) so the
  # whole hub is always exercisable, but in PRODUCTION reveal each rail only
  # when its own backend is actually live. That keeps a half-wired rail (the
  # placeholder PayPal/Venmo, or a flagged-off Coinbase ramp) from shipping a
  # dead button to real users, while leaving the full set visible for design
  # review and tests.
  #
  #   :coinbase        -> AppFlags.cdp_ramp?        (ENABLE_CDP_RAMP)
  #   :paypal, :venmo  -> Payments.paypal_checkout? (provider + credentials)
  #   :stripe          -> Payments.stripe?          (provider + key enabled)
  def onramp_rail_visible?(rail)
    return true unless Rails.env.production?

    case rail.to_sym
    when :coinbase       then AppFlags.cdp_ramp?
    when :paypal, :venmo then Payments.paypal_checkout?
    when :stripe         then Payments.stripe?
    else false
    end
  end
end
