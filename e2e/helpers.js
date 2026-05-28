const { setupPhantomMock, MOCK_PUBKEY_B58 } = require("./phantom-mock");
const { setupOnchainMocks, computeMockTransaction } = require("./rpc-mock");

/**
 * Log in via the login form.
 * Waits for the URL to navigate away from /login — handles either landing on /
 * or the redirect chain / → /contests/:slug that ContestsController#world_cup
 * does when at least one contest exists.
 */
async function login(page, email, password) {
  await page.goto("/login");
  await page.fill('input[name="email"]', email);
  await page.fill('input[name="password"]', password);
  await page.locator('form button.btn-primary[type="submit"]').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/login"));
}

/**
 * Log in as admin user (alex@mcritchie.studio).
 */
async function loginAdmin(page) {
  await login(page, "alex@mcritchie.studio", "password");
}

/**
 * Log in via Phantom wallet mock.
 * Requires setupPhantomMock(page) to have been called first.
 * Clicks "Connect Wallet" on the login page and waits for navigation away.
 */
async function loginViaPhantom(page) {
  await page.goto("/login");
  await page.locator('button:has-text("Connect Wallet")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/login"));
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
