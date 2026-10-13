// Two counters in this plugin read the recorder's elapsed time, and both had
// their own defect.
//
// 1. ALTERNATING. BarWidget.qml has three writers into `applyServiceState`: the
//    FileView (watchChanges, so it fires on every 1s write the service makes),
//    a 1s `cat` Process, and a 5s poll Process. All three run concurrently and
//    nothing ordered them, so a `cat` that started before a write and finished
//    after it applied an OLDER snapshot on top of a fresher one. The count then
//    went forward, back, forward again -- "alternating, not properly counting".
//    `recordingElapsedAtMs` is the tie-breaker: the service stamps it with
//    Date.now() on every write, so it only ever moves forward across the whole
//    session, and an out-of-order snapshot is detectable by it alone.
//
// 2. NOT LIVE. Panel.qml had no Timer at all, and read `recordingElapsed`
//    straight out of the snapshot with no aging. The count could therefore only
//    ever change when a snapshot happened to land, and it was always up to a
//    poll interval behind what was actually being recorded.
//
// Both counters must share one shape: age the count on the service's stamp,
// and ratchet it so it never moves backwards within a take.
//
// Run from the plugin root:  node tests/elapsed-consumers.test.js
const fs = require("fs");
const assert = require("node:assert/strict");

const bar = fs.readFileSync("BarWidget.qml", "utf8");
const panel = fs.readFileSync("Panel.qml", "utf8");

// ---- 1. reject out-of-order snapshots -------------------------------------
const apply = bar.slice(bar.indexOf("function applyServiceState(raw)"),
                        bar.indexOf("function refresh()"));
assert(apply.length > 0, "applyServiceState is present");

assert(/_isStaleSnapshot|recordingElapsedAtMs/.test(apply),
  "applyServiceState orders incoming snapshots by the service's stamp");
assert(/root\.serviceState = parsed;/.test(apply),
  "a snapshot is still assigned once accepted");

// The stamp must be remembered, or there is nothing to compare against.
assert(/property double _lastStateStamp: 0/.test(bar),
  "BarWidget remembers the stamp of the last accepted snapshot");

// ---- 2. the bar widget's own counter is stamped and ratcheted ------------
const barElapsed = bar.slice(bar.indexOf("readonly property int elapsed"),
                             bar.indexOf("readonly property bool recording:"));
assert(barElapsed.length > 0, "the widget's elapsed binding is locatable");
assert(/recordingElapsedAtMs/.test(barElapsed),
  "the widget ages the count on the service's stamp");
assert(/_elapsedFloor/.test(barElapsed),
  "the widget's count is ratcheted so it cannot rewind");
// Reading and writing a plain property inside one binding is a binding loop;
// QML warns and re-evaluates. The floor must not be a dependency of the
// binding that maintains it, so it lives in an object whose field is mutated.
assert(!/property int _lastShownElapsed/.test(bar),
  "the widget's floor is not a plain property (that would be a binding loop)");

// ---- 3. the panel counter ticks on its own and is not a raw read ---------
// A raw `serviceState.recordingElapsed` read is the original bug: it is only
// as fresh as the last snapshot and is not projected forward between them.
// The one raw read inside the `elapsed` binding is the projection's input and
// is sanctioned, so the scan covers everything *outside* that binding.
const panelLines = panel.split("\n");
const elapsedFrom = panelLines.findIndex((l) => l.includes("readonly property int elapsed"));
const elapsedTo = panelLines.findIndex((l, i) => i > elapsedFrom && /property var _elapsedFloor/.test(l));
assert(elapsedFrom >= 0 && elapsedTo > elapsedFrom, "the panel's elapsed binding is locatable");
const inBinding = new Set();
for (let i = elapsedFrom; i < elapsedTo; i++) inBinding.add(i);

const rawReads = panelLines
    .map((line, i) => [i + 1, line])
    .filter(([i, l]) => /serviceState\.recordingElapsed/.test(l)
        && !inBinding.has(i - 1)
        && !/_elapsedFloor|_tick|recordingElapsedAtMs/.test(l));
assert.equal(rawReads.length, 0,
  "no raw serviceState.recordingElapsed reads remain outside the projection; found at lines "
    + rawReads.map(([n]) => n).join(", "));

assert(/Timer \{/.test(panel),
  "Panel has a Timer so the counter advances between snapshots");
assert(/recordingElapsedAtMs/.test(panel),
  "Panel ages the count on the service's stamp");
assert(/_elapsedFloor/.test(panel),
  "Panel's count is ratcheted so it cannot rewind");
assert(!/property int _lastShownElapsed/.test(panel),
  "Panel's floor is not a plain property (that would be a binding loop)");

// stateLabel() rendered "REC 00:12" from the same raw read twice over.
const label = panel.slice(panel.indexOf("function stateLabel()"),
                          panel.indexOf("function targetLabel()"));
assert(!/recordingElapsed \|\| 0/.test(label),
  "stateLabel reads the shared projected count, not the raw snapshot");

console.log("ok - both counters are stamped, ticked and monotonic");