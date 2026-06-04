const { test, expect } = require("@playwright/test");
const { reseed } = require("./helpers");

// Unified create-or-login magic link + the multi-wallet hub. The email round
// trip can't be clicked in a browser test, so we mint tokens through the
// dev-only /test/magic_link_token endpoint and navigate to the consume URL.
//
// The emailed link's GET is a scanner-safe interstitial that does NOT consume
// the token on the server; it AUTO-SUBMITS the consume form via JS on load, so a
// real browser signs in with no manual tap. So the browser flow is just:
// goto(url) -> the page auto-redirects off /magic_link, signed in.

test.beforeEach(async ({ request }) => await reseed(request));

test("magic link creates a new account and logs the visitor in", async ({ page }) => {
  const email = `ml-${Date.now().toString(36)}@example.com`;
  const resp = await page.request.post("/test/magic_link_token", { data: { email } });
  expect(resp.ok()).toBeTruthy();
  const { url } = await resp.json();

  // GET lands on the interstitial, which auto-submits the consume POST on load,
  // consumes the token, and lands off /magic_link — no manual click.
  await page.goto(url);
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
  // (no JS executed, so the auto-submit never fires) against the emailed URL.
  const prefetch = await page.request.get(url);
  expect(prefetch.ok()).toBeTruthy();

  // The human then opens the link for real — the token must still be live (the
  // prefetch GET must not have consumed it), so the auto-submit signs them in.
  await page.goto(url);
  await page.waitForURL((u) => !u.pathname.startsWith("/magic_link"));
  await page.goto("/account");
  await expect(page).toHaveURL(/\/account/);
});

test("an invalid magic-link token is rejected on confirm", async ({ page }) => {
  // The GET interstitial is inert and renders even for a garbage token; the
  // auto-submit then POSTs it, the consume rejects it, and we bounce to /signin.
  await page.goto("/magic_link/bogus.token.value");
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
