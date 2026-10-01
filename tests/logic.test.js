// Pure-logic tests for the `.pragma library` JS modules. Run: node tests/logic.test.js
"use strict";

const fs = require("fs");
const path = require("path");
const assert = require("assert/strict");

const PLUGIN_DIR = path.join(__dirname, "..");

// QML JS libraries are plain scripts with a `.pragma library` header; evaluate
// one in this realm and hand back its top-level functions and vars.
function load(file) {
    const src = fs.readFileSync(path.join(PLUGIN_DIR, file), "utf8").replace(/^\.pragma library\s*$/m, "");
    const names = [...src.matchAll(/^(?:function|var)\s+([A-Za-z_$][\w$]*)/gm)].map(m => m[1]);
    return new Function(src + "\nreturn { " + names.join(", ") + " };")();
}

let passed = 0;
let failed = 0;
function test(name, fn) {
    try {
        fn();
        passed++;
        console.log("  ok: " + name);
    } catch (e) {
        failed++;
        console.log("  FAIL: " + name + "\n    " + String(e.message).split("\n").join("\n    "));
    }
}

const Config = load("Config.js");
const PostProcess = load("PostProcess.js");

test("parseMimeApps keeps default first and drops repeats", () => {
    const gio = fs.readFileSync(path.join(__dirname, "fixtures/gio-mime-video-mp4.txt"), "utf8");
    assert.deepEqual(PostProcess.parseMimeApps(gio), ["mpv.desktop", "omacut.desktop", "org.kde.kdenlive.desktop", "vlc.desktop"]);
});

test("post-process command for a desktop app uses gtk-launch", () => {
    assert.deepEqual(PostProcess.command({ postProcessApp: "org.kde.kdenlive.desktop" }, "/v/a b.mp4"),
        ["gtk-launch", "org.kde.kdenlive", "/v/a b.mp4"]);
});

test("post-process custom command gets the file as $1", () => {
    assert.deepEqual(PostProcess.command({ postProcessApp: "custom", postProcessCommand: "handbrake --input" }, "/v/a.mp4"),
        ["bash", "-c", 'handbrake --input "$1"', "_", "/v/a.mp4"]);
});

test("post-process is off when unset or custom is empty", () => {
    assert.equal(PostProcess.command({ postProcessApp: "" }, "/v/a.mp4"), null);
    assert.equal(PostProcess.command({ postProcessApp: "custom", postProcessCommand: "  " }, "/v/a.mp4"), null);
});

test("shellQuote survives single quotes", () => {
    assert.equal(PostProcess.shellQuote("/opt/it's here/app"), "'/opt/it'\\''s here/app'");
});

test("normalize rejects a postProcessApp that is not a desktop id", () => {
    assert.equal(Config.normalize({ postProcessApp: "rm -rf ~" }).postProcessApp, "");
    assert.equal(Config.normalize({ postProcessApp: "vlc.desktop" }).postProcessApp, "vlc.desktop");
    assert.equal(Config.normalize({ postProcessApp: "custom" }).postProcessApp, "custom");
});

const Binds = load("Binds.js");
const PREFIX = Binds.DESCRIPTION_PREFIX;
const takenBy = (...combos) => c => combos.includes(c);
const action = id => Binds.ACTIONS.find(a => a.id === id);

test("parseCombo/formatCombo normalize modifier order and case", () => {
    assert.deepEqual(Binds.parseCombo("alt + super + p"), { mask: 72, key: "P" });
    assert.equal(Binds.formatCombo(72, "p"), "SUPER + ALT + P");
    assert.equal(Binds.normalizeCombo("shift+control+super+alt+f12"), "SUPER + CTRL + ALT + SHIFT + F12");
    assert.equal(Binds.normalizeCombo("Print"), "PRINT");
});

test("parseCombo rejects junk", () => {
    assert.equal(Binds.parseCombo(""), null);
    assert.equal(Binds.parseCombo("SUPER + ALT"), null);
    assert.equal(Binds.parseCombo("SUPER + P + Q"), null);
    assert.equal(Binds.parseCombo('SUPER + "); os.exit()'), null);
});

test("parseConfigBinds finds px-recast exec binds, legacy pause included", () => {
    const tsv = fs.readFileSync(path.join(__dirname, "fixtures/hypr/binds.tsv"), "utf8");
    assert.deepEqual(Binds.parseConfigBinds(tsv), { cancel: "CTRL + ALT + PRINT", pause: "SUPER + ALT + SHIFT + P" });
});

test("parseConfigBinds keeps the first bind per action and ignores stopReplay", () => {
    const tsv = "72\ta\tS\texec\tomarchy-shell px-recast stop\n76\tb\tS\texec\tomarchy-shell px-recast stop\n8\tc\tQ\texec\tomarchy-shell px-recast stopReplay\n";
    assert.deepEqual(Binds.parseConfigBinds(tsv), { stop: "SUPER + ALT + S" });
});

test("isTaken ignores our own binds and submaps", () => {
    const binds = [
        { modmask: 72, key: "P", submap: "", description: PREFIX + "Pause / resume" },
        { modmask: 72, key: "s", submap: "", description: "Something else" },
        { modmask: 72, key: "X", submap: "resize", description: "Submap only" },
    ];
    assert.equal(Binds.isTaken(binds, "SUPER + ALT + P", PREFIX), false);
    assert.equal(Binds.isTaken(binds, "SUPER + ALT + S", PREFIX), true);
    assert.equal(Binds.isTaken(binds, "SUPER + ALT + X", PREFIX), false);
    assert.deepEqual(Binds.ownedCombos(binds, PREFIX), ["SUPER + ALT + P"]);
});

test("autoCombo walks SUPER+ALT, SUPER+CTRL+ALT, then the next letters", () => {
    assert.equal(Binds.autoCombo(action("stop"), takenBy(), {}), "SUPER + ALT + S");
    assert.equal(Binds.autoCombo(action("stop"), takenBy("SUPER + ALT + S"), {}), "SUPER + CTRL + ALT + S");
    assert.equal(Binds.autoCombo(action("stop"), takenBy("SUPER + ALT + S", "SUPER + CTRL + ALT + S"), {}), "SUPER + ALT + T");
    assert.equal(Binds.autoCombo(action("stop"), takenBy("SUPER + ALT + S", "SUPER + CTRL + ALT + S"), { "SUPER + ALT + T": true }), "SUPER + ALT + U");
});

test("autoCombo wraps from Z to A and skips its own letter", () => {
    const taken = c => c !== "SUPER + ALT + A" && c.startsWith("SUPER + ALT + ") || c.startsWith("SUPER + CTRL");
    assert.equal(Binds.autoCombo({ letter: "X" }, taken, {}), "SUPER + ALT + A");
});

test("resolve: override beats config beats auto", () => {
    const config = { bindPause: "super+shift+p", bindStop: "", bindCancel: "", bindSaveReplay: "" };
    const configBinds = { pause: "CTRL + ALT + P", stop: "CTRL + ALT + S" };
    assert.deepEqual(Binds.resolve(config, configBinds, takenBy()), {
        pause: { combo: "SUPER + SHIFT + P", source: "override", conflict: false },
        stop: { combo: "CTRL + ALT + S", source: "config", conflict: false },
        cancel: { combo: "SUPER + ALT + X", source: "auto", conflict: false },
        saveReplay: { combo: "SUPER + ALT + R", source: "auto", conflict: false },
    });
});

test("resolve flags a taken override and keeps auto off its combo", () => {
    const config = { bindPause: "", bindStop: "SUPER + ALT + X", bindCancel: "", bindSaveReplay: "" };
    const r = Binds.resolve(config, {}, takenBy("SUPER + ALT + X"));
    assert.deepEqual(r.stop, { combo: "SUPER + ALT + X", source: "override", conflict: true });
    assert.deepEqual(r.cancel, { combo: "SUPER + CTRL + ALT + X", source: "auto", conflict: false });
    assert.deepEqual(Binds.managed(r, "record").map(e => e.action.id + "=" + e.combo),
        ["pause=SUPER + ALT + P", "cancel=SUPER + CTRL + ALT + X"]);
});

test("resolve: an override equal to the action's own bindings.lua bind is not a conflict", () => {
    const config = { bindPause: "", bindStop: "", bindCancel: "CTRL + ALT + PRINT", bindSaveReplay: "" };
    const r = Binds.resolve(config, { cancel: "CTRL + ALT + PRINT" }, takenBy("CTRL + ALT + PRINT"));
    assert.deepEqual(r.cancel, { combo: "CTRL + ALT + PRINT", source: "override", conflict: false });
});

test("syncScript clears stale and target combos of our binds, then binds", () => {
    const e = (id, combo) => ({ action: action(id), combo });
    const script = Binds.syncScript([e("pause", "SUPER + ALT + P"), e("stop", "SUPER + ALT + S")],
        [e("stop", "SUPER + ALT + S"), e("cancel", "SUPER + ALT + X")], PREFIX);
    const guard = (m, k) => "hyprctl binds -j | jq -e --argjson m " + m + " --arg k " + k + " --arg p 'Better Recast: '"
        + " '[.[] | select(.modmask == $m and (.key | ascii_upcase) == $k and .submap == \"\")] | all(.description | startswith($p))' >/dev/null"
        + " && hyprctl eval 'hl.unbind(\"SUPER + ALT + " + k + "\")'";
    assert.equal(script,
        guard(72, "P") + "\n" + guard(72, "X") + "\n"
        + "hyprctl eval 'hl.bind(\"SUPER + ALT + X\", hl.dsp.exec_cmd(\"omarchy-shell px-recast cancel\"), { description = \"Better Recast: Cancel (discard)\" })'");
    assert.equal(Binds.syncScript([e("stop", "SUPER + ALT + S")], [e("stop", "SUPER + ALT + S")], PREFIX), "");
});

const Placement = load("Placement.js");
const DP10 = { name: "DP-10", x: 2560, y: 0, width: 2560, height: 1440 };
const DP9 = { name: "DP-9", x: 5200, y: 0, width: 2560, height: 1440 };
const TWO = [DP10, DP9];

test("regionRect parses WxH+X+Y", () => {
    assert.deepEqual(Placement.regionRect("800x600+5000+-20"), { x: 5000, y: -20, w: 800, h: 600 });
    assert.equal(Placement.regionRect("junk"), null);
});

test("recordedScreens: monitor, spanning region (focused first), portal", () => {
    assert.deepEqual(Placement.recordedScreens({ type: "monitor", name: "DP-9" }, TWO, "DP-10"), ["DP-9"]);
    assert.deepEqual(Placement.recordedScreens({ type: "region", geometry: "800x600+4800+100" }, TWO, "DP-9"), ["DP-9", "DP-10"]);
    assert.deepEqual(Placement.recordedScreens({ type: "region", geometry: "100x100+3000+100" }, TWO, "DP-9"), ["DP-10"]);
    assert.deepEqual(Placement.recordedScreens({ type: "portal" }, TWO, "DP-10"), ["DP-10"]);
});

test("auto puts the overlay on the free screen, facing the recording", () => {
    assert.deepEqual(Placement.choosePlacement("auto", ["DP-9"], TWO, "right"), { screen: "DP-10", edge: "right", kind: "pinned" });
    assert.deepEqual(Placement.choosePlacement("auto", ["DP-10"], TWO, "right"), { screen: "DP-9", edge: "left", kind: "pinned" });
});

test("a region on one screen keeps the overlay on the other, wherever focus is", () => {
    const region = { type: "region", geometry: "1261x686+6487+742" };
    for (const focused of ["DP-9", "DP-10"])
        assert.deepEqual(Placement.choosePlacement("auto", Placement.recordedScreens(region, TWO, focused), TWO, "right"), { screen: "DP-10", edge: "right", kind: "pinned" });
});

test("auto with no free screen peeks from the edge setting", () => {
    assert.deepEqual(Placement.choosePlacement("auto", ["DP-10"], [DP10], "top"), { screen: "DP-10", edge: "top", kind: "peek" });
    assert.deepEqual(Placement.choosePlacement("auto", ["DP-9", "DP-10"], TWO, "left"), { screen: "DP-9", edge: "left", kind: "peek" });
});

test("pin, timed, float and off", () => {
    assert.deepEqual(Placement.choosePlacement("pin", ["DP-10"], [DP10], "bottom"), { screen: "DP-10", edge: "bottom", kind: "pinned" });
    assert.deepEqual(Placement.choosePlacement("timed", ["DP-9"], TWO, "bottom"), { screen: "DP-10", edge: "right", kind: "peek" });
    assert.deepEqual(Placement.choosePlacement("float", ["DP-9"], TWO, "bottom"), { screen: "DP-10", edge: "right", kind: "float" });
    assert.equal(Placement.choosePlacement("off", ["DP-9"], TWO, "bottom"), null);
});

test("the free screen nearest the recording wins, stacked vertically too", () => {
    const top = { name: "TOP", x: 0, y: -1080, width: 1920, height: 1080 };
    const main = { name: "MAIN", x: 0, y: 0, width: 1920, height: 1080 };
    const far = { name: "FAR", x: 5000, y: 0, width: 1920, height: 1080 };
    assert.deepEqual(Placement.choosePlacement("auto", ["MAIN"], [far, top, main], "right"), { screen: "TOP", edge: "bottom", kind: "pinned" });
});

test("normalize clamps and validates overlay keys", () => {
    const c = Config.normalize({ overlayMode: "sideways", overlayPrevMode: "float", overlaySeconds: 99, overlayEdge: "top", overlayFloatX: "abc", overlayFloatY: 120.6, overlayPinned: "true" });
    assert.deepEqual([c.overlayMode, c.overlayPrevMode, c.overlaySeconds, c.overlayEdge, c.overlayFloatX, c.overlayFloatY, c.overlayPinned],
        ["auto", "auto", 60, "top", -1, 121, true]);
});

console.log("  passed: " + passed + "  failed: " + failed);
process.exit(failed === 0 ? 0 : 1);
