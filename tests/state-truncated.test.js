// A truncated state.json must never blank the recording chip.
//
// THE BUG THIS EXISTS FOR. Service.qml writes state.json with
// `atomicWrites: false` (see flushState) so BarWidget's inotify watcher sees the
// change -- which necessarily means the file is briefly truncated while it is
// rewritten. applyServiceState() fell straight through that window and assigned
// the parsed-empty object as the new state, blanking the chip.
//
// The consequence was worse than a stale chip: anything gated on the recording
// being over -- stripSpecialFace in the bar, gated on `!recastActive` -- took
// the same frame the REC face vanished, so the pill swapped faces mid-take and
// read as two overlapping pills. pix.bar's own Recast singleton had the same
// flaw in applyState()/onLoadFailed and is fixed there.
//
// The contract: an unreadable or empty read is not evidence that anything
// changed. Keep the last good state; the next successful read carries the truth,
// including a real `idle` when a session genuinely ends.
//
// Run from the plugin root:  node tests/state-truncated.test.js
const fs = require("fs");
const assert = require("node:assert/strict");

const bar = fs.readFileSync("BarWidget.qml", "utf8");

const apply = bar.slice(bar.indexOf("function applyServiceState(raw)"),
                        bar.indexOf("function refresh()"));
assert(apply.length > 0, "applyServiceState is locatable");

// The empty read must return before anything is assigned. The old
// `JSON.parse(String(raw || "").trim() || "{}")` coerced the window into `{}`
// and let it through.
assert(/String\(raw \|\| ""\)\.trim\(\)/.test(apply),
  "applyServiceState normalises its input itself");
assert(/if \(text\.length === 0\)\s*return;/.test(apply),
  "an empty read returns before parsing");
assert(!/\.trim\(\) \|\| "\{\}"/.test(apply),
  "an empty read is no longer coerced into a state object");

// A failed parse is the same event, not a different one. The old handler kept
// the last good state here but still meant an unreadable file reset the chip.
assert(/catch \(e\) \{[\s\S]{0,200}return;\s*\}/.test(apply),
  "a truncated parse keeps the last good state");

// The three concurrent readers can still race, so the stale-snapshot guard that
// orders them must survive untouched -- the fix is in front of it, not in place
// of it.
assert(/_isStaleSnapshot\(parsed\)/.test(apply),
  "the stale-snapshot guard is still applied");

console.log("ok - a truncated state read keeps the last good state");