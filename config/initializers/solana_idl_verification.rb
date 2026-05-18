# Boot-time IDL hash verification (audit Tier 3 #22).
# In production only — verifies the committed turf_vault IDL hasn't drifted
# from the on-chain program. Raises before the web server accepts connections.
#
# Skip locally + in tests because:
#   - dev DBs often run against an older IDL during iteration
#   - tests stub Solana calls anyway (see test_solana_stubs.rb)
#
# To bypass in production (e.g. during a controlled deploy mid-upgrade),
# set SKIP_IDL_VERIFICATION=true.
if Rails.env.production? && ENV["SKIP_IDL_VERIFICATION"].blank?
  Rails.application.config.after_initialize do
    Solana::Config.verify_idl!
  rescue Solana::Config::IdlMismatchError => e
    Rails.logger.error(e.message)
    raise
  end
end
