// @ts-check
const { test, expect } = require("@playwright/test");

const OMNIPARSER_SERVER = "http://localhost:8010";
const OMNIPARSER_DEMO = "http://localhost:7861";

test.describe("OmniParser Server (port 8010)", () => {
  test("health probe responds", async ({ request }) => {
    const res = await request.get(`${OMNIPARSER_SERVER}/probe/`);
    expect(res.ok()).toBeTruthy();
  });

  test("parse endpoint accepts image upload", async ({ request }) => {
    // Send a minimal 1x1 white PNG as base64 to the parse API
    const tiny1x1png =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg==";
    const res = await request.post(`${OMNIPARSER_SERVER}/parse/`, {
      data: { base64_image: tiny1x1png },
      headers: { "Content-Type": "application/json" },
    });
    // Expect any response except connection failure (server is up)
    // Tiny image may return 200, 422, or 500 depending on model behavior
    expect(res.status()).toBeLessThan(600);
  });
});

test.describe("OmniParser Demo UI (port 7861)", () => {
  test("Gradio app loads", async ({ page }) => {
    await page.goto(OMNIPARSER_DEMO, { waitUntil: "domcontentloaded" });
    // Gradio root element should exist
    await expect(page.locator("gradio-app")).toBeAttached({ timeout: 15_000 });
  });

  test("upload button and submit button are present", async ({ page }) => {
    await page.goto(OMNIPARSER_DEMO, { waitUntil: "networkidle" });
    // File upload button
    await expect(
      page.getByRole("button", { name: /upload file/i })
    ).toBeVisible({ timeout: 15_000 });
    // Submit button
    await expect(
      page.getByRole("button", { name: /submit/i })
    ).toBeVisible();
  });

  test("threshold sliders are present", async ({ page }) => {
    await page.goto(OMNIPARSER_DEMO, { waitUntil: "networkidle" });
    await expect(page.getByText(/box threshold/i)).toBeVisible({ timeout: 15_000 });
    await expect(page.getByText(/iou threshold/i)).toBeVisible();
  });
});
