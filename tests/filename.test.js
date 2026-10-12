// makeFileName: token substitution with filesystem-safe output, plus
// normalize() validation for the fileNameTemplate setting.
// Run from the plugin root:  node tests/filename.test.js
const fs = require("fs");
const vm = require("node:vm");
const assert = require("node:assert/strict");

// Config.js carries QML's `.pragma library`, which node's vm cannot parse.
const source = fs.readFileSync("Config.js", "utf8").replace(/^\.pragma.*$/gm, "");
const Config = vm.runInNewContext(source + "\nthis", {});

// A fixed instant produces an exact, predictable name.
assert.equal(
  Config.makeFileName("screenrecording-%Y%m%d_%H%M%S", new Date(2026, 9, 12, 18, 30, 5)),
  "screenrecording-20261012_183005",
  "tokens expand to zero-padded values");

// Literal text around tokens passes through (kept alongside a time token so
// recordings in the same day cannot collide).
assert.equal(
  Config.makeFileName("clip-%Y-%m-%d_%H%M%S", new Date(2026, 9, 12, 18, 30, 5)),
  "clip-2026-10-12_183005",
  "literal separators survive");

// Filesystem-unsafe characters never reach the filesystem.
const dirty = Config.makeFileName('my:bad*name?"<>|-%H%M%S', new Date(2026, 0, 1, 5, 6, 7));
assert(!/[/\\:*?"<>|]/.test(dirty), "unsafe characters are stripped");
assert(dirty.indexOf("mybadname") === 0, "safe text is kept");

// A template with no time token collides on the second recording, so it
// must fall back to the default template.
const noTime = Config.makeFileName("recording", new Date(2026, 0, 1));
assert.equal(noTime, Config.makeFileName(Config.defaultConfig().fileNameTemplate, new Date(2026, 0, 1)),
  "a template without a time token falls back to the default");

// An empty or junk template also falls back.
assert.equal(Config.makeFileName("", new Date(2026, 0, 1)), "screenrecording-20260101_000000");

// normalize(): junk values fall back to the default, valid ones pass through.
const d = Config.defaultConfig().fileNameTemplate;
assert.equal(Config.normalize({ fileNameTemplate: 42 }).fileNameTemplate, d, "numbers fall back");
assert.equal(Config.normalize({ fileNameTemplate: null }).fileNameTemplate, d, "null falls back");
assert.equal(Config.normalize({ fileNameTemplate: "x".repeat(200) }).fileNameTemplate, d,
  "absurdly long templates fall back");
assert.equal(Config.normalize({ fileNameTemplate: "clip-%H%M%S" }).fileNameTemplate, "clip-%H%M%S",
  "a valid custom template is kept");
assert.equal(Config.normalize({ fileNameTemplate: "clip" }).fileNameTemplate, d,
  "a template with no time token falls back");

// organizeByDate: a date subdirectory for organized output.
assert.equal(
  Config.outputSubdir({ organizeByDate: true }, new Date(2026, 9, 12)),
  "2026-10-12", "organizeByDate builds a YYYY-MM-DD subdir");
assert.equal(Config.outputSubdir({ organizeByDate: false }, new Date(2026, 9, 12)), "",
  "off means the root output dir");
assert.equal(Config.defaultConfig().organizeByDate, false, "date folders default off");
assert.equal(Config.normalize({ organizeByDate: "yes" }).organizeByDate, true, "boolean coercion");
assert.equal(Config.normalize({ organizeByDate: 1 }).organizeByDate, true, "truthy numbers coerce");

// Service wiring: the templated name lands in the (optional) date subdir and
// prepareDir creates the directory of the actual file, not just outputDir.
const svc = fs.readFileSync("Service.qml", "utf8");
const launch = svc.slice(svc.indexOf("function launchRecording(target, streamMode)"));
const fileLine = launch.split("\n").find(l => /recordingFile = fileDir/.test(l));
assert(fileLine && /Config\.makeFileName\(config\.fileNameTemplate\)/.test(fileLine),
  "the recording path is built from the template");
assert(/outputSubdir/.test(launch),
  "the recording path can descend into a date subdir");
const prepLines = svc.split("\n").filter(l => /prepareDir\.command = /.test(l));
assert(prepLines.every(l => /mkdir -p/.test(l)), "prepareDir always mkdirs");
// At least one prepareDir command must create the recording file's directory.
assert(svc.indexOf("fileDir") >= 0 || /mkFileName|makeFileName/.test(prepLines.join(" ")),
  "prepareDir covers the recording file's directory");
assert(prepLines.length >= 2, "stream and recording paths each prepare their own dir");

console.log("ok - filename templates substitute safely and validate");
