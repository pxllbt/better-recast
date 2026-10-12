// Container default: MKV is the crash-safe container for screen recording —
// its index is written incrementally, so a recording survives an interrupted
// capture (power loss, OOM kill, compositor crash). MP4's moov atom lands at
// the end of the file, which truncates the whole clip when the writer dies
// before it is flushed.
// Run from the plugin root:  node tests/container.test.js
const fs = require("fs");
const vm = require("node:vm");
const assert = require("node:assert/strict");

const source = fs.readFileSync("Config.js", "utf8").replace(/^\.pragma.*$/gm, "");
const Config = vm.runInNewContext(source + "\nthis", {});

assert.equal(Config.defaultConfig().container, "mkv",
  "new installs default to the crash-safe MKV container");
// An empty value must fall back to the default, never to a hardcoded mp4.
assert.equal(Config.normalize({ container: "" }).container, "mkv",
  "an empty container falls back to the default");
assert.equal(Config.normalize({ container: "mp4" }).container, "mp4",
  "an explicit mp4 choice is honored");
assert.equal(Config.normalize({ container: "webm" }).container, "webm",
  "webm stays reachable");
assert.equal(Config.normalize({ container: "avi" }).container, "mkv",
  "an unsupported container falls back to the default");

// Both fallbacks that guard a missing key must agree with the default, or a
// config built by hand would land on mp4 while the panel says mkv.
for (const file of ["Config.js", "Service.qml"]) {
  const text = fs.readFileSync(file, "utf8");
  const fallbacks = text.match(/config\.container \|\| "\w+"/g) || [];
  for (const f of fallbacks) {
    assert.equal(f, 'config.container || "mkv"',
      `${file}: the container fallback must match the default (${f})`);
  }
}

console.log("ok - MKV is the default container everywhere");
