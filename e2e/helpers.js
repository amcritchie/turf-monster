const { setupPhantomMock, MOCK_PUBKEY_B58 } = require("./phantom-mock");
const { setupOnchainMocks, computeMockTransaction } = require("./rpc-mock");

/**
 * Log in (or create the account) via the magic link.
 * Email auth is now a passwordless magic link, so there's no form to fill —
 * we mint a token through the dev-only /test/magic_link_token endpoint and
 * navigate to the consume URL (same browser context, so the session cookie
 * sticks). The `password` arg is ignored (kept for call-site compatibility).
 * Waits for the URL to leave /signin and /magic_link.
 */
async function login(page, email, _password) {
  const resp = await page.request.post("/test/magic_link_token", { data: { email } });
  if (!resp.ok()) {
    throw new Error(`magic_link_token failed: ${resp.status()} ${await resp.text()}`);
  }
  const { url } = await resp.json();
  await page.goto(url);
  await page.waitForURL(
    (u) => !u.pathname.startsWith("/signin") && !u.pathname.startsWith("/magic_link")
  );
}

/**
 * Log in as admin user (alex@mcritchie.studio).
 */
async function loginAdmin(page) {
  await login(page, "alex@mcritchie.studio", "password");
}

/**
 * Log in via Phantom wallet mock.
 * Requires setupPhantomMock(page) to have been called first (injects
 * window.phantom, which the legacy PhantomProvider surfaces in the hub).
 * Opens the multi-wallet hub, then picks the detected (mock) Phantom wallet.
 */
async function loginViaPhantom(page) {
  await page.goto("/signin");
  await page.locator('button:has-text("Solana")').click();
  // The hub reads walletProvider.available() at click time; wait for the
  // detected-wallet button to appear once the wallet_provider module loads.
  const wallet = page.locator('button:has-text("phantom")').first();
  await wallet.waitFor({ state: "visible" });
  await wallet.click();
  await page.waitForURL((url) => !url.pathname.startsWith("/signin"));
}

/**
 * Reset cross-spec pollution sources before a spec runs.
 *
 * Posts to POST /test/reseed (TestController#reseed), which clears:
 *   - rack-attack throttle counters (otherwise loginAdmin times out
 *     after a previous spec's repeated logins hit `login/email` 5/min)
 *   - entry-token Rails.cache keys (stale post-mint reads linger ~60s)
 *   - OmniAuth.config.mock_auth (leftover provider hashes from prior
 *     set_oauth_mock calls would sign in the wrong user)
 *
 * Call this in test.beforeEach for any spec that does ≥1 login per
 * test or touches token state — once-per-file (beforeAll) is NOT
 * enough; a single spec doing 6 admin logins (financial, geo,
 * admin-security) blows past `login/email`'s 5/min throttle mid-file.
 * The reseed POST is a few milliseconds — cheap to use defensively.
 */
async function reseed(request) {
  const response = await request.post("/test/reseed");
  if (!response.ok()) {
    throw new Error(`reseed failed: ${response.status()} ${await response.text()}`);
  }
  return await response.json();
}

module.exports = {
  login,
  loginAdmin,
  loginViaPhantom,
  reseed,
  setupPhantomMock,
  MOCK_PUBKEY_B58,
  setupOnchainMocks,
  computeMockTransaction,
};
