import assert from "node:assert/strict";

export async function runTextInputSmoke({ page, context }) {
  const readStatus = () => page.evaluate(() => window.__gpuiSmokeStatus());
  const waitForText = async (count, text) => {
    await page.waitForFunction(({ count, text }) => {
      const status = window.__gpuiSmokeStatus();
      return status.textCommitCount === count && status.lastCommittedText === text &&
        document.querySelector("#text-commit-count")?.textContent === String(count) &&
        document.querySelector("#committed-text")?.textContent === text;
    }, { count, text });
  };
  const settleBrowserInput = () => page.evaluate(() => new Promise((resolve) => setTimeout(resolve, 20)));
  await page.waitForFunction(() => typeof window.__gpuiTextInput === "function");
  await page.evaluate(() => window.__gpuiTextInput("stop"));
  assert.equal(await page.locator("#gpui-text-input").count(), 1);
  const initial = await readStatus();
  assert.equal(initial.capabilities.committedTextInput, true);
  assert.equal(initial.capabilities.textInputIme, false, "committed inserts do not advertise a complete IME/editor API");

  // The existing canvas keyboard/activation path keeps ownership while off.
  await page.locator("#gpui-viewport").focus();
  await page.keyboard.press("x");
  await page.waitForFunction(() => window.__gpuiSmokeStatus().lastKey === "Character");
  assert.equal((await readStatus()).textCommitCount, initial.textCommitCount);
  const legacy = page.getByRole("textbox", { name: "Legacy note text" });
  const legacyValue = await legacy.inputValue();
  await legacy.fill("A legacy edit stays in its existing owner.");
  assert.equal(await page.evaluate(() => document.activeElement?.getAttribute("aria-label")), "Legacy note text");
  assert.equal((await readStatus()).textCommitCount, initial.textCommitCount);

  await page.locator("#text-input-start").click();
  await page.waitForFunction(() => window.__gpuiTextInput("status").focused);
  assert.equal(await page.evaluate(() => document.activeElement?.id), "gpui-text-input");
  assert.equal((await readStatus()).hostInputOwner, "text-input");
  const beforeText = await readStatus();
  let count = beforeText.textCommitCount;
  await page.evaluate(() => {
    const textarea = document.querySelector("#gpui-text-input");
    window.__gpuiTextInputEvidence = [];
    for (const type of ["keydown", "input", "compositionstart", "compositionupdate", "compositionend"]) {
      textarea.addEventListener(type, (event) => window.__gpuiTextInputEvidence.push({
        type, trusted: event.isTrusted, inputType: event.inputType,
        composing: event.isComposing, data: event.data,
      }));
    }
  });
  await page.keyboard.type("Ab");
  count += 2;
  await waitForText(count, "b");
  assert.equal((await readStatus()).lastKey, beforeText.lastKey, "text callbacks do not synthesize portable key events");
  assert.equal((await readStatus()).clicks, beforeText.clicks, "typing cannot activate a previously focused canvas button");

  const unicode = "日本語 👩🏽‍💻 e\u0301 שלום العربية <literal>";
  await page.keyboard.insertText(unicode);
  count += 1;
  await waitForText(count, unicode);
  assert.equal(await page.locator("#gpui-text-input").inputValue(), "", "committed input is drained from the browser transport");

  const client = await context.newCDPSession(page);
  try {
    // Chromium dispatches this sequence through CDP, not through our DOM
    // fixtures. It marks compositionstart/update/input trusted, but its CDP
    // compositionend is untrusted even for an otherwise empty native textarea.
    // This path does not validate an OS IME UI.
    await client.send("Input.imeSetComposition", { text: "にほん", selectionStart: 3, selectionEnd: 3 });
    await client.send("Input.imeSetComposition", { text: "日本語", selectionStart: 3, selectionEnd: 3 });
    assert.equal((await readStatus()).textCommitCount, count, "composition updates never enter the portable model");
    assert.equal(await page.evaluate(() => window.__gpuiTextInput("status").composing), true);
    await client.send("Input.insertText", { text: "日本語" });
    count += 1;
    await waitForText(count, "日本語");
    await settleBrowserInput();
    assert.equal((await readStatus()).textCommitCount, count, "the final native composition commits exactly once");
    await client.send("Input.insertText", { text: "日本語" });
    count += 1;
    await waitForText(count, "日本語");

    await client.send("Input.imeSetComposition", { text: "キャンセル", selectionStart: 5, selectionEnd: 5 });
    await client.send("Input.imeSetComposition", { text: "", selectionStart: 0, selectionEnd: 0 });
    await settleBrowserInput();
    assert.equal((await readStatus()).textCommitCount, count, "CDP cancellation discards provisional text");
    assert.equal(await page.evaluate(() => window.__gpuiTextInput("status").composing), false);

    // Native focus loss must discard a composition, even when the browser
    // itself emits compositionend while processing the focus change.
    await client.send("Input.imeSetComposition", { text: "未確定", selectionStart: 3, selectionEnd: 3 });
    await legacy.focus();
    await settleBrowserInput();
    assert.equal((await readStatus()).textCommitCount, count, "blur does not commit provisional text");
    assert.equal(await page.evaluate(() => window.__gpuiTextInput("status").focused), false);
    await legacy.fill(legacyValue);
    await page.locator("#text-input-start").click();
  } finally {
    await client.detach();
  }

  const evidence = await page.evaluate(() => window.__gpuiTextInputEvidence);
  assert.ok(evidence.some((event) => event.type === "keydown" && event.trusted));
  assert.ok(evidence.some((event) => event.type === "input" && event.trusted && event.data === unicode));
  assert.ok(evidence.some((event) => event.type === "compositionstart" && event.trusted));
  assert.ok(evidence.some((event) => event.type === "input" && event.trusted &&
    event.inputType === "insertCompositionText" && event.composing && event.data === "日本語"));
  assert.ok(evidence.some((event) => event.type === "compositionend" && event.data === "日本語"),
    "CDP emits the exact composition end value; Chromium currently marks this event untrusted");

  // Chromium uses final-input-before-compositionend. Exercise the opposite
  // order explicitly, including a microtask between native-style callbacks.
  for (const inputType of ["insertText", "insertFromComposition", "insertCompositionText"]) {
    const text = `tail:${inputType} 漢字`;
    await page.evaluate(async ({ text, inputType }) => {
      const textarea = document.querySelector("#gpui-text-input");
      textarea.dispatchEvent(new CompositionEvent("compositionstart", { data: "" }));
      textarea.dispatchEvent(new CompositionEvent("compositionupdate", { data: "未確定" }));
      textarea.value = "未確定";
      textarea.dispatchEvent(new InputEvent("input", { inputType: "insertCompositionText", data: "未確定", isComposing: true }));
      textarea.dispatchEvent(new CompositionEvent("compositionend", { data: text }));
      await Promise.resolve();
      textarea.dispatchEvent(new InputEvent("beforeinput", { inputType, data: text, cancelable: true }));
      textarea.value = text;
      textarea.dispatchEvent(new InputEvent("input", { inputType, data: text }));
    }, { text, inputType });
    count += 1;
    await waitForText(count, text);
    await settleBrowserInput();
    assert.equal((await readStatus()).textCommitCount, count, inputType);
  }

  // Controlled lifecycle fixtures supplement the native CDP cancellation and
  // blur cases. Visibility is overridden because headless has no tab strip.
  for (const lifecycle of ["cancel", "blur", "hidden", "stop"]) {
    await page.evaluate((lifecycle) => {
      window.__gpuiTextInput("start");
      const textarea = document.querySelector("#gpui-text-input");
      textarea.dispatchEvent(new CompositionEvent("compositionstart", { data: "" }));
      textarea.value = "provisional";
      textarea.dispatchEvent(new InputEvent("input", { data: "provisional", inputType: "insertCompositionText", isComposing: true }));
      textarea.dispatchEvent(new CompositionEvent("compositionend", { data: lifecycle === "cancel" ? "" : "discard me" }));
      if (lifecycle === "hidden") {
        Object.defineProperty(document, "hidden", { configurable: true, value: true });
        Object.defineProperty(document, "visibilityState", { configurable: true, value: "hidden" });
        document.dispatchEvent(new Event("visibilitychange"));
      } else if (lifecycle !== "cancel") window.__gpuiTextInput(lifecycle);
      textarea.dispatchEvent(new InputEvent("input", { data: "provisional", inputType: "insertCompositionText", isComposing: true }));
    }, lifecycle);
    await settleBrowserInput();
    assert.equal((await readStatus()).textCommitCount, count, `${lifecycle} cannot enqueue a pending composition`);
    if (lifecycle === "hidden") {
      await page.evaluate(() => {
        delete document.hidden;
        delete document.visibilityState;
        document.dispatchEvent(new Event("visibilitychange"));
      });
    }
  }

  // A disposed textarea must not deliver late events into the replacement app.
  await page.evaluate(() => {
    window.__gpuiTextInput("start");
    const textarea = window.__gpuiOldTextInput = document.querySelector("#gpui-text-input");
    textarea.dispatchEvent(new CompositionEvent("compositionstart", { data: "" }));
    textarea.dispatchEvent(new CompositionEvent("compositionend", { data: "old generation" }));
    document.querySelector("#remount").click();
    textarea.dispatchEvent(new InputEvent("input", { data: "late old event", inputType: "insertText" }));
  });
  await page.waitForFunction(() => document.querySelector("#frame-state")?.textContent === "RUNNING" && window.__gpuiSmokeStatus().events >= 3);
  await settleBrowserInput();
  assert.equal((await readStatus()).textCommitCount, 0);
  assert.equal(await page.locator("#gpui-text-input").count(), 1);
  assert.equal(await page.evaluate(() => window.__gpuiOldTextInput.isConnected), false);
  await page.locator("#text-input-start").click();
  await page.keyboard.type("Z");
  await waitForText(1, "Z");
  await page.locator("#text-input-stop").click();
  assert.equal(await page.evaluate(() => window.__gpuiTextInput("status").active), false);
  await page.evaluate(() => {
    delete window.__gpuiOldTextInput;
    delete window.__gpuiTextInputEvidence;
  });
  console.log("Committed text smoke passed: trusted Chromium keyboard/Unicode input, CDP Japanese composition/commit/cancel, synthetic alternate event order, lifecycle cancellation, focus ownership, and fresh input after remount. Chromium CDP compositionend is untrusted; OS IME candidate UI and production editor semantics are not covered.");
}
