const { test, expect } = require("@playwright/test");
const { reseed } = require("./helpers");

test("NFL team totals page shows all cached weeks @smoke", async ({ page, request }) => {
  await reseed(request);

  await page.goto("/nfl/team-totals");
  await expect(page.getByRole("heading", { name: "NFL Team Totals" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Week 18" })).toBeVisible();
  await expect(page.locator("[data-total-card]").first()).toBeVisible();

  await page.getByRole("link", { name: "Week 18" }).click();
  await expect(page).toHaveURL(/week=18/);
  await expect(page.locator("[data-total-card]")).toHaveCount(16);
  await expect(page.locator("body")).toContainText("Highest team total");
});
