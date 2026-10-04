import * as fixture from "mbt:f4ah6o/gpui/tests/browser/dev_watch_fixture";

const marker = document.querySelector("#dev-watch-marker");

function render(module) {
  const value = module.dev_watch_marker();
  marker.textContent = value;
  document.body.dataset.devWatchMarker = value;
}

render(fixture);

if (import.meta.hot) {
  import.meta.hot.accept(
    "mbt:f4ah6o/gpui/tests/browser/dev_watch_fixture",
    (next) => {
      if (next) render(next);
    },
  );
}
