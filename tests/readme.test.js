// The README documents the new surface: hotkeys, settings, presets, trim,
// the OSD, and the state-file locations. Keeping it pinned by a test stops
// the docs from drifting away from the code again.
// Run from the plugin root:  node tests/readme.test.js
const fs = require("fs");
const assert = require("node:assert/strict");

const readme = fs.readFileSync("README.md", "utf8");

// Hotkey table — both config forms (Hyprland's "SUPER+ALT, R" and Omarchy's
// "SUPER + ALT + R" lua helper).
const combo = (k) => new RegExp(`SUPER\\s*\\+\\s*ALT\\s*[,+]\\s*${k}\\b`);
for (const key of ["R", "S", "P", "O"]) {
  assert(combo(key).test(readme), `the README documents the SUPER+ALT+${key} hotkey`);
}
assert(/bind = SUPER/.test(readme), "the README shows hyprland .conf bindings");
assert(/o\.bind\(/.test(readme), "the README shows hyprland .lua bindings");

// Features that exist in this version (hyphen/spacing tolerant).
const feat = (f) => new RegExp(f.replace(/ /g, "[- ]"), "i");
for (const feature of ["Recording OSD", "presets", "region", "Trim", "recent",
                       "disk space", "template", "application audio"]) {
  assert(feat(feature).test(readme), `the README mentions ${feature}`);
}

// Settings reference for the keys added in this round of work.
for (const key of ["minFreeDiskMb", "fileNameTemplate", "organizeByDate",
                   "osdEnabled", "osdPosition"]) {
  assert(readme.includes(key), `the README documents the ${key} setting`);
}

// The state locations users need when things look wrong.
assert(/pix-recast\/presets\.json/.test(readme),
  "the README says where presets live");

console.log("ok - README documents the hotkeys, features and settings");
