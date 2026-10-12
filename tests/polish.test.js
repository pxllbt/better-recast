// Final polish: a persistent error banner (not only in the error state),
// countdown notifications that replace in place instead of stacking, and the
// version bump that ships this round of work.
// Run from the plugin root:  node tests/polish.test.js
const fs = require("fs");
const assert = require("node:assert/strict");

const panel = fs.readFileSync("Panel.qml", "utf8");
const svc = fs.readFileSync("Service.qml", "utf8");
const manifest = JSON.parse(fs.readFileSync("manifest.json", "utf8"));

// The error banner renders whenever an error message exists — the old copy
// was gated on state === "error", so a refusal during "idle" (the disk guard)
// never showed.
assert(/id: errorBanner/.test(panel), "the panel has an error banner");
const banner = panel.slice(panel.indexOf("id: errorBanner"));
const bannerEnd = banner.indexOf("\n        }", banner.indexOf("MouseArea"));
const bannerBody = banner.slice(0, bannerEnd > 0 ? bannerEnd : 1400);
assert(/visible: root\.errorMessage\.length > 0/.test(bannerBody),
  "the banner shows for any non-empty error, not only the error state");
assert(/errorMessage = ""/.test(bannerBody), "the banner can be dismissed");

// Countdown notices replace in place: one replace id, -r into the notifier.
assert(/function sendNotification\(summary, body, urgency, timeout, replaceId\)/.test(svc),
  "sendNotification takes an optional replace id");
const sendFn = svc.slice(svc.indexOf("function sendNotification(summary, body, urgency, timeout, replaceId)"),
                         svc.indexOf("function ", svc.indexOf("function sendNotification(summary, body, urgency, timeout, replaceId)") + 12));
assert(/"-r"/.test(sendFn),
  "sendNotification can pass a replace id");
assert(/replaceId > 0/.test(sendFn), "the replace id is validated before use");
assert(/"Recording starts in "/.test(svc), "the countdown still announces each second");
// The countdown notifications must share ONE id so tick 2 replaces tick 1.
const countdownNotices = svc.match(/sendNotification\("Better Recast", "Recording starts in [^)]*\)/g) || [];
assert(countdownNotices.length >= 2, "both countdown call sites exist");
assert(countdownNotices.every(c => c.includes("recastCountdownId")),
  "every countdown notice passes the same replace id");

// Version bump.
assert.equal(manifest.version, "1.3.0", "the manifest version is 1.3.0");

console.log("ok - error banner, in-place countdown notices, version 1.3.0");
