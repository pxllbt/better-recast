// Asserts that GpuProbe.js and Config.js implement dual-GPU auto-detection,
// active DRM render-node resolution, and hardware auto-profiling.
const fs = require("fs");
const assert = require("node:assert/strict");
const vm = require("node:vm");

const gpuSrc = fs.readFileSync("GpuProbe.js", "utf8").replace(/^\.pragma.*$/gm, "");
const sandbox = { console };
const GpuProbe = vm.runInNewContext(gpuSrc + "\nthis", sandbox);

const configSrc = fs.readFileSync("Config.js", "utf8").replace(/^\.pragma.*$/gm, "");
const Config = vm.runInNewContext(configSrc + "\nthis", sandbox);

// 1. parseDrmCards parses multiple GPU devices
assert(typeof GpuProbe.parseDrmCards === "function",
  "GpuProbe.parseDrmCards function exists");

const sampleDrm = `
card0: /sys/class/drm/card0 (AMD Radeon 780M iGPU)
card0-eDP-1: connected
card1: /sys/class/drm/card1 (NVIDIA GeForce RTX 4070 dGPU)
card1-HDMI-A-1: connected
`;

const cards = GpuProbe.parseDrmCards(sampleDrm);
assert.equal(cards.length, 2, "detects both iGPU and dGPU cards");
assert.equal(cards[0].name, "card0");
assert.equal(cards[1].name, "card1");

// 2. resolveOptimalRenderNode maps the active display output to the driving GPU
assert(typeof GpuProbe.resolveOptimalRenderNode === "function",
  "GpuProbe.resolveOptimalRenderNode exists");

// When HDMI-A-1 is the active monitor, routes to card1 (dGPU)
const chosenDgpu = GpuProbe.resolveOptimalRenderNode(cards, "HDMI-A-1");
assert.equal(chosenDgpu.name, "card1", "routes external monitor to discrete GPU");

// When eDP-1 (laptop display) is active, routes to card0 (iGPU)
const chosenIgpu = GpuProbe.resolveOptimalRenderNode(cards, "eDP-1");
assert.equal(chosenIgpu.name, "card0", "routes internal panel to integrated GPU");

// 3. Config.resolveProfile with lowPower battery optimization
const baseCfg = { codec: "auto", quality: "auto", lowPower: true };
const amdGpu = { vendor: "amd", codecs: ["hevc", "h264"] };
const resolved = Config.resolveProfile(baseCfg, amdGpu);
assert.equal(resolved.codec, "hevc", "selects high efficiency HEVC for AMD");
assert.equal(resolved.lowPower, true, "preserves lowPower flag for battery savings");

console.log("ok - dual-GPU routing and hardware auto-profiling verified");
