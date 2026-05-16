const { setupPhantomMock, MOCK_PUBKEY_B58 } = require("./phantom-mock");
const { setupOnchainMocks, computeMockTransaction } = require("./rpc-mock");

/**
 * Log in via the login form.
 * Waits for the URL to navigate away from /login — handles either landing on /
 * or the redirect chain / → /c/:slug/lobby that ContestsController#world_cup
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

module.exports = {
  login,
  loginAdmin,
  loginViaPhantom,
  setupPhantomMock,
  MOCK_PUBKEY_B58,
  setupOnchainMocks,
  computeMockTransaction,
};
