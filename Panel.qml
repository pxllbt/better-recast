import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Binds.js" as Binds
import "Config.js" as Config
import "PostProcess.js" as PostProcess

// pix.recast control panel — the settings popup anchored to the bar widget
// (right click) or `omarchy-shell shell summon pix.recast`. Reads recording state
// and config off the pix.recast service; writes settings through service.setConfig.
// Two modes share one optimized encode pipeline:
//   record  — regular screen recording (the "Better Recast")
//   stream  — RTMP live streaming to TikTok/Twitch/YouTube/any platform
//
// Extends qs.Ui Panel so the bar's popout contract (opened/open/close/toggle/
// closeForPopoutSwitch) comes from the shared base; the popup window is a
// KeyboardPanel anchored to the bar button.
Panel {
    id: root

    moduleName: "pix.recast"
    ipcTarget: "pix.recast"
    manageIpc: false

    // ---- host injections ----------------------------------------------------
    property var shell: null
    property var manifest: null
    property var service: null
    property var serviceState: ({})
    // Optimistic override for config keys set while the service is unreachable.
    // Cleared when the state file is next polled and confirms the change.
    property var _pendingConfig: ({})
    // Only clear pending config when the state file has caught up to our
    // optimistic change — otherwise the UI flickers back between the
    // optimistic update and the 2 s poll interval.
    function _clearPendingIfConfirmed() {
        if (!root.serviceState || !root.serviceState.config)
            return;
        var allConfirmed = true;
        for (var k in root._pendingConfig) {
            if (root.serviceState.config[k] !== root._pendingConfig[k]) {
                allConfirmed = false;
                break;
            }
        }
        if (allConfirmed)
            root._pendingConfig = ({});
    }
    // Rolling in-panel error log (most recent last, capped at 6).
    property var _errorLog: []
    function _pushError(msg) {
        if (!msg)
            return;
        var next = root._errorLog.slice(-5);
        next.push(msg);
        root._errorLog = next;
    }
    // Error message: pulled from the live service or the state file.
    readonly property string errorMessage: root.service
        ? (root.service.errorMessage || "")
        : (root.serviceState ? (root.serviceState.errorMessage || "") : "")
    property var anchorItem: null
    property var hostWidget: null
    property string omarchyPath: ""

    // ---- update check -----------------------------------------------------
    property bool updateAvailable: false
    property string updateCurrentVersion: "1.1.0"
    property string updateNewVersion: ""
    property int updateCommitsBehind: 0
    property bool updateChecking: false
    property string updateError: ""

    // ---- theme --------------------------------------------------------------
    readonly property color foreground: Color.foreground
    readonly property color background: Color.background
    readonly property color accent: Color.accent
    readonly property color muted: Color.muted
    readonly property color urgent: Color.urgent
    readonly property string fontFamily: Style.font.family

    // Effective config: live service config → state file config (with optimistic
    // overrides) → settings → defaults
    // Using a mutable property allows us to force re-evaluation via the
    // handlers below, working around Qt 6's QML engine not always
    // re-evaluating complex readonly property var bindings.
    property var cfg: root._computeCfg()

    function _computeCfg() {
        if (root.service && root.service.config)
            return root.service.config;
        var base = {};
        if (root.serviceState && root.serviceState.config)
            base = root.serviceState.config;
        if (root.settings && typeof root.settings === "object")
            base = Object.assign({}, base, root.settings);
        if (Object.keys(base).length === 0)
            base = Config.defaultConfig();
        if (Object.keys(root._pendingConfig).length > 0) {
            var merged = Object.assign({}, base);
            for (var k in root._pendingConfig)
                merged[k] = root._pendingConfig[k];
            return merged;
        }
        return base;
    }

    onServiceChanged: {
        root.cfg = root._computeCfg();
    }
    onSettingsChanged: {
        root.cfg = root._computeCfg();
    }
    onServiceStateChanged: {
        root._clearPendingIfConfirmed();
        root.cfg = root._computeCfg();
    }

    Connections {
        target: root.service
        ignoreUnknownSignals: true
        onConfigChanged: {
            root.cfg = root._computeCfg();
        }
    }

    // GPU info: live service → state file → defaults
    readonly property var gpu: root.service
        ? (root.service.gpuInfo || {})
        : (root.serviceState && root.serviceState.gpuInfo
            ? root.serviceState.gpuInfo
            : { vendor: "unknown", codecs: [] })
    // Audio devices for the desktop/mic selectors (live service → state file)
    readonly property var audioDevices: root.service
        ? (root.service.audioDevices || [])
        : (root.serviceState ? (root.serviceState.audioDevices || []) : [])
    readonly property string state: root.service
        ? (root.service.recordingState || root.service.state || "idle")
        : (root.serviceState && (root.serviceState.recordingState || root.serviceState.state) || "idle")
    readonly property bool recording: state === "recording" || state === "paused"
    readonly property bool paused: state === "paused"
    readonly property bool busy: state === "starting" || state === "stopping"
    readonly property bool isStream: root.service && root.service.config
        ? root.service.config.mode === "stream"
        : (root.cfg && root.cfg.mode === "stream")
    readonly property bool isReplay: root.service && root.service.config
        ? root.service.config.mode === "replay"
        : (root.cfg && root.cfg.mode === "replay")
    readonly property bool replayActive: root.service
        ? (root.service.replayActive === true)
        : (root.serviceState ? (root.serviceState.replayActive === true) : false)
    readonly property int elapsed: root.service
        ? (root.service.recordingElapsed || 0)
        : (root.serviceState ? (root.serviceState.recordingElapsed || 0) : 0)
    readonly property string lastSavedPath: root.service
        ? (root.service.lastSavedPath || "")
        : (root.serviceState ? (root.serviceState.lastSavedPath || "") : "")

    function formatElapsed(sec) {
        var h = Math.floor(sec / 3600);
        var m = Math.floor((sec % 3600) / 60);
        var s = sec % 60;
        var pad = function (n) {
            return n < 10 ? "0" + n : String(n);
        };
        return (h > 0 ? pad(h) + ":" : "") + pad(m) + ":" + pad(s);
    }

    function settingsSummary() {
        var c = root.cfg;
        var parts = [];
        if (c.codec && c.codec !== "auto")
            parts.push((c.codec || "").toUpperCase());
        if (c.quality && c.quality !== "auto")
            parts.push(c.quality);
        if (c.frameMode && c.frameMode !== "auto" && c.frameMode !== "cfr")
            parts.push(c.frameMode);
        if (c.container)
            parts.push(c.container);
        if (c.fps)
            parts.push(c.fps + " fps");
        if (c.encoder === "cpu")
            parts.push("CPU encoder");
        if (c.audioEnabled === false)
            parts.push("no audio");
        else {
            parts.push("audio");
            if (c.audioMicrophone)
                parts.push("mic");
        }
        return parts.length ? parts.join("  \u00b7  ") : "";
    }

    function stateLabel() {
        if (state === "recording") {
            var kind = root.isStream ? "LIVE" : "REC";
            var elapsed = root.service ? (root.service.recordingElapsed || 0) : (root.serviceState.recordingElapsed || 0);
            return kind + " " + formatElapsed(elapsed);
        }
        if (state === "paused") {
            var elapsed2 = root.service ? (root.service.recordingElapsed || 0) : (root.serviceState.recordingElapsed || 0);
            return "PAUSED " + formatElapsed(elapsed2);
        }
        if (state === "starting")
            return "STARTING…";
        if (state === "stopping")
            return "STOPPING…";
        if (state === "error")
            return "ERROR";
        return root.isStream ? "Ready to go live" : "Idle";
    }

    function targetLabel() {
        var mode = root.cfg.targetMode || "portal";
        if (mode === "monitor")
            return root.cfg.monitorName || root.cfg._lastMonitor || "Monitor";
        if (mode === "region")
            return root.cfg._lastRegion || "Pick region";
        return "Portal / window";
    }

    function platformLabel() {
        var def = Config.streamPlatformDefaults(root.cfg.streamPlatform || "custom");
        return def.label;
    }

    function effectiveEncoder() {
        if (root.service && root.service.config && root.service.config.encoder) {
            return root.service.config.encoder;
        }
        if (root.serviceState && root.serviceState.config && root.serviceState.config.encoder)
            return root.serviceState.config.encoder;
        var eff = Config.applyGpuProfile(root.cfg, root.gpu);
        return eff.encoder || "gpu";
    }

    function effectiveCodec() {
        if (root.isStream)
            return "h264";
        if (root.service && root.service.config && root.service.config.codec && root.service.config.codec !== "auto") {
            return root.service.config.codec;
        }
        if (root.serviceState && root.serviceState.config && root.serviceState.config.codec && root.serviceState.config.codec !== "auto")
            return root.serviceState.config.codec;
        var eff = Config.applyGpuProfile(root.cfg, root.gpu);
        return eff.codec || "h264";
    }

    function effectiveQuality() {
        if (root.isStream)
            return String(root.cfg.streamKbps || 6000) + " kbps";
        if (root.service && root.service.config && root.service.config.quality && root.service.config.quality !== "auto") {
            return root.service.config.quality;
        }
        if (root.serviceState && root.serviceState.config && root.serviceState.config.quality && root.serviceState.config.quality !== "auto")
            return root.serviceState.config.quality;
        var eff = Config.applyGpuProfile(root.cfg, root.gpu);
        return eff.quality || "very_high";
    }

    function effectiveBitrate() {
        if (root.isStream)
            return "CBR";
        var eff = Config.applyGpuProfile(root.cfg, root.gpu);
        return eff.bitrateMode || "vbr";
    }

    function monitorOptions() {
        var list = [];
        var ms = root.service ? (root.service.monitors || [])
            : (root.serviceState ? (root.serviceState.monitors || []) : []);
        for (var i = 0; i < ms.length; i++) {
            list.push({
                value: ms[i].name,
                label: ms[i].name + " (" + ms[i].resolution + ")"
            });
        }
        return list;
    }

    function audioDeviceOptions() {
        var list = [];
        for (var i = 0; i < root.audioDevices.length; i++) {
            var d = root.audioDevices[i];
            list.push({
                value: d.id,
                label: d.name || d.id
            });
        }
        return list;
    }

    readonly property var resolvedBinds: root.service
        ? (root.service.resolvedBinds || {})
        : (root.serviceState ? (root.serviceState.resolvedBinds || {}) : {})
    // Action id of the keybind field being edited ("" = none), and the
    // action ids whose last entry wasn't a valid combo.
    property string _bindFieldFocus: ""
    property var _bindErrors: ({})

    function bindPlaceholder(actionId) {
        var r = root.resolvedBinds[actionId];
        if (!r || r.combo === "" || r.source === "override")
            return "Automatic";
        return r.combo + " (" + Binds.SOURCE_LABELS[r.source] + ")";
    }

    function setBindOverride(action, text) {
        var t = String(text || "").trim();
        var combo = t === "" ? "" : Binds.normalizeCombo(t);
        var errors = Object.assign({}, root._bindErrors);
        errors[action.id] = t !== "" && combo === "";
        root._bindErrors = errors;
        if (!errors[action.id] && combo !== (root.cfg[action.configKey] || ""))
            root.setConfig(action.configKey, combo);
    }

    function setOverlayMode(mode) {
        var current = root.cfg.overlayMode || "auto";
        if (mode === current)
            return;
        // Docking a floating overlay restores the mode it was popped out of.
        if (mode === "float")
            root.setConfig("overlayPrevMode", current);
        root.setConfig("overlayMode", mode);
    }

    // Desktop ids from `gio mime video/mp4`, and those of them that resolve
    // to a desktop entry as [{ value: "<id>.desktop", label }]. Reading
    // `applications` re-resolves once the entry scan (re)loads.
    property var openWithIds: []
    readonly property var openWithApps: {
        var loaded = DesktopEntries.applications.values;
        var apps = [];
        for (var i = 0; i < root.openWithIds.length && loaded.length > 0; i++) {
            var entry = DesktopEntries.byId(root.openWithIds[i].replace(/\.desktop$/, ""));
            if (entry && entry.name)
                apps.push({ value: root.openWithIds[i], label: entry.name });
        }
        return apps;
    }

    function openWithOptions() {
        var opts = [{ value: "", label: "None" }].concat(root.openWithApps);
        var cur = root.cfg.postProcessApp || "";
        if (cur !== "" && cur !== "custom" && !opts.some(function (o) { return o.value === cur; }))
            opts.push({ value: cur, label: cur.replace(/\.desktop$/, "") });
        opts.push({ value: "custom", label: "Custom…" });
        return opts;
    }

    // Numeric config read that never coerces 0 to the fallback.
    function cfgNum(key, fallback) {
        var v = root.cfg ? root.cfg[key] : undefined;
        var n = Number(v);
        if (v === undefined || v === null || isNaN(n))
            return fallback;
        return n;
    }

    function setConfig(key, value) {
        if (root.service && typeof root.service.setConfig === "function") {
            root.service.setConfig(key, value);
            return;
        }
        // Try the bar shell's updateEntryInline — this only works for the
        // built-in omarchy.bar because the scoped PluginShellApi resolves the
        // service and writes to shell.json directly. For replacement bars
        // (px.bar) the scoped API exists but updateEntryInline silently
        // returns false because it only accepts the bar widget's own plugin ID.
        if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
            var entry = { id: "pix.recast" };
            var cfg = root.cfg || Config.defaultConfig();
            for (var k in cfg)
                if (k !== "id")
                    entry[k] = cfg[k];
            entry[key] = value;
            if (root.bar.shell.updateEntryInline("pix.recast", entry))
                return;
        }
        // IPC fallback for replacement bars (px.bar): no service access,
        // so write the config change into the state file via IPC.
        configIpcProc.running = false;
        configIpcProc.command = ["omarchy-shell", "px-recast", "config", key, String(value)];
        configIpcProc.running = true;
        // Optimistically update local state so the UI responds immediately.
        var next = Object.assign({}, root._pendingConfig);
        next[key] = value;
        root._pendingConfig = next;
    }

    // Stream URL/key are session-only unless "remember" is on, so the key never
    // lands in shell.json by default.
    function setStreamField(key, value) {
        if (root.service) {
            if (root.cfg.streamRemember === true)
                root.service.setConfig(key, value);
            else if (typeof root.service.setSessionConfig === "function")
                root.service.setSessionConfig(key, value);
            else
                root.service.setConfig(key, value);
        } else if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
            var entry = {
                id: "pix.recast"
            };
            for (var k in root.settings)
                if (k !== "id")
                    entry[k] = root.settings[k];
            entry[key] = value;
            root.bar.shell.updateEntryInline("pix.recast", entry);
        }
    }

    function platformOptions() {
        return [
            {
                value: "tiktok",
                label: "TikTok Live"
            },
            {
                value: "twitch",
                label: "Twitch"
            },
            {
                value: "youtube",
                label: "YouTube"
            },
            {
                value: "custom",
                label: "Custom / Other"
            }
        ];
    }

    // Apply gsr's recommended encode profile for the chosen platform. Resolution
    // is only suggested when the user hasn't pinned their own.
    function applyPlatformDefaults(platform) {
        var def = Config.streamPlatformDefaults(platform);
        var hadResolution = root.cfg.resolution && root.cfg.resolution !== "";
        root.setConfig("streamPlatform", platform);
        root.setConfig("streamKbps", def.kbps);
        root.setConfig("fps", def.fps);
        if (!hadResolution)
            root.setConfig("resolution", def.resolution);
    }

    function toggleRecording() {
        if (root.service && typeof root.service.toggle === "function") {
            root.service.toggle();
        } else {
            toggleIpcAction.command = ["omarchy-shell", "px-recast", "toggle"];
            toggleIpcAction.running = true;
        }
    }

    function pauseRecording() {
        if (root.service && typeof root.service.pause === "function") {
            root.service.pause();
        } else {
            ipcActionProc.command = ["omarchy-shell", "px-recast", "pause"];
            ipcActionProc.running = true;
        }
    }

    function resumeRecording() {
        if (root.service && typeof root.service.resume === "function") {
            root.service.resume();
        } else {
            ipcActionProc.command = ["omarchy-shell", "px-recast", "resume"];
            ipcActionProc.running = true;
        }
    }

    function pickRegion() {
        if (root.service && typeof root.service.pickRegion === "function") {
            root.service.pickRegion();
        } else {
            ipcActionProc.command = ["omarchy-shell", "px-recast", "pickRegion"];
            ipcActionProc.running = true;
        }
    }

    function saveReplay() {
        if (!root.isReplay)
            return;
        if (root.service && typeof root.service.saveReplay === "function") {
            root.service.saveReplay();
        } else {
            ipcActionProc.command = ["omarchy-shell", "px-recast", "saveReplay"];
            ipcActionProc.running = true;
        }
    }

    // Popup is driven by the qs.Ui Panel base: open()/close()/toggle()/opened
    // come from the PanelController, closeForPopoutSwitch() keeps the card
    // visible while the bar hands the popout over to another panel, and
    // KeyboardPanel shows it anchored to the bar button.
    function open() {
        root.controller.show();
        mimeAppsProc.running = true;
        if (root.service && typeof root.service.refreshGpuInfo === "function")
            root.service.refreshGpuInfo();
    }

    onOpenedChanged: {
        if (root.service)
            root.service.panelOpen = root.opened;
    }

    function requestClose() {
        root.close();
    }

    // ---- popup window -------------------------------------------------------
    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        bar: root.bar
        owner: root.hostWidget || root
        focusTarget: keyCatcher
        open: root.opened
        centerOnBar: false
        contentWidth: panel.fittedContentWidth(Style.space(460))
        contentHeight: panel.fittedContentHeight(Style.space(440))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            // While a spinbox is being edited, forward keys to the field so the
            // S shortcut can't fire mid-typing.
            blocked: streamKbpsField.field.activeFocus
                || fpsField.field.activeFocus
                || audioBitrateField.field.activeFocus
                || keyframeField.field.activeFocus
                || replaySecondsField.field.activeFocus
                || replayBitrateField.field.activeFocus
                || replaySaveLengthField.field.activeFocus
                || outputDirField.activeFocus
                || postProcessCommandField.activeFocus
                || overlaySecondsField.field.activeFocus
                || root._bindFieldFocus !== ""
            onCloseRequested: root.requestClose()
            onActivateRequested: root.toggleRecording()
            onTextKey: function(t) {
                if ((t === "s" || t === "S") && root.isReplay)
                    root.saveReplay();
            }

            ScrollView {
                anchors.fill: parent
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ScrollBar.vertical.policy: contentColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

                Column {
                    id: contentColumn
                    width: parent.width
                    spacing: Style.space(12)

                    // ---- Header: title + live state ------------------------------------
                    RowLayout {
                        width: parent.width
                        spacing: Style.space(10)

                        Text {
                            text: "Better Recast"
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.title
                            font.bold: true
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }

                        Text {
                            text: root.stateLabel()
                            color: {
                                if (root.state === "recording")
                                    return root.isStream ? root.urgent : root.accent;
                                if (root.state === "error")
                                    return root.urgent;
                                return root.muted;
                            }
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
                        }
                    }

                    // ---- Mode toggle (record / stream) ----------------------------------
                    RowLayout {
                        width: parent.width
                        spacing: Style.space(8)

                        Button {
                            text: "Record"
                            Layout.fillWidth: true
                            selected: !root.isStream && !root.isReplay
                            foreground: root.foreground
                            accent: root.accent
                            fontFamily: root.fontFamily
                            fontSize: Style.font.body
                            onClicked: {
                                if (root.isStream || root.isReplay)
                                    root.setConfig("mode", "record");
                            }
                        }

                        Button {
                            text: "Stream"
                            Layout.fillWidth: true
                            selected: root.isStream
                            foreground: root.foreground
                            accent: root.accent
                            fontFamily: root.fontFamily
                            fontSize: Style.font.body
                            onClicked: {
                                if (!root.isStream)
                                    root.setConfig("mode", "stream");
                            }
                        }

                        Button {
                            text: "Replay"
                            Layout.fillWidth: true
                            selected: root.isReplay
                            foreground: root.foreground
                            accent: root.accent
                            fontFamily: root.fontFamily
                            fontSize: Style.font.body
                            onClicked: {
                                if (!root.isReplay)
                                    root.setConfig("mode", "replay");
                            }
                        }
                    }

                    // ---- Primary action button ------------------------------------------
                    Button {
                        width: parent.width
                        height: Style.spacing.controlHeight * 1.4
                        foreground: root.foreground
                        accent: root.accent
                        fontFamily: root.fontFamily
                        fontSize: Style.font.title
                        text: {
                            if (root.busy)
                                return root.state === "starting" ? "Starting…" : "Stopping…";
                            if (root.isReplay)
                                return "●  Start buffer";
                            if (root.recording)
                                return root.paused ? "▶  Resume" : (root.isStream ? "■  Stop stream" : "■  Stop");
                            if (root.replayActive)
                                return "▶  Save replay";
                            return root.isStream ? "●  Go live" : "●  Record";
                        }
                        onClicked: {
                            if (root.isReplay)
                                root.toggleRecording();
                            else if (root.replayActive)
                                root.saveReplay();
                            else
                                root.toggleRecording();
                        }
                    }

                    // Replay buffer control row: save (S) + stop buffer.
                    RowLayout {
                        width: parent.width
                        spacing: Style.space(8)
                        visible: root.isReplay

                        Button {
                            text: "Save replay"
                            foreground: root.foreground
                            accent: root.accent
                            fontFamily: root.fontFamily
                            onClicked: root.saveReplay()
                        }

                        Button {
                            text: "Stop buffer"
                            foreground: root.foreground
                            accent: root.urgent
                            fontFamily: root.fontFamily
                            onClicked: root.toggleRecording()
                        }

                        Text {
                            text: "Last " + String(root.cfg.replaySeconds || 60) + "s · " + root.formatElapsed(root.elapsed)
                                + " · " + String(Math.min(100, Math.round(root.elapsed / (root.cfg.replaySeconds || 60) * 100))) + "%"
                            color: root.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: Style.space(8)
                        visible: root.recording && !root.isStream

                        Button {
                            id: pauseButton
                            text: root.paused ? "Resume" : "Pause"
                            onClicked: {
                                if (root.paused)
                                    root.resumeRecording();
                                else
                                    root.pauseRecording();
                            }
                        }

                        Text {
                            text: (root.service && root.service.recordingFile) ? "Saving to:\n" + root.service.recordingFile
                                : (root.serviceState && root.serviceState.recordingFile ? "Saving to:\n" + root.serviceState.recordingFile : "")
                            color: root.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - pauseButton.width - Style.space(8)
                            wrapMode: Text.WordWrap
                        }
                    }

                    Text {
                        visible: root.recording && root.isStream
                        text: "Streaming to " + root.platformLabel() + " · " + String(root.cfg.streamKbps || 6000) + " kbps CBR"
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        width: parent.width
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        visible: !root.recording && root.isStream && (!root.cfg.streamUrl || !root.cfg.streamKey)
                        text: "Set a stream URL and key below, then press Go live."
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        width: parent.width
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        visible: root.state === "error" && root.errorMessage.length > 0
                        text: "Error: " + root.errorMessage
                        color: root.urgent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }

                    PanelSeparator {
                        foreground: root.foreground
                    }

                    // ---- Capture target --------------------------------------------------
                    Column {
                        width: parent.width
                        spacing: Style.space(8)

                        PanelSectionHeader {
                            text: "CAPTURE"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        GridLayout {
                            width: parent.width
                            columns: 2
                            columnSpacing: Style.space(10)
                            rowSpacing: Style.space(8)

                            Text {
                                text: "Target"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Dropdown {
                                id: targetDropdown
                                label: ""
                                value: root.cfg.targetMode || "portal"
                                options: [
                                    {
                                        value: "portal",
                                        label: "Window / portal"
                                    },
                                    {
                                        value: "monitor",
                                        label: "Monitor"
                                    },
                                    {
                                        value: "region",
                                        label: "Region"
                                    }
                                ]
                                foreground: root.foreground
                                background: root.background
                                accent: root.accent
                                fontFamily: root.fontFamily
                                Layout.fillWidth: true
                                onChanged: function (v) {
                                    root.setConfig("targetMode", v);
                                }
                            }

                            Text {
                                text: "Monitor"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                visible: (root.cfg.targetMode || "portal") === "monitor"
                            }
                            Dropdown {
                                id: monitorDropdown
                                label: ""
                                visible: (root.cfg.targetMode || "portal") === "monitor"
                                value: root.cfg.monitorName || ""
                                options: root.monitorOptions()
                                foreground: root.foreground
                                background: root.background
                                accent: root.accent
                                fontFamily: root.fontFamily
                                Layout.fillWidth: true
                                onChanged: function (v) {
                                    root.setConfig("monitorName", v);
                                }
                            }
                        }

                        Row {
                            width: parent.width
                            spacing: Style.space(8)
                            visible: (root.cfg.targetMode || "portal") === "region"

                            Button {
                                text: root.cfg._lastRegion ? "Re-pick region" : "Pick region"
                                onClicked: root.pickRegion()
                            }

                            Text {
                                text: root.cfg._lastRegion ? root.cfg._lastRegion : "No region selected"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        RowLayout {
                            width: parent.width
                            spacing: Style.space(8)
                            visible: (root.cfg.targetMode || "portal") === "region"

                            ToggleSwitch {
                                checked: root.cfg.regionAskEachTime === true
                                foreground: root.foreground
                                accent: root.accent
                                Layout.alignment: Qt.AlignVCenter
                                onToggled: root.setConfig("regionAskEachTime", !root.cfg.regionAskEachTime)
                            }

                            Text {
                                text: "Pick a new region each time"
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                elide: Text.ElideRight
                            }
                        }

                        RowLayout {
                            width: parent.width
                            spacing: Style.space(8)

                            ToggleSwitch {
                                checked: root.cfg.leftClickMenu === true
                                foreground: root.foreground
                                accent: root.accent
                                Layout.alignment: Qt.AlignVCenter
                                onToggled: root.setConfig("leftClickMenu", !root.cfg.leftClickMenu)
                            }

                            Column {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter

                                Text {
                                    text: "Left-click menu"
                                    color: root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                }

                                Text {
                                    width: parent.width
                                    text: "Left-click the bar icon to pick capture type and target, then start"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }

                    PanelSeparator {
                        foreground: root.foreground
                    }

                    // ---- Hardware / detection -------------------------------------------
                    Column {
                        width: parent.width
                        spacing: Style.space(8)

                        PanelSectionHeader {
                            text: "DETECTED HARDWARE"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        GridLayout {
                            width: parent.width
                            columns: 2
                            columnSpacing: Style.space(10)
                            rowSpacing: Style.space(4)

                            Text {
                                text: "GPU"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Text {
                                text: String(root.gpu.vendor || "unknown").toUpperCase()
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }

                            Text {
                                text: "Encoder"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Text {
                                text: root.effectiveEncoder().toUpperCase() + " (" + String(root.gpu.backend || "cpu").toUpperCase() + ")"
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }

                            Text {
                                text: "Codec"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Text {
                                text: root.effectiveCodec().toUpperCase()
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }

                            Text {
                                text: "Bitrate"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Text {
                                text: root.effectiveBitrate().toUpperCase()
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }

                            Text {
                                text: "Quality"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Text {
                                text: root.effectiveQuality().toUpperCase()
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }
                        }

                        Text {
                            text: "Codecs: " + (root.gpu.codecs || []).join(", ")
                            color: root.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            wrapMode: Text.WordWrap
                            width: parent.width
                        }
                    }

                    PanelSeparator {
                        foreground: root.foreground
                    }

                    // ---- Streaming (mode == stream) --------------------------------------
                    Column {
                        width: parent.width
                        spacing: Style.space(8)
                        visible: root.isStream

                        PanelSectionHeader {
                            text: "STREAM"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        GridLayout {
                            width: parent.width
                            columns: 2
                            columnSpacing: Style.space(10)
                            rowSpacing: Style.space(8)

                            Text {
                                text: "Platform"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Dropdown {
                                id: platformDropdown
                                label: ""
                                value: root.cfg.streamPlatform || "custom"
                                options: root.platformOptions()
                                foreground: root.foreground
                                background: root.background
                                accent: root.accent
                                fontFamily: root.fontFamily
                                Layout.fillWidth: true
                                onChanged: function (v) {
                                    root.applyPlatformDefaults(v);
                                }
                            }

                            Text {
                                text: "Server URL"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            TextField {
                                text: root.cfg.streamUrl || ""
                                placeholderText: "rtmp://push.tiktokcdn.com/live/"
                                foreground: root.foreground
                                accent: root.accent
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.fillWidth: true
                                onEditingFinished: root.setStreamField("streamUrl", text)
                            }

                            Text {
                                text: "Stream key"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            TextField {
                                text: root.cfg.streamKey || ""
                                password: true
                                placeholderText: "live stream key"
                                foreground: root.foreground
                                accent: root.accent
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.fillWidth: true
                                onEditingFinished: root.setStreamField("streamKey", text)
                            }

                            Text {
                                text: "Bitrate"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            NumberField {
                                id: streamKbpsField
                                value: Number(root.cfg.streamKbps || 6000)
                                from: 32
                                to: 20000
                                stepSize: 500
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                fontSize: Style.font.caption
                                onModified: function (v) {
                                    root.setConfig("streamKbps", v);
                                }
                            }

                            Text {
                                text: "Remember key"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            ToggleSwitch {
                                checked: root.cfg.streamRemember === true
                                foreground: root.foreground
                                accent: root.accent
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                onToggled: {
                                    var next = !root.cfg.streamRemember;
                                    root.setConfig("streamRemember", next);
                                    // Persist the session URL/key the moment remembering is enabled.
                                    if (next && root.service && typeof root.service.persistConfig === "function") {
                                        root.service.persistConfig();
                                    }
                                }
                            }

                            Text {
                                text: "Save local copy"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            ToggleSwitch {
                                checked: root.cfg.streamBackupLocal === true
                                foreground: root.foreground
                                accent: root.accent
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                onToggled: root.setConfig("streamBackupLocal", !root.cfg.streamBackupLocal)
                            }
                        }

                        Button {
                            text: "Reset to " + root.platformLabel() + " defaults"
                            onClicked: root.applyPlatformDefaults(root.cfg.streamPlatform || "custom")
                        }

                        Text {
                            text: {
                                var p = root.cfg.streamPlatform || "custom";
                                if (p === "tiktok")
                                    return "TikTok: H.264 + AAC, CBR, portrait 9:16 recommended. Requires 18+ and 1000+ followers; the key is temporary and only works with the matching Server URL.";
                                if (p === "twitch")
                                    return "Twitch: ingest rtmp://live.twitch.tv/app + your stream key from the Creator Dashboard.";
                                if (p === "youtube")
                                    return "YouTube: find your stream key under Go live; the Server URL is usually rtmp://a.rtmp.youtube.com/live2.";
                                return "Custom: point the Server URL + key at any RTMP-compatible service.";
                            }
                            color: root.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                            width: parent.width
                        }
                    }

                    // ---- Instant replay (mode == replay) ----------------------------------
                    Column {
                        width: parent.width
                        spacing: Style.space(8)
                        visible: root.isReplay

                        PanelSectionHeader {
                            text: "REPLAY"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        GridLayout {
                            width: parent.width
                            columns: 2
                            columnSpacing: Style.space(10)
                            rowSpacing: Style.space(8)

                            Text {
                                text: "Buffer length"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            NumberField {
                                id: replaySecondsField
                                value: Number(root.cfg.replaySeconds || 60)
                                from: 5
                                to: 600
                                stepSize: 5
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                fontSize: Style.font.caption
                                onModified: function (v) {
                                    root.setConfig("replaySeconds", v);
                                }
                            }

                            Text {
                                text: "Buffer storage"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Dropdown {
                                label: ""
                                value: root.cfg.replayStorage || "ram"
                                options: [
                                    {
                                        value: "ram",
                                        label: "RAM (faster)"
                                    },
                                    {
                                        value: "disk",
                                        label: "Disk"
                                    }
                                ]
                                foreground: root.foreground
                                background: root.background
                                accent: root.accent
                                fontFamily: root.fontFamily
                                Layout.fillWidth: true
                                onChanged: function (v) {
                                    root.setConfig("replayStorage", v);
                                }
                            }

                            Text {
                                text: "Bitrate (kbps)"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            NumberField {
                                id: replayBitrateField
                                value: Number(root.cfg.replayKbps || 20000)
                                from: 1000
                                to: 100000
                                stepSize: 500
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                fontSize: Style.font.caption
                                onModified: function (v) {
                                    root.setConfig("replayKbps", v);
                                }
                            }

                            Text {
                                text: "Save length"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            NumberField {
                                id: replaySaveLengthField
                                value: Number(root.cfg.replaySaveSeconds || 0)
                                from: 0
                                to: 600
                                stepSize: 5
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                fontSize: Style.font.caption
                                onModified: function (v) {
                                    root.setConfig("replaySaveSeconds", v);
                                }
                            }

                            Text {
                                text: "Date folders"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            ToggleSwitch {
                                checked: root.cfg.replayOrganize === true
                                foreground: root.foreground
                                accent: root.accent
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                onToggled: root.setConfig("replayOrganize", !root.cfg.replayOrganize)
                            }
                        }

                        Text {
                            text: "Save keeps the clip (0 = whole buffer), then the buffer restarts. CBR keeps buffer RAM predictable."
                            color: root.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                            width: parent.width
                        }
                    }

                    // ---- Settings --------------------------------------------------------
                    Column {
                        width: parent.width
                        spacing: Style.space(8)

                        PanelSectionHeader {
                            text: "SETTINGS"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        GridLayout {
                            id: settingsGrid
                            width: parent.width
                            columns: 2
                            columnSpacing: Style.space(10)
                            rowSpacing: Style.space(8)

                            Text {
                                text: "Frame rate"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            NumberField {
                                id: fpsField
                                value: Number(root.cfg.fps || 60)
                                from: 1
                                to: 240
                                stepSize: 15
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                fontSize: Style.font.caption
                                onModified: function (v) {
                                    root.setConfig("fps", v);
                                }
                            }

                            Text {
                                text: "Container"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                visible: !root.isStream
                            }
                            Dropdown {
                                id: containerDropdown
                                label: ""
                                visible: !root.isStream
                                value: root.cfg.container || "mp4"
                                options: [
                                    {
                                        value: "mp4",
                                        label: "mp4"
                                    },
                                    {
                                        value: "mkv",
                                        label: "mkv"
                                    },
                                    {
                                        value: "webm",
                                        label: "webm"
                                    }
                                ]
                                foreground: root.foreground
                                background: root.background
                                accent: root.accent
                                fontFamily: root.fontFamily
                                Layout.fillWidth: true
                                onChanged: function (v) {
                                    root.setConfig("container", v);
                                }
                            }
                        }

                        // ---- Audio / cursor toggles ----------------------------------------
                        GridLayout {
                            width: parent.width
                            columns: 2
                            columnSpacing: Style.space(10)
                            rowSpacing: Style.space(8)

                            Text {
                                text: "Audio"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            ToggleSwitch {
                                checked: root.cfg.audioEnabled === true
                                foreground: root.foreground
                                accent: root.accent
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                onToggled: root.setConfig("audioEnabled", !root.cfg.audioEnabled)
                            }

                            Text {
                                text: "Mic"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            ToggleSwitch {
                                checked: root.cfg.audioMicrophone === true
                                foreground: root.foreground
                                accent: root.accent
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                onToggled: root.setConfig("audioMicrophone", !root.cfg.audioMicrophone)
                            }

                            Text {
                                text: "Cursor"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            ToggleSwitch {
                                checked: root.cfg.cursor !== false
                                foreground: root.foreground
                                accent: root.accent
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                onToggled: root.setConfig("cursor", root.cfg.cursor !== true)
                            }
                        }

                        // ---- Audio devices + volume --------------------------------------
                        Column {
                            width: parent.width
                            spacing: Style.space(6)
                            visible: root.cfg.audioEnabled !== false

                            Text {
                                text: "Audio devices"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }

                            GridLayout {
                                width: parent.width
                                columns: 2
                                columnSpacing: Style.space(10)
                                rowSpacing: Style.space(8)

                                Text {
                                    text: "Desktop"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                }
                                Dropdown {
                                    label: ""
                                    value: root.cfg.audioDesktopDevice || "default_output"
                                    options: root.audioDeviceOptions()
                                    foreground: root.foreground
                                    background: root.background
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    Layout.fillWidth: true
                                    onChanged: function (v) {
                                        root.setConfig("audioDesktopDevice", v);
                                    }
                                }

                                Text {
                                    text: "Mic"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                }
                                Dropdown {
                                    label: ""
                                    value: root.cfg.audioMicDevice || "default_input"
                                    options: root.audioDeviceOptions()
                                    foreground: root.foreground
                                    background: root.background
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    Layout.fillWidth: true
                                    onChanged: function (v) {
                                        root.setConfig("audioMicDevice", v);
                                    }
                                }

                                Text {
                                    text: "Set levels"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                }
                                ToggleSwitch {
                                    checked: root.cfg.audioSetVolume === true
                                    foreground: root.foreground
                                    accent: root.accent
                                    Layout.fillWidth: true
                                    Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                    onToggled: root.setConfig("audioSetVolume", root.cfg.audioSetVolume !== true)
                                }

                                Text {
                                    text: "Set the volume levels below while recording; off leaves system volume alone"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    wrapMode: Text.WordWrap
                                    opacity: 0.8
                                    Layout.columnSpan: 2
                                    Layout.fillWidth: true
                                }

                                Text {
                                    text: "Desktop volume"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                }
                                RowLayout {
                                    spacing: Style.space(6)
                                    Layout.fillWidth: true

                                    PanelSlider {
                                        id: desktopVolumeSlider
                                        Layout.fillWidth: true
                                        enabled: root.cfg.audioSetVolume === true
                                        opacity: enabled ? 1 : 0.4
                                        minimum: 0
                                        maximum: 100
                                        integer: true
                                        step: 5
                                        tickCount: 5
                                        value: root.cfgNum("audioVolume", 100)
                                        onReleased: function (v) {
                                            root.setConfig("audioVolume", v);
                                        }
                                    }

                                    Text {
                                        text: desktopVolumeSlider.liveValue.toFixed(0) + "%"
                                        opacity: desktopVolumeSlider.opacity
                                        color: root.muted
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.caption
                                        Layout.alignment: Qt.AlignVCenter
                                    }
                                }

                                Text {
                                    text: "Mic volume"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                }
                                RowLayout {
                                    spacing: Style.space(6)
                                    Layout.fillWidth: true

                                    PanelSlider {
                                        id: micVolumeSlider
                                        Layout.fillWidth: true
                                        enabled: root.cfg.audioSetVolume === true
                                        opacity: enabled ? 1 : 0.4
                                        minimum: 0
                                        maximum: 100
                                        integer: true
                                        step: 5
                                        tickCount: 5
                                        value: root.cfgNum("audioMicVolume", 100)
                                        onReleased: function (v) {
                                            root.setConfig("audioMicVolume", v);
                                        }
                                    }

                                    Text {
                                        text: micVolumeSlider.liveValue.toFixed(0) + "%"
                                        opacity: micVolumeSlider.opacity
                                        color: root.muted
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.caption
                                        Layout.alignment: Qt.AlignVCenter
                                    }
                                }

                                Text {
                                    text: "Codec"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                }
                                Dropdown {
                                    label: ""
                                    value: root.cfg.audioCodec || "aac"
                                    options: [
                                        {
                                            value: "aac",
                                            label: "AAC"
                                        },
                                        {
                                            value: "opus",
                                            label: "Opus"
                                        }
                                    ]
                                    foreground: root.foreground
                                    background: root.background
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    Layout.fillWidth: true
                                    onChanged: function (v) {
                                        root.setConfig("audioCodec", v);
                                    }
                                }

                                Text {
                                    text: "Bitrate"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                }
                                NumberField {
                                    id: audioBitrateField
                                    value: Number(root.cfg.audioBitrate || 0)
                                    from: 0
                                    to: 512
                                    stepSize: 16
                                    foreground: root.foreground
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    fontSize: Style.font.caption
                                    onModified: function (v) {
                                        root.setConfig("audioBitrate", v);
                                    }
                                }
                            }

                            Text {
                                text: "0 = automatic bitrate"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                wrapMode: Text.WordWrap
                                width: parent.width
                            }
                        }

                        Column {
                            width: parent.width
                            spacing: Style.space(6)

                            Text {
                                text: "Output folder"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }

                            RowLayout {
                                width: parent.width
                                spacing: Style.space(6)

                                TextField {
                                    id: outputDirField
                                    Layout.fillWidth: true
                                    text: root.cfg.outputDir || ""
                                    foreground: root.foreground
                                    accent: root.accent
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    placeholderText: root.service ? root.service.outputDir
                                        : (root.serviceState ? (root.serviceState.outputDir || "") : "")
                                    onEditingFinished: root.setConfig("outputDir", text)
                                }

                                Button {
                                    text: "Browse…"
                                    foreground: root.foreground
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    fontSize: Style.font.caption
                                    onClicked: {
                                        browseDirProc.command = [
                                            "bash", "-c",
                                            "zenity --file-selection --directory --title='Select output folder' 2>/dev/null"
                                        ];
                                        browseDirProc.running = true;
                                    }
                                }
                            }
                        }

                        // ---- Last saved clip ------------------------------------------------
                        RowLayout {
                            width: parent.width
                            spacing: Style.space(6)
                            visible: root.lastSavedPath !== ""

                            Text {
                                text: "Last clip"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }

                            Text {
                                text: root.lastSavedPath
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                elide: Text.ElideMiddle
                                maximumLineCount: 1
                                Layout.fillWidth: true
                            }

                            Button {
                                text: "Open"
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                fontSize: Style.font.caption
                                onClicked: {
                                    if (root.service)
                                        root.service.openPath(root.lastSavedPath);
                                    else {
                                        ipcActionProc.command = ["omarchy-shell", "px-recast", "openClip"];
                                        ipcActionProc.running = true;
                                    }
                                }
                            }

                            Button {
                                text: "Folder"
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                fontSize: Style.font.caption
                                onClicked: {
                                    if (root.service)
                                        root.service.openFolderOf(root.lastSavedPath);
                                    else {
                                        ipcActionProc.command = ["omarchy-shell", "px-recast", "openFolder"];
                                        ipcActionProc.running = true;
                                    }
                                }
                            }
                        }

                        // ---- Advanced encoder profile --------------------------------------
                        Row {
                            spacing: Style.space(8)
                            Button {
                                text: root.cfg.advanced ? "Hide advanced" : "Advanced (encoder)"
                                onClicked: root.setConfig("advanced", !root.cfg.advanced)
                            }
                        }

                        Column {
                            width: parent.width
                            spacing: Style.space(8)
                            visible: root.cfg.advanced === true
                            // Encoder tweaks apply to recordings; streams always use
                            // H.264 + CBR with the bitrate above.

                            GridLayout {
                                width: parent.width
                                columns: 2
                                columnSpacing: Style.space(10)
                                rowSpacing: Style.space(8)

                                Text {
                                    text: "Codec"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                    visible: !root.isStream
                                }
                                Dropdown {
                                    id: codecDropdown
                                    label: ""
                                    visible: !root.isStream
                                    value: root.cfg.codec || "auto"
                                    options: [
                                        {
                                            value: "auto",
                                            label: "Auto (detected)"
                                        },
                                        {
                                            value: "h264",
                                            label: "H.264"
                                        },
                                        {
                                            value: "hevc",
                                            label: "HEVC / H.265"
                                        },
                                        {
                                            value: "av1",
                                            label: "AV1"
                                        },
                                        {
                                            value: "vp9",
                                            label: "VP9"
                                        },
                                        {
                                            value: "vp8",
                                            label: "VP8"
                                        }
                                    ]
                                    foreground: root.foreground
                                    background: root.background
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    Layout.fillWidth: true
                                    onChanged: function (v) {
                                        root.setConfig("codec", v);
                                    }
                                }

                                Text {
                                    text: "Quality"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                    visible: !root.isStream
                                }
                                Dropdown {
                                    id: qualityDropdown
                                    label: ""
                                    visible: !root.isStream
                                    value: root.cfg.quality || "auto"
                                    options: [
                                        {
                                            value: "auto",
                                            label: "Auto (detected)"
                                        },
                                        {
                                            value: "medium",
                                            label: "Medium"
                                        },
                                        {
                                            value: "high",
                                            label: "High"
                                        },
                                        {
                                            value: "very_high",
                                            label: "Very high"
                                        },
                                        {
                                            value: "ultra",
                                            label: "Ultra"
                                        }
                                    ]
                                    foreground: root.foreground
                                    background: root.background
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    Layout.fillWidth: true
                                    onChanged: function (v) {
                                        root.setConfig("quality", v);
                                    }
                                }

                                Text {
                                    text: "Bitrate mode"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                    visible: !root.isStream
                                }
                                Dropdown {
                                    id: bitrateDropdown
                                    label: ""
                                    visible: !root.isStream
                                    value: root.cfg.bitrateMode || "auto"
                                    options: [
                                        {
                                            value: "auto",
                                            label: "Auto (detected)"
                                        },
                                        {
                                            value: "qp",
                                            label: "QP (constant quality)"
                                        },
                                        {
                                            value: "vbr",
                                            label: "VBR"
                                        },
                                        {
                                            value: "cbr",
                                            label: "CBR"
                                        }
                                    ]
                                    foreground: root.foreground
                                    background: root.background
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    Layout.fillWidth: true
                                    onChanged: function (v) {
                                        root.setConfig("bitrateMode", v);
                                    }
                                }

                                Text {
                                    text: "Encoder"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                }
                                Dropdown {
                                    id: encoderDropdown
                                    label: ""
                                    value: root.cfg.encoder || "gpu"
                                    options: [
                                        {
                                            value: "gpu",
                                            label: "GPU (hardware)"
                                        },
                                        {
                                            value: "cpu",
                                            label: "CPU (software)"
                                        }
                                    ]
                                    foreground: root.foreground
                                    background: root.background
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    Layout.fillWidth: true
                                    onChanged: function (v) {
                                        root.setConfig("encoder", v);
                                    }
                                }

                                Text {
                                    text: "Frame mode"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                    visible: !root.isStream
                                }
                                Dropdown {
                                    label: ""
                                    visible: !root.isStream
                                    value: root.cfg.frameMode || "cfr"
                                    options: [
                                        {
                                            value: "cfr",
                                            label: "CFR (constant rate)"
                                        },
                                        {
                                            value: "vfr",
                                            label: "VFR (variable rate)"
                                        },
                                        {
                                            value: "content",
                                            label: "Content-aware"
                                        }
                                    ]
                                    foreground: root.foreground
                                    background: root.background
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    Layout.fillWidth: true
                                    onChanged: function (v) {
                                        root.setConfig("frameMode", v);
                                    }
                                }

                                Text {
                                    text: "Color range"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                    visible: !root.isStream
                                }
                                Dropdown {
                                    label: ""
                                    visible: !root.isStream
                                    value: root.cfg.colorRange || "limited"
                                    options: [
                                        {
                                            value: "limited",
                                            label: "Limited (TV)"
                                        },
                                        {
                                            value: "full",
                                            label: "Full (PC)"
                                        }
                                    ]
                                    foreground: root.foreground
                                    background: root.background
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    Layout.fillWidth: true
                                    onChanged: function (v) {
                                        root.setConfig("colorRange", v);
                                    }
                                }

                                Text {
                                    text: "Video tune"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                    visible: !root.isStream
                                }
                                Dropdown {
                                    label: ""
                                    visible: !root.isStream
                                    value: root.cfg.tune || "performance"
                                    options: [
                                        {
                                            value: "performance",
                                            label: "Performance"
                                        },
                                        {
                                            value: "quality",
                                            label: "Quality"
                                        }
                                    ]
                                    foreground: root.foreground
                                    background: root.background
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    Layout.fillWidth: true
                                    onChanged: function (v) {
                                        root.setConfig("tune", v);
                                    }
                                }

                                Text {
                                    text: "Keyframe interval"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                    visible: !root.isStream
                                }
                                NumberField {
                                    id: keyframeField
                                    value: Number(root.cfg.keyInterval || 2.0)
                                    from: 1
                                    to: 10
                                    stepSize: 1
                                    visible: !root.isStream
                                    foreground: root.foreground
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    fontSize: Style.font.caption
                                    onModified: function (v) {
                                        root.setConfig("keyInterval", v);
                                    }
                                }

                                Text {
                                    text: "Show timer"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                }
                                ToggleSwitch {
                                    checked: root.cfg.showTimer !== false
                                    foreground: root.foreground
                                    accent: root.accent
                                    Layout.fillWidth: true
                                    Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                    onToggled: root.setConfig("showTimer", !(root.cfg.showTimer !== false))
                                }

                                Text {
                                    text: "Low power"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                    visible: !root.isStream
                                }
                                ToggleSwitch {
                                    checked: root.cfg.lowPower === true
                                    visible: !root.isStream
                                    foreground: root.foreground
                                    accent: root.accent
                                    Layout.fillWidth: true
                                    Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                    onToggled: root.setConfig("lowPower", !root.cfg.lowPower)
                                }
                            }

                            Text {
                                visible: root.cfg.advanced === true && root.cfg.lowPower === true && !root.isStream
                                text: "Low power lowers GPU clocks on AMD and switches to content-aware frame mode."
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                wrapMode: Text.WordWrap
                                width: parent.width
                            }
                        }
                    }

                    // ---- Controls overlay + keybinds -------------------------------------
                    Column {
                        width: parent.width
                        spacing: Style.space(8)

                        PanelSectionHeader {
                            text: "CONTROLS OVERLAY"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        GridLayout {
                            width: parent.width
                            columns: 2
                            columnSpacing: Style.space(10)
                            rowSpacing: Style.space(8)

                            Text {
                                text: "Mode"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Dropdown {
                                label: ""
                                value: root.cfg.overlayMode || "auto"
                                options: [
                                    {
                                        value: "auto",
                                        label: "Auto"
                                    },
                                    {
                                        value: "pin",
                                        label: "Pinned"
                                    },
                                    {
                                        value: "timed",
                                        label: "Show for N seconds"
                                    },
                                    {
                                        value: "float",
                                        label: "Floating"
                                    },
                                    {
                                        value: "off",
                                        label: "Off"
                                    }
                                ]
                                foreground: root.foreground
                                background: root.background
                                accent: root.accent
                                fontFamily: root.fontFamily
                                Layout.fillWidth: true
                                onChanged: function (v) {
                                    root.setOverlayMode(v);
                                }
                            }

                            Text {
                                text: "Seconds"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            NumberField {
                                id: overlaySecondsField
                                enabled: ["auto", "timed"].indexOf(root.cfg.overlayMode || "auto") !== -1
                                opacity: enabled ? 1 : 0.5
                                value: root.cfgNum("overlaySeconds", 5)
                                from: 1
                                to: 60
                                stepSize: 1
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                fontSize: Style.font.caption
                                onModified: function (v) {
                                    root.setConfig("overlaySeconds", v);
                                }
                            }

                            Text {
                                text: "Edge"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Dropdown {
                                label: ""
                                value: root.cfg.overlayEdge || "right"
                                options: [
                                    {
                                        value: "left",
                                        label: "Left"
                                    },
                                    {
                                        value: "right",
                                        label: "Right"
                                    },
                                    {
                                        value: "top",
                                        label: "Top"
                                    },
                                    {
                                        value: "bottom",
                                        label: "Bottom"
                                    }
                                ]
                                foreground: root.foreground
                                background: root.background
                                accent: root.accent
                                fontFamily: root.fontFamily
                                Layout.fillWidth: true
                                onChanged: function (v) {
                                    root.setConfig("overlayEdge", v);
                                }
                            }
                        }

                        Text {
                            text: "The edge is used when no other monitor is free. With a free monitor, Auto keeps the overlay there."
                            color: root.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                            width: parent.width
                        }

                        PanelSectionHeader {
                            text: "KEYBINDS"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        Repeater {
                            model: Binds.ACTIONS

                            Column {
                                id: bindRow

                                required property var modelData
                                readonly property var bind: root.resolvedBinds[modelData.id] || null

                                width: parent ? parent.width : 0
                                spacing: Style.space(4)

                                RowLayout {
                                    width: parent.width
                                    spacing: Style.space(10)

                                    Text {
                                        text: bindRow.modelData.label
                                        color: root.muted
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.caption
                                        Layout.preferredWidth: Style.space(110)
                                        horizontalAlignment: Text.AlignRight
                                    }

                                    TextField {
                                        Layout.fillWidth: true
                                        text: root.cfg[bindRow.modelData.configKey] || ""
                                        foreground: root.foreground
                                        accent: root.accent
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.caption
                                        placeholderText: root.bindPlaceholder(bindRow.modelData.id)
                                        onActiveFocusChanged: {
                                            if (activeFocus)
                                                root._bindFieldFocus = bindRow.modelData.id;
                                            else if (root._bindFieldFocus === bindRow.modelData.id)
                                                root._bindFieldFocus = "";
                                        }
                                        onEditingFinished: root.setBindOverride(bindRow.modelData, text)
                                    }
                                }

                                Text {
                                    visible: root._bindErrors[bindRow.modelData.id] === true
                                        || (bindRow.bind !== null && bindRow.bind.conflict === true)
                                    text: root._bindErrors[bindRow.modelData.id] === true
                                        ? "Not a key combo. Use the form SUPER + ALT + P."
                                        : "Another bind already uses this combo, so it is not bound."
                                    color: root.urgent
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.bodySmall
                                    wrapMode: Text.WordWrap
                                    width: parent.width
                                }
                            }
                        }

                        Text {
                            text: "Leave a field empty for an automatic free combo. Plugin binds exist only while a capture runs. A bindings.lua bind that runs omarchy-shell px-recast togglePause, stop, cancel or saveReplay is used as is."
                            color: root.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                            width: parent.width
                        }
                    }

                    // ---- After capture --------------------------------------------------
                    Column {
                        width: parent.width
                        spacing: Style.space(8)

                        PanelSectionHeader {
                            text: "AFTER CAPTURE"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        GridLayout {
                            width: parent.width
                            columns: 2
                            columnSpacing: Style.space(10)
                            rowSpacing: Style.space(8)

                            Text {
                                text: "Open with"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Dropdown {
                                label: ""
                                value: root.cfg.postProcessApp || ""
                                options: root.openWithOptions()
                                foreground: root.foreground
                                background: root.background
                                accent: root.accent
                                fontFamily: root.fontFamily
                                Layout.fillWidth: true
                                onChanged: function (v) {
                                    root.setConfig("postProcessApp", v);
                                }
                            }
                        }

                        RowLayout {
                            width: parent.width
                            spacing: Style.space(6)
                            visible: root.cfg.postProcessApp === "custom"

                            TextField {
                                id: postProcessCommandField
                                Layout.fillWidth: true
                                text: root.cfg.postProcessCommand || ""
                                foreground: root.foreground
                                accent: root.accent
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                placeholderText: "Command or app path"
                                onEditingFinished: root.setConfig("postProcessCommand", text)
                            }

                            Button {
                                text: "Browse…"
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                fontSize: Style.font.caption
                                onClicked: pickAppProc.running = true
                            }
                        }

                        Text {
                            text: root.cfg.postProcessApp === "custom"
                                ? "Runs with the saved file as its last argument (\"$1\")."
                                : "Opens each saved recording and replay clip."
                            color: root.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                            width: parent.width
                        }
                    }

                    // ---- UPDATE --------------------------------------------------------
                    Column {
                        width: parent.width
                        spacing: Style.space(6)

                        PanelSectionHeader {
                            text: "UPDATE"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        Row {
                            width: parent.width
                            spacing: Style.space(8)
                            visible: !root.updateAvailable || root.updateChecking

                            Text {
                                text: root.updateChecking
                                    ? "Checking for updates…"
                                    : "Up to date" + (root.updateNewVersion !== "" ? " (v" + root.updateCurrentVersion + ")" : "")
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Button {
                                text: "Check"
                                onClicked: root.checkForUpdates()
                            }
                        }

                        Row {
                            width: parent.width
                            spacing: Style.space(8)
                            visible: root.updateAvailable && !root.updateChecking

                            Text {
                                text: "v" + root.updateCurrentVersion + " → v" + root.updateNewVersion + (root.updateCommitsBehind > 0 ? " (" + root.updateCommitsBehind + " commits)" : "")
                                textFormat: Text.PlainText
                                color: root.accent
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Item {
                                Layout.fillWidth: true
                            }

                            Button {
                                text: "Copy command"
                                onClicked: {
                                    copyUpdateCmdProc.command = ["sh", "-c", "printf '%s' \"$1\" | wl-copy", "_", "omarchy plugin update pix.recast"];
                                    copyUpdateCmdProc.running = true;
                                }
                            }

                            Button {
                                text: "Update"
                                accent: root.accent
                                onClicked: {
                                    Util.execDetached("omarchy-launch-floating-terminal-with-presentation 'omarchy plugin update pix.recast'");
                                }
                            }
                        }

                        Text {
                            visible: root.updateError !== "" && !root.updateChecking
                            text: "Update check failed — " + root.updateError
                            color: root.urgent
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            wrapMode: Text.WordWrap
                            width: parent.width
                        }
                    }

                    PanelSeparator {
                        foreground: root.foreground
                    }

                    // ---- Footer: re-detect + diagnostics --------------------------------
                    Row {
                        width: parent.width
                        spacing: Style.space(8)

                        Button {
                            text: "Re-detect hardware"
                            onClicked: {
                                if (root.service) {
                                    root.service.refreshGpuInfo();
                                    root.service.refreshMonitors();
                                } else {
                                    ipcActionProc.command = ["omarchy-shell", "px-recast", "refreshGpu"];
                                    ipcActionProc.running = true;
                                }
                            }
                        }

                        Text {
                            text: root.service ? (root.service.gpuDetected ? "Detected" : "Detecting…")
                                : (root.serviceState ? (root.serviceState.gpuDetected ? "Detected" : "Detecting…") : "Detecting…")
                            color: root.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Text {
                        visible: Boolean(root.service ? root.service.gpuDetected : (root.serviceState ? root.serviceState.gpuDetected : false)) && (root.gpu.codecs || []).indexOf("h264_software") === -1
                        text: "Hardware encoding active. CPU fallback is enabled automatically if the GPU encoder is unavailable."
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }

                    // ---- Settings summary ------------------------------------------------
                    Text {
                        text: root.settingsSummary()
                        visible: Boolean(text)
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }

                    // ---- Keyboard shortcuts hint ------------------------------------------
                    Text {
                        text: {
                            if (root.replayActive)
                                return "Esc close · S save replay · Space stop buffer";
                            if (root.isReplay)
                                return "Esc close · Space/Enter start buffer";
                            return "Esc close · Space/Enter record";
                        }
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        width: parent.width
                    }

                    // ---- Error log --------------------------------------------------------
                    Repeater {
                        model: root._errorLog
                        Row {
                            width: parent ? parent.width : 0
                            spacing: Style.space(6)
                            Text {
                                text: "!"
                                color: root.urgent
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                font.bold: true
                            }
                            Text {
                                text: modelData
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                wrapMode: Text.WordWrap
                                width: parent.width - Style.space(10)
                            }
                        }
                    }
                }
            }
        }
    }

    // Fallback IPC action process — used when service object is null
    // (replacement bars can't resolve third-party services)
    Process {
        id: ipcActionProc
        running: false
    }

    Process {
        id: toggleIpcAction
        running: false
    }

    Process {
        id: configIpcProc
        running: false
    }

    // Browse button folder picker — used for the output-dir field.
    Process {
        id: browseDirProc
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var dir = text.trim();
                if (dir && !dir.match(/^cancelled$/i))
                    root.setConfig("outputDir", dir);
            }
        }
    }

    Process {
        id: mimeAppsProc
        command: ["gio", "mime", "video/mp4"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.openWithIds = PostProcess.parseMimeApps(text)
        }
    }

    // omarchy-file-select exits 1 when nothing was picked, 2 when the chooser
    // itself failed.
    Process {
        id: pickAppProc
        command: ["omarchy-file-select", "--title", "Choose application"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var picked = text.trim();
                if (picked)
                    root.setConfig("postProcessCommand", PostProcess.shellQuote(picked));
            }
        }
        onExited: function (exitCode) {
            if (exitCode === 2)
                root._pushError("File chooser failed to open");
        }
    }

    // ---- Update checker ---------------------------------------------------
    readonly property string updateCheckerPath: {
        var u = Qt.resolvedUrl("scripts/check-update.sh").toString();
        return decodeURIComponent(u.replace(/^file:\/\//, ""));
    }

    Process {
        id: updateCheckProc
        command: [root.updateCheckerPath, "check"]
        stdout: StdioCollector {
            waitForEnd: true
                    onStreamFinished: {
                        var line = String(text || "").trim();
                        if (line.length > 65536)
                            line = line.substring(0, 65536);
                        if (!line) return;
                        try {
                            var data = JSON.parse(line);
                            root.updateAvailable = data.update_available === true;
                            root.updateCurrentVersion = data.current_version || "1.1.0";
                            root.updateNewVersion = data.new_version || "";
                            root.updateCommitsBehind = data.commits_behind || 0;
                            root.updateError = data.error || "";
                        } catch (e) {}
                        root.updateChecking = false;
                    }
        }
        onExited: function (exitCode) {
            updateCheckTimer.stop();
            root.updateChecking = false;
        }
    }
    Timer {
        id: updateCheckTimer
        interval: 30000
        repeat: false
        onTriggered: {
            if (updateCheckProc.running) {
                updateCheckProc.running = false;
                root.updateChecking = false;
            }
        }
    }

    Timer {
        id: updateCheckStartup
        interval: 10000
        running: true
        repeat: false
        onTriggered: root.checkForUpdates()
    }

    Timer {
        id: updateCheckRecurring
        interval: 21600000
        running: true
        repeat: true
        onTriggered: root.checkForUpdates()
    }

    function checkForUpdates() {
        root.updateChecking = true;
        root.updateError = "";
        if (!updateCheckProc.running)
            updateCheckProc.running = true;
    }

    Process {
        id: copyUpdateCmdProc
        running: false
    }
}
