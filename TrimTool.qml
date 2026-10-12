import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Trim the last saved recording with ffmpeg — stream copy by default (fast),
// re-encode when a frame-accurate edge matters. Mounted by Panel.qml's
// POST-RECORDING section; works with either the live service object or the
// IPC fallback a replacement bar provides.
Column {
    id: root

    property var service: null
    property var serviceState: ({})
    readonly property string lastPath: root.service
        ? (root.service.lastSavedPath || "")
        : (root.serviceState ? (root.serviceState.lastSavedPath || "") : "")

    property color foreground: "#ffffff"
    property color background: "#000000"
    property color accent: "#1e66f5"
    property color muted: "#888888"
    property color urgent: "#ff5555"
    property string fontFamily: "sans-serif"

    readonly property real fontCaption: 12

    width: parent ? parent.width : 300
    spacing: 6

    function trim() {
        if (startField.text.trim() === "")
            return;
        if (root.service && typeof root.service.trimLastClip === "function") {
            root.service.trimLastClip(startField.text, endField.text, preciseBox.checked);
        } else {
            trimIpc.command = ["omarchy-shell", "px-recast", "trim",
                startField.text, endField.text, preciseBox.checked ? "precise" : "fast"];
            trimIpc.running = true;
        }
    }

    RowLayout {
        width: parent.width
        spacing: 6

        Text {
            text: "Start"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: root.fontCaption
            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
        }
        TextField {
            id: startField
            Layout.fillWidth: true
            text: "0"
            placeholderText: "0 or 1:30"
            foreground: root.foreground
            accent: root.accent
            font.family: root.fontFamily
            font.pixelSize: root.fontCaption
        }

        Text {
            text: "End"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: root.fontCaption
            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
        }
        TextField {
            id: endField
            Layout.fillWidth: true
            placeholderText: "blank = to end"
            foreground: root.foreground
            accent: root.accent
            font.family: root.fontFamily
            font.pixelSize: root.fontCaption
        }
    }

    RowLayout {
        width: parent.width
        spacing: 6

        Text {
            text: "Frame-accurate"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: root.fontCaption
            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
        }
        ToggleSwitch {
            id: preciseBox
            checked: false
            foreground: root.foreground
            accent: root.accent
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
        }

        Button {
            text: "Trim last clip"
            enabled: root.lastPath !== "" && startField.text.trim() !== ""
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: root.fontCaption
            onClicked: root.trim()
        }
    }

    Text {
        text: root.lastPath === ""
            ? "Record a clip first — trims are written next to it as <name>.trim.<ext>."
            : "Off cuts to the nearest keyframe. On re-encodes a copy is kept beside the original."
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: root.fontCaption
        wrapMode: Text.WordWrap
        width: parent.width
    }

    Process {
        id: trimIpc
        running: false
    }
}
