// Recent recordings: the service lists the output directory and the panel
// offers open/copy-path actions, through the live service or the state file.
// Run from the plugin root:  node tests/recent.test.js
const fs = require("fs");
const assert = require("node:assert/strict");

const svc = fs.readFileSync("Service.qml", "utf8");

assert(/property var recentFiles/.test(svc), "Service declares recentFiles");
assert(/recentFiles: root\.recentFiles/.test(svc),
  "recentFiles is in statusJson (replacement bars read state.json)");
assert(/id: recentProc/.test(svc), "Service has a recentProc Process");

const recentBlock = svc.slice(svc.indexOf("id: recentProc"),
                              svc.indexOf("Component.onCompleted", svc.indexOf("id: recentProc")));
assert(/ls -1t/.test(recentBlock), "the listing is newest-first (ls -1t)");
assert(/head -6/.test(recentBlock), "the listing is capped at 6 entries");
assert(/\\"/.test(recentBlock) || /"/.test(recentBlock),
  "the listing quotes the output dir path");
assert(/function refreshRecent\(/.test(svc), "refreshRecent() exists");
assert(/refreshRecent\(\)/.test(svc), "refreshRecent is actually called");

// The panel mounts the recent-recordings component.
const panel = fs.readFileSync("Panel.qml", "utf8");
assert(/RecentRecordings/.test(panel), "the panel mounts RecentRecordings");

// The component owns the two per-file actions.
const tool = fs.existsSync("RecentRecordings.qml") ? fs.readFileSync("RecentRecordings.qml", "utf8") : "";
assert(tool !== "", "RecentRecordings.qml exists");
assert(/xdg-open/.test(tool), "open action uses xdg-open");
assert(/wl-copy/.test(tool), "copy action uses wl-copy");
assert(/recentFiles/.test(tool), "the list binds recentFiles");

console.log("ok - recent recordings list with open and copy-path actions");
