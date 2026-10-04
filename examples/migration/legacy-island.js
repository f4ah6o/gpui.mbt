function finite(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function checkedBounds(bounds) {
  if (!bounds || ![bounds.x, bounds.y, bounds.width, bounds.height].every(finite) || bounds.width < 0 || bounds.height < 0) {
    throw new TypeError("legacy island bounds must be finite logical coordinates");
  }
  return bounds;
}

/// Position a migration-only DOM region using framework-owned logical bounds.
/// The caller supplies bounds from its current framework layout; this adapter
/// never participates in layout, hit testing, or scene generation.
export function createLegacyIsland({ frame, surface, canvas, onOwnerChange = () => {} }) {
  if (!frame || !surface || !canvas) throw new TypeError("legacy island requires a frame, surface, and canvas");
  let disposed = false;
  let owner = "framework";
  const listeners = [];
  const listen = (target, type, callback) => {
    target.addEventListener(type, callback);
    listeners.push(() => target.removeEventListener(type, callback));
  };

  const setOwner = (next) => {
    if (disposed || owner === next) return;
    owner = next;
    frame.dataset.inputOwner = owner;
    onOwnerChange(owner);
  };
  const onFocus = () => setOwner("legacy-island");
  const onBlur = (event) => {
    if (event.relatedTarget && surface.contains(event.relatedTarget)) return;
    setOwner("framework");
  };
  listen(surface, "focusin", onFocus);
  listen(surface, "focusout", onBlur);

  return Object.freeze({
    sync(bounds, nextVisible = true) {
      if (disposed) return false;
      const logical = checkedBounds(bounds);
      const hadFocus = surface.contains(document.activeElement);
      surface.hidden = !nextVisible || logical.width < 1 || logical.height < 1;
      surface.inert = surface.hidden;
      surface.style.position = "absolute";
      surface.style.left = `${logical.x}px`;
      surface.style.top = `${logical.y}px`;
      surface.style.width = `${logical.width}px`;
      surface.style.height = `${logical.height}px`;
      surface.dataset.logicalBounds = `${logical.x},${logical.y},${logical.width},${logical.height}`;
      if (surface.hidden && hadFocus) {
        surface.blur?.();
        canvas.focus({ preventScroll: true });
      }
      return !surface.hidden;
    },

    returnToFramework() {
      if (disposed) return false;
      surface.blur?.();
      canvas.focus({ preventScroll: true });
      setOwner("framework");
      return true;
    },

    inputOwner() {
      return owner;
    },

    dispose() {
      if (disposed) return;
      if (surface.contains(document.activeElement)) {
        surface.dispatchEvent(new FocusEvent("focusout", { relatedTarget: canvas, bubbles: true }));
        canvas.focus({ preventScroll: true });
      }
      if (owner !== "framework") setOwner("framework");
      disposed = true;
      for (const remove of listeners.splice(0)) remove();
      surface.remove();
      delete frame.dataset.inputOwner;
      owner = "framework";
    },
  });
}
