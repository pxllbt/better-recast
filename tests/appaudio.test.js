// Application audio: gpu-screen-recorder can capture a single application's
// output (man page: `-a default_output|app:firefox`). This parses the
// --list-application-audio probe into selector entries. The probe returns
// nothing on machines where no application exposes capturable audio, in which
// case the selectors simply keep today's device-only list.
// Run from the plugin root:  node tests/appaudio.test.js
const fs = require("fs");
const vm = require("node:vm");
const assert = require("node:assert/strict");
// vm-built arrays carry the vm prototype; compare serialized.
const same = (a, b) => assert.equal(JSON.stringify(a), JSON.stringify(b));

const gpuProbe = fs.readFileSync("GpuProbe.js", "utf8").replace(/^\.pragma.*$/gm, "");
const GpuProbe = vm.runInNewContext(gpuProbe + "\nthis", {});

// Two application lines become two app: entries.
const parsed = GpuProbe.parseAppAudio("firefox\nmpv\n");
assert.equal(parsed.length, 2, "each application line becomes an entry");
assert.deepEqual(JSON.parse(JSON.stringify(parsed[0])), { id: "app:firefox", name: "firefox" },
  "entries carry the app: prefixed id gsr expects");

// Empty and banner-only output produce no entries — the probe is silent on
// machines with no capturable application, and that must stay harmless.
same(GpuProbe.parseAppAudio(""), [], "empty output → no entries");
same(GpuProbe.parseAppAudio("\n\n"), [], "whitespace → no entries");

// Lines that are not a bare application name (containers, separators) are
// dropped rather than fed to gsr as a bogus source.
same(GpuProbe.parseAppAudio("default_output|app:firefox"), [],
  "a combined source line is not an application list entry");

// Service wiring: the probe runs through bash (binary-absent safety, same
// pattern as the gsr version probe) and merges into the audio sources.
const svc = fs.readFileSync("Service.qml", "utf8");
assert(/property var appAudioSources/.test(svc), "the service holds appAudioSources");
assert(/--list-application-audio/.test(svc), "the service probes application audio");
assert(/command -v gpu-screen-recorder/.test(svc),
  "the app-audio probe runs through bash so a missing binary still exits");
assert(/appAudioSources: root\.appAudioSources/.test(svc),
  "appAudioSources is exposed to replacement bars through state.json");

// Config: app sources pass through audioSourceName unchanged.
const source = fs.readFileSync("Config.js", "utf8").replace(/^\.pragma.*$/gm, "");
const Config = vm.runInNewContext(source + "\nthis", {});
assert.equal(Config.audioSourceName("app:firefox"), "app:firefox",
  "an app source is passed to gsr verbatim");
assert.equal(Config.audioSourceName("default_output"), "default_output",
  "device sources still pass through");

// Panel: both selectors offer app sources after the devices (via
// audioDeviceOptions, which the desktop and mic dropdowns share).
const panel = fs.readFileSync("Panel.qml", "utf8");
assert(/appAudioSources/.test(panel), "the panel offers application sources");
assert(/function audioDeviceOptions\(\)/.test(panel), "the shared selector builder exists");
const optionsFn = panel.slice(panel.indexOf("function audioDeviceOptions()"),
                              panel.indexOf("function ", panel.indexOf("function audioDeviceOptions()") + 12));
assert(/appAudioSources/.test(optionsFn),
  "the selector builder appends app sources after the devices");

console.log("ok - application audio parses, probes safely and merges into the selectors");
