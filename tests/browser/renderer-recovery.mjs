import assert from "node:assert/strict";

// Chromium exercises the real Canvas2D paint path, but the context lifecycle
// events and acquisition failures below are injected deterministically. This
// does not claim to force, or qualify, an operating-system/GPU device reset.
export async function runRendererRecoverySmoke({ page, context }) {
  const ready = () => page.waitForFunction(() => {
    const renderer = window.__gpuiSmokeStatus?.().renderer;
    return renderer?.state === "ready" && !renderer.framePending
      && document.querySelector("#diagnostic")?.hidden;
  }, null, { polling: 20 });
  const read = () => page.evaluate(() => window.__gpuiSmokeStatus());
  const record = () => page.evaluate(() => window.__gpuiRecoveryFixture.record());
  const cdp = await context.newCDPSession(page);
  const metrics = await page.evaluate(() => ({
    width: window.innerWidth,
    height: window.innerHeight,
    deviceScaleFactor: window.devicePixelRatio,
    mobile: false,
  }));

  await page.getByRole("button", { name: "Remount viewport" }).click();
  await ready();
  await page.evaluate(() => {
    const canvas = document.querySelector("#gpui-viewport");
    const fixture = window.__gpuiRecoveryFixture = {
      canvas,
      context: canvas.getContext("2d"),
      cleanups: [],
      patch(object, property, value) {
        const descriptor = Object.getOwnPropertyDescriptor(object, property);
        Object.defineProperty(object, property, { configurable: true, value });
        const undo = () => {
          if (descriptor) Object.defineProperty(object, property, descriptor);
          else delete object[property];
        };
        this.cleanups.push(undo);
        return undo;
      },
      record() {
        return {
          status: window.__gpuiSmokeStatus(),
          diagnosticVisible: !document.querySelector("#diagnostic").hidden,
          diagnosticCode: document.querySelector("#diagnostic-code").textContent,
          sameCanvas: document.querySelector("#gpui-viewport") === this.canvas,
        };
      },
      pixels() {
        return [
          [3, 3],
          [Math.floor(this.canvas.width / 2), Math.floor(this.canvas.height / 2)],
        ].map(([x, y]) => Array.from(this.context.getImageData(x, y, 1, 1).data));
      },
    };
    fixture.canvas.focus();
    window.__gpuiDirectCounter(4);
  });

  try {
    await ready();
    await page.waitForTimeout(80);
    const before = await record();
    const paintedPixels = await page.evaluate(() => window.__gpuiRecoveryFixture.pixels());
    assert.ok(paintedPixels.some((pixel) => pixel.slice(0, 3).some((channel) => channel > 0)));
    assert.equal(before.status.capabilityValue, 4);

    const loss = await page.evaluate(() => {
      const fixture = window.__gpuiRecoveryFixture;
      // Schedule work immediately before loss to prove that it is cancelled.
      fixture.canvas.dispatchEvent(new FocusEvent("focus"));
      const frameWasPending = window.__gpuiSmokeStatus().renderer.framePending;
      const event = new Event("contextlost", { cancelable: true });
      fixture.canvas.dispatchEvent(event);
      const duplicate = new Event("contextlost", { cancelable: true });
      fixture.canvas.dispatchEvent(duplicate);
      fixture.context.setTransform(1, 0, 0, 1, 0, 0);
      fixture.context.clearRect(0, 0, fixture.canvas.width, fixture.canvas.height);
      const bounds = fixture.canvas.getBoundingClientRect();
      const pointer = {
        bubbles: true, pointerId: 83, pointerType: "mouse", isPrimary: true,
        clientX: bounds.left + 120, clientY: bounds.top + 238, button: 0,
      };
      fixture.canvas.dispatchEvent(new PointerEvent("pointermove", pointer));
      fixture.canvas.dispatchEvent(new PointerEvent("pointerdown", { ...pointer, buttons: 1 }));
      fixture.canvas.dispatchEvent(new PointerEvent("pointerup", { ...pointer, buttons: 0 }));
      fixture.canvas.dispatchEvent(new WheelEvent("wheel", { ...pointer, deltaY: 80, cancelable: true }));
      for (const key of ["Tab", "Enter", "ArrowRight"]) {
        fixture.canvas.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true }));
        fixture.canvas.dispatchEvent(new KeyboardEvent("keyup", { key, bubbles: true }));
      }
      const semantic = document.querySelector("#gpui-accessibility-node-4");
      semantic.dispatchEvent(new FocusEvent("focus"));
      semantic.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
      semantic.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", bubbles: true }));
      window.dispatchEvent(new Event("resize"));
      return {
        ...fixture.record(), frameWasPending,
        prevented: event.defaultPrevented,
        duplicatePrevented: duplicate.defaultPrevented,
        pixels: fixture.pixels(),
      };
    });
    assert.equal(loss.frameWasPending, true);
    assert.equal(loss.prevented, false, "Canvas2D contextlost must remain uncanceled to allow browser restoration");
    assert.equal(loss.duplicatePrevented, false);
    assert.equal(loss.status.renderer.state, "lost");
    assert.equal(loss.status.renderer.framePending, false);
    assert.equal(loss.status.renderer.lossCount, before.status.renderer.lossCount + 1, "duplicate loss coalesces");
    assert.equal(loss.status.renderer.completedFrames, before.status.renderer.completedFrames);
    assert.equal(loss.diagnosticVisible, true);
    assert.match(loss.diagnosticCode, /^surface_lost/);
    assert.ok(loss.pixels.every((pixel) => pixel.slice(0, 3).every((channel) => channel === 0)));
    for (const key of ["events", "clicks", "focus", "lastKey", "scrollY", "capabilityValue"]) {
      assert.equal(loss.status[key], before.status[key], `${key} is unchanged by input during loss`);
    }
    await page.waitForTimeout(120);
    assert.deepEqual((await read()).renderer, loss.status.renderer, "lost canvas has no retry/frame loop");
    assert.equal(await page.evaluate(() => window.__gpuiDirectCounter(3)), 7, "the preserved app can still accept a direct API mutation");
    assert.equal((await read()).renderer.framePending, false);

    const pending = await page.evaluate(() => {
      const fixture = window.__gpuiRecoveryFixture;
      fixture.canvas.dispatchEvent(new Event("contextrestored"));
      const once = fixture.record();
      fixture.canvas.dispatchEvent(new Event("contextrestored"));
      return { once, twice: fixture.record() };
    });
    assert.equal(pending.once.status.renderer.state, "restoring");
    assert.equal(pending.once.status.renderer.framePending, true);
    assert.equal(pending.once.diagnosticVisible, true, "loss diagnostic stays visible until a frame succeeds");
    assert.deepEqual(pending.twice, pending.once, "duplicate restoration schedules only one frame");
    await ready();
    const recovered = await record();
    assert.equal(recovered.sameCanvas, true, "recovery retains the canvas and logical app");
    assert.equal(recovered.status.renderer.generation, before.status.renderer.generation);
    assert.equal(recovered.status.renderer.recoveries, before.status.renderer.recoveries + 1);
    assert.equal(recovered.status.renderer.completedFrames, before.status.renderer.completedFrames + 1);
    assert.equal(recovered.status.capabilityValue, 7);
    assert.equal(await page.evaluate(() => window.__gpuiReadCounter()), 7);
    assert.equal(recovered.diagnosticVisible, false);
    for (const key of ["clicks", "focus", "lastKey", "scrollY"]) {
      assert.equal(recovered.status[key], before.status[key], `ignored ${key} input is not replayed after recovery`);
    }
    assert.deepEqual(await page.evaluate(() => window.__gpuiRecoveryFixture.pixels()), paintedPixels, "the lost surface is repainted from the retained snapshot state");
    await page.waitForTimeout(100);
    assert.deepEqual((await read()).renderer, recovered.status.renderer, "recovered canvas returns to idle");

    // null, throwing, and still-lost context results are each bounded failures.
    const beforeFailures = (await read()).renderer;
    await page.evaluate(() => window.__gpuiRecoveryFixture.canvas.dispatchEvent(new Event("contextlost", { cancelable: true })));
    for (const mode of ["null", "throws", "still-lost"]) {
      const failure = await page.evaluate((kind) => {
        const fixture = window.__gpuiRecoveryFixture;
        const undo = kind === "still-lost"
          ? fixture.patch(fixture.context, "isContextLost", () => true)
          : fixture.patch(fixture.canvas, "getContext", () => {
              if (kind === "throws") throw new Error("injected context acquisition failure");
              return null;
            });
        fixture.canvas.dispatchEvent(new Event("contextrestored"));
        undo();
        return fixture.record();
      }, mode);
      assert.equal(failure.status.renderer.state, "lost", `${mode} acquisition cannot report recovery`);
      assert.equal(failure.status.renderer.framePending, false);
      assert.equal(failure.status.renderer.completedFrames, beforeFailures.completedFrames);
      assert.equal(failure.status.renderer.recoveries, beforeFailures.recoveries);
      assert.equal(failure.status.capabilityValue, 7);
      assert.match(failure.diagnosticCode, /^surface_lost/);
      await page.waitForTimeout(80);
      assert.deepEqual((await read()).renderer, failure.status.renderer, `${mode} failure does not retry itself`);
    }
    assert.equal((await read()).renderer.restoreAttempts, beforeFailures.restoreAttempts + 3);
    await page.evaluate(() => window.__gpuiRecoveryFixture.canvas.dispatchEvent(new Event("contextrestored")));
    await ready();
    assert.equal((await read()).renderer.recoveries, beforeFailures.recoveries + 1);

    // A context becoming lost again before the first paint must not clear the
    // diagnostic or let another rAF automatically retry the failed restoration.
    const beforePaintFailure = (await read()).renderer;
    await page.evaluate(() => {
      const fixture = window.__gpuiRecoveryFixture;
      fixture.canvas.dispatchEvent(new Event("contextlost", { cancelable: true }));
      fixture.canvas.dispatchEvent(new Event("contextrestored"));
      fixture.undoContextLost = fixture.patch(fixture.context, "isContextLost", () => true);
    });
    await page.waitForFunction(() => window.__gpuiSmokeStatus().renderer.state === "lost", null, { polling: 20 });
    const failedPaint = await record();
    assert.match(failedPaint.diagnosticCode, /^surface_lost/);
    assert.equal(failedPaint.diagnosticVisible, true);
    assert.equal(failedPaint.status.renderer.completedFrames, beforePaintFailure.completedFrames);
    assert.equal(failedPaint.status.renderer.recoveries, beforePaintFailure.recoveries);
    await page.waitForTimeout(100);
    assert.deepEqual((await read()).renderer, failedPaint.status.renderer);
    await page.evaluate(() => {
      const fixture = window.__gpuiRecoveryFixture;
      fixture.undoContextLost();
      fixture.canvas.dispatchEvent(new Event("contextrestored"));
    });
    await ready();

    // An unrelated renderer callback exception retains its distinct diagnostic.
    await page.evaluate(() => {
      const fixture = window.__gpuiRecoveryFixture;
      fixture.undoPaint = fixture.patch(fixture.context, "fillRect", () => {
        throw new Error("injected ordinary paint callback failure");
      });
      fixture.canvas.dispatchEvent(new FocusEvent("focus"));
    });
    await page.waitForFunction(() => document.querySelector("#diagnostic-code").textContent.startsWith("callback_failure"), null, { polling: 20 });
    assert.equal((await read()).renderer.state, "ready", "an ordinary callback exception is not a context loss");
    await page.evaluate(() => {
      window.__gpuiRecoveryFixture.undoPaint();
      window.__gpuiRecoveryFixture.canvas.dispatchEvent(new FocusEvent("focus"));
    });
    await ready();

    // Restoration can wait for a frame after contextrestored has fired. Input
    // remains blocked during that wait, so a DOM focus move must be reconciled
    // immediately before the first restored frame drains the app's events.
    await page.evaluate(() => window.__gpuiRecoveryFixture.canvas.focus());
    await ready();
    for (const focusCase of [
      { selector: "#legacy-island textarea", focused: false, owner: "legacy-island" },
      { selector: "#gpui-viewport", focused: true, owner: "framework" },
    ]) {
      const beforeFocusMove = await read();
      assert.equal(beforeFocusMove.focused, !focusCase.focused);
      const waitingForFocus = await page.evaluate(({ selector }) => {
        const fixture = window.__gpuiRecoveryFixture;
        fixture.canvas.dispatchEvent(new Event("contextlost", { cancelable: true }));
        const request = window.requestAnimationFrame.bind(window);
        const undoRequest = fixture.patch(window, "requestAnimationFrame", (callback) => {
          fixture.heldRestorationFrame = callback;
          return request(() => {});
        });
        fixture.canvas.dispatchEvent(new Event("contextrestored"));
        undoRequest();
        const destination = document.querySelector(selector);
        destination.focus();
        return { ...fixture.record(), destinationFocused: document.activeElement === destination };
      }, focusCase);
      assert.equal(waitingForFocus.destinationFocused, true);
      assert.equal(waitingForFocus.status.renderer.state, "restoring");
      assert.equal(waitingForFocus.status.renderer.framePending, true);
      assert.equal(waitingForFocus.status.focused, beforeFocusMove.focused, "focus callbacks are still blocked before recovery completes");
      assert.equal(waitingForFocus.status.hostInputOwner, focusCase.owner);
      await page.waitForTimeout(40);
      assert.equal((await read()).renderer.completedFrames, beforeFocusMove.renderer.completedFrames);
      await page.evaluate(() => {
        const fixture = window.__gpuiRecoveryFixture;
        fixture.heldRestorationFrame(performance.now());
        fixture.heldRestorationFrame = null;
      });
      await ready();
      const afterFocusMove = await read();
      assert.equal(afterFocusMove.focused, focusCase.focused, "the first restored frame uses the current DOM focus");
      assert.equal(afterFocusMove.hostInputOwner, focusCase.owner);
      assert.equal(afterFocusMove.renderer.completedFrames, beforeFocusMove.renderer.completedFrames + 1);
      assert.equal(afterFocusMove.renderer.generation, beforeFocusMove.renderer.generation);
      assert.equal(afterFocusMove.capabilityValue, 7);
    }

    // A focused ARIA proxy carries a semantic target as well as focus ownership.
    // Reconcile both before Enter can reach a different retained app target.
    await page.locator("#gpui-accessibility-node-4").focus();
    await ready();
    assert.equal((await read()).focus, 4);
    const semanticWait = await page.evaluate(() => {
      const fixture = window.__gpuiRecoveryFixture;
      fixture.canvas.dispatchEvent(new Event("contextlost", { cancelable: true }));
      const request = window.requestAnimationFrame.bind(window);
      const undoRequest = fixture.patch(window, "requestAnimationFrame", (callback) => {
        fixture.heldRestorationFrame = callback;
        return request(() => {});
      });
      fixture.canvas.dispatchEvent(new Event("contextrestored"));
      undoRequest();
      document.querySelector("#gpui-accessibility-node-7").focus();
      return fixture.record();
    });
    assert.equal(semanticWait.status.focus, 4, "semantic callbacks stay queued out during loss");
    assert.equal(semanticWait.status.renderer.state, "restoring");
    await page.evaluate(() => {
      const fixture = window.__gpuiRecoveryFixture;
      fixture.heldRestorationFrame(performance.now());
      fixture.heldRestorationFrame = null;
    });
    await ready();
    const semanticReady = await read();
    assert.equal(semanticReady.focus, 7, "the restored model matches the focused semantic proxy");
    assert.equal(semanticReady.focused, true);
    assert.equal(await page.evaluate(() => document.activeElement.id), "gpui-accessibility-node-7");
    await page.keyboard.press("Enter");
    await ready();
    assert.equal((await read()).clicks, semanticReady.clicks + 1);
    assert.equal((await read()).capabilityValue, semanticReady.capabilityValue, "Enter on node 7 cannot activate node 4's counter");

    // The normal proxy-to-legacy focusout clears the semantic target. Losing
    // that lifecycle transition must not leave an invisible action selected.
    await page.locator("#gpui-accessibility-node-4").focus();
    await ready();
    const beforeSemanticClear = await read();
    assert.equal(beforeSemanticClear.focus, 4);
    await page.evaluate(() => {
      const fixture = window.__gpuiRecoveryFixture;
      fixture.canvas.dispatchEvent(new Event("contextlost", { cancelable: true }));
      document.querySelector("#legacy-island textarea").focus();
    });
    assert.equal((await read()).focus, 4, "semantic clearing waits for the restored drain");
    await page.evaluate(() => window.__gpuiRecoveryFixture.canvas.dispatchEvent(new Event("contextrestored")));
    await ready();
    const afterSemanticClear = await read();
    const clearedCurrent = await page.locator("#gpui-accessibility-node-4").getAttribute("aria-current");
    await page.locator("#return-framework").click();
    await ready();
    await page.keyboard.press("Enter");
    await ready();
    const afterCanvasReturn = await read();
    assert.deepEqual({
      focus: afterSemanticClear.focus,
      ariaCurrent: clearedCurrent,
      counterAfterEnter: afterCanvasReturn.capabilityValue,
      activationsAfterEnter: afterCanvasReturn.clicks,
    }, {
      focus: null,
      ariaCurrent: "false",
      counterAfterEnter: beforeSemanticClear.capabilityValue,
      activationsAfterEnter: beforeSemanticClear.clicks,
    }, "loss → legacy → restore → canvas → Enter cannot activate a stale semantic target");
    assert.equal(afterSemanticClear.focused, false);
    assert.equal(afterSemanticClear.hostInputOwner, "legacy-island");
    assert.equal(afterCanvasReturn.focused, true);
    assert.equal(afterCanvasReturn.hostInputOwner, "framework");

    // Canvas focus normally retains its logical selection. Recovery must not
    // clear every selected target merely because no ARIA proxy is active.
    await page.locator("#gpui-accessibility-node-4").focus();
    await ready();
    await page.locator("#gpui-viewport").focus();
    await ready();
    await page.evaluate(() => {
      const fixture = window.__gpuiRecoveryFixture;
      fixture.canvas.dispatchEvent(new Event("contextlost", { cancelable: true }));
      fixture.canvas.dispatchEvent(new Event("contextrestored"));
    });
    await ready();
    assert.equal((await read()).focus, 4, "ordinary canvas recovery preserves the intentionally selected target");
    assert.equal(await page.locator("#gpui-accessibility-node-4").getAttribute("aria-current"), "true");

    // Re-entering the canvas before presentation retains the latest semantic
    // lifecycle intent: clear after visiting legacy, or select a newer proxy.
    for (const focusIntent of [null, 7]) {
      await page.locator("#gpui-accessibility-node-4").focus();
      await ready();
      const beforeIntent = await read();
      const intentWait = await page.evaluate((target) => {
        const fixture = window.__gpuiRecoveryFixture;
        fixture.canvas.dispatchEvent(new Event("contextlost", { cancelable: true }));
        document.querySelector("#legacy-island textarea").focus();
        if (target === null) {
          const undoContext = fixture.patch(fixture.canvas, "getContext", () => null);
          fixture.canvas.dispatchEvent(new Event("contextrestored"));
          undoContext();
        }
        const request = window.requestAnimationFrame.bind(window);
        const undoRequest = fixture.patch(window, "requestAnimationFrame", (callback) => {
          fixture.heldRestorationFrame = callback;
          return request(() => {});
        });
        fixture.canvas.dispatchEvent(new Event("contextrestored"));
        undoRequest();
        if (target !== null) document.querySelector(`#gpui-accessibility-node-${target}`).focus();
        fixture.canvas.focus();
        return fixture.record();
      }, focusIntent);
      assert.equal(intentWait.status.focus, 4);
      assert.equal(intentWait.status.renderer.state, "restoring");
      assert.equal(intentWait.status.hostInputOwner, "framework");
      await page.evaluate(() => {
        const fixture = window.__gpuiRecoveryFixture;
        fixture.heldRestorationFrame(performance.now());
        fixture.heldRestorationFrame = null;
      });
      await ready();
      const afterIntent = await read();
      assert.equal(afterIntent.focus, focusIntent, "the latest semantic intent survives returning to canvas before paint");
      assert.equal(afterIntent.focused, true);
      assert.equal(afterIntent.capabilityValue, beforeIntent.capabilityValue);
      assert.equal(afterIntent.renderer.completedFrames, beforeIntent.renderer.completedFrames + 1);
      assert.equal(await page.locator("#gpui-accessibility-node-4").getAttribute("aria-current"), "false");
      assert.equal(await page.locator("#gpui-accessibility-node-7").getAttribute("aria-current"), String(focusIntent === 7));
    }

    const beforeHidden = (await read()).renderer;
    const hidden = await page.evaluate(() => {
      const fixture = window.__gpuiRecoveryFixture;
      fixture.undoHidden = fixture.patch(document, "hidden", true);
      fixture.undoVisibility = fixture.patch(document, "visibilityState", "hidden");
      document.dispatchEvent(new Event("visibilitychange"));
      fixture.canvas.dispatchEvent(new Event("contextlost", { cancelable: true }));
      fixture.canvas.dispatchEvent(new Event("contextrestored"));
      window.__gpuiDirectCounter(2);
      fixture.canvas.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", bubbles: true }));
      return fixture.record();
    });
    assert.equal(hidden.status.renderer.state, "restoring");
    assert.equal(hidden.status.renderer.framePending, false, "hidden restoration cannot schedule a paint");
    assert.equal(hidden.diagnosticVisible, true);
    assert.equal(hidden.status.capabilityValue, 9);
    await page.waitForTimeout(120);
    assert.deepEqual((await read()).renderer, hidden.status.renderer);
    await page.evaluate(() => {
      const fixture = window.__gpuiRecoveryFixture;
      fixture.undoHidden();
      fixture.undoVisibility();
      document.dispatchEvent(new Event("visibilitychange"));
    });
    await ready();
    const visible = await read();
    assert.equal(visible.visible, true);
    assert.equal(visible.capabilityValue, 9);
    assert.equal(visible.renderer.recoveries, beforeHidden.recoveries + 1);
    assert.equal(visible.renderer.completedFrames, beforeHidden.completedFrames + 1);

    // Use Chromium's real device-metrics boundary for a resize/DPR transition
    // while loss is pending. Observer callbacks must not overwrite surface_lost.
    await page.evaluate(() => window.__gpuiRecoveryFixture.canvas.dispatchEvent(new Event("contextlost", { cancelable: true })));
    const newScale = metrics.deviceScaleFactor === 2 ? 1.5 : 2;
    await cdp.send("Emulation.setDeviceMetricsOverride", {
      ...metrics,
      width: metrics.width + 96,
      height: metrics.height + 64,
      deviceScaleFactor: newScale,
    });
    await page.waitForFunction((scale) => window.devicePixelRatio === scale, newScale);
    await page.waitForTimeout(80);
    const resizedLoss = await record();
    assert.equal(resizedLoss.status.renderer.state, "lost");
    assert.equal(resizedLoss.status.renderer.framePending, false);
    assert.match(resizedLoss.diagnosticCode, /^surface_lost/);
    await page.evaluate(() => window.__gpuiRecoveryFixture.canvas.dispatchEvent(new Event("contextrestored")));
    await ready();
    const viewport = await page.evaluate(() => {
      const canvas = document.querySelector("#gpui-viewport");
      const bounds = canvas.getBoundingClientRect();
      return {
        status: window.__gpuiSmokeStatus(), width: bounds.width, height: bounds.height,
        backingWidth: canvas.width, backingHeight: canvas.height,
      };
    });
    assert.equal(viewport.status.dpr, newScale);
    assert.ok(Math.abs(viewport.status.logicalWidth - viewport.width) < 0.1);
    assert.ok(Math.abs(viewport.status.logicalHeight - viewport.height) < 0.1);
    assert.equal(viewport.backingWidth, Math.round(viewport.width * newScale));
    assert.equal(viewport.backingHeight, Math.round(viewport.height * newScale));
    assert.equal(viewport.status.capabilityValue, 9);

    const stale = await page.evaluate(() => {
      const fixture = window.__gpuiRecoveryFixture;
      const oldCanvas = fixture.canvas;
      const oldSemantic = document.querySelector("#gpui-accessibility-node-4");
      oldCanvas.dispatchEvent(new Event("contextlost", { cancelable: true }));
      const request = window.requestAnimationFrame.bind(window);
      let oldCallback;
      const undoRequest = fixture.patch(window, "requestAnimationFrame", (callback) => {
        oldCallback = callback;
        return request(callback);
      });
      oldCanvas.dispatchEvent(new Event("contextrestored"));
      undoRequest();
      const oldGeneration = window.__gpuiSmokeStatus().renderer.generation;
      document.querySelector("#remount").click();
      const beforeStale = window.__gpuiSmokeStatus();
      const event = new Event("contextlost", { cancelable: true });
      oldCanvas.dispatchEvent(event);
      oldCanvas.dispatchEvent(new Event("contextrestored"));
      oldCanvas.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
      oldSemantic.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      oldSemantic.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", bubbles: true }));
      oldCallback(performance.now());
      return {
        oldGeneration, beforeStale, afterStale: window.__gpuiSmokeStatus(),
        stalePrevented: event.defaultPrevented,
        newCanvas: document.querySelector("#gpui-viewport") !== oldCanvas,
      };
    });
    assert.equal(stale.newCanvas, true);
    assert.ok(stale.beforeStale.renderer.generation > stale.oldGeneration);
    assert.equal(stale.stalePrevented, false, "old canvas listeners are removed at teardown");
    assert.deepEqual(stale.afterStale, stale.beforeStale, "stale listeners and cancelled rAF cannot affect the remounted app");
    await ready();
    assert.equal((await read()).renderer.lossCount, 0);
    assert.equal((await read()).renderer.restoreAttempts, 0);
    assert.equal(await page.evaluate(() => window.__gpuiReadCounter()), 0, "explicit remount still creates a new logical app");
    assert.equal(await page.locator("#gpui-viewport").count(), 1);
    assert.equal(await page.locator("#gpui-accessibility-bridge").count(), 1);
  } finally {
    await page.evaluate(() => {
      const fixture = window.__gpuiRecoveryFixture;
      for (const cleanup of fixture?.cleanups.reverse() || []) cleanup();
      delete window.__gpuiRecoveryFixture;
      document.dispatchEvent(new Event("visibilitychange"));
    });
    await cdp.send("Emulation.setDeviceMetricsOverride", metrics);
    await cdp.detach();
  }
  await ready();
  console.log("Renderer recovery smoke passed: synthetic context lifecycle, retained state and pixels, blocked input, single repaint, failed acquisition/paint, focus changes before first paint, hidden restoration, live DPR/resize, and stale remount callbacks.");
}
