.pragma library

// pix.recast GPU and encoder detection.
// Primary source: `gpu-screen-recorder --info` (authoritative for what gsr supports).
// Fallback: nvidia-smi for NVIDIA detail, DRM/sysfs for AMD/Intel info.

function parseGsrInfo(text) {
  var info = { vendor: "unknown", cardPath: "", codecs: [], driverVersion: "", backend: "cpu" }
  var lines = String(text || "").split("\n")
  var section = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "section=gpu_info") { section = "gpu"; continue }
    if (line === "section=video_codecs") { section = "codecs"; continue }
    if (line.indexOf("section=") === 0) { section = ""; continue }
    if (section === "gpu") {
      if (line.indexOf("vendor|") === 0) info.vendor = line.substring(7).trim()
      if (line.indexOf("card_path|") === 0) info.cardPath = line.substring(10).trim()
    }
    if (section === "codecs") {
      if (line && line !== "h264_software") info.codecs.push(line)
      else if (line === "h264_software") info.codecs.push("h264_software")
    }
  }
  if (info.vendor === "nvidia") info.backend = "nvenc"
  else if (info.vendor === "amd") info.backend = "vaapi"
  else if (info.vendor === "intel") info.backend = "vaapi"
  return info
}

function parseMonitorList(text) {
  var monitors = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("|")
    if (parts.length >= 2) {
      monitors.push({ name: parts[0].trim(), resolution: parts[1].trim() })
    }
  }
  return monitors
}

function parseAudioDevices(text) {
  var devices = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("|")
    if (parts.length >= 2) {
      devices.push({ id: parts[0].trim(), name: (parts[1] || parts[0]).trim() })
    }
  }
  return devices
}

// Application audio capture: gpu-screen-recorder lists capturable
// applications (one name per line) for `-a <sink>|app:<name>` capture. A line
// that is not a bare name — a combined "a|app:b" source, a banner, anything
// with a separator — is dropped rather than offered as a bogus source.
function parseAppAudio(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "")
      continue
    if (line.indexOf("|") !== -1 || line.indexOf(":") !== -1)
      continue
    out.push({ id: "app:" + line, name: line })
  }
  return out
}

function parseV4L2Devices(text) {
  var devices = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line || line.indexOf("/dev/") !== 0) continue
    var parts = line.split("|")
    devices.push({ path: parts[0].trim(), name: parts.length > 1 && parts[1].trim() ? parts[1].trim() : parts[0].trim() })
  }
  if (devices.length === 0)
    devices.push({ path: "", name: "No webcam found" })
  return devices
}

// Dual-GPU & Hybrid Laptop Auto-Routing:
// Parses DRM graphics cards and their active output connectors.
function parseDrmCards(text) {
  var cards = []
  var lines = String(text || "").split("\n")
  var current = null
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    if (line.indexOf("card") === 0 && line.indexOf("-") === -1) {
      var cardName = line.split(":")[0].trim()
      current = { name: cardName, outputs: [] }
      cards.push(current)
    } else if (current && line.indexOf(current.name + "-") === 0) {
      var connectorPart = line.split(":")[0].substring(current.name.length + 1).trim()
      var status = line.indexOf("connected") !== -1 ? "connected" : "disconnected"
      current.outputs.push({ name: connectorPart, status: status })
    }
  }
  return cards
}

// Maps the active monitor connector (eDP-1, HDMI-A-1, DP-1) to the driving GPU
function resolveOptimalRenderNode(cards, activeConnector) {
  if (!cards || !Array.isArray(cards) || cards.length === 0)
    return null
  if (!activeConnector)
    return cards[0]
  for (var i = 0; i < cards.length; i++) {
    var c = cards[i]
    if (c && c.outputs) {
      for (var j = 0; j < c.outputs.length; j++) {
        if (c.outputs[j].name === activeConnector)
          return c
      }
    }
  }
  return cards[0]
}
