const { test, expect } = require("@playwright/test");
const { login, loginAdmin } = require("./helpers");

test.describe("Admin Security", () => {
  test("non-admin cannot access admin transactions", async ({ page }) => {
    await login(page, "mason@mcritchie.studio", "password");
    await page.goto("/admin/transactions");

    // Should be redirected away from /admin/ with "Not authorized" alert.
    // The actual landing URL is /contests/:slug (root_path → contests#world_cup redirect).
    await expect(page).not.toHaveURL(/\/admin\//);
    await expect(page.locator("body")).toContainText("Not authorized");
  });

  test("non-admin cannot access geo settings", async ({ page }) => {
    await login(page, "mason@mcritchie.studio", "password");
    await page.goto("/admin/geo");

    // Should be redirected away from /admin/ with "Not authorized" alert.
    await expect(page).not.toHaveURL(/\/admin\//);
    await expect(page.locator("body")).toContainText("Not authorized");
  });

  test("non-admin cannot POST add_funds", async ({ page }) => {
    await login(page, "mason@mcritchie.studio", "password");

    // Try to POST add_funds via fetch
    const result = await page.evaluate(async () => {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
      const response = await fetch("/add_funds", {
        method: "POST",
        headers: {
          "X-CSRF-Token": csrfToken,
          Accept: "text/html",
        },
        redirect: "follow",
      });
      return { url: response.url, status: response.status };
    });

    // Should have been redirected (302 → root)
    expect(result.url).toContain("/");
  });

  test("admin can access transaction log", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/transactions");

    // Should load fine
    await expect(page.getByRole("heading", { name: "Transaction Log" })).toBeVisible();
  });

  test("admin can access geo settings", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/geo");

    // Should load fine
    await expect(page.getByRole("heading", { name: "Geo Settings" })).toBeVisible();
  });
});
