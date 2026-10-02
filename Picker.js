.pragma library

// Region picker logic. Rects are { x, y, w, h } in global layout px (the
// space Hyprland reports window and monitor positions in). A pick is a
// "region spec": "WxH+X+Y", or "monitor:NAME" when it covers a whole monitor.

var CLICK_AREA = 20

function monitorRects(monitors) {
  return (monitors || []).map(function (m) {
    var w = Math.floor(m.width / (m.scale || 1))
    var h = Math.floor(m.height / (m.scale || 1))
    var rotated = m.transform % 2 === 1
    var ws = [m.activeWorkspace ? m.activeWorkspace.id : null]
    if (m.specialWorkspace && m.specialWorkspace.id)
      ws.push(m.specialWorkspace.id)
    return { name: m.name, x: m.x, y: m.y, w: rotated ? h : w, h: rotated ? w : h, workspaces: ws }
  })
}

// Windows visible on some monitor, each with the stacking layer it draws in:
// special workspace over regular, floating over tiled. A fullscreen or
// maximized window hides the tiled windows behind it.
function windowRects(clients, monitors) {
  var visible = {}
  var special = {}
  monitorRects(monitors).forEach(function (m) {
    m.workspaces.forEach(function (id, i) {
      if (id !== null) {
        visible[id] = true
        if (i > 0) special[id] = true
      }
    })
  })
  var shown = (clients || []).filter(function (c) {
    return c.workspace && visible[c.workspace.id] && c.hidden !== true && c.mapped !== false
  })
  var covered = {}
  shown.forEach(function (c) {
    if (c.fullscreen > 0)
      covered[c.workspace.id] = c.address
  })
  return shown.filter(function (c) {
    var cover = covered[c.workspace.id]
    return !cover || cover === c.address || c.floating
  }).map(function (c) {
    return {
      x: c.at[0], y: c.at[1], w: c.size[0], h: c.size[1],
      layer: (special[c.workspace.id] ? 2 : 0) + (c.floating ? 1 : 0)
    }
  })
}

function contains(r, x, y) {
  return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

// The topmost layer wins, then the smallest rect (nested or overlapping
// windows in one layer), then the first listed.
function windowAt(windows, x, y) {
  var best = null
  for (var i = 0; i < (windows || []).length; i++) {
    var r = windows[i]
    if (!contains(r, x, y))
      continue
    if (!best || r.layer > best.layer || (r.layer === best.layer && r.w * r.h < best.w * best.h))
      best = r
  }
  return best
}

function monitorAt(monitors, x, y) {
  for (var i = 0; i < (monitors || []).length; i++) {
    if (contains(monitors[i], x, y))
      return monitors[i]
  }
  return null
}

function dragRect(x0, y0, x1, y1) {
  var x = Math.round(Math.min(x0, x1))
  var y = Math.round(Math.min(y0, y1))
  return { x: x, y: y, w: Math.round(Math.max(x0, x1)) - x, h: Math.round(Math.max(y0, y1)) - y }
}

function isClick(rect) {
  return rect.w * rect.h < CLICK_AREA
}

function formatGeometry(rect) {
  return rect.w + "x" + rect.h + "+" + rect.x + "+" + rect.y
}

function specForRect(rect, monitors) {
  for (var i = 0; i < (monitors || []).length; i++) {
    var m = monitors[i]
    if (m.x === rect.x && m.y === rect.y && m.w === rect.w && m.h === rect.h)
      return "monitor:" + m.name
  }
  return formatGeometry(rect)
}

// A bare click picks the window under it, or the whole monitor.
function clickSpec(windows, monitors, x, y) {
  var win = windowAt(windows, x, y)
  if (win)
    return specForRect(win, monitors)
  var mon = monitorAt(monitors, x, y)
  return mon ? "monitor:" + mon.name : ""
}

// omarchy-capture-region output ("X,Y WxH" or "monitor:NAME") as a spec.
function specFromCaptureRegion(text) {
  var out = String(text || "").trim()
  if (/^monitor:\S+$/.test(out) || /^[0-9]+x[0-9]+\+-?[0-9]+\+-?[0-9]+$/.test(out))
    return out
  var m = out.match(/^(-?[0-9]+),(-?[0-9]+)\s+([0-9]+)x([0-9]+)$/)
  return m ? m[3] + "x" + m[4] + "+" + m[1] + "+" + m[2] : ""
}

function targetFromSpec(spec) {
  var s = String(spec || "")
  if (s.indexOf("monitor:") === 0)
    return s.length > 8 ? { type: "monitor", name: s.substring(8) } : null
  return /^[0-9]+x[0-9]+\+-?[0-9]+\+-?[0-9]+$/.test(s) ? { type: "region", geometry: s } : null
}

// The region a start records: a fresh pick, else the saved one unless every
// start asks for a new pick. "" = open the picker first.
function regionForStart(config, pending) {
  if (pending)
    return pending
  if (config.regionAskEachTime)
    return ""
  var saved = config.region || config._lastRegion || ""
  return targetFromSpec(saved) ? saved : ""
}
