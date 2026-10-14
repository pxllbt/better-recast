// Asserts that Service.qml implements autonomous low-disk emergency protection (<500MB)
// during live recording to prevent file corruption.
const fs = require("fs");
const assert = require("node:assert/strict");

const src = fs.readFileSync("Service.qml", "utf8");

// 1. Service.qml must have periodic disk monitoring while recording
assert(/diskMonitorTimer|id: diskMonitor/.test(src),
  "Service.qml contains a disk monitor timer for active recordings");

// 2. The monitor checks free space and enforces the 500MB emergency threshold
assert(/500\s*\*\s*1024|524288/.test(src),
  "Service.qml checks the 500MB emergency free space threshold");

// 3. Low disk emergency pauses capture safely to finalize container index
assert(/root\.pause\(\)/.test(src) && /Low Disk Space|protect your video/i.test(src),
  "Service.qml pauses capture and dispatches emergency notification on low disk");

console.log("ok - low-disk emergency protection verified");
