import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Config.js" as Config
import "Picker.js" as Picker

// Left-click menu on the bar widget: capture type, target, start/stop. It is
// its own popout owner, so the bar's one-popout-at-a-time rule swaps it with
// the settings panel and other widgets' popups.
Item {
    id: root

    property var bar: null
    property Item anchorItem: null
    property var service: null
    property var serviceState: ({})

    property bool opened: false
    property bool popoutSwitchClosing: false

    function open() {
        opened = true;
    }
    function close() {
        opened = false;
    }
    function toggle() {
        opened = !opened;
    }
    function closeForPopoutSwitch() {
        popoutSwitchClosing = true;
        close();
        Qt.callLater(function () {
            root.popoutSwitchClosing = false;
        });
    }

    readonly property var cfg: service ? service.config : (serviceState.config || Config.defaultConfig())
    readonly property string captureState: service ? service.state : (serviceState.state || "idle")
    readonly property bool running: captureState === "recording" || captureState === "paused" || captureState === "replay"
    readonly property bool busy: captureState === "starting" || captureState === "stopping" || (service !== null && service.picking)
    readonly property string mode: cfg.mode || "record"
    readonly property string targetMode: cfg.targetMode || "portal"
    readonly property var monitors: service ? service.monitors : (serviceState.monitors || [])
    readonly property string regionLabel: {
        var spec = Picker.regionForStart(cfg, service ? service.pendingRegion : "");
        return spec === "" ? "Pick when starting" : spec.replace(/^monitor:/, "Monitor ");
    }

    function call(fn) {
        if (service && typeof service[fn] === "function")
            service[fn]();
        else
            Quickshell.execDetached(["omarchy-shell", "px-recast", fn]);
    }

    function setConfig(key, value) {
        if (service)
            service.setConfig(key, value);
        else
            Quickshell.execDetached(["omarchy-shell", "px-recast", "config", key, String(value)]);
    }

    // Start once the menu has faded out, so it isn't in the first frames.
    function start() {
        close();
        startDelay.restart();
    }

    function stop() {
        close();
        call("stop");
    }

    function primary() {
        if (busy)
            return;
        if (running)
            stop();
        else
            start();
    }

    Timer {
        id: startDelay
        interval: 200
        onTriggered: root.call("toggle")
    }

    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        bar: root.bar
        owner: root
        focusTarget: keyCatcher
        open: root.opened
        contentWidth: panel.fittedContentWidth(Style.space(320))
        contentHeight: panel.fittedContentHeight(content.implicitHeight)

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()
            onActivateRequested: root.primary()

            ColumnLayout {
                id: content
                width: parent.width
                spacing: Style.space(10)

                Text {
                    text: "CAPTURE"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                }

                // Type and target can't change while a capture runs.
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(10)
                    enabled: !root.running && !root.busy
                    opacity: enabled ? 1 : 0.45

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(8)

                        Repeater {
                            model: [
                                { value: "record", label: "Record" },
                                { value: "stream", label: "Stream" },
                                { value: "replay", label: "Replay" }
                            ]

                            Button {
                                required property var modelData
                                text: modelData.label
                                Layout.fillWidth: true
                                selected: root.mode === modelData.value
                                onClicked: {
                                    if (root.mode !== modelData.value)
                                        root.setConfig("mode", modelData.value);
                                }
                            }
                        }
                    }

                    Dropdown {
                        label: ""
                        Layout.fillWidth: true
                        value: root.targetMode
                        options: [
                            { value: "portal", label: "Window / portal" },
                            { value: "monitor", label: "Monitor" },
                            { value: "region", label: "Region" }
                        ]
                        onChanged: function (v) {
                            root.setConfig("targetMode", v);
                        }
                    }

                    Dropdown {
                        label: ""
                        Layout.fillWidth: true
                        visible: root.targetMode === "monitor"
                        value: root.cfg.monitorName || ""
                        options: root.monitors.map(function (m) {
                            return { value: m.name, label: m.name + " (" + m.resolution + ")" };
                        })
                        onChanged: function (v) {
                            root.setConfig("monitorName", v);
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        visible: root.targetMode === "region"
                        spacing: Style.space(8)

                        Text {
                            text: root.regionLabel
                            color: Color.muted
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }

                        Button {
                            text: "Pick now"
                                onClicked: {
                                root.close();
                                root.call("pickRegion");
                            }
                        }
                    }
                }

                Button {
                    Layout.fillWidth: true
                    implicitHeight: Style.spacing.controlHeight * 1.3
                    fontSize: Style.font.subtitle
                    enabled: !root.busy
                    accent: root.running ? Color.urgent : Color.accent
                    text: {
                        if (root.captureState === "starting")
                            return "Starting…";
                        if (root.captureState === "stopping")
                            return "Stopping…";
                        if (root.busy)
                            return "Picking region…";
                        if (root.running)
                            return root.captureState === "replay" ? "■  Stop replay buffer" : "■  Stop";
                        if (root.mode === "stream")
                            return "●  Go live";
                        return root.mode === "replay" ? "●  Start replay buffer" : "●  Start recording";
                    }
                    onClicked: root.primary()
                }

                Button {
                    Layout.fillWidth: true
                    visible: root.captureState === "replay"
                    text: "Save replay"
                    onClicked: root.call("saveReplay")
                }
            }
        }
    }
}
