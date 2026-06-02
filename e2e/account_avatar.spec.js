const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");
const path = require("path");

const IMG = path.join(__dirname, "..", "test", "fixtures", "files", "banner_wide.png");

// Avatar upload routes its save through the same window.submitFormWithProgress
// helper as the contest banner: a "saving" loading card shows while the upload
// is in flight. AccountsController#update REDIRECTS, so the card is opened
// dismissible — the reload's closeAllDismissible() clears it and the server
// flash toasts. The regression guard is that the card both appears AND clears
// (a non-dismissible card would survive the reload and stick on screen).
test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Account avatar upload", () => {
  test("shows the loading card while saving, then clears on reload", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/account");

    // Picking a file opens crop-photo straight to the cropper (imageUrl passed).
    await page.locator('input[type="file"][accept="image/*"]').first().setInputFiles(IMG);
    await expect(page.locator(".cropper-container")).toBeVisible();

    await page.getByRole("button", { name: /Crop.*Save/ }).click();

    await expect(page.getByText("Saving photo")).toBeVisible();    // loading card during upload
    await expect(page.getByText("Account updated")).toBeVisible(); // flash toast after reload
    await expect(page.getByText("Saving photo")).toBeHidden();     // card cleared (not stuck)
  });
});
