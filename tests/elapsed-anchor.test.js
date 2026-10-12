// A fresh recording must start counting from 00:00, not from the previous
// take's leftover.
//
// The service anchors its count in onStateChanged with
// `recordingBaseSec = recordingElapsed` — the CURRENT value. The elapsed
// timer is `triggeredOnStart` and runs while state is recording, so on the
// same flip it can recompute `recordingElapsed` from the PREVIOUS take's
// base before the anchor copies it. The new recording then starts at whatever
// the last one ended on (observed: a 1s-old take starting at 06:00 after a
// 359s one), which is both wrong on its own and impossible to correct from a
// consumer that trusts the state file.
//
// Resuming from a pause must NOT reset: the count continues across it.
// Run from the plugin root:  node tests/elapsed-anchor.test.js
const fs = require("fs");
const assert = require("node:assert/strict");

const src = fs.readFileSync("Service.qml", "utf8");

const handler = src.slice(src.indexOf("onStateChanged:"),
                          src.indexOf("onRecordingElapsedChanged:"));
assert(handler.length > 0, "onStateChanged handler exists");

// A fresh take resets the anchor; a resume keeps it. Without distinguishing
// the two, either a new recording starts stale or a resume restarts at 00:00.
assert(/_prevState/.test(handler),
  "the handler tracks the previous state to tell a fresh take from a resume");
assert(/wasCapturing/.test(handler),
  "the handler distinguishes resuming from starting fresh");
assert(/recordingBaseSec = 0/.test(handler),
  "a fresh take zeroes the base instead of copying the stale elapsed");
assert(/recordingBaseMs = Date\.now\(\)/.test(handler),
  "a fresh take re-anchors the clock");

// The paused -> recording transition must be treated as the same take.
assert(/paused/.test(handler), "paused counts as part of the live take");

// The countdown path must also reach a zeroed base.
const start = src.slice(src.indexOf("function beginRecording(targetType)"),
                        src.indexOf("function launchRecording(target, streamMode)"));
assert(/recordingElapsed = 0/.test(start) || /recordingElapsed = 0/.test(src.slice(src.indexOf("function launchRecording"))),
  "the launch path zeroes the displayed elapsed");


// Paused time must not be added back on resume: the count reports how long the
// recording has actually been running, not the wall clock since it started.
assert(/recordingBaseSec = recordingElapsed;\s*\n\s*recordingBaseMs = Date\.now\(\)/.test(
    src.slice(src.indexOf("function pause()"), src.indexOf("function resume()"))),
  "pause() re-anchors the count at the paused value");
assert(/recordingBaseMs = Date\.now\(\)/.test(
    src.slice(src.indexOf("function resume()"), src.indexOf("function ", src.indexOf("function resume()") + 12))),
  "resume() re-anchors the clock so the paused gap is not re-added");

console.log("ok - a fresh take counts from 00:00 and a resume keeps counting");
