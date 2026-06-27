const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

test.beforeEach(async ({ request }) => await reseed(request));

test.describe("World Cup knockout slates", () => {
  test("admin can target elimination-round slates from the contest generator", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/contests/generator");

    const roundOf32 = page.getByRole("row", { name: /World Cup 2026 Round of 32/ });
    await expect(roundOf32).toContainText("32 matchups available");
    await expect(page.getByRole("row", { name: /World Cup 2026 Final/ })).toContainText("2 matchups available");
  });
});
