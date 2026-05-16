const { test, expect } = require("@playwright/test");
const { login, loginAdmin } = require("./helpers");

test.describe("Wallet & Transactions", () => {
  test("wallet page loads with USDC balance", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/wallet");
    await expect(page.getByRole("heading", { name: "Wallet", exact: true })).toBeVisible();
    await expect(page.locator("body")).toContainText("USDC Balance");
    await expect(page.locator("body")).toContainText("Available to Play");
    // Balance should show a dollar amount (don't check exact value — tests share state)
    await expect(page.locator("body")).toContainText(/\$\d+\.\d{2}/);
  });

  test("wallet shows wallet address", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/wallet");
    await expect(page.locator("body")).toContainText("Wallet Address");
  });

  test("wallet shows faucet link", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/wallet");
    await expect(page.locator("body")).toContainText("Get USDC");
    await expect(page.locator('a:has-text("Faucet Page")')).toBeVisible();
  });
});

test.describe("Admin Transaction Log", () => {
  test("admin can view transaction log", async ({ page }) => {
    await loginAdmin(page);

    // Transaction log should have the pre-seeded faucet transaction
    await page.goto("/admin/transactions");
    await expect(page.getByRole("heading", { name: "Transaction Log" })).toBeVisible();
    await expect(page.locator("body")).toContainText("faucet");
  });

  test("admin transaction log detail page", async ({ page }) => {
    await loginAdmin(page);

    // Navigate to admin transactions and click first description link in the table
    await page.goto("/admin/transactions");
    await page.locator("table a").first().click();

    // Wait for navigation away from the index — the show view may need a cold
    // compile, which races the default 5s assertion timeout.
    await page.waitForURL(/\/admin\/transactions\/[^/]+$/);
    await expect(page.getByRole("heading", { name: "Transaction Detail" })).toBeVisible({ timeout: 10_000 });
    await expect(page.locator("body")).toContainText("$10.00");
  });

  test("admin can filter by type", async ({ page }) => {
    await loginAdmin(page);

    // Navigate to admin transactions and click a filter link (e.g. "faucet" in the type column)
    await page.goto("/admin/transactions");
    // Click the faucet type badge/link in the table (not the navbar link)
    await page.locator("table a:has-text('faucet')").first().click();

    // Should navigate to a filtered or detail page
    await expect(page.locator("body")).toContainText("faucet");
  });
});
