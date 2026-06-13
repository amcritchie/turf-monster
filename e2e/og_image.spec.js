const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");
const path = require("path");

const OG_IMAGE = path.join(__dirname, "..", "test", "fixtures", "files", "banner_wide.png");

// Admin link-preview (og:image) uploader on /admin/dashboard (the shared
// admin/shared/_og_image_uploader partial). Same crop-photo flow as the contest
// banner: "Edit image" opens the modal, the file drops in, "Crop & Save" saves
// immediately (update_link_preview_image) then toasts + refreshes the preview
// via Turbo Stream. In test the image lands on the Disk service
// (OgImageAttachable::PUBLIC_OG_SERVICE = :test) — no S3.
test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Admin link-preview (og:image) uploader", () => {
  test("admin crops + saves the default og:image and the preview refreshes", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/dashboard");

    await page.getByRole("button", { name: "Edit image" }).click();
    await page.locator('input[type="file"][accept="image/*"]').setInputFiles(OG_IMAGE);
    await expect(page.locator(".cropper-container")).toBeVisible();

    // Crop & Save -> loading card -> success toast -> refreshed preview <img>.
    await page.getByRole("button", { name: /Crop.*Save/ }).click();
    await expect(page.getByText("Image updated")).toBeVisible();
    await expect(page.locator("#default-og-image-preview img")).toBeVisible();
  });
});
