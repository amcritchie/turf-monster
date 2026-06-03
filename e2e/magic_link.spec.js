const { test, expect } = require("@playwright/test");
const { reseed } = require("./helpers");

// Unified create-or-login magic link + the multi-wallet hub. The email round
// trip can't be clicked in a browser test, so we mint tokens through the
// dev-only /test/magic_link_token endpoint and navigate to the consume URL.
//
// The emailed link's GET is a scanner-safe "Confirm sign-in" interstitial that
// does NOT consume the token — only the human's button press (a POST) burns it
// and signs in. So the browser flow is: goto(url) -> click "Sign in".

test.beforeEach(async ({ request }) => await reseed(request));

test("magic link creates a new account and logs the visitor in", async ({ page }) => {
  const email = `ml-${Date.now().toString(36)}@example.com`;
  const resp = await page.request.post("/test/magic_link_token", { data: { email } });
  expect(resp.ok()).toBeTruthy();
  const { url } = await resp.json();

  // GET lands on the inert "Confirm sign-in" interstitial (still on /magic_link).
  await page.goto(url);
  await expect(page).toHaveURL(/\/magic_link\//);
  await expect(page.locator("body")).toContainText(/confirm|sign in/i);

  // The human's click POSTs the token, consumes it, and lands off /magic_link.
  await page.locator('button:has-text("Sign in to Turf Monster")').click();
  await page.waitForURL((u) => !u.pathname.startsWith("/magic_link"));

  // Logged in → an auth-gated page stays put instead of bouncing to /signin.
  await page.goto("/account");
  await expect(page).toHaveURL(/\/account/);
});

test("a scanner prefetch GET does not burn the token; the human can still sign in", async ({ page }) => {
  const email = `ml-pf-${Date.now().toString(36)}@example.com`;
  const resp = await page.request.post("/test/magic_link_token", { data: { email } });
  const { url } = await resp.json();

  // Simulate an email link-scanner / Gmail-image-proxy pre-fetch: a bare GET
  // (no cookies carried into the human's context) against the emailed URL.
  const prefetch = await page.request.get(url);
  expect(prefetch.ok()).toBeTruthy();

  // The human then opens the link for real and clicks through — the token must
  // still be live (the prefetch GET must not have consumed it).
  await page.goto(url);
  await page.locator('button:has-text("Sign in to Turf Monster")').click();
  await page.waitForURL((u) => !u.pathname.startsWith("/magic_link"));
  await page.goto("/account");
  await expect(page).toHaveURL(/\/account/);
});

test("an invalid magic-link token is rejected on confirm", async ({ page }) => {
  // The GET interstitial is inert and renders even for a garbage token; the
  // rejection happens when the human submits (POST). Click through and assert.
  await page.goto("/magic_link/bogus.token.value");
  await page.locator('button:has-text("Sign in to Turf Monster")').click();
  await expect(page).toHaveURL(/\/signin/);
  await expect(page.locator("body")).toContainText(/invalid|expired/i);
});

test("the wallet hub offers install options when no wallet is present", async ({ page }) => {
  await page.goto("/signin");
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
  await page.goto("/signin");
  await page.waitForFunction(() => window.walletProvider && typeof window.walletProvider.available === "function");
  const names = await page.evaluate(() =>
    window.walletProvider.available().map((w) => (w.name || "").toLowerCase())
  );
  expect(names).not.toContain("keypair");
});
