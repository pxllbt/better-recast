import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Setting presets and saved regions. Presets are partial configs (only the
// keys they name), so applying one leaves everything else at the user's
// current values. Both live in the state dir, outside shell.json, so a plugin
// update never resets them.
Column {
    id: root

    property var service: null
    property var serviceState: ({})

    property color foreground: "#ffffff"
    property color background: "#000000"
    property color accent: "#1e66f5"
    property color muted: "#888888"
    property color urgent: "#ff5555"
    property string fontFamily: "sans-serif"

    readonly property real fontCaption: 12

    readonly property var presets: root.service
        ? (root.service.presets || {})
        : {}
    readonly property var savedRegions: root.service
        ? (root.service.savedRegions || [])
        : []
    readonly property var cfg: root.service
        ? (root.service.config || {})
        : (root.serviceState ? (root.serviceState.config || {}) : {})
    readonly property bool regionMode: root.cfg.targetMode === "region"

    width: parent ? parent.width : 300
    spacing: 6

    function saveCurrent() {
        if (nameField.text.trim() === "")
            return;
        if (root.service && typeof root.service.savePreset === "function")
            root.service.savePreset(nameField.text, root.service.config);
    }

    function applyNamed(name) {
        if (root.service && typeof root.service.applyPreset === "function")
            root.service.applyPreset(name);
    }

    function deleteNamed(name) {
        if (root.service && typeof root.service.deletePreset === "function")
            root.service.deletePreset(name);
    }

    function saveCurrentRegion() {
        if (root.service && typeof root.service.saveRegion === "function")
            root.service.saveRegion(nameField.text.trim());
    }

    function applyNamedRegion(name) {
        if (root.service && typeof root.service.applyRegion === "function")
            root.service.applyRegion(name);
    }

    // ---- presets ---------------------------------------------------------
    Text {
        text: "Presets"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.fontCaption
        font.bold: true
    }

    Repeater {
        model: Object.keys(root.presets)

        RowLayout {
            width: root.width
            spacing: 6

            Text {
                text: modelData
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
                elide: Text.ElideMiddle
                maximumLineCount: 1
                Layout.fillWidth: true
            }

            Button {
                text: "Apply"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: root.fontCaption
                onClicked: root.applyNamed(modelData)
            }

            Button {
                text: "Delete"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: root.fontCaption
                onClicked: root.deleteNamed(modelData)
            }
        }
    }

    Text {
        visible: Object.keys(root.presets).length === 0
        text: "No presets yet — set the options how you like them, name it below and save."
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: root.fontCaption
        wrapMode: Text.WordWrap
        width: root.width
    }

    RowLayout {
        width: root.width
        spacing: 6

        TextField {
            id: nameField
            Layout.fillWidth: true
            placeholderText: "Preset name"
            foreground: root.foreground
            accent: root.accent
            font.family: root.fontFamily
            font.pixelSize: root.fontCaption
        }

        Button {
            text: "Save current"
            enabled: nameField.text.trim() !== ""
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: root.fontCaption
            onClicked: root.saveCurrent()
        }
    }

    // ---- saved regions ---------------------------------------------------
    Text {
        visible: root.regionMode
        text: "Saved regions"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.fontCaption
        font.bold: true
    }

    Repeater {
        visible: root.regionMode
        model: root.regionMode ? root.savedRegions : []

        RowLayout {
            width: root.width
            spacing: 6

            Text {
                text: (modelData && modelData.name ? modelData.name : "")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
                elide: Text.ElideMiddle
                maximumLineCount: 1
                Layout.fillWidth: true
            }

            Text {
                text: (modelData && modelData.geometry ? modelData.geometry : "")
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
            }

            Button {
                text: "Capture"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: root.fontCaption
                onClicked: root.applyNamedRegion(modelData.name)
            }
        }
    }

    Button {
        visible: root.regionMode
        text: "Save current region"
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: root.fontCaption
        onClicked: root.saveCurrentRegion()
    }
}
