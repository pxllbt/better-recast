.pragma library

// Where the controls overlay goes. Screens are plain
// { name, x, y, width, height } objects in global layout coordinates.

function regionRect(geometry) {
  var m = String(geometry || "").match(/^([0-9]+)x([0-9]+)\+(-?[0-9]+)\+(-?[0-9]+)$/)
  if (!m)
    return null
  return { x: Number(m[3]), y: Number(m[4]), w: Number(m[1]), h: Number(m[2]) }
}

function screenRect(s) {
  return { x: s.x, y: s.y, w: s.width, h: s.height }
}

function intersects(a, b) {
  return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

function union(rects) {
  var x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity
  rects.forEach(function (r) {
    x1 = Math.min(x1, r.x)
    y1 = Math.min(y1, r.y)
    x2 = Math.max(x2, r.x + r.w)
    y2 = Math.max(y2, r.y + r.h)
  })
  return { x: x1, y: y1, w: x2 - x1, h: y2 - y1 }
}

function gap(a, b) {
  var dx = Math.max(0, a.x - (b.x + b.w), b.x - (a.x + a.w))
  var dy = Math.max(0, a.y - (b.y + b.h), b.y - (a.y + a.h))
  return Math.sqrt(dx * dx + dy * dy)
}

// The side of `free` that faces `target`.
function facingEdge(free, target) {
  var dx = (target.x + target.w / 2) - (free.x + free.w / 2)
  var dy = (target.y + target.h / 2) - (free.y + free.h / 2)
  if (Math.abs(dx) >= Math.abs(dy))
    return dx > 0 ? "right" : "left"
  return dy > 0 ? "bottom" : "top"
}

// Names of the screens a capture target shows, focused screen first.
function recordedScreens(target, screens, focusedName) {
  var names = []
  if (target && target.type === "monitor") {
    names = screens.filter(function (s) { return s.name === target.name }).map(function (s) { return s.name })
  } else if (target && target.type === "region") {
    var r = regionRect(target.geometry)
    if (r)
      names = screens.filter(function (s) { return intersects(screenRect(s), r) }).map(function (s) { return s.name })
  }
  if (names.length === 0)
    return focusedName ? [focusedName] : []
  var i = names.indexOf(focusedName)
  if (i > 0)
    names.unshift(names.splice(i, 1)[0])
  return names
}

// { screen, edge, kind } or null for mode "off" / no screens.
//   kind "pinned": always shown, flush against `edge`
//   kind "peek":   shown for a while, then tucked into a hover strip on `edge`
//   kind "float":  free-floating, wherever the user dragged it
// With a free (unrecorded) screen the overlay sits on the one nearest the
// recording, on the side facing it; otherwise on the recorded screen at
// `edgeSetting`, where only "pin" keeps it out permanently.
function choosePlacement(mode, recordedNames, screens, edgeSetting) {
  if (mode === "off" || screens.length === 0)
    return null
  var recorded = screens.filter(function (s) { return recordedNames.indexOf(s.name) !== -1 })
  if (recorded.length === 0)
    recorded = [screens[0]]
  var free = screens.filter(function (s) { return recorded.indexOf(s) === -1 })
  var target = union(recorded.map(screenRect))

  var place
  if (free.length > 0) {
    var best = free[0]
    free.forEach(function (s) {
      if (gap(screenRect(s), target) < gap(screenRect(best), target))
        best = s
    })
    place = { screen: best.name, edge: facingEdge(screenRect(best), target) }
  } else {
    var host = recorded.filter(function (s) { return s.name === recordedNames[0] })[0] || recorded[0]
    place = { screen: host.name, edge: edgeSetting }
  }

  var kinds = {
    auto: free.length > 0 ? "pinned" : "peek",
    pin: "pinned",
    timed: "peek",
    float: "float"
  }
  place.kind = kinds[mode] || kinds.auto
  return place
}
