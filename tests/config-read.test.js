// The config reader must not trust the FileView's text cache: on this
// environment inotify misses writes, so a cached read silently reverts the
// user's settings (observed live: container flipped back to mkv after being
// set to mp4, because a stale cache was re-applied).
// Run from the plugin root:  node tests/config-read.test.js
const fs = require("fs");
const assert = require("node:assert/strict");

const svc = fs.readFileSync("Service.qml", "utf8");

// A Process reads the file fresh; the FileView stays only as the change
// sensor.
assert(/id: configReadProc/.test(svc), "the config is read through a Process");
assert(/command: \["cat", root\.configFilePath\]/.test(svc),
  "the read Process cats the config file");

// refreshConfig must arm that Process, not read the FileView cache.
const refreshFn = svc.slice(svc.indexOf("function refreshConfig()"),
                            svc.indexOf("function ", svc.indexOf("function refreshConfig()") + 12));
assert(/configReadProc\.running = true/.test(refreshFn),
  "refreshConfig() arms the read Process");
assert(!/configFileView\.text\(\)/.test(refreshFn),
  "refreshConfig() must not read the FileView text cache");

// The cat output must reach parseAppliedConfig.
assert(/parseAppliedConfig\(text\)/.test(svc),
  "the read output is parsed as config");

console.log("ok - config reads are fresh, not cached");
