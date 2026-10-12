// Disk-space guard: a recording must not start when free space is below the
// configured floor, and a failed df probe must not block the launch.
// Run from the plugin root:  node tests/guard.test.js
const fs = require("fs");
const vm = require("node:vm");
const assert = require("node:assert/strict");
const { execSync } = require("node:child_process");

const source = fs.readFileSync("Config.js", "utf8").replace(/^\.pragma.*$/gm, "");
const Config = vm.runInNewContext(source + "\nthis", {});

// Real df output parses to a positive kilobyte count.
const real = execSync("df -Pk /").toString();
const kb = Config.parseDfAvailKb(real);
assert(typeof kb === "number" && kb > 0, "real df output parses to positive kB");

// Unparseable output reports -1 so the caller can distinguish it.
assert.equal(Config.parseDfAvailKb("garbage\n"), -1, "garbage → -1");
assert.equal(Config.parseDfAvailKb(""), -1, "empty → -1");

// The decision: below the floor refuses, above allows, unknown allows.
assert.equal(Config.diskAllows(5000000, 2000), true, "plenty of space allows");
assert.equal(Config.diskAllows(1000, 2000), false, "below the floor refuses");
assert.equal(Config.diskAllows(-1, 2000), true, "a failed probe never blocks recording");
assert.equal(Config.diskAllows(0, 0), true, "a zero floor always allows");
assert.equal(Config.diskAllows(2048 * 1024, 2048), true, "exactly the floor allows");

// normalize() pins the key's type and clamps.
const d = Config.defaultConfig().minFreeDiskMb;
assert.equal(Config.normalize({ minFreeDiskMb: "lots" }).minFreeDiskMb, d, "strings fall back");
assert.equal(Config.normalize({ minFreeDiskMb: -5 }).minFreeDiskMb, d,
  "negatives fall back to the default (a guard-off floor is worse)");
assert.equal(Config.normalize({ minFreeDiskMb: 999999999 }).minFreeDiskMb, 1000000, "huge clamps to 1e6");
assert.equal(Config.normalize({ minFreeDiskMb: 500 }).minFreeDiskMb, 500, "valid values pass through");

// Service structure: the guard runs before the process is ever spawned.
const svc = fs.readFileSync("Service.qml", "utf8");
assert(/function launchRecording\(target, streamMode\)/.test(svc),
  "beginRecording delegates the launch to launchRecording()");
const begin = svc.slice(svc.indexOf("function beginRecording(targetType)"),
                       svc.indexOf("function launchRecording(target, streamMode)"));
assert(/diskProbe\.running = true/.test(begin),
  "beginRecording arms the disk probe before launching");
assert(/_pendingTarget/.test(begin),
  "the launch is deferred through a stash property");
// The mode must be re-derived at launch time, not stashed: the user can flip
// it while the countdown or the disk probe is in flight.
assert(/var streamMode = config\.mode === "stream"/.test(svc.slice(svc.indexOf("id: diskProbe"), svc.indexOf("Component.onCompleted", svc.indexOf("id: diskProbe")))),
  "the probe handler re-derives streamMode from the live config");
assert(!/_pendingStream/.test(svc), "no stashed streamMode (it would go stale)");
assert(/state = "idle"/.test(svc.slice(svc.indexOf("id: diskProbe"), svc.indexOf("Component.onCompleted", svc.indexOf("id: diskProbe")))),
  "a refused launch resets state to idle — no stuck starting");
// A pure stream writes no local file, so it must skip the disk probe entirely.
assert(/streamMode && !config\.streamBackupLocal\)\s*\n\s*launchRecording/.test(begin),
  "a stream without a local backup bypasses the disk guard");
assert(/df -Pk/.test(svc), "the probe reads free space with df -Pk");
// The probe must hand the parser the full df table: parseDfAvailKb reads the
// avail-kB column itself, so an awk-extracted bare number would parse as -1
// (probe failed ⇒ guard silently disabled). This exact mismatch shipped once
// during development — the guard failed open while tests stayed green.
const probeStart = svc.indexOf("id: diskProbe");
assert(probeStart >= 0, "the diskProbe Process exists");
const cmdLine = svc.slice(probeStart).split("\n").find(l => /command:/.test(l));
assert(/df -Pk/.test(cmdLine) && !/awk/.test(cmdLine),
  "the probe command feeds the full df table to the parser (no awk pre-extraction)");
const probeBlock = svc.slice(probeStart, svc.indexOf("function pickRegion", probeStart));
assert(/parseDfAvailKb\(text\)/.test(probeBlock),
  "the probe handler parses through Config.parseDfAvailKb");
assert(/id: diskProbe/.test(svc), "the diskProbe Process exists");

console.log("ok - disk guard refuses below the floor and never blocks on a failed probe");
