.pragma library

// pix.recast config defaults, normalization, and encoder profile rules.
// Singleton import: used by Service.qml at startup and Panel.qml for defaults.

function defaultConfig() {
  return {
    // Recording target
    targetMode: "auto",       // "auto" | "monitor" | "region" | "portal"
    monitorName: "",           // explicit monitor (from --list-monitors)
    region: "",                // "WxH+X+Y" or ""

    // Video
    codec: "auto",            // "auto" | "h264" | "hevc" | "av1" | "vp9" | "vp8"
    encoder: "gpu",           // "gpu" | "cpu"
    bitrateMode: "auto",      // "auto" | "qp" | "vbr" | "cbr"
    quality: "auto",          // "auto" | "medium" | "high" | "very_high" | "ultra" | number (kbps for cbr)
    fps: 60,
    resolution: "",           // "" = native, "1920x1080", etc.
    frameMode: "cfr",         // "cfr" | "vfr" | "content"
    colorRange: "limited",    // "limited" | "full"
    tune: "performance",      // "performance" | "quality"
    keyInterval: 1.0,
    countdown: 3,            // 0 = off, 3/5/10 seconds
    cursor: true,

    // Audio
    audioEnabled: true,
    audioDesktop: true,
    audioMicrophone: false,
    audioCodec: "aac",        // "aac" | "opus"
    audioBitrate: 0,          // 0 = auto
    audioVolume: 100,         // 0-100, desktop audio volume
    audioMicVolume: 100,      // 0-100, microphone volume
    audioDesktopDevice: "default_output",
    audioMicDevice: "default_input",
    audioNoiseGate: false,    // noise gate/suppression via FFmpeg filter

    // Container
    container: "mp4",         // "mp4" | "mkv" | "webm"

    // Output
    outputDir: "",            // "" = auto from XDG_VIDEOS_DIR
    fileNameTemplate: "screenrecording-%Y%m%d_%H%M%S", // tokens: %Y %m %d %H %M %S
    organizeByDate: false,     // write recordings into YYYY-MM-DD subdirectories
    minFreeDiskMb: 2000,       // refuse to record below this much free space

    // Webcam overlay
    webcamEnabled: false,
    webcamDevice: "",
    webcamSize: "medium",     // "small" | "medium" | "large"

    // Streaming (reuses the recording encode pipeline with stream overrides)
    mode: "record",           // "record" | "stream" | "replay"
    streamUrl: "",            // RTMP server URL (e.g. rtmp://push.tiktokcdn.com/live/)
    streamKey: "",            // per-session stream key (not persisted unless streamRemember)
    streamKbps: 6000,         // CBR video bitrate
    streamPlatform: "custom", // "custom" | "tiktok" | "twitch" | "youtube"
    streamRemember: false,    // persist URL/key to shell.json when true
    streamBackupLocal: false, // also save a local `-ro` copy while streaming

    // Instant replay (rolling buffer, saved on command)
    replaySeconds: 60,        // buffer length in seconds (2-86400); save = last N
    replaySaveSeconds: 0,     // 0 = save the whole buffer
    replayStorage: "ram",     // "ram" | "disk" (disk may shorten SSD lifespan)
    replayKbps: 20000,        // CBR bitrate for the replay buffer (predictable RAM)
    replayOrganize: false,    // sort replays into date-based folders (-df)
    lowPower: false,          // reduce GPU clocks on AMD; pairs with content frame mode

    // UI
    advanced: false,
    showTimer: true,
    osdEnabled: true,         // floating recording indicator while recording
    osdPosition: "top-right", // "top-right" | "top-center" | "bottom-right"

    // State (non-user, runtime)
    _lastMonitor: "",
    _lastRegion: ""
  }
}

// The best hardware codec the detected GPU reports, in preference order. Used to
// resolve "auto" and as the fallback when a recording reaches the encoder before
// the profile resolved -- a fresh/auto config must never land on a blind H.264,
// which is the VAAPI path that aborts Mesa on some AMD parts (the black screen).
function preferredCodec(gpuInfo) {
  var codecs = (gpuInfo && gpuInfo.codecs) || []
  if (codecs.indexOf("av1") !== -1) return "av1"
  if (codecs.indexOf("hevc") !== -1) return "hevc"
  return "h264"
}

function applyGpuProfile(config, gpuInfo) {
  return resolveProfile(config, gpuInfo)
}

function resolveProfile(config, gpuInfo) {
  // Resolve "auto"/"" sentinels against detected hardware. Never mutates
  // the persisted config.
  var resolved = Object.assign({}, config)
  var vendor = (gpuInfo && gpuInfo.vendor) || "unknown"
  var codecs = (gpuInfo && gpuInfo.codecs) || []

  if (resolved.codec === "auto" || resolved.codec === "") {
    if (vendor === "nvidia") resolved.codec = codecs.indexOf("hevc") !== -1 ? "hevc" : "h264"
    else if (vendor === "amd" || vendor === "intel") resolved.codec = preferredCodec(gpuInfo)
    else resolved.codec = "h264"
  }
  if (resolved.bitrateMode === "auto" || resolved.bitrateMode === "") {
    resolved.bitrateMode = vendor === "unknown" ? "qp" : "vbr"
  }
  if (resolved.quality === "auto" || resolved.quality === "") {
    resolved.quality = vendor === "intel" ? "high"
      : (vendor === "unknown" ? "medium" : "very_high")
  }
  if (resolved.encoder === "auto" || resolved.encoder === "") {
    resolved.encoder = vendor === "unknown" ? "cpu" : "gpu"
  }
  // The default is "gpu", not "auto", so a machine where gsr reports no GPU
  // vendor would otherwise keep recording with a GPU encoder and fail. When
  // nothing was detected there is no GPU to encode on -- force CPU encoding
  // regardless of what the persisted config says.
  if (vendor === "unknown")
    resolved.encoder = "cpu"
  if (resolved.tune === "auto" || resolved.tune === "") {
    resolved.tune = "performance"
  }
  return resolved
}

function streamPlatformDefaults(platform) {
  // Auto-suggested encode settings per platform. The panel applies these when
  // the user picks a platform and hasn't overridden the value yet.
  var map = {
    tiktok:  { kbps: 6000,  resolution: "1080x1920", fps: 60, label: "TikTok Live" },
    twitch:  { kbps: 6000,  resolution: "1920x1080", fps: 60, label: "Twitch" },
    youtube: { kbps: 12000, resolution: "1920x1080", fps: 60, label: "YouTube" },
    custom:  { kbps: 6000,  resolution: "",          fps: 60, label: "Custom / Other" }
  }
  return map[platform] || map.custom
}

function streamOutput(config) {
  // Return the RTMP server URL without the stream key.
  // The stream key is passed via the GSR_AUTH environment variable
  // (see Service.qml) to keep it out of /proc/<pid>/cmdline.
  return String(config.streamUrl || "").trim()
}

// gsr `-a` source names. Explicit devices from `--list-audio-devices` use the
// documented `device:<name>` form; the defaults pass through bare.
function audioSourceName(device) {
  if (device === "default_output" || device === "default_input")
    return device
  return "device:" + device
}

function encodeGsrArgs(config, gpuInfo, target, streamMode, replayMode) {
  var args = []
  config = resolveProfile(config, gpuInfo)
  streamMode = streamMode === true
  replayMode = replayMode === true

  // Target: monitor/portal get a combined `-w` capture string; region uses the
  // `-w region` keyword plus `-region`. A webcam overlay appends to the SAME
  // `-w` value (gsr combines sources with "|"), placed in the bottom-right.
  var capture = "";
  var isRegion = false;
  if (target.type === "monitor" && target.name) {
    capture = target.name
  } else if (target.type === "region" && target.geometry) {
    capture = "region"
    isRegion = true
  } else {
    capture = "portal"
  }

  if (config.webcamEnabled && config.webcamDevice && config.webcamDevice !== "") {
    var webcamSizeMap = { small: "width=20%;height=20%", medium: "width=30%;height=30%", large: "width=40%;height=40%" };
    capture += "|" + config.webcamDevice
      + ";halign=end;valign=end;" + (webcamSizeMap[config.webcamSize || "medium"] || webcamSizeMap.medium)
  }

  args.push("-w", capture)
  if (isRegion)
    args.push("-region", target.geometry)

  // Persist the portal session across recordings/streams (quicker reclaim,
  // no repeated portal permission).
  if (capture === "portal") {
    args.push("-restore-portal-session", "yes")
  }

  // Codec: streams stay H.264; recordings keep the hardware-resolved codec.
  // resolveProfile() has already turned "auto" into a concrete codec, so the
  // guard only matters if a recording somehow reaches gsr before the profile
  // resolved. Fall back to what the detected GPU actually reports rather than a
  // blind H.264 -- H.264 VAAPI is the encode path that aborts Mesa on some AMD
  // parts (the black screen), so a fresh/auto config must never land on it when
  // the GPU offers hevc/av1.
  var codec = streamMode ? "h264" : config.codec
  if (codec === "auto" || !codec)
    codec = preferredCodec(gpuInfo)
  args.push("-k", codec)

  // Bitrate mode: CBR for streaming and replay (man tip: predictable buffer
  // RAM), resolved mode for regular recordings.
  var bm = streamMode || replayMode ? "cbr" : config.bitrateMode
  if (bm === "auto") bm = streamMode || replayMode ? "cbr" : "qp"
  args.push("-bm", bm)

  // Quality: CBR kbps for streams and replay, resolved preset for recordings.
  var q = streamMode ? config.streamKbps : (replayMode ? config.replayKbps : config.quality)
  if (q === "auto" || q === "" || q === undefined || q === null) {
    q = streamMode ? 6000 : (replayMode ? 20000 : "very_high")
  }
  args.push("-q", String(q))

  // Frame rate
  args.push("-f", String(config.fps || 60))

  // Frame rate mode: constant for streams; recordings/replay follow the setting,
  // and low-power mode switches to content-aware encoding (man recommendation).
  if (streamMode) {
    args.push("-fm", "cfr")
  } else {
    var fm = config.frameMode || "cfr"
    if (config.lowPower && fm === "cfr") fm = "content"
    args.push("-fm", fm)
    if (config.lowPower)
      args.push("-low-power", "yes")
  }

  // Resolution
  if (config.resolution && config.resolution !== "") {
    args.push("-s", config.resolution)
  } else {
    args.push("-s", "0x0")
  }

  // Encoder
  args.push("-encoder", config.encoder || "gpu")
  args.push("-fallback-cpu-encoding", "yes")

  // Color range
  args.push("-cr", config.colorRange || "limited")

  // Tune (NVIDIA only, recordings only). gsr accepts only performance|quality;
  // streams stay H.264 + CBR and pass no tune at all.
  if (!streamMode && config.tune) {
    args.push("-tune", config.tune)
  }

  // Keyframe interval
  args.push("-keyint", String(config.keyInterval || 2.0))

  // Cursor
  args.push("-cursor", config.cursor ? "yes" : "no")

  // Audio
  if (config.audioEnabled) {
    var devices = []
    if (config.audioDesktop) devices.push(audioSourceName(config.audioDesktopDevice || "default_output"))
    if (config.audioMicrophone) devices.push(audioSourceName(config.audioMicDevice || "default_input"))
    if (devices.length > 0) {
      args.push("-a", devices.join("|"))
      args.push("-ac", streamMode ? "aac" : (config.audioCodec || "aac"))
      var ab = config.audioBitrate || 0
      if (streamMode && (ab <= 0)) ab = 128
      if (ab > 0) {
        args.push("-ab", String(ab))
      }
      if (config.audioNoiseGate) {
        args.push("-ffmpeg-opts", "filter:a=afftdn=nr=20,agate=threshold=0.02")
      }
    }
  }

  // Streams are FLV transport.
  if (streamMode) {
    args.push("-c", "flv")
  }

  // Replay buffer: rolling `-r` buffer saved on command. `-restart-replay-on-save`
  // clears the buffer after a save so "save replay" always clips the last N s.
  if (replayMode) {
    args.push("-r", String(config.replaySeconds || 60))
    args.push("-replay-storage", config.replayStorage === "disk" ? "disk" : "ram")
    args.push("-restart-replay-on-save", "yes")
    args.push("-df", config.replayOrganize ? "yes" : "no")
    args.push("-c", config.container || "mp4")
  }

  // Metadata: gsr injects its own for screen recordings by default; strip it
  // for streams (transport has no metadata channel).
  if (!streamMode) {
    args.push("-exclude-metadata", "yes")
  }

  return args
}

function normalize(raw) {
  var d = defaultConfig()
  var out = {}
  var keys = Object.keys(d)
  for (var i = 0; i < keys.length; i++) {
    var k = keys[i]
    var v = raw && raw[k] !== undefined ? raw[k] : d[k]
    if (v === null || v === undefined) v = d[k]
    if (k === "audioVolume" || k === "audioMicVolume") {
      v = Number(v)
      if (isNaN(v) || v < 0) v = d[k]
      if (v > 100) v = 100
    }
    if (k === "audioDesktopDevice" || k === "audioMicDevice") {
      if (typeof v !== "string") v = d[k]
    }
    if (k === "audioNoiseGate") {
      if (typeof v !== "boolean") v = d[k]
    }
    if (k === "audioCodec" && ["aac", "opus", "flac"].indexOf(v) === -1) v = d[k]
    if (k === "fps" || k === "keyInterval" || k === "countdown" || k === "audioBitrate") {
      v = Number(v)
      if (isNaN(v) || v < 0) v = d[k]
    }
    if (k === "replayKbps") {
      v = Number(v)
      if (isNaN(v) || v < 0) v = d[k]
      if (v > 100000) v = 100000
    }
    if (k === "replaySeconds") {
      v = Number(v)
      if (isNaN(v) || v < 2) v = d[k]
      if (v > 86400) v = 86400
    }
    if (k === "replaySaveSeconds") {
      v = Number(v)
      if (isNaN(v) || v < 0) v = d[k]
      if (v > 86400) v = 86400
    }
    if (k === "streamKbps") {
      v = Number(v)
      if (isNaN(v)) v = d[k]
      if (v < 32) v = 32
      if (v > 20000) v = 20000
    }
    if (k === "cursor" || k === "audioEnabled" || k === "audioDesktop"
        || k === "audioMicrophone" || k === "audioNoiseGate" || k === "advanced" || k === "showTimer"
        || k === "webcamEnabled" || k === "streamRemember"
        || k === "streamBackupLocal" || k === "replayOrganize" || k === "lowPower") {
      v = v === true || v === "true" || v === "yes" || v === 1
    }
    if (k === "mode" && ["record", "stream", "replay"].indexOf(v) === -1) v = d[k]
    if (k === "streamPlatform" && ["custom", "tiktok", "twitch", "youtube"].indexOf(v) === -1) v = d[k]
    if (k === "container" && ["mp4", "mkv", "webm", "flv", "mov"].indexOf(v) === -1) v = d[k]
    if (k === "frameMode" && ["cfr", "vfr", "content"].indexOf(v) === -1) v = d[k]
    if (k === "colorRange" && ["limited", "full"].indexOf(v) === -1) v = d[k]
    if (k === "tune" && ["performance", "quality"].indexOf(v) === -1) v = d[k]
    if (k === "encoder" && ["gpu", "cpu"].indexOf(v) === -1) v = d[k]
    // Pin the encoder selections to the values the profile resolver (and gsr)
    // understand. A stale or hand-edited value must fall back to "auto" so the
    // GPU profile still optimizes it, instead of passing a name gsr rejects.
    if (k === "codec" && ["auto", "h264", "hevc", "av1", "vp9", "vp8"].indexOf(v) === -1) v = d[k]
    if (k === "bitrateMode" && ["auto", "qp", "vbr", "cbr"].indexOf(v) === -1) v = d[k]
    if (k === "quality" && typeof v !== "number"
        && ["auto", "medium", "high", "very_high", "ultra"].indexOf(v) === -1) v = d[k]
    if (k === "webcamSize" && ["small", "medium", "large"].indexOf(v) === -1) v = d[k]
    if (k === "fileNameTemplate" && (typeof v !== "string" || v.length > 128
        || !(v.indexOf("%H") !== -1 || v.indexOf("%M") !== -1 || v.indexOf("%S") !== -1))) v = d[k]
    if (k === "minFreeDiskMb") {
      v = Math.floor(Number(v))
      if (isNaN(v) || v < 0) v = d[k]
      if (v > 1000000) v = 1000000
    }
    if (k === "organizeByDate") {
      v = v === true || v === "true" || v === "yes" || v === 1
    }
    if (k === "osdEnabled") {
      v = v === true || v === "true" || v === "yes" || v === 1
    }
    if (k === "osdPosition" && ["top-right", "top-center", "bottom-right"].indexOf(v) === -1) v = d[k]
    if (k === "replayStorage" && ["ram", "disk"].indexOf(v) === -1) v = d[k]
    if (k === "webcamDevice" && typeof v !== "string") v = d[k]
    out[k] = v
  }
  return out
}

// Disk-space guard. `df -Pk` prints the available-kB column as field 4 of the
// second line; anything that does not parse returns -1 so the caller can tell
// "unknown" from "0 bytes free" and never blocks a launch on a failed probe.
function parseDfAvailKb(text) {
  var lines = String(text || "").split("\n")
  if (lines.length < 2) return -1
  var fields = lines[1].trim().split(/\s+/)
  var kb = parseInt(fields[3], 10)
  return isNaN(kb) ? -1 : kb
}

function diskAllows(freeKb, minFreeDiskMb) {
  if (freeKb < 0) return true          // probe failed: do not block
  return freeKb >= minFreeDiskMb * 1024
}

// The YYYY-MM-DD subdirectory organized recordings descend into, or "" when
// organization is off (files stay in the output root).
function outputSubdir(config, when) {
  if (!config || config.organizeByDate !== true)
    return ""
  var d = when && typeof when.getFullYear === "function" ? when : new Date()
  var pad = function(n) { return n < 10 ? "0" + n : String(n) }
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
}

// Trim: accept seconds ("90"), mm:ss ("1:30") or h:mm:ss ("00:01:30").
// Anything else reports -1 so the caller can refuse instead of trimming wrong.
function parseTimeSpec(spec) {
  var s = String(spec === undefined || spec === null ? "" : spec).trim();
  if (s === "") return -1;
  var parts = s.split(":");
  if (parts.length > 3) return -1;
  var total = 0;
  for (var i = 0; i < parts.length; i++) {
    var n = parts[i];
    if (n === "" || !/^\d+$/.test(n)) return -1;
    total = total * 60 + parseInt(n, 10);
  }
  return total;
}

// ffmpeg argv for a trim. `-ss` lands before `-i` so the seek is fast (keyframe
// seek); stream copy is the default because it is near-instant, and `precise`
// re-encodes for frame-accurate edges. endSec < 0 means "to the end".
function buildTrimArgs(opts) {
  var args = ["ffmpeg", "-y", "-ss", String(Math.max(0, opts.startSec))];
  if (opts.endSec >= 0)
    args.push("-to", String(opts.endSec));
  args.push("-i", opts.input);
  if (opts.precise) {
    args.push("-c:v", "libx264", "-crf", "18", "-preset", "veryfast", "-c:a", "aac");
  } else {
    args.push("-c", "copy");
  }
  args.push(opts.output);
  return args;
}

// Presets. A preset is a partial config (only the keys it names are stored),
// so applying one leaves everything else at the user's current values.
// Credentials are never part of a preset: streamKey and streamUrl hold the
// user's live-stream secret and are dropped on merge, and streamRemember is
// off so nothing re-persists them.
var PRESET_BLOCKED_KEYS = ["streamKey", "streamUrl", "streamRemember"]

function mergePreset(base, patch) {
  var merged = normalize(Object.assign({}, base))
  var raw = patch || {}
  for (var k in raw) {
    if (PRESET_BLOCKED_KEYS.indexOf(k) !== -1)
      continue
    merged[k] = raw[k]
  }
  // Strip credentials from the RESULT too: a preset saved from a live config
  // carries them in the base, and skipping only the patch's keys is not
  // enough. streamRemember is forced off so nothing re-persists them.
  for (var i = 0; i < PRESET_BLOCKED_KEYS.length; i++) {
    merged[PRESET_BLOCKED_KEYS[i]] = normalize({})[PRESET_BLOCKED_KEYS[i]]
  }
  return normalize(merged)
}

// The subset of config a patch actually changes — this is what the service
// pushes through setConfig when a preset is applied.
function presetPatch(base, patch) {
  var out = {}
  var merged = mergePreset(base, patch)
  for (var k in merged) {
    if (merged[k] !== base[k] || (merged[k] && typeof merged[k] === "object"))
      out[k] = merged[k]
  }
  for (var b in PRESET_BLOCKED_KEYS) {
    delete out[PRESET_BLOCKED_KEYS[b]]
  }
  return out
}

function makeTimestamp() {
  var d = new Date()
  var pad = function(n) { return n < 10 ? "0" + n : String(n) }
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
    + "_" + pad(d.getHours()) + "-" + pad(d.getMinutes()) + "-" + pad(d.getSeconds())
}

// Build a recording file name from a template. Tokens %Y %m %d %H %M %S are
// expanded from `when` (default now); everything else is literal. A template
// that expands to nothing, or that carries no time token at all (so every
// recording in a minute would collide), falls back to the default template.
function makeFileName(template, when) {
  // Duck-typed on purpose: this file is also evaluated in a node vm for the
  // unit tests, where a Date built in the test realm is not `instanceof` the
  // vm realm's Date.
  var d = when && typeof when.getFullYear === "function" ? when : new Date()
  var pad = function(n) { return n < 10 ? "0" + n : String(n) }
  var tokens = {
    "%Y": String(d.getFullYear()),
    "%m": pad(d.getMonth() + 1),
    "%d": pad(d.getDate()),
    "%H": pad(d.getHours()),
    "%M": pad(d.getMinutes()),
    "%S": pad(d.getSeconds())
  }
  var def = defaultConfig().fileNameTemplate
  var t = typeof template === "string" ? template : ""
  if (t === "" || t.indexOf("%H") === -1 && t.indexOf("%M") === -1 && t.indexOf("%S") === -1)
    t = def
  var out = t
  for (var k in tokens)
    out = out.split(k).join(tokens[k])
  // Filesystem-unsafe characters (plus control chars) never reach the disk.
  out = out.replace(/[\\/:*?"<>|\x00-\x1f]/g, "")
  out = out.trim()
  if (out === "")
    out = makeTimestamp()
  return out
}
