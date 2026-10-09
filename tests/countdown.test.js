// Regression tests for the pre-roll countdown and the gsr version probe.
// Run from the plugin root:  node tests/countdown.test.js
const fs = require("fs");
const assert = require("assert");

const src = fs.readFileSync("Service.qml", "utf8");
const panel = fs.readFileSync("Panel.qml", "utf8");

// ── countdown must not enter the recorder state machine ─────────────────
// The countdown used to set state="starting", which flips `busy`, so the
// deferred start() hit `if (active || busy) return` and recording never began.
const guardIdx = src.indexOf("function start(targetType)");
assert(guardIdx >= 0, "start(targetType) exists");
const guardEnd = src.indexOf('var streamMode = config.mode', guardIdx);
const startBody = src.slice(guardIdx, guardEnd);
assert(!/state = "starting"/.test(startBody),
  "countdown must not set state=starting (busy would deadlock start())");
assert(/countdownTarget = targetType/.test(startBody),
  "countdown must remember the real target type");
assert(/if \(countdownPending\)\s*\n\s*return;/.test(startBody),
  "a second press must not stack countdowns");

// ── stop() and toggle() must abort an in-flight countdown ───────────────
// Otherwise the recorder starts after the user already cancelled it.
for (const fn of ["stop", "toggle"]) {
  const i = src.indexOf(`function ${fn}(`);
  assert(i >= 0, `${fn}() exists`);
  const end = src.indexOf("\n    function ", i + 10);
  const body = src.slice(i, end < 0 ? undefined : end);
  assert(/countdownPending/.test(body) && /cancelCountdown\(\)/.test(body),
    `${fn}() must cancel a pending countdown`);
}

// ── timer counts down visibly, then starts with the stored target ───────
const t = src.slice(src.indexOf("id: countdownTimer"), src.indexOf("id: elapsedTimer"));
assert(/countdownTimer\.restart\(\)/.test(t), "timer must tick down");

assert(!/root\.start\(lastTarget\)/.test(src),
  "must not feed the display string back into start(targetType)");

// ── the countdown is mirrored into state.json for the replacement bar ──
assert(/onCountdownRemainingChanged:\s*\{\s*flushState\(\)/.test(src),
  "countdown tick must flush state.json");
assert(/onCountdownPendingChanged:\s*\{\s*flushState\(\)/.test(src),
  "countdown start must flush state.json");
assert(/countdownRemaining: root\.countdownRemaining/.test(src),
  "countdownRemaining must be in statusJson");
assert(/countdownPending: root\.countdownPending/.test(src),
  "countdownPending must be in statusJson");

// ── config: countdown default + validation ─────────────────────────────
const cfg = fs.readFileSync("Config.js", "utf8");
assert(/countdown:\s*0,/.test(cfg), "countdown defaults to off");
assert(/k === "countdown"/.test(cfg), "countdown is validated as a number");

// ── panel: dropdown + visible countdown ────────────────────────────────
assert(/text: "Countdown"/.test(panel), "panel has a Countdown label");
assert(/countdownDropdown/.test(panel), "panel has a countdown dropdown");
assert(/Starting in /.test(panel), "panel shows the countdown on the button");
assert(/readonly property bool countdownPending/.test(panel),
  "panel resolves countdownPending live");

// ── gsr version probe: --version prints a bare "6.1.0" ─────────────────
// A parser anchored on the program name never matched, so the update
// notice stayed hidden forever.
const v = src.slice(src.indexOf("id: gsrVerProc"), src.indexOf("id: gsrLatestProc"));
const bareParse = /text\.match\(\/\(\\d\+\\\.\\d\+\\\.\\d\+\)\/\)/.test(v);
assert(bareParse, "version parser must accept a bare semver line");

// ── panel update notice: children must qualify the parent's property ───
// Bare `st` threw "ReferenceError: st is not defined" and broke the panel.
const notice = panel.slice(panel.indexOf("id: gsrUpdateNotice"));
const noticeEnd = notice.indexOf("Primary action button");
const noticeBody = notice.slice(0, noticeEnd < 0 ? 1400 : noticeEnd);
// `st` on the Item's own `visible` binding IS in scope; only child objects
// need it qualified, so flag a bare `st.` that is not preceded by `.`.
assert(!/(?<![.\w])st\.(gsrVersion|gsrLatest|gsrUpdateAvailable)/.test(
    noticeBody.split("\n").filter(l => !/visible:/.test(l)).join("\n")),
  "child objects must qualify st (bare st is out of scope in QML)");
assert(/gsrUpdateNotice\.st\.gsrVersion/.test(noticeBody),
  "update notice reads gsrUpdateNotice.st.gsrVersion");

// ── QML will not generate a change handler for an underscore property ───
// `property bool _pending` + `on_PendingChanged` fails the whole file with
// "Cannot assign to non-existent property", taking the service down with it.
// Only properties that HAVE a change handler may not be underscore-prefixed:
// QML refuses `on<name>Changed` for those and fails the whole file. Internal
// flags with no handler (e.g. _countdownSpent) are fine either way.
for (const name of ["countdownPending", "countdownRemaining"]) {
  assert(new RegExp(`property\\s+\\w+\\s+${name}\\b`).test(src),
    `${name} must be a plain (non-underscore) property`);
  assert(!new RegExp(`property\\s+\\w+\\s+_${name}\\b`).test(src),
    `_${name} would make on${name}Changed unassignable`);
}
// The pre-roll must hand off to beginRecording(), never back through start().
// Routing it through start() re-entered the countdown branch on every tick and
// looped 3-2-1-3-2-1 forever without ever recording.
assert(/function beginRecording\(targetType\)/.test(src),
  "beginRecording() must exist as the countdown hand-off target");
assert(/beginRecording\(targetType\);[\s\S]{0,10}\}/.test(startBody),
  "start() must delegate to beginRecording() when there is no countdown");
assert(/root\.beginRecording\(t\)/.test(t),
  "the timer must call beginRecording(), not start()");
assert(!/root\.start\(/.test(t),
  "the timer must not re-enter start() (that re-arms the countdown)");
assert(!/_countdownSpent/.test(src),
  "the re-entrant bypass flag must be gone");

console.log("ok - countdown + version probe + update notice");
