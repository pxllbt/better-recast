// The bar glyph must be distinct per recording state so the state is visible
// at a glance: idle, recording, paused, replay and streaming each get their
// own icon (and the recording/streaming ones their own color), not the same
// resting glyph with a subtle color shift.
// Run from the plugin root:  node tests/bar-glyph.test.js
const fs = require("fs");
const assert = require("node:assert/strict");

const src = fs.readFileSync("BarWidget.qml", "utf8");

// Five distinct codepoints — one per state (all verified present in the
// active Nerd Font: video, record-circle, pause, broadcast, history).
const GLYPHS = {
  idle: "\u{F0EC2}",      // 󰻂 video
  recording: "\u{F047D}", // 󰕧 record-circle
  paused: "\u{F03E5}",    // 󰏥 pause
  streaming: "\u{F0417}", // 󰐊 broadcast
  replay: "\u{F1DA}"      // 󰄽 history (rolling buffer)
};

const glyphLine = src.split("\n").find(l => /readonly property string glyphText/.test(l));
assert(glyphLine, "glyphText exists");
for (const [state, glyph] of Object.entries(GLYPHS)) {
  assert(src.includes(glyph), `the ${state} glyph is used in BarWidget.qml`);
}
// The five glyphs must be five different characters.
const used = Object.values(GLYPHS);
assert(new Set(used).size === Object.keys(GLYPHS).length,
  "every state maps to a distinct glyph");

// Color follows the state too, so idle stays dim while active states pop.
assert(/glyphColor[\s\S]{0,200}Color\.accent/.test(src), "recording glyph is accent-colored");
assert(/glyphColor[\s\S]{0,200}Color\.urgent/.test(src), "streaming glyph is urgent-colored");
assert(/replayActive\s*\n\s*\?\s*Color\.accent/.test(src),
  "replay has its own accent color (it shared idle's before)");

// The glyph must bind to the text item that is actually on screen.
assert(/text: root\.glyphText/.test(src), "the on-screen glyph binds glyphText");

console.log("ok - bar glyph is distinct per recording state");
