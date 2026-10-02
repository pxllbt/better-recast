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
    const c = Config.normalize({ overlayMode: "sideways", overlayPrevMode: "float", overlaySeconds: 99, overlayEdge: "top", overlayPinned: "true" });
    assert.deepEqual([c.overlayMode, c.overlayPrevMode, c.overlaySeconds, c.overlayEdge, c.overlayPinned],
        ["auto", "auto", 60, "top", true]);
});

const Picker = load("Picker.js");

const HYPR_MONITORS = [
    { name: "DP-10", x: 2560, y: 0, width: 2560, height: 1440, scale: 1, transform: 0, activeWorkspace: { id: 1 }, specialWorkspace: { id: 0 } },
    { name: "eDP-1", x: 0, y: 0, width: 2880, height: 1800, scale: 1.5, transform: 0, activeWorkspace: { id: 2 }, specialWorkspace: { id: -98 } },
    { name: "DP-9", x: 5120, y: 0, width: 2560, height: 1440, scale: 1, transform: 1, activeWorkspace: { id: 3 }, specialWorkspace: { id: 0 } },
];
function client(ws, at, size, extra) {
    return Object.assign({ address: "0x" + at.join("") + size.join(""), workspace: { id: ws }, at, size, floating: false, hidden: false, mapped: true, fullscreen: 0 }, extra);
}
const PICK_MONITORS = Picker.monitorRects(HYPR_MONITORS);

test("monitorRects divides by scale and swaps rotated sides", () => {
    assert.deepEqual(PICK_MONITORS.map(m => Picker.formatGeometry(m)), ["2560x1440+2560+0", "1920x1200+0+0", "1440x2560+5120+0"]);
});

test("windowRects keeps active and special workspaces, drops hidden ones and other workspaces", () => {
    const clients = [
        client(1, [2570, 40], [1000, 700]),
        client(5, [2570, 40], [400, 300]),
        client(1, [2570, 800], [400, 300], { hidden: true }),
        client(-98, [100, 100], [800, 600], { floating: true }),
    ];
    assert.deepEqual(Picker.windowRects(clients, HYPR_MONITORS), [
        { x: 2570, y: 40, w: 1000, h: 700, layer: 0 },
        { x: 100, y: 100, w: 800, h: 600, layer: 3 },
    ]);
});

test("a fullscreen window hides the tiled windows of its workspace, not the floating ones", () => {
    const clients = [
        client(1, [2560, 0], [2560, 1440], { fullscreen: 2 }),
        client(1, [2570, 40], [1000, 700]),
        client(1, [3000, 300], [500, 400], { floating: true }),
    ];
    assert.deepEqual(Picker.windowRects(clients, HYPR_MONITORS).map(r => Picker.formatGeometry(r)), ["2560x1440+2560+0", "500x400+3000+300"]);
});

test("windowAt: floating over tiled, smallest within a layer, null outside", () => {
    const tiled = { x: 0, y: 0, w: 500, h: 500, layer: 0 };
    const smallTiled = { x: 100, y: 100, w: 100, h: 100, layer: 0 };
    const floating = { x: 50, y: 50, w: 300, h: 300, layer: 1 };
    assert.equal(Picker.windowAt([tiled, floating], 60, 60), floating);
    assert.equal(Picker.windowAt([floating, smallTiled, tiled], 150, 150), floating);
    assert.equal(Picker.windowAt([tiled, smallTiled], 150, 150), smallTiled);
    assert.equal(Picker.windowAt([tiled, floating], 600, 600), null);
    assert.equal(Picker.windowAt([tiled], 500, 10), null);
});

test("dragRect normalizes a drag in any direction", () => {
    assert.equal(Picker.formatGeometry(Picker.dragRect(100, 200, 40, 50)), "60x150+40+50");
    assert.equal(Picker.formatGeometry(Picker.dragRect(2600.4, 10, 2700.6, 20.2)), "101x10+2600+10");
});

test("a drag under 20px^2 counts as a click", () => {
    assert.equal(Picker.isClick(Picker.dragRect(10, 10, 13, 16)), true);
    assert.equal(Picker.isClick(Picker.dragRect(10, 10, 14, 15)), false);
});

test("monitorAt and specForRect map a whole-monitor rect to the monitor", () => {
    assert.equal(Picker.monitorAt(PICK_MONITORS, 5119, 10).name, "DP-10");
    assert.equal(Picker.monitorAt(PICK_MONITORS, 100, 1300), null);
    assert.equal(Picker.specForRect({ x: 0, y: 0, w: 1920, h: 1200 }, PICK_MONITORS), "monitor:eDP-1");
    assert.equal(Picker.specForRect({ x: 0, y: 0, w: 1920, h: 1199 }, PICK_MONITORS), "1920x1199+0+0");
});

test("clickSpec picks the window under the click, else the monitor", () => {
    const wins = [{ x: 2570, y: 40, w: 1000, h: 700, layer: 0 }];
    assert.equal(Picker.clickSpec(wins, PICK_MONITORS, 2600, 100), "1000x700+2570+40");
    assert.equal(Picker.clickSpec(wins, PICK_MONITORS, 4000, 1000), "monitor:DP-10");
    assert.equal(Picker.clickSpec(wins, PICK_MONITORS, -50, -50), "");
});

test("specFromCaptureRegion reads omarchy-capture-region output", () => {
    assert.equal(Picker.specFromCaptureRegion("40,-50 60x150\n"), "60x150+40+-50");
    assert.equal(Picker.specFromCaptureRegion("monitor:DP-9"), "monitor:DP-9");
    assert.equal(Picker.specFromCaptureRegion(""), "");
});

test("targetFromSpec turns a spec into a capture target", () => {
    assert.deepEqual(Picker.targetFromSpec("60x150+40+50"), { type: "region", geometry: "60x150+40+50" });
    assert.deepEqual(Picker.targetFromSpec("monitor:DP-9"), { type: "monitor", name: "DP-9" });
    assert.equal(Picker.targetFromSpec(""), null);
    assert.equal(Picker.targetFromSpec("monitor:"), null);
});

test("regionForStart: a fresh pick, else the saved region unless asking each time", () => {
    const saved = { region: "", _lastRegion: "800x600+0+0", regionAskEachTime: false };
    assert.equal(Picker.regionForStart(saved, ""), "800x600+0+0");
    assert.equal(Picker.regionForStart(saved, "monitor:DP-9"), "monitor:DP-9");
    assert.equal(Picker.regionForStart(Object.assign({}, saved, { regionAskEachTime: true }), ""), "");
    assert.equal(Picker.regionForStart(Object.assign({}, saved, { regionAskEachTime: true }), "10x10+5+5"), "10x10+5+5");
    assert.equal(Picker.regionForStart({ region: "", _lastRegion: "" }, ""), "");
});

test("normalize keeps regionAskEachTime a boolean, off by default", () => {
    assert.equal(Config.normalize({}).regionAskEachTime, false);
    assert.equal(Config.normalize({ regionAskEachTime: "true" }).regionAskEachTime, true);
});

console.log("  passed: " + passed + "  failed: " + failed);
process.exit(failed === 0 ? 0 : 1);
