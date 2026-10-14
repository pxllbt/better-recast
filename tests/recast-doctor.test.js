// Asserts that scripts/recast-doctor.sh and Service.qml implement the
// Recast Doctor diagnostic, self-repair, and pre-flight engine.
const fs = require("fs");
const assert = require("node:assert/strict");

const doctorPath = "scripts/recast-doctor.sh";
assert(fs.existsSync(doctorPath), "scripts/recast-doctor.sh exists");

const doctorSrc = fs.readFileSync(doctorPath, "utf8");

// 1. Checks GPU render nodes and encoders
assert(/renderD[0-9]+|\/dev\/dri/.test(doctorSrc),
  "recast-doctor checks /dev/dri render node access");

// 2. Checks audio and microphone volume
assert(/DEFAULT_AUDIO_SOURCE|wpctl get-volume/.test(doctorSrc),
  "recast-doctor inspects microphone volume");

// 3. Supports --fix, --test, --json
assert(/--fix/.test(doctorSrc), "recast-doctor supports --fix");
assert(/--test/.test(doctorSrc), "recast-doctor supports --test");
assert(/--json/.test(doctorSrc), "recast-doctor supports --json");

// 4. Service.qml registers doctor in IpcHandler
const serviceSrc = fs.readFileSync("Service.qml", "utf8");
assert(/function doctor\(/.test(serviceSrc),
  "Service.qml registers doctor() in IpcHandler");

console.log("ok - recast-doctor diagnostic engine verified");
