const { test, expect } = require("@playwright/test");

// /teams is public. It lists every team with a four-color palette (🎨 primary /
// 🔤 secondary / ☀️ alt-light / 🌙 alt-dark) and a league filter. This guards
// the whole vertical: seeded colors → DB → view swatches → Alpine filter.
test.describe("Teams four-color palette", () => {
  test("shows the palette and filters to NFL @smoke", async ({ page }) => {
    await page.goto("/teams");

    // Legend documents the four roles.
    await expect(page.getByText("🎨 background")).toBeVisible();

    // Bills wear their four brand colors, each swatch tagged by role + hex.
    const bills = page.locator("a[data-team-card]", { hasText: "Buffalo Bills" });
    await expect(bills.locator('[title="🎨 #00338D"]')).toBeVisible();
    await expect(bills.locator('[title="🔤 #C60C30"]')).toBeVisible(); // red mascot text
    await expect(bills.locator('[title="☀️ #FFFFFF"]')).toBeVisible(); // white alt-light
    await expect(bills.locator('[title="🌙 #041E42"]')).toBeVisible(); // navy alt-dark

    // The NFL pill narrows the grid to the 32 NFL teams.
    await page.getByRole("button", { name: "NFL", exact: true }).click();
    await expect(page.locator('[data-team-card][data-league="fifa"]:visible')).toHaveCount(0);
    await expect(page.locator('[data-team-card][data-league="nfl"]:visible')).toHaveCount(32);
  });
});
