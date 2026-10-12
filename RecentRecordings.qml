import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Recent recordings: the newest files in the output dir, each with open and
// copy-path actions. The list is computed by the service (ls -1t), so this
// component reads either the live service object or the state-file snapshot a
// replacement bar supplies.
Column {
    id: root

    property var service: null
    property var serviceState: ({})
    readonly property var files: root.service
        ? (root.service.recentFiles || [])
        : (root.serviceState ? (root.serviceState.recentFiles || []) : [])

    property color foreground: "#ffffff"
    property color background: "#000000"
    property color accent: "#1e66f5"
    property color muted: "#888888"
    property color urgent: "#ff5555"
    property string fontFamily: "sans-serif"

    readonly property real fontCaption: 12

    width: parent ? parent.width : 300
    spacing: 6

    function openFile(path) {
        if (root.service && typeof root.service.openPath === "function") {
            root.service.openPath(path);
        } else {
            openProc.command = ["xdg-open", path];
            openProc.running = true;
        }
    }

    function copyPath(path) {
        // printf %s keeps the path byte-exact — no trailing newline in the
        // clipboard.
        copyProc.command = ["bash", "-c", "printf '%s' \"$1\" | wl-copy", "_", path];
        copyProc.running = true;
    }

    Text {
        visible: root.files.length === 0
        text: "No recordings in the output folder yet."
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: root.fontCaption
        wrapMode: Text.WordWrap
        width: parent.width
    }

    Repeater {
        model: root.files

        RowLayout {
            width: root.width
            spacing: 6

            Text {
                text: modelData && modelData.name ? modelData.name : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
                elide: Text.ElideMiddle
                maximumLineCount: 1
                Layout.fillWidth: true
            }

            Button {
                text: "Open"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: root.fontCaption
                onClicked: root.openFile(modelData.path)
            }

            Button {
                text: "Copy path"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: root.fontCaption
                onClicked: root.copyPath(modelData.path)
            }
        }
    }

    Process {
        id: openProc
        running: false
    }

    Process {
        id: copyProc
        running: false
    }
}
