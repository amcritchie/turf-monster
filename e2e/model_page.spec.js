const { test, expect } = require("@playwright/test");
const { loginAdmin } = require("./helpers");

// turf's model-page adoption: an admin opens the shared-engine model inspector
// from the admin dashboard "Model JSON" card and sees a Contest rendered by the
// engine (record JSON + copy/paste console command + random-sample jump).
test("admin opens a Contest model page from the dashboard", async ({ page }) => {
  await loginAdmin(page);

  await page.goto("/admin/dashboard");
  await page.getByRole("link", { name: /Model JSON/ }).click();

  await expect(page).toHaveURL(/\/models\/contest\/.+/);
  await expect(page.getByText("Rails console")).toBeVisible();
  await expect(page.locator("code")).toContainText("Contest.find_by(slug:");
  await expect(page.locator("pre")).toContainText('"slug"');
  await expect(page.getByRole("link", { name: /Random sample/ })).toBeVisible();
});
