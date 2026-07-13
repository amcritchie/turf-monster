require "test_helper"
require "yaml"

# Pins the root cause of the model_page e2e flake (task fix-model-page-flake).
#
# The CI playwright job's test server must NEVER reach a live Solana RPC.
# Without an explicit SOLANA_RPC_URL, Solana::Client falls back to public
# devnet (https://api.devnet.solana.com), and every authenticated HTML request
# blocks on it: perform_solana_preload runs as a before_action for
# wallet-connected users, and the test env's :null_store cache disables the
# 60-second caches, so every request re-fires live RPCs. When public devnet
# throttles (peak hours: 429s + stalls against a 10s open / 30s read timeout),
# page renders degrade from milliseconds to 3-6s+ and the tightest post-click
# assertion window dies first — model_page.spec.js's toHaveURL(5s) failed with
# the URL stuck on /admin/dashboard while GET /models/contest/random starved
# (Actions run 29254091915, trace network log: status -1, never answered).
#
# The fix pins the playwright job to a black-hole loopback URL: nothing
# listens on port 9, connect fails instantly (Errno::ECONNREFUSED is not in
# the RPC client's retry set), and the app takes its designed nil-safe
# fallbacks. Browser-side RPC is mocked by e2e/rpc-mock.js; specs that truly
# need a chain are tagged @devnet and run by devnet-nightly.yml, not here.
class CiPlaywrightHermeticTest < ActiveSupport::TestCase
  WORKFLOW_PATH = Rails.root.join(".github/workflows/ci.yml")

  def playwright_job
    workflow = YAML.safe_load_file(WORKFLOW_PATH)
    workflow.fetch("jobs").fetch("playwright")
  end

  test "playwright job pins SOLANA_RPC_URL so the e2e server never reaches a live RPC" do
    rpc_url = playwright_job.fetch("env", {})["SOLANA_RPC_URL"]

    assert rpc_url.present?,
           "playwright job must set SOLANA_RPC_URL: without it the e2e test " \
           "server defaults to public devnet and every authenticated page " \
           "render blocks on live RPC — the model_page toHaveURL flake " \
           "(Actions run 29254091915). Point it at a black-hole loopback " \
           "port (e.g. http://127.0.0.1:9)."

    uri = URI.parse(rpc_url)
    assert_includes %w[localhost 127.0.0.1 ::1], uri.host,
                    "playwright job SOLANA_RPC_URL (#{rpc_url.inspect}) must " \
                    "stay on loopback — a non-local RPC reintroduces the " \
                    "time-of-day e2e flake"
  end
end
