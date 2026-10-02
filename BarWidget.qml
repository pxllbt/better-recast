import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// pix.recast bar widget — recording state indicator.
// Idle shows a dimmed resting glyph; left click toggles recording (or opens
// the quick menu when leftClickMenu is on), right click opens the control
// panel as a popup anchored to the button. While recording the glyph
// brightens and shows the elapsed time next to it.
BarWidget {
    id: root

    moduleName: "pix.recast"

    // State file written by Service.qml — needed because replacement bars
    // (px.bar) cannot resolve third-party services via PluginBarFacade.
    readonly property string stateFilePath: {
        var xdg = Quickshell.env("XDG_RUNTIME_DIR");
        if (!xdg || xdg.length === 0) xdg = "/tmp";
        return xdg + "/px-gsr/state.json";
    }

    property var service: null
    property var serviceState: ({})

    // Derived from either the live service object (built-in bar) or the
    // state file (replacement bar). When service is null, serviceState
    // drives display; when service is available, it takes precedence.
    readonly property string stateText: root.service
        ? (root.service.recordingState || "idle")
        : (root.serviceState.recordingState || root.serviceState.state || "idle")
    readonly property int elapsed: root.service
        ? (root.service.recordingElapsed || 0)
        : (root.serviceState.recordingElapsed || 0)

    // Popup is hosted by Panel.qml, which the bar mounts per monitor through
    // this hidden loader. The panel extends qs.Ui Panel, so the bar's popout
    // contract (open/close/opened/closeForPopoutSwitch) forwards straight to it.
    // Besides the bar/anchoring props, the panel needs the shared service — the
    // old panel-host used to inject it (shell.qml panelLoader), the bar-widget
    // loader must do the same.
    function injectPanel() {
        var target = panelLoader.item;
        if (!target)
            return;
        if ("bar" in target)
            target.bar = root.bar;
        if ("settings" in target)
            target.settings = root.settings;
        if ("anchorItem" in target)
            target.anchorItem = root;
        if ("hostWidget" in target)
            target.hostWidget = root;
        if ("service" in target)
            target.service = root.service;
        if ("serviceState" in target)
            target.serviceState = root.serviceState;
    }

    function _tryGetService() {
        if (service) return service;
        if (!bar || !bar.shell) return null;
        if (typeof bar.shell.serviceFor === "function") {
            var s = bar.shell.serviceFor("pix.recast");
            if (s) { service = s; return s; }
        }
        if (typeof bar.shell.firstPartyServiceFor === "function") {
            var f = bar.shell.firstPartyServiceFor("pix.recast");
            if (f) { service = f; return f; }
        }
        return null;
    }

    function applyServiceState(raw) {
        var parsed = {};
        try {
            parsed = JSON.parse(String(raw || "").trim() || "{}");
        } catch (e) {
            parsed = {};
        }
        root.serviceState = parsed;
        _tryGetService();
        // Push updated state to the Panel so its readonly properties
        // (cfg, gpu, state, etc.) re-evaluate with fresh data.
        if (panelLoader.item) {
            if ("service" in panelLoader.item)
                panelLoader.item.service = root.service;
            if ("serviceState" in panelLoader.item)
                panelLoader.item.serviceState = root.serviceState;
        }
    }

    function refresh() {
        _tryGetService();
        if (panelLoader.item && ("service" in panelLoader.item))
            panelLoader.item.service = root.service;
    }

    readonly property bool recording: stateText === "recording" || stateText === "paused" || stateText === "starting" || stateText === "replay"
    readonly property bool pausedState: stateText === "paused"
    readonly property bool replayActive: stateText === "replay"
    readonly property bool replayMode: Boolean(root.service
        ? (root.service.config && root.service.config.mode === "replay")
        : (root.serviceState.config && root.serviceState.config.mode === "replay"))
    readonly property int replaySeconds: root.service
        ? (root.service.config ? (root.service.config.replaySeconds || 60) : 60)
        : (root.serviceState.config ? (root.serviceState.config.replaySeconds || 60) : 60)
    readonly property bool streaming: Boolean(root.service
        ? (root.service.config && (root.service.config.mode || "record") === "stream")
        : (root.serviceState.config && (root.serviceState.config.mode || "record") === "stream"))
    readonly property bool leftClickMenu: Boolean(root.service
        ? (root.service.config && root.service.config.leftClickMenu)
        : (root.serviceState.config && root.serviceState.config.leftClickMenu))
    readonly property bool updateAvailable: panelLoader.item ? (panelLoader.item.updateAvailable === true) : false
    readonly property string updateVersionText: panelLoader.item ? (panelLoader.item.updateNewVersion || "") : ""

    function formatElapsed(sec) {
        var h = Math.floor(sec / 3600);
        var m = Math.floor((sec % 3600) / 60);
        var s = sec % 60;
        var pad = function (n) {
            return n < 10 ? "0" + n : String(n);
        };
        return (h > 0 ? pad(h) + ":" : "") + pad(m) + ":" + pad(s);
    }

    // ---- popout contract (Bar.findPanelWidget / bar.requestPopout) ----------
    readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

    function open() {
        if (panelLoader.item && panelLoader.item.open)
            panelLoader.item.open();
    }

    function close() {
        if (panelLoader.item && panelLoader.item.close)
            panelLoader.item.close();
    }

    function togglePanel() {
        if (panelLoader.item && panelLoader.item.toggle)
            panelLoader.item.toggle();
    }

    readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

    function closeForPopoutSwitch() {
        if (panelLoader.item)
            panelLoader.item.closeForPopoutSwitch();
    }

    readonly property string glyphText: replayActive ? "󰻂" : (recording ? (streaming ? "●" : (pausedState ? "󰏥" : "󰻂")) : "󰻂")
    readonly property color glyphColor: replayActive
        ? (root.bar ? root.bar.barForeground : Color.foreground)
        : (recording ? (streaming ? Color.urgent : Color.accent) : (root.bar ? root.bar.barForeground : Color.foreground))
    readonly property string tooltipBase: replayActive
        ? ("Replay buffer · last " + root.replaySeconds + "s · " + root.formatElapsed(root.elapsed) + "\n" + (leftClickMenu ? "Left-click menu · Right-click panel" : "Left-click stop buffer · Right-click panel (S saves)"))
        : (recording ? (pausedState ? "Paused" : (streaming ? "Live" : "Recording")) + " · " + formatElapsed(elapsed) + "\n" + (leftClickMenu ? "Left-click menu" : "Left-click to stop") + " · Right-click panel" : "Screen Recorder\n" + (leftClickMenu ? "Left-click menu" : (streaming ? "Left-click to go live" : "Left-click to record")) + " · Right-click panel")
    readonly property string tooltip: (updateAvailable && !replayActive && !recording)
        ? tooltipBase + "\nUpdate available: v" + updateVersionText + "\nRight-click panel to check"
        : tooltipBase

    onBarChanged: {
        refresh();
        injectPanel();
        if (!stateReadProc.running) stateReadProc.running = true;
    }
    onSettingsChanged: {
        injectPanel();
    }
    Component.onCompleted: {
        refresh();
        pollTimer.start();
    }

    Connections {
        target: root.service
        ignoreUnknownSignals: true
        function onRecordingStateChanged(value) {
            root.refresh();
        }
        function onRecordingElapsedChanged(value) {
            root.refresh();
        }
        function onConfigChanged(value) {
            root.refresh();
        }
    }

    Timer {
        interval: 1000
        running: root.recording
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!root.service) {
                if (!stateReadProc.running) stateReadProc.running = true;
            } else {
                root.refresh();
            }
        }
    }

    implicitWidth: row.implicitWidth + Style.space(10)
    implicitHeight: barSize

    Row {
        id: row
        anchors.centerIn: parent
        spacing: Style.space(5)

        Text {
            id: glyph
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyphText
            color: root.glyphColor
            opacity: root.recording ? 1 : 0.6
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            Behavior on color {
                enabled: !root.bar || root.bar.foregroundAnimationEnabled
                ColorAnimation {
                    duration: 160
                }
            }
        }

        Text {
            id: elapsedLabel
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: root.formatElapsed(root.elapsed)
            visible: root.recording && root.elapsed > 0 && !root.bar.vertical
            color: root.bar.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
        }

        Text {
            id: liveLabel
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: "LIVE"
            visible: root.streaming && root.recording && !root.bar.vertical
            color: Color.urgent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton

        onClicked: function (mouse) {
            if (mouse.button === Qt.RightButton) {
                root.togglePanel();
            } else if (mouse.button === Qt.LeftButton) {
                if (root.leftClickMenu) {
                    quickMenu.toggle();
                } else if (root.service && typeof root.service.toggle === "function") {
                    root.service.toggle();
                } else {
                    toggleActionProc.command = ["omarchy-shell", "px-recast", "toggle"];
                    toggleActionProc.running = true;
                }
            }
        }
        onEntered: if (root.bar && typeof root.bar.showTooltip === "function")
            root.bar.showTooltip(root, root.tooltip)
        onExited: if (root.bar && typeof root.bar.hideTooltip === "function")
            root.bar.hideTooltip(root)
    }

    QuickMenu {
        id: quickMenu
        bar: root.bar
        anchorItem: root
        service: root.service
        serviceState: root.serviceState
    }

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: {
            root.injectPanel();
            Qt.callLater(root.injectPanel);
        }
    }

    // State file reader — replacement bars can't resolve third-party services,
    // so the Service.qml writes a JSON snapshot that this widget polls via
    // a Process (cat). FileView.reload() can silently skip updates in some
    // environments (inotify misses changes, mtime granularity, etc.), so we
    // read via Process which always returns the latest content.
    Process {
        id: stateReadProc
        running: false
        command: ["cat", root.stateFilePath]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.applyServiceState(text)
            }
        }
    }

    // Polling timer — reads state.json every 1s.
    Timer {
        id: pollTimer
        interval: 1000
        repeat: true
        onTriggered: {
            if (!stateReadProc.running) {
                stateReadProc.running = true;
            }
        }
    }

    // IPC fallback for toggle when the service object is not reachable
    // (px.shell issue #41: replacement bars can't resolve third-party services).
    Process {
        id: toggleActionProc
        running: false
    }
}
