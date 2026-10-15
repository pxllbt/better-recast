// A hidden TextField is not inert.
//
// Panel.qml is loaded for the whole life of the shell -- BarWidget mounts it
// through `Loader { active: true; visible: false }`, so the panel exists while
// the popup is closed. That means its editable text inputs are live C++
// objects, and Qt does not leave them alone.
//
// QQuickTextInputPrivate::init() connects every TextInput to the clipboard:
//
//     qmlobject_connect(QGuiApplication::clipboard(), QClipboard,
//         SIGNAL(dataChanged()), q, QQuickTextInput, SLOT(q_canPasteChanged()));
//
// Unconditionally, in the constructor, whether or not any QML ever binds
// `canPaste` -- this plugin never does. The slot re-evaluates canPaste, and in
// Qt <= 6.12 that means calling mimeData()->text():
//
//     if (const QMimeData *mimeData = QGuiApplication::clipboard()->mimeData())
//         canPaste = mimeData->hasText() && !mimeData->text().isEmpty();
//
// Under Wayland with a clipboard owned by another client, that text() lands in
// QWaylandMimeData::retrieveData_sys(), which writes a wl_data_offer.receive to
// the foreign owner and then blocks reading the pipe --
//
//     m_dataOffer->startReceiving(mime, pipefd[1]);
//     ...
//     readData(pipefd[0], content)   // qt_safe_poll(..., QDeadlineTimer(1s))
//
// up to a second, on the GUI thread, per live field, per clipboard-owner
// change, with no paste and no focus involved. `hasText()` on its own only
// reads the format list that the compositor already delivered; it is the
// `.text()` that makes it a transfer.
//
// So every editable text input in a permanently loaded panel must be gated.
// `readOnly` is the lever that works, because both canPaste and
// q_canPasteChanged early-out on it:
//
//     if (!d->m_readOnly) { ...clipboard... }
//
// Notably `visible: false` and `enabled: false` do NOT work -- the object is
// still constructed and the connection is still made.
//
// Run from the plugin root:  node tests/clipboard-gating.test.js
const fs = require("fs");
const assert = require("node:assert/strict");
const path = require("node:path");

const QML = ["Panel.qml", "BarWidget.qml", "Service.qml"];

const GATE = /readOnly\s*:\s*!?[a-zA-Z_.]*opened/;

// Pull out whole `Type { ... }` blocks by brace matching, so a gate can only be
// credited to the field it actually belongs to.
function blocks(source, type) {
  const out = [];
  const lines = source.split("\n");
  lines.forEach((line, i) => {
    if (!new RegExp(`\\b${type}\\s*\\{`).test(line)) return;
    let depth = 0;
    let start = -1;
    for (let j = i; j < lines.length; j++) {
      const opens = (lines[j].match(/\{/g) || []).length;
      const closes = (lines[j].match(/\}/g) || []).length;
      if (start < 0 && opens > 0) start = j;
      depth += opens - closes;
      if (depth <= 0 && start >= 0) {
        out.push({ name: `${type} at line ${i + 1}`, body: lines.slice(start, j + 1).join("\n") });
        return;
      }
    }
    out.push({ name: `${type} at line ${i + 1}`, body: lines.slice(i).join("\n") });
  });
  return out;
}

let gated = 0;
const ungated = [];

for (const file of QML) {
  if (!fs.existsSync(file)) continue;
  const source = fs.readFileSync(file, "utf8");

  for (const field of blocks(source, "TextField")) {
    if (GATE.test(field.body)) {
      gated++;
    } else {
      ungated.push(`${file}: ${field.name} is editable with no readOnly gate`);
    }
  }
  for (const field of blocks(source, "TextArea")) {
    ungated.push(`${file}: ${field.name} needs a readOnly gate`);
  }
}

// The panel must not have gained a text field that has silently gone ungated.
// The count is deliberately a floor, not an exact number: fields get added and
// removed as the panel grows, and pinning it would break on ordinary churn. What
// must never happen is a text field entering ungated.
assert.equal(ungated.length, 0, "ungated text inputs: " + ungated.join("; "));
assert(gated >= 1, `expected at least one gated field, found ${gated}`);

// The gate must reference the popup's own open state, not a constant. A
// hardcoded `readOnly: true` would pass the check above and break editing.
const panel = fs.readFileSync("Panel.qml", "utf8");
assert(/readOnly:\s*!root\.opened/.test(panel),
  "fields are gated on the panel being open, not permanently read-only");

// Sanity: the panel really is permanently instantiated while closed. If that
// Loader ever becomes lazy this file becomes belt-and-braces, not load-bearing.
const bar = fs.readFileSync("BarWidget.qml", "utf8");
const loader = bar.slice(bar.indexOf("Loader {"), bar.indexOf("Loader {") + 200);
assert(/active:\s*true/.test(loader), "the panel Loader is active: true (always instantiated)");

console.log("ok - hidden editable text fields are gated so Qt never queries the clipboard");
