// Asserts that Config.js and Service.qml implement seamless audio failover
// when a configured audio device is disconnected or missing.
const fs = require("fs");
const assert = require("node:assert/strict");
const vm = require("node:vm");

const configSrc = fs.readFileSync("Config.js", "utf8").replace(/^\.pragma.*$/gm, "");
const sandbox = { console };
const Config = vm.runInNewContext(configSrc + "\nthis", sandbox);

// 1. Config.resolveAudioDevice
assert(typeof Config.resolveAudioDevice === "function",
  "Config.resolveAudioDevice exists");

const available = [
  { id: "default_output", name: "Default Output" },
  { id: "alsa_output.pci-0000_00_1f.3", name: "Built-in Audio" }
];

// Valid device is preserved
assert.equal(Config.resolveAudioDevice("alsa_output.pci-0000_00_1f.3", available, "default_output"),
  "alsa_output.pci-0000_00_1f.3", "existing device is preserved");

// Disconnected device seamlessly falls back
assert.equal(Config.resolveAudioDevice("usb_disconnected_mic", available, "default_input"),
  "default_input", "missing device automatically falls back to default");

// 2. encodeGsrArgs uses resolveAudioDevice when devices are passed
const cfg = {
  audioEnabled: true,
  audioDesktop: true,
  audioDesktopDevice: "missing_bluetooth_speaker",
  audioMicrophone: false
};
const args = Config.encodeGsrArgs(cfg, null, "screen", false, false, available);
assert(args.includes("-a"), "args include audio flag");
const aIdx = args.indexOf("-a");
assert(args[aIdx + 1].includes("default_output"),
  "encodeGsrArgs automatically redirected disconnected device to default_output");

console.log("ok - audio device disconnect failover verified");
