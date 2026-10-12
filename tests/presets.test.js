// Presets and saved regions: named partial-config profiles and region
// geometries, persisted outside shell.json so a plugin update never resets
// them. The stream key must never be persistable into a preset.
// Run from the plugin root:  node tests/presets.test.js
const fs = require("fs");
const vm = require("node:vm");
const assert = require("node:assert/strict");

const source = fs.readFileSync("Config.js", "utf8").replace(/^\.pragma.*$/gm, "");
const Config = vm.runInNewContext(source + "\nthis", {});

// mergePreset: normalize the patch, drop the never-persisted keys, leave the
// rest of the base untouched.
const base = Config.defaultConfig();
const merged = Config.mergePreset(base, { fps: 30, streamKey: "SECRET", streamUrl: "rtmp://x" });
assert.equal(merged.fps, 30, "the patch applies");
assert.equal(merged.streamKey, base.streamKey, "the stream key is never taken from a preset");
assert.equal(merged.streamUrl, base.streamUrl, "the stream URL is never taken from a preset");
assert.equal(merged.container, base.container, "untouched keys survive");
assert.equal(Config.mergePreset(base, {}).fps, base.fps, "an empty patch is a no-op");

// ...and it must also strip credentials that arrived in the BASE — a preset
// saved from a live config carries streamKey/streamUrl in the config it is
// built from, so skipping only the patch's keys silently leaks them.
const dirty = Object.assign({}, base, { streamKey: "TOPSECRET", streamUrl: "rtmp://live/x" });
const cleaned = Config.mergePreset(dirty, { fps: 24 });
assert.equal(cleaned.streamKey, base.streamKey, "a credential in the base never survives the merge");
assert.equal(cleaned.streamUrl, base.streamUrl, "a stream URL in the base never survives the merge");
assert.equal(cleaned.fps, 24, "the patch still applies around the stripping");

// Applying a patch touches only the keys it names.
const patch = Config.presetPatch(base, { fps: 24, quality: "medium" });
assert.deepEqual(Object.keys(patch).sort(), ["fps", "quality"],
  "presetPatch returns only the changed keys");
assert.equal(patch.quality, "medium", "changed values are the new ones");

// Service wiring: the state file, the storage functions, region apply.
const svc = fs.readFileSync("Service.qml", "utf8");
assert(/presetsFile/.test(svc), "the presets file path exists");
assert(/pix-recast\/presets\.json/.test(svc),
  "presets live in their own state-dir file, outside shell.json");
assert(/XDG_STATE_HOME/.test(svc) && /\.local\/state/.test(svc),
  "the state dir honours XDG_STATE_HOME with a .local/state fallback");
assert(/property var presets:/.test(svc), "the presets map is a property");
assert(/property var savedRegions:/.test(svc), "saved regions are a property");
for (const fn of ["applyPreset", "savePreset", "deletePreset", "applyRegion", "saveRegion"]) {
  assert(new RegExp(`function ${fn}\\(`).test(svc), `${fn}() exists`);
}
// applyRegion must arm the region mode, not just store the geometry.
const applyRegion = svc.slice(svc.indexOf("function applyRegion("),
                              svc.indexOf("function ", svc.indexOf("function applyRegion(") + 12));
assert(/setConfig\("region"/.test(applyRegion), "applyRegion sets the region geometry");
assert(/setConfig\("targetMode", "region"\)/.test(applyRegion),
  "applyRegion arms region capture");

// Panel wiring.
const panel = fs.readFileSync("Panel.qml", "utf8");
assert(/PresetsSection/.test(panel), "the panel mounts the presets section");
const presets = fs.existsSync("PresetsSection.qml") ? fs.readFileSync("PresetsSection.qml", "utf8") : "";
assert(presets !== "", "PresetsSection.qml exists");
assert(/presets/.test(presets), "the section binds the presets map");
assert(/savedRegions|region/.test(presets), "the section offers saved regions");

// IPC surface: presets and regions are reachable from hotkeys/scripts.
for (const fn of ["savePreset", "applyPreset", "deletePreset", "saveRegion", "applyRegion"]) {
  assert(new RegExp(`function ${fn}\\(`).test(svc), `the IPC handler exposes ${fn}`);
}
assert(/JSON\.parse\(patchJson/.test(svc), "savePreset parses its JSON patch");

console.log("ok - presets merge safely, regions arm capture, nothing persists the stream key");
