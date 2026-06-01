const { test, expect } = require("@playwright/test");
const { reseed } = require("./helpers");

// Unified create-or-login magic link + the multi-wallet hub. The email round
// trip can't be clicked in a browser test, so we mint tokens through the
// dev-only /test/magic_link_token endpoint and navigate to the consume URL.

test.beforeEach(async ({ request }) => await reseed(request));

test("magic link creates a new account and logs the visitor in", async ({ page }) => {
  const email = `ml-${Date.now().toString(36)}@example.com`;
  const resp = await page.request.post("/test/magic_link_token", { data: { email } });
  expect(resp.ok()).toBeTruthy();
  const { url } = await resp.json();

  await page.goto(url);
  await page.waitForURL((u) => !u.pathname.startsWith("/magic_link"));

  // Logged in → an auth-gated page stays put instead of bouncing to /login.
  await page.goto("/account");
  await expect(page).toHaveURL(/\/account/);
});

test("an invalid magic-link token is rejected", async ({ page }) => {
  await page.goto("/magic_link/bogus.token.value");
  await expect(page).toHaveURL(/\/login/);
  await expect(page.locator("body")).toContainText(/invalid|expired/i);
});

test("the wallet hub offers install options when no wallet is present", async ({ page }) => {
  await page.goto("/login");
  await page.locator('button:has-text("Solana")').click();
  // No injected wallet in headless Chromium → featured install links appear.
  // The hub (_wallet_connect) renders each uninstalled wallet as a link to its
  // download page — name + a separate "Install" label, NOT the literal text
  // "Install Phantom" — so match by the install URL.
  await expect(page.locator('a[href*="phantom.app"]')).toBeVisible();
  await expect(page.locator('a[href*="solflare.com"]')).toBeVisible();
});

test("the hub does not surface the keypair test provider", async ({ page }) => {
  // The Playwright keypair provider is for signing, never a user-pickable
  // wallet — available() must exclude it (returns [] in headless).
  await page.addInitScript(() => {
    window.__WALLET_KEYPAIR_SECRET = new Uint8Array(64);
  });
  await page.goto("/login");
  await page.waitForFunction(() => window.walletProvider && typeof window.walletProvider.available === "function");
  const names = await page.evaluate(() =>
    window.walletProvider.available().map((w) => (w.name || "").toLowerCase())
  );
  expect(names).not.toContain("keypair");
});
