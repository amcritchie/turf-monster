const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");
const path = require("path");

const BANNER_WIDE = path.join(__dirname, "..", "test", "fixtures", "files", "banner_wide.png");

// Admin banner editor on the contest EDIT screen (PR #29). "Edit banner" opens
// the shared crop-photo modal (cropPhotoModal) in dropzone + dispatch mode: the
// modal picks the file (click / drag-drop), shows the cropper at 4:1, and
// "Crop & Save" saves immediately (update_banner) and refreshes the preview.
test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Contest banner editor (edit screen)", () => {
  test("admin frames + saves a banner via the shared crop modal", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/contests/world-cup-2026/edit");

    // Open the crop modal (starts in the dropzone state).
    await page.getByRole("button", { name: "Edit banner" }).click();

    // Pick a file inside the modal -> the cropper mounts.
    await page.locator('input[type="file"][accept="image/*"]').setInputFiles(BANNER_WIDE);
    await expect(page.locator(".cropper-container")).toBeVisible();

    // Crop & Save -> immediate save -> the preview refreshes, modal closes.
    await page.getByRole("button", { name: /Crop.*Save/ }).click();
    await expect(page.locator(".cropper-container")).toBeHidden();
    await expect(page.locator("#contest-banner-preview img")).toBeVisible();
  });

  test("the actions dropdown reaches the edit screen's banner control", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/contests/world-cup-2026");

    await page.getByRole("button", { name: "Contest actions" }).click();
    await page.getByRole("link", { name: "Edit Contest" }).click();

    await expect(page).toHaveURL(/\/edit$/);
    await expect(page.getByRole("button", { name: "Edit banner" })).toBeVisible();
  });
});
