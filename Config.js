.pragma library

// pix.recast config defaults, normalization, and encoder profile rules.
// Singleton import: used by Service.qml at startup and Panel.qml for defaults.

function defaultConfig() {
  return {
    // Recording target
    targetMode: "auto",       // "auto" | "monitor" | "region" | "portal"
    monitorName: "",           // explicit monitor (from --list-monitors)
    region: "",                // "WxH+X+Y" or ""
    regionAskEachTime: false,  // open the region picker on every start

    // Video
    codec: "auto",            // "auto" | "h264" | "hevc" | "av1" | "vp9" | "vp8"
    encoder: "gpu",           // "gpu" | "cpu"
    bitrateMode: "auto",      // "auto" | "qp" | "vbr" | "cbr"
    quality: "auto",          // "auto" | "medium" | "high" | "very_high" | "ultra" | number (kbps for cbr)
    fps: 60,
    resolution: "",           // "" = native, "1920x1080", etc.
    frameMode: "vfr",         // "cfr" | "vfr" | "content"
    colorRange: "limited",    // "limited" | "full"
    tune: "performance",      // "performance" | "quality"
    keyInterval: 1.0,
    cursor: true,

    // Audio
    audioEnabled: true,
    audioDesktop: true,
    audioMicrophone: false,
    audioCodec: "aac",        // "aac" | "opus"
    audioBitrate: 0,          // 0 = auto
    audioSetVolume: false,    // set the levels below only while recording
    audioVolume: 100,         // 0-100, desktop audio volume
    audioMicVolume: 100,      // 0-100, microphone volume
    audioDesktopDevice: "default_output",
    audioMicDevice: "default_input",
    audioNoiseGate: false,    // noise gate/suppression via FFmpeg filter

    // Container
    container: "mp4",         // "mp4" | "mkv" | "webm"

    // Output
    outputDir: "",            // "" = auto from XDG_VIDEOS_DIR

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

    // Controls overlay
    overlayMode: "auto",      // "auto" | "pin" | "timed" | "float" | "off"
    overlayPrevMode: "auto",  // mode to restore when a popped-out overlay is docked again
    overlaySeconds: 5,        // 1-60, how long "timed" (and "auto" without a free monitor) stays out
    overlayEdge: "right",     // "left" | "right" | "top" | "bottom": edge used when no other monitor is free
    overlayPinned: false,     // pin button on the overlay: keep a peeking overlay out

    // Capture-control keybinds: "" = automatic, else a combo like "SUPER + ALT + P"
    bindPause: "",
    bindStop: "",
    bindCancel: "",
    bindSaveReplay: "",

    // After capture: open the saved file with a desktop app or a command
    postProcessApp: "",       // "" = none | "<id>.desktop" | "custom"
    postProcessCommand: "",   // used when postProcessApp === "custom"; file is passed as "$1"

    // UI
    advanced: false,
    showTimer: true,

    // State (non-user, runtime)
    _lastMonitor: "",
    _lastRegion: ""
  }
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
    else if (vendor === "amd" || vendor === "intel") {
      if (codecs.indexOf("av1") !== -1) resolved.codec = "av1"
      else if (codecs.indexOf("hevc") !== -1) resolved.codec = "hevc"
      else resolved.codec = "h264"
    } else resolved.codec = "h264"
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
  var codec = streamMode ? "h264" : config.codec
  if (codec === "auto") codec = "h264"
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
    if (k === "audioNoiseGate" || k === "audioSetVolume") {
      if (typeof v !== "boolean") v = d[k]
    }
    if (k === "audioCodec" && ["aac", "opus", "flac"].indexOf(v) === -1) v = d[k]
    if (k === "fps" || k === "keyInterval" || k === "audioBitrate") {
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
        || k === "streamBackupLocal" || k === "replayOrganize" || k === "lowPower" || k === "overlayPinned"
        || k === "regionAskEachTime") {
      v = v === true || v === "true" || v === "yes" || v === 1
    }
    if (k === "mode" && ["record", "stream", "replay"].indexOf(v) === -1) v = d[k]
    if (k === "streamPlatform" && ["custom", "tiktok", "twitch", "youtube"].indexOf(v) === -1) v = d[k]
    if (k === "container" && ["mp4", "mkv", "webm", "flv", "mov"].indexOf(v) === -1) v = d[k]
    if (k === "frameMode" && ["cfr", "vfr", "content"].indexOf(v) === -1) v = d[k]
    if (k === "colorRange" && ["limited", "full"].indexOf(v) === -1) v = d[k]
    if (k === "tune" && ["performance", "quality"].indexOf(v) === -1) v = d[k]
    if (k === "encoder" && ["gpu", "cpu"].indexOf(v) === -1) v = d[k]
    if (k === "webcamSize" && ["small", "medium", "large"].indexOf(v) === -1) v = d[k]
    if (k === "replayStorage" && ["ram", "disk"].indexOf(v) === -1) v = d[k]
    if (k === "webcamDevice" && typeof v !== "string") v = d[k]
    if (k === "overlayMode" && ["auto", "pin", "timed", "float", "off"].indexOf(v) === -1) v = d[k]
    if (k === "overlayPrevMode" && ["auto", "pin", "timed", "off"].indexOf(v) === -1) v = d[k]
    if (k === "overlayEdge" && ["left", "right", "top", "bottom"].indexOf(v) === -1) v = d[k]
    if (k === "overlaySeconds") {
      v = Math.round(Number(v))
      if (isNaN(v)) v = d[k]
      v = Math.max(1, Math.min(60, v))
    }
    if (k === "postProcessApp"
        && (typeof v !== "string" || (v !== "" && v !== "custom" && !/^[A-Za-z0-9._-]+\.desktop$/.test(v)))) v = d[k]
    if ((k === "postProcessCommand" || k === "bindPause" || k === "bindStop"
        || k === "bindCancel" || k === "bindSaveReplay") && typeof v !== "string") v = d[k]
    out[k] = v
  }
  return out
}

function makeTimestamp() {
  var d = new Date()
  var pad = function(n) { return n < 10 ? "0" + n : String(n) }
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
    + "_" + pad(d.getHours()) + "-" + pad(d.getMinutes()) + "-" + pad(d.getSeconds())
}
