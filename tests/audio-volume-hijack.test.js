// The plugin must not drive the system volume unless the user opted in.
//
// Three separate defects, all observed live:
//
//  1. HIJACK. applyVolume() ran unconditionally and set @DEFAULT_AUDIO_SINK@ to
//     `audioVolume` (100 by default) the moment a recording started. Music jumped
//     to full volume for the length of every take and dropped back on stop.
//     Measured: user set 0.25, recording forced 0.65 mid-transition.
//
//  2. DESTRUCTIVE RESTORE. The saved levels were seeded with 1.0 / 0.0 *before*
//     the async read landed. A short recording stops before the read completes,
//     so restoreVolume() wrote the seeded 1.0 back over the user's real level --
//     the setting was destroyed, not merely overridden. Measured: 0.25 -> 1.00
//     after a single record/stop cycle.
//
//  3. MIC ALWAYS MUTED. `wpctl get-volume @A@ @B@` prints only the FIRST node,
//     so the old `awk '{print $2, $4}'` read an empty $4 for the source. The
//     saved mic level stayed 0.0 and every restoreVolume() set the microphone
//     to 0%.
//
// gsr captures the stream regardless of the sink level, so none of this affects
// what ends up in the recording. The fix is an explicit opt-in, default off.
//
// Run from the plugin root:  node tests/audio-volume-hijack.test.js
const fs = require("fs");
const assert = require("node:assert/strict");

const svc = fs.readFileSync("Service.qml", "utf8");
const cfg = fs.readFileSync("Config.js", "utf8");

const applyBlock = svc.slice(svc.indexOf("function applyVolume()"),
                             svc.indexOf("function setWpctlVolume("));
assert(applyBlock.length > 0, "applyVolume is locatable");
const restoreBlock = svc.slice(svc.indexOf("function restoreVolume()"),
                               svc.indexOf("function setSessionConfig("));
assert(restoreBlock.length > 0, "restoreVolume is locatable");

// --- the opt-in exists and defaults to off -------------------------------
assert(/audioSetVolume:\s*false/.test(cfg),
  "audioSetVolume defaults to off: silence is the safe default");
assert(/audioSetVolume/.test(applyBlock),
  "applyVolume consults the opt-in before touching any node");

// The guard must come BEFORE the first setWpctlVolume in applyVolume, or the
// hijack still happens on the way to discovering the flag is off.
const guardAt = applyBlock.indexOf("if (!config.audioSetVolume)");
const firstSet = applyBlock.indexOf("setWpctlVolume(");
assert(guardAt >= 0 && firstSet >= 0 && guardAt < firstSet,
  "the opt-in guard precedes any volume write in applyVolume");

// --- no seeded defaults that can be restored over the user --------------
assert(/_savedAudioSinkVolume:\s*-1/.test(svc) && /_savedAudioSourceVolume:\s*-1/.test(svc),
  "saved levels start at 'never read', not at a plausible default");
// applyVolume must reset them to the same sentinel before each read.
assert(/_savedAudioSinkVolume = -1/.test(applyBlock) &&
       /_savedAudioSourceVolume = -1/.test(applyBlock),
  "applyVolume re-arms the sentinel before every read");

// --- restore writes nothing it did not actually read --------------------
assert(/_volumeManaged/.test(restoreBlock),
  "restore only acts when this service actually drove the volume");
assert(/_savedAudioSinkVolume >= 0/.test(restoreBlock) &&
       /_savedAudioSourceVolume >= 0/.test(restoreBlock),
  "restore skips a level whose read never completed");

// --- the broken multi-node parse is gone --------------------------------
// One node per invocation, parsed line by line. A single `awk '{print $2, $4}'`
// over `get-volume @SINK@ @SOURCE@` can never see the source.
// Comments are stripped first: the fix explains the old parse in prose, and
// grepping the raw text would match that explanation rather than code.
const code = svc.split("\n").filter((l) => !/^\s*\/\//.test(l)).join("\n");
assert(!/print \$2, \$4/.test(code),
  "the awk parse that could not see the second node is gone");
assert(/wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>\/dev\/null/.test(applyBlock) &&
       /wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>\/dev\/null/.test(applyBlock),
  "each node is read on its own");

// Bound the read handler by the next Process declaration AFTER it. wpctlProc
// happens to be declared before volReadProc, so slicing "up to wpctlProc"
// yields an empty string and every assertion below passes vacuously.
const rpAt = svc.indexOf("id: volReadProc");
const nextProc = svc.indexOf("\n        id: ", rpAt + 10);
const readHandler = svc.slice(rpAt, nextProc > rpAt ? nextProc : svc.length);
assert(readHandler.includes("onStreamFinished"), "the volReadProc handler is locatable");
assert(/split\(\/\\n\+\/\)/.test(readHandler),
  "the read handler parses one line per node");
assert(/parseFloat\(lines\[0\]\)/.test(readHandler) &&
       /lines\.length > 1 \? lines\[1\]/.test(readHandler),
  "sink and source are read from their own lines");

// --- the read handler must still respect the opt-in ---------------------
// The write path must be closed locally, not just by the caller. Both the
// negated early-return and a positive gate satisfy this.
assert(/if \(!config\.audioSetVolume\)/.test(readHandler) ||
       /if \(config\.audioSetVolume\)/.test(readHandler),
  "the read handler cannot write volumes when the opt-in is off");

console.log("ok - the plugin never touches the system volume unless asked");