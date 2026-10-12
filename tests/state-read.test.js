// The bar widget must read state.json through an inotify-backed FileView so an
// idle session spawns nothing, with the `cat` Process kept only as a slow
// safety net for environments whose inotify misses writes.
// Run from the plugin root:  node tests/state-read.test.js
const fs = require("fs");
const assert = require("node:assert/strict");

const src = fs.readFileSync("BarWidget.qml", "utf8");

// (a) A FileView on the state file, watching changes.
const fv = src.indexOf("id: stateFileView");
assert(fv >= 0, "a state FileView exists");
const fvStart = src.lastIndexOf("FileView {", fv);
const fvBody = src.slice(fvStart, src.indexOf("}", fvStart) + 1);
assert(/path: root\.stateFilePath/.test(fvBody), "FileView watches stateFilePath");
assert(/watchChanges: true/.test(fvBody), "FileView must watch changes");
assert(/onFileChanged/.test(src) && /onLoaded/.test(src) && /onLoadFailed/.test(src),
  "FileView handles the load, change and load-failure events");

// (b) Change events route into applyServiceState with the file's text.
for (const handler of ["onLoaded", "onFileChanged", "onLoadFailed"]) {
  assert(new RegExp(`${handler}:[\\s\\S]{0,140}applyServiceState\\(stateFileView\\.text\\(\\)\\)`).test(src),
    `${handler} must feed applyServiceState(stateFileView.text())`);
}

// (c)+(d) The cat poll survives only as a slow fallback, gated on the
// replacement-bar case (no live service object).
const poll = src.slice(src.indexOf("id: pollTimer"));
const pollBody = poll.slice(0, poll.indexOf("}", poll.indexOf("onTriggered")));
assert(/interval: 5000/.test(pollBody), "fallback poll interval is 5s, not 1s");
assert(/running: root\.service === null/.test(pollBody),
  "fallback poll runs only when the service object is unreachable");

// (e) The cat Process stays as the fallback channel.
assert(/id: stateReadProc/.test(src) && /command: \["cat", root\.stateFilePath\]/.test(src),
  "the cat Process remains as the fallback reader");

console.log("ok - event-driven state reads with a gated cat fallback");
