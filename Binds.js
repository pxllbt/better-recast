.pragma library

// Capture-control keybinds: which combo each action uses and where it came
// from. Service.qml binds the plugin-managed ones while a capture runs;
// ControlsOverlay.qml and Panel.qml display the result.

var DESCRIPTION_PREFIX = "Better Recast: "

var ACTIONS = [
  { id: "pause", ipc: "togglePause", label: "Pause / resume", letter: "P", configKey: "bindPause", contexts: ["record"] },
  { id: "stop", ipc: "stop", label: "Stop", letter: "S", configKey: "bindStop", contexts: ["record", "stream", "replay"] },
  { id: "cancel", ipc: "cancel", label: "Cancel (discard)", letter: "X", configKey: "bindCancel", contexts: ["record", "replay"] },
  { id: "saveReplay", ipc: "saveReplay", label: "Save replay", letter: "R", configKey: "bindSaveReplay", contexts: ["replay"] }
]

// Older bindings.lua entries that still mean an action above.
var LEGACY_IPC = { pause: "pause", resume: "pause" }

var MODIFIERS = [
  { name: "SUPER", bit: 64 },
  { name: "CTRL", bit: 4 },
  { name: "ALT", bit: 8 },
  { name: "SHIFT", bit: 1 }
]
var MODIFIER_ALIASES = { CONTROL: "CTRL" }

// Keys are restricted to keysym-safe characters so a combo can be pasted
// into a Lua string without escaping.
var KEY_RE = /^[A-Z0-9_]+$/

function actionsFor(context) {
  return ACTIONS.filter(function (a) { return a.contexts.indexOf(context) !== -1 })
}

function parseCombo(text) {
  var parts = String(text || "").split("+")
  var mask = 0
  var key = ""
  for (var i = 0; i < parts.length; i++) {
    var p = parts[i].trim().toUpperCase()
    p = MODIFIER_ALIASES[p] || p
    var mod = MODIFIERS.filter(function (m) { return m.name === p })[0]
    if (mod) {
      mask |= mod.bit
    } else {
      if (key !== "" || !KEY_RE.test(p))
        return null
      key = p
    }
  }
  if (key === "")
    return null
  return { mask: mask, key: key }
}

function formatCombo(mask, key) {
  var k = String(key || "").toUpperCase()
  if (!KEY_RE.test(k))
    return ""
  var names = []
  for (var i = 0; i < MODIFIERS.length; i++)
    if (mask & MODIFIERS[i].bit)
      names.push(MODIFIERS[i].name)
  names.push(k)
  return names.join(" + ")
}

function normalizeCombo(text) {
  var c = parseCombo(text)
  return c ? formatCombo(c.mask, c.key) : ""
}

function actionForIpc(name) {
  var ipc = LEGACY_IPC[name] ? "togglePause" : name
  return ACTIONS.filter(function (a) { return a.ipc === ipc })[0] || null
}

// From read-binds.lua TSV (modmask, description, key, dispatcher, arg): the
// combo of the first exec bind that calls each action over px-recast IPC.
function parseConfigBinds(text) {
  var names = ACTIONS.map(function (a) { return a.ipc }).concat(Object.keys(LEGACY_IPC))
  var re = new RegExp("px-recast\\s+(" + names.join("|") + ")\\b")
  var found = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var f = lines[i].split("\t")
    if (f.length < 5 || f[3] !== "exec")
      continue
    var m = f[4].match(re)
    if (!m)
      continue
    var action = actionForIpc(m[1])
    var combo = formatCombo(Number(f[0]) || 0, f[2])
    if (action && combo !== "" && found[action.id] === undefined)
      found[action.id] = combo
  }
  return found
}

function bindsOn(hyprBinds, combo) {
  var c = parseCombo(combo)
  if (!c || !Array.isArray(hyprBinds))
    return []
  return hyprBinds.filter(function (b) {
    return b && Number(b.modmask) === c.mask && String(b.key || "").toUpperCase() === c.key && !b.submap
  })
}

function isOurs(bind, prefix) {
  return String(bind.description || "").indexOf(prefix) === 0
}

// `hyprBinds` is `hyprctl binds -j`. Our own runtime binds never count.
function isTaken(hyprBinds, combo, prefix) {
  return bindsOn(hyprBinds, combo).some(function (b) { return !isOurs(b, prefix) })
}

// Every combo that currently carries one of our runtime binds.
function ownedCombos(hyprBinds, prefix) {
  var out = []
  if (!Array.isArray(hyprBinds))
    return out
  hyprBinds.forEach(function (b) {
    if (!b || b.submap || !isOurs(b, prefix))
      return
    var combo = formatCombo(Number(b.modmask) || 0, b.key)
    if (combo !== "" && out.indexOf(combo) === -1)
      out.push(combo)
  })
  return out
}

function autoCandidates(letter) {
  var out = ["SUPER + ALT + " + letter, "SUPER + CTRL + ALT + " + letter]
  var start = letter.charCodeAt(0) - 65
  for (var i = 1; i < 26; i++)
    out.push("SUPER + ALT + " + String.fromCharCode(65 + (start + i) % 26))
  return out
}

// `chosen` is a { combo: true } map of combos already spoken for.
function autoCombo(action, takenFn, chosen) {
  var candidates = autoCandidates(action.letter)
  for (var i = 0; i < candidates.length; i++) {
    var c = candidates[i]
    if (!(chosen && chosen[c]) && !takenFn(c))
      return c
  }
  return ""
}

// { actionId: { combo, source: "override"|"config"|"auto"|"none", conflict } }
// An override wins, then a bindings.lua bind, then an automatic free combo.
// An override that something else already holds is reported as a conflict
// and left unbound.
function resolve(config, configBinds, takenFn) {
  var out = {}
  var chosen = {}
  configBinds = configBinds || {}
  ACTIONS.forEach(function (a) {
    var override = normalizeCombo(config ? config[a.configKey] : "")
    if (override !== "") {
      out[a.id] = { combo: override, source: "override", conflict: override !== configBinds[a.id] && takenFn(override) }
      chosen[override] = true
    } else if (configBinds[a.id]) {
      out[a.id] = { combo: configBinds[a.id], source: "config", conflict: false }
      chosen[configBinds[a.id]] = true
    }
  })
  ACTIONS.forEach(function (a) {
    if (out[a.id])
      return
    var combo = autoCombo(a, takenFn, chosen)
    out[a.id] = { combo: combo, source: combo === "" ? "none" : "auto", conflict: false }
    if (combo !== "")
      chosen[combo] = true
  })
  return out
}

// [{ action, combo }] the plugin binds itself. bindings.lua binds already
// work on their own.
function managed(resolved, context) {
  var list = context ? actionsFor(context) : ACTIONS
  return list.filter(function (a) {
    var r = resolved && resolved[a.id]
    return r && r.combo !== "" && (r.source === "auto" || (r.source === "override" && !r.conflict))
  }).map(function (a) {
    return { action: a, combo: resolved[a.id].combo }
  })
}

function bindStatement(entry) {
  return 'hl.bind("' + entry.combo + '", hl.dsp.exec_cmd("omarchy-shell px-recast ' + entry.action.ipc
    + '"), { description = "' + DESCRIPTION_PREFIX + entry.action.label + '" })'
}

// Bash that unbinds each combo, but only while every live bind on it is
// ours: Hyprland's unbind drops all binds on the keys, not just one.
function unbindScript(combos, prefix) {
  return combos.map(function (combo) {
    var c = parseCombo(combo)
    if (!c)
      return ""
    return "hyprctl binds -j | jq -e --argjson m " + c.mask + " --arg k " + c.key + " --arg p '" + prefix + "'"
      + " '[.[] | select(.modmask == $m and (.key | ascii_upcase) == $k and .submap == \"\")]"
      + " | all(.description | startswith($p))' >/dev/null"
      + " && hyprctl eval 'hl.unbind(\"" + formatCombo(c.mask, c.key) + "\")'"
  }).filter(function (s) { return s !== "" }).join("\n")
}

// One bash script that moves the live binds from `bound` to `wanted` (both
// [{ action, combo }]). Every touched combo is first cleared of our own
// binds, so rebinding after a config reload (or over a leftover from an
// earlier shell) never stacks a second copy.
function syncScript(bound, wanted, prefix) {
  var key = function (e) { return e.combo + "\t" + e.action.ipc }
  var wantedKeys = wanted.map(key)
  var boundKeys = bound.map(key)
  var drop = bound.filter(function (e) { return wantedKeys.indexOf(key(e)) === -1 })
  var add = wanted.filter(function (e) { return boundKeys.indexOf(key(e)) === -1 })
  var clear = []
  drop.concat(add).forEach(function (e) {
    if (clear.indexOf(e.combo) === -1)
      clear.push(e.combo)
  })
  var lines = []
  if (clear.length > 0)
    lines.push(unbindScript(clear, prefix))
  if (add.length > 0)
    lines.push("hyprctl eval '" + add.map(bindStatement).join(" ") + "'")
  return lines.join("\n")
}
