const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// ---------------------------------------------------------------------------
// Page navigation — verify key pages load without errors
// ---------------------------------------------------------------------------

test("teams page loads", async ({ page }) => {
  await page.goto("/teams");
  await expect(page.locator("body")).toBeVisible();
  // Should have some team content from seeds
  await expect(page.locator("body")).toContainText(/team/i);
});

test("games page loads", async ({ page }) => {
  await page.goto("/games");
  await expect(page.locator("body")).toBeVisible();
});

test("signin page loads with magic-link + wallet options", async ({ page }) => {
  await page.goto("/signin");
  await expect(page.locator('input[name="email"]')).toBeVisible();
  // Passwordless now — email magic link + Google + wallet hub, no password.
  await expect(page.locator('input[name="password"]')).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Email Link" })).toBeVisible();
  await expect(page.locator('button:has-text("Google")')).toBeVisible();
  await expect(page.locator('button:has-text("Solana")')).toBeVisible();
});

// Unified auth: /login + /signup are one create-or-login flow, so they both
// 301-redirect to the canonical /signin page.
test("legacy /login + /signup redirect to /signin", async ({ page }) => {
  await page.goto("/login");
  await expect(page).toHaveURL(/\/signin/);

  await page.goto("/signup");
  await expect(page).toHaveURL(/\/signin/);
  await expect(page.getByRole("button", { name: "Email Link" })).toBeVisible();
});

test("error logs page loads", async ({ page }) => {
  await page.goto("/error_logs");
  await expect(page.locator("body")).toBeVisible();
});

test("turf totals page loads", async ({ page }) => {
  await page.goto("/turf-totals-v1");
  await expect(page.locator("body")).toBeVisible();
});

test("gear sidebar reopens after browser back from signed-in routes", async ({ page, request }) => {
  await reseed(request);
  await loginAdmin(page);

  const routes = ["/contests", "/account", "/contests/my"];
  const triggers = [
    "button[data-gear-sidebar-trigger]",
    "button[data-username-display]",
    "button[data-profile-image-toggle]",
  ];

  for (const route of routes) {
    await page.goto(route);
    await page.waitForFunction(() => window.Alpine && Alpine.store("sidebars"));

    await page.locator("button[data-gear-sidebar-trigger]").first().click();
    await expect(page.locator("#gear-sidebar")).toBeVisible();

    const destination = route === "/account" ? "/contests" : "/account";
    await Promise.all([
      page.waitForURL(destination),
      page.locator(`#gear-sidebar a[href="${destination}"]`).first().click(),
    ]);
    await expect(page).toHaveURL(destination);

    await page.goBack();
    await expect(page).toHaveURL(route);
    await page.waitForFunction(() => window.Alpine && Alpine.store("sidebars"));

    for (const trigger of triggers) {
      await page.locator(trigger).first().click();
      await expect(page.locator("#gear-sidebar")).toBeVisible();
      await page.keyboard.press("Escape");
      await expect(page.locator("#gear-sidebar")).toBeHidden();
    }
  }
});
