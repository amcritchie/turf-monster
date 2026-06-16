const { test, expect } = require("@playwright/test");
const { reseed, attestAge } = require("./helpers");

// Auth-modal UI flows driven through the REAL login form — the path the
// login() test backdoor skips, and exactly where the #30 x-data regression
// silently broke the "Check your inbox" modal (the whole component failed to
// parse, so nothing rendered). These tests would have caught that.
//
// NOT covered here: the resend 429 / "Too many requests" error path — the e2e
// server runs in test env with rack-attack disabled, so resends never throttle
// in tests. That path stays a known Playwright gap.
//
// reseed clears rack-attack counters + volatile state between tests (when run
// locally against the dev :3100 server, rack-attack IS on; CI's test-env server
// has it off — either way reseed keeps runs isolated).
test.beforeEach(async ({ request }) => await reseed(request));

test("requesting a magic link from the login form opens the Check your inbox modal", async ({ page }) => {
  await page.goto("/signin");
  await page.fill('input[name="email"]', `authmodal-${Date.now()}@example.com`);
  await attestAge(page);
  await page.getByRole("button", { name: "Email Link" }).click();

  // The auth modal's magic-link-sent step. (#30 broke this: a double-quote in
  // the x-data closed the attribute, so the modal rendered empty.)
  await expect(page.getByText("Check your inbox")).toBeVisible();
  await expect(page.locator('button:has-text("Resend link")')).toBeVisible();
});

test("resending swaps to the Link Resent confirmation and starts the cooldown", async ({ page }) => {
  await page.goto("/signin");
  await page.fill('input[name="email"]', `authmodal-resend-${Date.now()}@example.com`);
  await attestAge(page);
  await page.getByRole("button", { name: "Email Link" }).click();
  await expect(page.getByText("Check your inbox")).toBeVisible();

  await page.locator('button:has-text("Resend link")').click();

  // A successful resend swaps to the dedicated success step and disables the
  // link with a counting-down 60s cooldown.
  await expect(page.getByText("Link Resent!")).toBeVisible();
  await expect(page.getByText(/Resend available in \d+s/)).toBeVisible();
});

test("Solana button in standalone auth modal opens the wallet chooser", async ({ page }) => {
  await page.goto("/signin");

  await page.evaluate(() => {
    Alpine.store("modals").open("auth", {
      step: "credentials",
      submitting: null,
      formError: "",
      phantomError: "",
      googleError: "",
    });
  });

  const dialog = page.getByRole("dialog");
  await expect(dialog.getByRole("heading", { name: "Sign in" })).toBeVisible();

  await attestAge(page);
  await dialog.getByRole("button", { name: "Solana" }).click();

  await expect(dialog.getByRole("heading", { name: "Connect Wallet" })).toBeVisible();
  await expect(dialog.getByRole("link", { name: /Phantom Install/ })).toBeVisible();
});
