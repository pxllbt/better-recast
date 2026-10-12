// Pause must be visible: the service sends gsr the set-paused IPC but used to
// never flip its own state, so a paused recording looked exactly like a
// running one in the bar glyph, the panel and the OSD.
// Run from the plugin root:  node tests/pause-state.test.js
const fs = require("fs");
const assert = require("node:assert/strict");

const svc = fs.readFileSync("Service.qml", "utf8");

const pauseFn = svc.slice(svc.indexOf("function pause()"),
                          svc.indexOf("function resume()"));
assert(/state = "paused"/.test(pauseFn),
  "pause() must move the service into the paused state");

const resumeFn = svc.slice(svc.indexOf("function resume()"),
                           svc.indexOf("function togglePause()"));
assert(/state = "recording"/.test(resumeFn),
  "resume() must move the service back to recording");

// The pause glyph the bar shows must be distinct from the recording glyph.
const bar = fs.readFileSync("BarWidget.qml", "utf8");
const pauseGlyph = String.fromCodePoint(0xF03E5);
assert(bar.includes(`pausedState ? "${pauseGlyph}"`),
  "the bar maps paused to the pause glyph");

console.log("ok - pause is visible in the service and bar");
