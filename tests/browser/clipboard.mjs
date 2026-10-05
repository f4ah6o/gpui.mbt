import assert from "node:assert/strict";

/// Exercise the real browser API through explicit visible Copy/Paste actions.
/// The caller owns a fresh Chromium context and a loaded browser demo page.
export async function runClipboardSmoke({ page, context }) {
  const origin = new URL(page.url()).origin;
  const value = page.locator("#clipboard-value");
  const copiedText = "gpui.mbt clipboard · 日本語 👩🏽‍💻 e\u0301\nsecond line";
  const pastedText = "Browser clipboard → portable host envelope · مرحبا 🌕";
  const permissions = ["clipboard-read", "clipboard-write"];
  assert.equal(await page.evaluate(() => window.isSecureContext), true, "clipboard smoke requires a secure localhost origin");
  const waitForSuccess = () => page.waitForFunction(() => document.querySelector("#clipboard-result")?.dataset.state === "success");
  try {
    await context.grantPermissions(permissions, { origin });
    await value.fill(copiedText);
    await page.locator("#clipboard-copy").click();
    await waitForSuccess();
    assert.equal(await page.evaluate(() => navigator.clipboard.readText()), copiedText, "Copy must write the exact Unicode text through the browser API");

    await page.evaluate((text) => navigator.clipboard.writeText(text), pastedText);
    await value.fill("replace me only after successful Paste");
    await page.locator("#clipboard-paste").click();
    await page.waitForFunction((text) => document.querySelector("#clipboard-value")?.value === text, pastedText);
    await waitForSuccess();

    // Clear the previous grants before installing an empty allowlist. Chromium
    // denies the omitted clipboard permissions instead of displaying a prompt.
    await context.clearPermissions();
    await context.grantPermissions([], { origin });
    const preservedText = "Permission denial must preserve this text.";
    await value.fill(preservedText);
    await page.locator("#clipboard-paste").click();
    await page.waitForFunction(() => document.querySelector("#clipboard-result")?.dataset.code === "permission_denied");
    assert.equal(await value.inputValue(), preservedText);
    assert.equal(await page.evaluate(() => window.__gpuiSmokeStatus().active), true, "clipboard denial keeps the logical application alive");

    // A later authorized operation must work on the same adapter and scope.
    await context.grantPermissions(permissions, { origin });
    await page.locator("#clipboard-paste").click();
    await page.waitForFunction((text) => document.querySelector("#clipboard-value")?.value === text, pastedText);
    await waitForSuccess();
  } finally {
    await context.clearPermissions();
  }
}
