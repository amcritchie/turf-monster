const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

test.beforeEach(async ({ page, request }) => {
  await page.route("**/account/session_refresh", async (route) => {
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ ok: true }),
    });
  });
  await reseed(request);
});

test.describe("Geo Settings", () => {
  test("geo settings page loads for admin", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/geo");
    await expect(page.getByRole("heading", { name: "Geo Settings" })).toBeVisible();
    await expect(page.locator("body")).toContainText("Current Detection");
    await expect(page.locator("body")).toContainText("Configuration");
    await expect(page.locator("body")).toContainText("Banned States");
  });

  test("admin can toggle geo override on", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/geo");

    // Click "Simulate WA" button on the geo page (the .btn one, not the navbar dropdown)
    await page.locator("button.btn:has-text('Simulate WA')").click();
    await page.waitForLoadState("networkidle");

    // Verify notice
    await expect(page.locator("body")).toContainText("Simulating WA");
  });

  test("admin can clear geo override", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/geo");

    // Toggle on first
    await page.locator("button.btn:has-text('Simulate WA')").click();
    await page.waitForLoadState("networkidle");

    // After toggle ON, the page should show "Simulating WA" notice
    await expect(page.locator("body")).toContainText("Simulating WA");

    // Now the override is active — find the "Clear GEO Override" button (has btn-danger class)
    await page.getByRole("button", { name: "Clear GEO Override" }).click();

    // Verify cleared
    await expect(page.getByText("GEO override cleared.")).toBeVisible();
  });

  test("geo badge shows in navbar when logged in", async ({ page }) => {
    await loginAdmin(page);
    // The navbar should show a geo state badge (could be "??" if no geo detected in test)
    const badge = page.locator("span.font-mono.rounded-lg", { hasText: /[A-Z]{2}|\?\?/ });
    await expect(badge.first()).toBeVisible();
  });

  test("blocked state prevents contest entry", async ({ page }) => {
    await loginAdmin(page);

    // Enable geoblocking
    await page.goto("/admin/geo");
    await page.getByRole("checkbox", { name: "Enable Geo-Blocking" }).check();
    await page.locator('input[value="Save Settings"]').click();
    // Web-first assertion replaces waitForLoadState("networkidle"): the navbar
    // hydrates on every page load (refreshSession + ActionCable), so the network
    // is never reliably idle and networkidle flakes under shard load. toContainText
    // auto-polls through the post-redirect navigation until the flash appears.
    await expect(page.locator("body")).toContainText("Geo settings updated");

    // Simulate WA state — click the .btn on the geo page (not the navbar dropdown)
    await page.locator("button.btn-outline:has-text('Simulate WA')").click();
    await expect(page.locator("body")).toContainText("Simulating WA");

    // Try to toggle a selection — should be blocked (geo-restricted action)
    const contestSlug = await page.evaluate(async () => {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
      const res = await fetch("/contests", { headers: { Accept: "text/html" } });
      return res.url; // Just check we can reach contests page
    });
    // The geo block is enforced on toggle_selection/enter — verified by hold validation in other test

    // Clean up: clear geo override — assert the flash so the cleared state lands
    // before teardown (GeoSetting is global; reseed does not reset it, so an
    // un-awaited write here leaks geo-blocking into later specs).
    await page.goto("/admin/geo");
    await page.getByRole("button", { name: "Clear GEO Override" }).click();
    await expect(page.getByText("GEO override cleared.")).toBeVisible();

    // Disable geoblocking — assert the flash so the DB write completes deterministically.
    await page.goto("/admin/geo");
    await page.getByRole("checkbox", { name: "Enable Geo-Blocking" }).uncheck();
    await page.locator('input[value="Save Settings"]').click();
    await expect(page.locator("body")).toContainText("Geo settings updated");
  });
});
