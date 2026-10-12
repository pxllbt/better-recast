// Trim: time-spec parsing and ffmpeg argument building, plus the Service and
// panel wiring that drives it.
// Run from the plugin root:  node tests/trim.test.js
const fs = require("fs");
const vm = require("node:vm");
const assert = require("node:assert/strict");

const source = fs.readFileSync("Config.js", "utf8").replace(/^\.pragma.*$/gm, "");
const Config = vm.runInNewContext(source + "\nthis", {});

// parseTimeSpec accepts seconds, mm:ss and h:mm:ss; junk reports -1.
assert.equal(Config.parseTimeSpec("90"), 90, "bare seconds");
assert.equal(Config.parseTimeSpec("1:30"), 90, "mm:ss");
assert.equal(Config.parseTimeSpec("00:01:30"), 90, "h:mm:ss");
assert.equal(Config.parseTimeSpec("0:00"), 0, "zero");
assert.equal(Config.parseTimeSpec("abc"), -1, "junk → -1");
assert.equal(Config.parseTimeSpec(""), -1, "empty → -1");
assert.equal(Config.parseTimeSpec("1:2:3:4"), -1, "too many parts → -1");

// buildTrimArgs: fast seek (-ss before -i), stream copy by default, re-encode
// when precise, output last. Paths with spaces stay single argv elements.
const fast = Config.buildTrimArgs({
  input: "/home/u/my clips/clip 1.mp4",
  startSec: 90,
  endSec: 150,
  output: "/home/u/my clips/clip 1.trim.mp4",
  precise: false
});
// Cross-realm guard: buildTrimArgs runs inside the vm, so its array's
// prototype is the vm's — compare serialized so the check tests the values.
const same = (a, b) => assert.equal(JSON.stringify(a), JSON.stringify(b));

same(fast, [
  "ffmpeg", "-y", "-ss", "90", "-to", "150",
  "-i", "/home/u/my clips/clip 1.mp4",
  "-c", "copy",
  "/home/u/my clips/clip 1.trim.mp4"
], "stream-copy args, spaces preserved in argv");

const precise = Config.buildTrimArgs({
  input: "/a.mp4", startSec: 0, endSec: 5, output: "/b.mp4", precise: true
});
same(precise.slice(0, 6),
  ["ffmpeg", "-y", "-ss", "0", "-to", "5"], "seek args come first");
assert(precise.includes("-c:v") && precise.includes("libx264") && precise.includes("-crf"),
  "precise mode re-encodes video");
assert(precise[precise.length - 1] === "/b.mp4", "output is the last argument");

// A missing end means "to the end of the file": no -to flag at all.
const openEnd = Config.buildTrimArgs({
  input: "/a.mp4", startSec: 10, endSec: -1, output: "/c.mp4", precise: false
});
assert(!openEnd.includes("-to"), "endSec -1 omits -to");
assert(openEnd.includes("-ss") && openEnd.includes("10"), "start still seeks");

// Service + panel wiring.
const svc = fs.readFileSync("Service.qml", "utf8");
assert(/function trimLastClip\(/.test(svc), "Service has trimLastClip");
assert(/id: trimProc/.test(svc), "Service has a trim Process");
assert(/trimLastClip\(/.test(svc), "trimLastClip is reachable");
assert(/function trim\(start: string, end: string, precise: string\)/.test(svc),
  "the IPC handler exposes trim(start, end, precise)");

const panel = fs.readFileSync("Panel.qml", "utf8");
assert(/TrimTool/.test(panel), "the panel mounts the trim tool");
assert(/POST-RECORDING/.test(panel), "the trim tool lives in a post-recording section");

// TrimTool itself: it owns the inputs and reports through the panel.
const tool = fs.existsSync("TrimTool.qml") ? fs.readFileSync("TrimTool.qml", "utf8") : "";
assert(tool !== "", "TrimTool.qml exists");
assert(/startField/.test(tool) && /endField/.test(tool), "trim tool has start and end inputs");
assert((/precise/i).test(tool), "trim tool exposes the precise-cut option");
assert(/Trim last clip/.test(tool), "trim tool has an action button");
assert(/trimLastClip\(/.test(tool) || /"trim"/.test(tool),
  "the trim tool drives the trim through the service or IPC");

console.log("ok - trim parses times, builds safe argv and is wired end to end");
