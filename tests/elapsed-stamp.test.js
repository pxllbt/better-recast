// The elapsed count published in state.json must carry the instant it was
// measured on.
//
// `recordingElapsed` is recomputed once a second by the service, but the state
// file is polled far less often (5s while live in px.bar). A reader that has no
// idea how old the number it just read is has to assume it is current, so it
// anchors "now" against a value that may already be a second old. Every poll
// then under-shoots, the anchor snaps, and the on-screen clock rewinds by a
// second before carrying on — the reported "freeze for a second, then it
// keeps counting" stutter.
//
// The fix is to publish the measurement clock beside the count
// (`recordingElapsedAtMs`), stamped in the same place the count is written, so
// a consumer can age the value exactly instead of guessing.
//
// Run from the plugin root:  node tests/elapsed-stamp.test.js
const fs = require("fs");
const assert = require("node:assert/strict");

const src = fs.readFileSync("Service.qml", "utf8");

// 1. The stamp is published next to the count.
const statusSlice = src.slice(src.indexOf("function statusJson()"),
                             src.indexOf("function flushState()"));
assert(/recordingElapsed:\s*root\.recordingElapsed/.test(statusSlice),
  "statusJson publishes recordingElapsed");
assert(/recordingElapsedAtMs:\s*root\.elapsedAtMsForConsumer\(\)/.test(statusSlice),
  "statusJson publishes recordingElapsedAtMs beside it");

// 2. The count and the stamp are written together, in exactly one place each.
//    A bare `recordingElapsed = ...` anywhere else would publish a count whose
//    age no reader can recover -- the whole defect, reintroduced locally. The
//    two helpers below are the only sanctioned writers, so their line ranges
//    are excluded from the scan.
const lines = src.split("\n");
const from = (needle, startAt = 0) => {
    const i = lines.findIndex((l, idx) => idx >= startAt && l.includes(needle));
    assert(i >= 0, `"${needle}" is present in Service.qml`);
    return i;
};
const sanctioned = new Set();
for (const [start, end] of [["function resetElapsed()", "function advanceElapsed()"],
                            ["function advanceElapsed()", "Timer {"]]) {
    const a = from(start);
    // Search on from `a`: "Timer {" also names an earlier timer elsewhere in the
    // file, and an off-by-order range would silently sanction nothing.
    const b = from(end, a + 1);
    assert(b > a, `"${start}" block ends before it begins`);
    for (let i = a; i < b; i++) sanctioned.add(i);
}
const writers = lines
    .map((line, i) => [i + 1, line])
    .filter(([i, line]) => /^\s*recordingElapsed\s*=/.test(line) && !sanctioned.has(i - 1));
assert.equal(writers.length, 0,
  "no direct recordingElapsed assignment remains outside the helpers; found at lines "
    + writers.map(([n]) => n).join(", "));

assert(/function resetElapsed\(\)[\s\S]*?recordingElapsed = 0;\s*\n\s*recordingElapsedAtMs = Date\.now\(\);/.test(src),
  "resetElapsed() zeroes the count and stamps the clock together");
assert(/function advanceElapsed\(\)[\s\S]*?recordingElapsed = recordingBaseSec[\s\S]*?recordingElapsedAtMs = Date\.now\(\);/.test(src),
  "advanceElapsed() recomputes the count and stamps the clock together");

// The live timer must go through the stamping helper, not assign directly.
assert(/root\.advanceElapsed\(\)/.test(src),
  "the elapsed timer uses advanceElapsed()");

// 3. Every start path stamps too, so a fresh take publishes an aged-0 rather
//    than an unstamped leftover.
for (const fn of ["function startReplay()", "function launchRecording(target, streamMode)"]) {
    const body = src.slice(src.indexOf(fn), src.indexOf("function ", src.indexOf(fn) + 12));
    assert(/resetElapsed\(\)/.test(body),
      `${fn} stamps a fresh count via resetElapsed()`);
}

// 4. An unstamped session must degrade to "now", never to the epoch. Falling
//    through to 0 would extrapolate from 1970 and render an absurd count.
assert(/if \(recordingElapsedAtMs <= 0\)\s*\n\s*return Date\.now\(\);/.test(src),
  "elapsedAtMsForConsumer() falls back to now instead of an unstamped 0");

// 5. The widget ages the count with the stamp rather than trusting it fresh.
const bar = fs.readFileSync("BarWidget.qml", "utf8");
assert(/recordingElapsedAtMs/.test(bar),
  "BarWidget reads the stamp");
assert(/serviceState\.recordingElapsedAtMs/.test(bar),
  "BarWidget anchors its projected count on the service's stamp");
assert(/drift > 0 \? base \+ drift : base/.test(bar),
  "BarWidget never extrapolates backwards on a disagreeing clock");

console.log("ok - the published count is stamped, so consumers age it exactly");