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

console.log("  passed: " + passed + "  failed: " + failed);
process.exit(failed === 0 ? 0 : 1);
