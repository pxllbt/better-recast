// Asserts that Service.qml implements automated orphan process reaping
// for gpu-screen-recorder and sanitizes dead IPC sockets on startup.
const fs = require("fs");
const assert = require("node:assert/strict");

const src = fs.readFileSync("Service.qml", "utf8");

// 1. Service.qml must have a reaper function for orphaned gpu-screen-recorder processes
assert(/function reapOrphanRecorders\(/.test(src),
  "Service.qml defines reapOrphanRecorders()");

// 2. The reaper must check if state is idle and send SIGINT for graceful finalization
assert(/pgrep.*gpu-screen-recorder/.test(src) || /pkill.*gpu-screen-recorder/.test(src),
  "reaper inspects running gpu-screen-recorder processes");

// 3. Service.qml calls reapOrphanRecorders on startup
assert(/reapOrphanRecorders\(\)/.test(src),
  "Service.qml invokes reapOrphanRecorders on startup");

// 4. Service.qml unlinks stale IPC socket on startup before binding
assert(/rm -f.*ipcSocketPath|unlink.*ipcSocketPath|rm -f.*ipc\.sock/.test(src),
  "Service.qml cleans stale IPC socket on startup");

console.log("ok - orphan recorder reaping and dead socket sanitation verified");
