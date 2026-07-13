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
# vars.DEVNET_NIGHTLY_ENABLED == 'true'; every scheduled run has completed
# `skipped`; it has never run). This pin is NOT justified by coverage living
# elsewhere — it lives nowhere.
#
# It costs no coverage either, but for a CONTINGENT reason. After the
# async-navbar-balance change the preload fires exactly ONE server-side on-chain
# RPC for a wallet-connected user: Solana::Vault#list_entry_tokens
# (application_controller.rb:617) → getProgramAccounts(dataSize:124,
# memcmp@8=wallet) (vault.rb:1771-1786). Run against devnet for the e2e wallet
# (MOCK_PUBKEY_B58, 6ASf…pGWt) it returns [] — and NOT vacuously: the same
# program holds 72 entry-token accounts today, none owned by the mock wallet. So
# the count was 0 before this pin and rescues to 0 after it. Mint an entry token
# to that wallet on devnet and this premise EXPIRES.
#
# Do NOT restate this as "the e2e wallet has no devnet state" — it does: 6ASf…
# pGWt holds ~86 SOL on devnet in a real program-owned account. The claim holds
# only because the preload no longer reads balances (application_controller.rb
# :605-614). Browser-side RPC is mocked in e2e/rpc-mock.js.
class CiPlaywrightHermeticTest < ActiveSupport::TestCase
  WORKFLOW_PATH = Rails.root.join(".github/workflows/ci.yml")

  LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

  # The discard port: reserved by RFC 863 and closed everywhere, so connect is
  # REFUSED instantly. Asserted exactly rather than denylisting known-listening
  # ports — a denylist misses whatever happens to listen next (postgres 5432 and
  # redis 6379 both listen in this job) and rots the moment the e2e server moves
  # off 3100. Any port that ANSWERS is disqualifying: the RPC client would POST
  # JSON-RPC, get something back, and pay a real round trip before failing.
  BLACK_HOLE_PORT = 9

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
    # connection is refused instantly instead of being answered by something.
    assert_equal BLACK_HOLE_PORT, uri.port,
                 "playwright job SOLANA_RPC_URL (#{rpc_url.inspect}) must use the " \
                 "discard port #{BLACK_HOLE_PORT} — the only port guaranteed closed. " \
                 "Any port that ANSWERS (the e2e server on 3100, postgres 5432, " \
                 "redis 6379) is not a black hole: the RPC client would POST " \
                 "JSON-RPC, pay a real round trip, and fail slowly instead of " \
                 "being refused instantly."
  end
end
