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
# The fix pins the playwright job to a black-hole loopback URL on a closed
# port: connect fails instantly (Errno::ECONNREFUSED is not in the RPC
# client's retry set), and the app takes its designed nil-safe fallbacks.
#
# COVERAGE, STATED HONESTLY: server-side on-chain paths are NOT exercised by
# any e2e that runs today. CI excludes the @devnet specs (--grep-invert), and
# devnet-nightly.yml — the workflow that would run them — is DISABLED (gated on
# vars.DEVNET_NIGHTLY_ENABLED == 'true'; every scheduled run since 2026-06-14
# completed `skipped`, 30/30). This pin is NOT justified by coverage living
# elsewhere — it lives nowhere. It costs no coverage either: the e2e wallet is
# MOCK_PUBKEY_B58, a fabricated pubkey with no devnet state, so those RPCs
# already returned empty/zero. Browser-side RPC is mocked in e2e/rpc-mock.js.
class CiPlaywrightHermeticTest < ActiveSupport::TestCase
  WORKFLOW_PATH = Rails.root.join(".github/workflows/ci.yml")

  LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

  # Ports the app itself serves in a local/CI context. Aiming the RPC client at
  # one of these is NOT a black hole — the app would POST JSON-RPC to a Rails
  # server, get HTML back, and raise JSON::ParserError after a real round trip
  # (degraded and slower, not instant). 9 (discard) is the intended value; 3100
  # is the e2e server, 3000/3104 are dev/worktree stacks.
  APP_PORTS = [3000, 3100, 3104].freeze

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

    assert_includes LOOPBACK_HOSTS, uri.host,
                    "playwright job SOLANA_RPC_URL (#{rpc_url.inspect}) must " \
                    "stay on loopback — a non-local RPC reintroduces the " \
                    "time-of-day e2e flake"

    # Loopback alone is not enough: the URL must point at a CLOSED port, so the
    # connection is refused instantly instead of being answered by our own app.
    assert_not_includes APP_PORTS, uri.port,
                        "playwright job SOLANA_RPC_URL (#{rpc_url.inspect}) is " \
                        "aimed at a port the app itself serves — the RPC client " \
                        "would POST JSON-RPC to Rails, get HTML, and raise " \
                        "JSON::ParserError after a real round trip. Point it at a " \
                        "closed port (9, the discard port) so connect is refused " \
                        "instantly."
  end
end
