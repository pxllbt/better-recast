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

console.log("  passed: " + passed + "  failed: " + failed);
process.exit(failed === 0 ? 0 : 1);
