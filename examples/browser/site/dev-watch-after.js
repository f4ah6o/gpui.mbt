import * as fixture from "mbt:f4ah6o/gpui/tests/browser/dev_watch_fixture?dev-watch-after";

const value = fixture.dev_watch_marker();
document.body.dataset.devWatchMarker = value;
document.querySelector("#dev-watch-marker").textContent = value;
