# Test-env-only Solana stubs.
#
# Playwright's rpc-mock.js intercepts Solana RPC calls in the BROWSER, but
# server-side flows (e.g. ContestsController#confirm_onchain_contest's
# verify_solana_transaction!) make their own HTTP calls from the Rails process.
# Those calls hit real devnet, which knows nothing about the mock signatures
# and returns "Invalid param: WrongSize".
#
# This stub recognizes the mock signature prefix from e2e/rpc-mock.js
# (MockTxSignature...) and short-circuits get_transaction to return a successful
# transaction shape. Real signatures still go through the real RPC.
return unless Rails.env.test?

Rails.application.config.after_initialize do
  stub = Module.new do
    def get_transaction(signature, *args, **kwargs)
      if signature.to_s.start_with?("MockTxSignature")
        return { "meta" => { "err" => nil }, "slot" => 1, "transaction" => {} }
      end
      super
    end
  end

  Solana::Client.prepend(stub)
end
