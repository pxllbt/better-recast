.pragma library

// What to run on a finished capture (config.postProcessApp /
// postProcessCommand). Used by Service.qml after a save and by Panel.qml for
// the "Open with" list.

function parseMimeApps(text) {
  var ids = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/([A-Za-z0-9._-]+\.desktop)\s*$/)
    if (m && ids.indexOf(m[1]) === -1)
      ids.push(m[1])
  }
  return ids
}

function shellQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'"
}

function command(config, path) {
  var app = String(config.postProcessApp || "")
  if (!path || app === "")
    return null
  if (app === "custom") {
    var cmd = String(config.postProcessCommand || "").trim()
    if (cmd === "")
      return null
    return ["bash", "-c", cmd + ' "$1"', "_", path]
  }
  return ["gtk-launch", app.replace(/\.desktop$/, ""), path]
}
