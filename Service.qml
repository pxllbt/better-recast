pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Binds.js" as Binds
import "Config.js" as Config
import "GpuProbe.js" as GpuProbe
import "PostProcess.js" as PostProcess

// pix.recast service — owns gpu-screen-recorder lifecycle, GPU detection, config
// persistence and the IPC socket used for pause/resume/stop.
Item {
    id: root

    // Host-injected
    property var shell: null
    property var manifest: null
    property var pluginRegistry: null
    property string omarchyPath: ""

    // ── Hardware / environment ──
    property var gpuInfo: ({
            vendor: "unknown",
            cardPath: "",
            codecs: [],
            backend: "cpu"
        })
    property bool gpuDetected: false
    property var monitors: []
    property bool monitorsLoaded: false
    property var audioDevices: []
    property bool audioDevicesLoaded: false
    property var webcamDevices: []

    // ── Config (defaults seeded, then shell.json overrides) ──
    property var config: Config.normalize({})
    property bool configLoaded: false

    // True while we are persisting our own write to shell.json so the FileView
    // reload (onFileChanged / onLoaded) can skip re-reading a buffer that may
    // still lag the disk write — otherwise the in-memory config we just updated
    // gets reverted, which is why settings like mode sometimes need two toggles
    // to stick.
    property bool _configWriteInProgress: false

    // Timer to delay clearing the write-in-progress flag. Multiple file system
    // events can fire during a single write (onFileChanged + onLoaded); a small
    // window avoids a reload sneaking in before the file is fully flushed.
    Timer {
        id: configWriteDelay
        interval: 250
        onTriggered: {
            root._configWriteInProgress = false;
        }
    }

    // ── Recording state ──
    property string state: "idle" // idle | starting | recording | paused | stopping | replay | error
    // Alias so the bar widget / panel can read the recording state uniformly.
    property string recordingState: state
    property bool recordingIsStream: false
    property string recordingFile: ""
    property string recordingPath: ""
    property int recordingPid: 0
    property int recordingElapsed: 0
    property int recordingBaseSec: 0
    property double recordingBaseMs: 0
    property string lastTarget: ""      // for panel display / notification
    property string pendingRegion: ""   // set by pickRegion before start
    // resolveTarget() result for the running capture, null when idle.
    property var activeTarget: null
    // Set by Panel.qml while the settings panel is open (overlay preview).
    property bool panelOpen: false
    property string errorMessage: ""

    // Driving the starting→replay promotion in gsr.onRunningChanged, and
    // tagging the stop-notification so a closed buffer isn't announced as a
    // saved recording.
    property bool _startingReplay: false
    property bool _wasReplay: false
    // Set by cancel(): the finished file is deleted instead of announced.
    property bool _cancelRequested: false
    property string _lastSavedPath: ""
    readonly property string lastSavedPath: _lastSavedPath

    // Levels saved by applyVolume() before it overrides them, so
    // restoreVolume() can put them back on stop/fail. null = not touched.
    property var _savedAudioSinkVolume: null
    property var _savedAudioSourceVolume: null

    readonly property bool active: state === "recording" || state === "paused"
    readonly property bool paused: state === "paused"
    readonly property bool replayActive: state === "replay"
    readonly property bool busy: state === "starting" || state === "stopping"
    // Which capture-control actions apply right now ("" = none).
    readonly property string captureKind: active ? (recordingIsStream ? "stream" : "record") : (state === "replay" ? "replay" : "")

    // ── Capture-control keybinds ──
    // bindings.lua binds that already call px-recast, by action id.
    property var _configBinds: ({})
    // `hyprctl binds -j` as of the last refresh.
    property var _hyprBinds: []
    property bool _bindsLoaded: false
    property bool _bindsRefreshPending: false
    // Override keys as last seen; a change re-reads what Hyprland has bound.
    property string _bindOverrides: ""
    // [{ action, combo }] this service has bound in Hyprland.
    property var _boundBinds: []
    readonly property var resolvedBinds: Binds.resolve(config, _configBinds, function (combo) {
        return Binds.isTaken(root._hyprBinds, combo, Binds.DESCRIPTION_PREFIX);
    })

    // ── Paths ──
    readonly property string runtimeDir: {
        var xdg = Quickshell.env("XDG_RUNTIME_DIR");
        if (!xdg || xdg.length === 0)
            xdg = "/tmp";
        return xdg + "/px-gsr";
    }
    readonly property string ipcSocketPath: runtimeDir + "/ipc.sock"
    readonly property string stateFilePath: runtimeDir + "/state.txt"
    readonly property string recordingStateFilePath: "/tmp/omarchy-screenrecord-filename"
    readonly property string ipcScriptPath: pluginPath("scripts/gsr-ipc.py")
    readonly property string readBindsScriptPath: pluginPath("scripts/read-binds.lua")

    // Absolute path of a file shipped with this plugin.
    function pluginPath(relative) {
        var s = String(Qt.resolvedUrl(relative));
        if (s.indexOf("file://") === 0)
            s = s.substring(7);
        try {
            s = decodeURIComponent(s);
        } catch (e) {}
        return s;
    }
    readonly property string configFilePath: {
        var home = Quickshell.env("HOME");
        if (!home)
            home = "/";
        return home + "/.config/omarchy/shell.json";
    }
    readonly property string outputDir: {
        var dir = config.outputDir || "";
        if (dir)
            return dir;
        var xdgVideos = Quickshell.env("XDG_VIDEOS_DIR");
        if (xdgVideos)
            return xdgVideos;
        var home = Quickshell.env("HOME");
        return home ? home + "/Videos" : "/tmp";
    }

    // ── Startup ──
    Component.onCompleted: {
        mkdirs.command = ["bash", "-c", "mkdir -p " + runtimeDir];
        mkdirs.running = true;
        refreshGpuInfo();
        refreshMonitors();
        refreshAudioDevices();
        refreshWebcamDevices();
        refreshConfig();
        refreshBinds();
        Qt.callLater(function() { flushState() });
    }

    // ── Public API (used by BarWidget / Panel) ──

    function refreshGpuInfo() {
        gsrInfoProc.command = ["gpu-screen-recorder", "--info"];
        gsrInfoProc.running = true;
    }

    function refreshMonitors() {
        listMonitorsProc.command = ["gpu-screen-recorder", "--list-monitors"];
        listMonitorsProc.running = true;
    }

    function refreshAudioDevices() {
        listAudioProc.command = ["gpu-screen-recorder", "--list-audio-devices"];
        listAudioProc.running = true;
    }

    function refreshWebcamDevices() {
        listWebcamProc.command = ["gpu-screen-recorder", "--list-v4l2-devices"];
        listWebcamProc.running = true;
    }

    function toggle() {
        if (state === "replay" && config.mode === "replay") {
            stopReplay();
        } else if (active) {
            stop();
        } else if (busy) {
            // ignore
        } else if (config.mode === "replay") {
            startReplay();
        } else {
            start("auto");
        }
    }

    function startReplay() {
        if (active || busy || state === "replay")
            return;
        errorMessage = "";

        var target = resolveTarget("auto");
        if (!target) {
            if (config.targetMode === "region") {
                pickRegion();
                return;
            }
            errorMessage = "No capture target available";
            state = "error";
            return;
        }

        if (config.webcamEnabled && (!config.webcamDevice || config.webcamDevice === "")) {
            errorMessage = "Webcam enabled but no device selected";
            state = "error";
            return;
        }

        // Replay buffer writes into the output directory and saves only on
        // command (whole buffer; -restart-replay-on-save clears it after).
        var args = Config.encodeGsrArgs(config, gpuInfo, target, false, true);
        recordingIsStream = false;
        recordingFile = "";
        _startingReplay = true;
        lastTarget = describeTarget(target) + " · replay buffer (" + String(config.replaySeconds || 60) + "s)";
        activeTarget = target;
        state = "starting";
        recordingElapsed = 0;
        gsr.command = ["gpu-screen-recorder"].concat(args, ["-o", outputDir, "-ipc", ipcSocketPath]);
        prepareDir.command = ["bash", "-c", "mkdir -p " + outputDir + " && mkdir -p " + runtimeDir];
        prepareDir.running = true;
        applyVolume();
        gsr.running = true;

        // compatibility marker for stock pyxis indicators
        writeMarker.command = ["bash", "-c", "mkdir -p " + runtimeDir + " && printf '%s\n' '" + outputDir + "/Replay' > " + recordingStateFilePath + " && printf '%s\n' '" + String(lastTarget) + "' > " + stateFilePath];
        writeMarker.running = true;
    }

    function saveReplay() {
        if (state !== "replay")
            return;
        // No seconds = save the whole buffer (ShadowPlay-style clip).
        var cmd = ["python3", ipcScriptPath, ipcSocketPath, "save-replay"];
        var clipLen = Number(root.config.replaySaveSeconds || 0);
        if (clipLen > 0) {
            var maxLen = Number(root.config.replaySeconds || 60) || 60;
            if (clipLen > maxLen) clipLen = maxLen;
            cmd.push(String(Math.round(clipLen)));
        }
        ipcSaveReplay.command = cmd;
        ipcSaveReplay.running = true;
        recordingBaseSec = 0;
        recordingBaseMs = Date.now();
    }

    function stopReplay() {
        if (state !== "replay")
            return;
        // `stop` in replay mode closes the buffer without saving it.
        _wasReplay = true;
        state = "stopping";
        stopTimeout.restart();
        if (gsr.running) {
            ipcStop.command = ["python3", ipcScriptPath, ipcSocketPath, "stop"];
            ipcStop.running = true;
        } else {
            stopTimeout.stop();
            onRecordingSaved();
        }
    }

    function openPath(path) {
        if (!path)
            return;
        openProc.command = ["xdg-open", path];
        openProc.running = true;
    }

    function openFolderOf(path) {
        if (!path)
            return;
        var idx = path.lastIndexOf("/");
        if (idx > 0)
            openPath(path.substring(0, idx));
    }

    function start(targetType) {
        if (active || busy)
            return;
        errorMessage = "";

        var streamMode = config.mode === "stream";

        var target = resolveTarget(targetType);
        if (!target) {
            if (config.targetMode === "region" || targetType === "region") {
                pickRegion();
                return;
            }
            errorMessage = "No capture target available";
            state = "error";
            return;
        }

        if (config.webcamEnabled && (!config.webcamDevice || config.webcamDevice === "")) {
            errorMessage = "Webcam enabled but no device selected";
            state = "error";
            return;
        }

        var args = Config.encodeGsrArgs(config, gpuInfo, target, streamMode);
        recordingIsStream = streamMode;

        if (streamMode) {
            // gsr streams the compositor capture to any RTMP/WHIP URL passed to -o.
            // The stream key is passed via the GSR_AUTH environment variable,
            // not embedded in the URL, to keep it out of /proc/<pid>/cmdline.
            var streamUrl = Config.streamOutput(config);
            var streamKey = String(config.streamKey || "").trim();
            if (!streamUrl || !streamKey) {
                recordingIsStream = false;
                errorMessage = "Set a stream URL and key to go live";
                state = "error";
                return;
            }
            args = args.concat(["-o", streamUrl, "-ipc", ipcSocketPath]);
            if (config.streamBackupLocal) {
                args = args.concat(["-ro", outputDir]);
            }
            recordingFile = "";
            lastTarget = describeTarget(target) + " · " + config.streamPlatform;
            activeTarget = target;
            state = "starting";
            recordingElapsed = 0;
            gsr.command = ["gpu-screen-recorder"].concat(args);
            gsr.environment = {"GSR_AUTH": streamKey};
            applyVolume();
            gsr.running = true;
            // Ensure the IPC socket dir (and the output dir when a local copy is
            // requested) exists before the recorder starts.
            prepareDir.command = ["bash", "-c", "mkdir -p " + outputDir + " && mkdir -p " + runtimeDir];
            prepareDir.running = true;
            return;
        }

        // Try to start; if hardware is missing, surface a friendly error.
        recordingFile = outputDir + "/screenrecording-" + Config.makeTimestamp() + "." + (config.container || "mp4");
        args = args.concat(["-o", recordingFile, "-ipc", ipcSocketPath]);
        args.unshift("gpu-screen-recorder");

        // ensure output dir + runtime state
        prepareDir.command = ["bash", "-c", "mkdir -p " + outputDir + " && mkdir -p " + runtimeDir];
        prepareDir.running = true;

        lastTarget = describeTarget(target);
        activeTarget = target;
        state = "starting";
        recordingElapsed = 0;
        gsr.command = args;
        applyVolume();
        gsr.running = true;

        // compatibility marker for stock pyxis indicators
        writeMarker.command = ["bash", "-c", "mkdir -p " + runtimeDir + " && printf '%s\n' '" + recordingFile + "' > " + recordingStateFilePath + " && printf '%s\n' '" + String(lastTarget) + "' > " + stateFilePath];
        writeMarker.running = true;
    }

    function refreshBinds() {
        if (bindsProc.running)
            _bindsRefreshPending = true;
        else
            bindsProc.running = true;
    }

    function applyBindsSnapshot(text) {
        var sep = text.indexOf("\x1e");
        var tsv = sep === -1 ? "" : text.substring(0, sep);
        var binds = [];
        try {
            binds = JSON.parse(sep === -1 ? text : text.substring(sep + 1));
        } catch (e) {}
        _configBinds = Binds.parseConfigBinds(tsv);
        _hyprBinds = Array.isArray(binds) ? binds : [];
        if (!_bindsLoaded) {
            _bindsLoaded = true;
            // Leftovers from a shell that went away mid-capture.
            var stale = Binds.ownedCombos(_hyprBinds, Binds.DESCRIPTION_PREFIX);
            if (stale.length > 0 && captureKind === "")
                Quickshell.execDetached(["bash", "-c", Binds.unbindScript(stale, Binds.DESCRIPTION_PREFIX)]);
        }
        syncBinds();
    }

    // Bind the plugin-managed combos for the current capture, unbind the
    // rest. Safe to call any time; it only sends the difference.
    function syncBinds() {
        if (!_bindsLoaded)
            return;
        var wanted = captureKind === "" ? [] : Binds.managed(resolvedBinds, captureKind);
        var script = Binds.syncScript(_boundBinds, wanted, Binds.DESCRIPTION_PREFIX);
        _boundBinds = wanted;
        if (script !== "")
            Quickshell.execDetached(["bash", "-c", script]);
    }

    function pickRegion() {
        regionPicker.command = ["omarchy-capture-region", "smart", "--match-monitor"];
        regionPicker.running = true;
    }

    function stop() {
        if (state === "replay") {
            stopReplay();
            return;
        }
        if (!active && state !== "starting")
            return;
        state = "stopping";
        stopTimeout.restart();
        if (gsr.running) {
            ipcStop.command = ["python3", ipcScriptPath, ipcSocketPath, "stop"];
            ipcStop.running = true;
        } else {
            stopTimeout.stop();
            // gsr already exited — verify the file before declaring saved
            fileVerifyTimer.restart();
        }
    }

    function pause() {
        if (state !== "recording")
            return;
        ipcPause.command = ["python3", ipcScriptPath, ipcSocketPath, "set-paused", "true"];
        ipcPause.running = true;
    }

    function resume() {
        if (state !== "paused")
            return;
        ipcResume.command = ["python3", ipcScriptPath, ipcSocketPath, "set-paused", "false"];
        ipcResume.running = true;
    }

    function togglePause() {
        if (state === "recording")
            pause();
        else if (state === "paused")
            resume();
    }

    // Recording: stop and delete the file. Replay: close the buffer unsaved.
    // Stream: just stop (there is nothing local to discard unless the backup
    // copy is on, and that copy is the point of the option).
    function cancel() {
        if (state === "replay") {
            stopReplay();
            return;
        }
        if (!active && state !== "starting")
            return;
        if (!recordingIsStream)
            _cancelRequested = true;
        stop();
    }

    function setConfig(key, value) {
        var changes = {};
        changes[key] = value;
        setConfigs(changes);
    }

    // Several keys, one write to shell.json.
    function setConfigs(changes) {
        config = Config.normalize(Object.assign({}, config, changes));
        persistConfig();
        if ("mode" in changes && config.mode !== "replay" && state === "replay")
            state = "idle";
        if ("webcamEnabled" in changes || "webcamDevice" in changes || "webcamSize" in changes)
            refreshWebcamDevices();
    }

    // Update config in memory only — never persist. Used for session-scoped
    // stream credentials while `streamRemember` is off.
    // Opt-in (audioSetVolume): set the recorded devices to the configured
    // levels when a recording starts, and restore them when it ends. Only
    // the devices actually being recorded are touched.
    function applyVolume() {
        _savedAudioSinkVolume = null;
        _savedAudioSourceVolume = null;
        if (!config.audioSetVolume || !config.audioEnabled)
            return;
        if (!config.audioDesktop && !config.audioMicrophone)
            return;
        // Read the current levels first so restoreVolume() can put them back.
        // wpctl get-volume takes a single node, so read each one separately.
        volReadProc.command = ["bash", "-c",
            "echo \"$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{print $2}') "
            + "$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ | awk '{print $2}')\""
        ];
        volReadProc.running = true;
    }

    function wpctlSetCommand(node, level) {
        return "wpctl set-volume @" + node + "@ " + Number(level).toFixed(2);
    }

    // One process for all nodes: starting wpctlProc twice in a row drops the
    // first command.
    function runWpctl(cmds) {
        if (cmds.length === 0)
            return;
        wpctlProc.command = ["bash", "-c", cmds.join("; ")];
        wpctlProc.running = true;
    }

    function restoreVolume() {
        var cmds = [];
        if (_savedAudioSinkVolume !== null)
            cmds.push(wpctlSetCommand("DEFAULT_AUDIO_SINK", _savedAudioSinkVolume));
        if (_savedAudioSourceVolume !== null)
            cmds.push(wpctlSetCommand("DEFAULT_AUDIO_SOURCE", _savedAudioSourceVolume));
        _savedAudioSinkVolume = null;
        _savedAudioSourceVolume = null;
        runWpctl(cmds);
    }

    function setSessionConfig(key, value) {
        if (!config)
            return;
        var copy = Object.assign({}, config);
        copy[key] = value;
        config = Config.normalize(copy);
    }

    function persistConfig() {
        if (!shell || typeof shell.updateEntryInline !== "function")
            return;
        var entries = {};
        for (var k in config) {
            if (k === "streamKey" && config.streamRemember !== true)
                continue;
            if (k === "_lastMonitor" || k === "_lastRegion")
                continue;
            entries[k] = config[k];
        }
        // Set the flag BEFORE writing so that file change / load events that
        // fire during the write are suppressed. The timer clears it after a
        // short grace period to catch any delayed events.
        root._configWriteInProgress = true;
        configWriteDelay.restart();
        shell.updateEntryInline("pix.recast", entries);
    }

    function refreshConfig() {
        configFileView.reload();
    }

    function effective(cfg) {
        return Config.applyGpuProfile(cfg || config, gpuInfo);
    }

    // ── Internals ──

    function resolveTarget(targetType) {
        var mode = targetType && targetType !== "auto" ? targetType : config.targetMode;
        if (mode === "region") {
            var geom = pendingRegion || config.region || config._lastRegion || "";
            if (!geom)
                return null;
            return {
                type: "region",
                geometry: geom
            };
        }
        if (mode === "monitor") {
            var name = config.monitorName || config._lastMonitor || "";
            if (!name && monitors.length > 0)
                name = monitors[0] && monitors[0].name || "";
            if (!name)
                return null;
            return {
                type: "monitor",
                name: name
            };
        }
        return {
            type: "portal"
        };
    }

    function describeTarget(target) {
        if (target.type === "monitor")
            return "Monitor: " + target.name;
        if (target.type === "region")
            return "Region: " + target.geometry;
        return "Window / portal";
    }

    function parseAppliedConfig(text) {
        var obj = null;
        try {
            obj = JSON.parse(text);
        } catch (e) {
            return false;
        }

        var found = null;
        if (obj && obj.bar && obj.bar.layout) {
            var sections = ["left", "center", "right"];
            for (var s = 0; s < sections.length; s++) {
                var arr = obj.bar.layout[sections[s]] || [];
                for (var i = 0; i < arr.length; i++) {
                    if (arr[i] && arr[i].id === "pix.recast") {
                        found = arr[i];
                        break;
                    }
                }
                if (found)
                    break;
            }
        }
        if (!found && obj && Array.isArray(obj.plugins)) {
            for (var j = 0; j < obj.plugins.length; j++) {
                if (obj.plugins[j] && obj.plugins[j].id === "pix.recast") {
                    found = obj.plugins[j];
                    break;
                }
            }
        }
        if (!found)
            return false;

        var merged = Object.assign({}, Config.defaultConfig());
        for (var k in found) {
            if (k === "id" || k === "__type")
                continue;
            merged[k] = found[k];
        }
        config = Config.normalize(merged);
        configLoaded = true;
        if (config.mode !== "replay" && state === "replay")
            state = "idle";
        return true;
    }

    function discardRecording(path) {
        if (path)
            Quickshell.execDetached(["rm", "-f", "--", path]);
        sendNotification("Recording discarded", "The recording was cancelled and deleted.", "normal", 5000);
    }

    function onRecordingSaved() {
        var wasStream = recordingIsStream;
        var wasReplay = _wasReplay;
        var cancelled = _cancelRequested;
        var saved = recordingFile;
        recordingFile = "";
        recordingIsStream = false;
        _wasReplay = false;
        _cancelRequested = false;
        activeTarget = null;
        state = "idle";
        clearMarkerProc.command = ["bash", "-c", "rm -f " + recordingStateFilePath + " " + stateFilePath];
        clearMarkerProc.running = true;
        if (cancelled) {
            discardRecording(saved);
        } else if (wasReplay) {
            sendNotification("Replay buffer stopped", "The rolling buffer was closed without saving.", "normal", 10000);
        } else if (wasStream) {
            sendNotification("Stream ended", "Your live stream has stopped.", "normal", 10000);
        } else if (saved) {
            root._lastSavedPath = saved;
            sendNotification("Screen recording saved", saved, "normal", 10000);
            runPostProcess(saved);
        }
        restoreVolume();
    }

    function onRecordingFailed(msg) {
        _startingReplay = false;
        var wasStream = recordingIsStream;
        var wasReplay = _wasReplay;
        var cancelled = _cancelRequested;
        if (!cancelled)
            errorMessage = msg;
        var saved = recordingFile;
        recordingFile = "";
        recordingIsStream = false;
        _wasReplay = false;
        _cancelRequested = false;
        activeTarget = null;
        state = "idle";
        clearMarkerProc.command = ["bash", "-c", "rm -f " + recordingStateFilePath + " " + stateFilePath];
        clearMarkerProc.running = true;
        if (cancelled) {
            discardRecording(saved);
        } else if (wasReplay) {
            sendNotification("Replay buffer crashed", msg, "critical", 8000);
        } else {
            sendNotification(wasStream ? "Stream ended unexpectedly" : "Screen recording failed", msg, "critical", 8000);
        }
        restoreVolume();
    }

    function runPostProcess(path) {
        var cmd = PostProcess.command(config, path);
        if (cmd)
            Quickshell.execDetached(cmd);
    }

    function sendNotification(summary, body, urgency, timeout) {
        var cmd = ["omarchy-notification-send"];
        if (urgency)
            cmd.push("-u", urgency);
        if (timeout)
            cmd.push("-t", String(timeout));
        cmd = cmd.concat([summary, body]);
        notifProc.command = cmd;
        notifProc.running = true;
    }

    // ── FileView: watch shell.json for external config edits ──
    FileView {
        id: configFileView
        path: root.configFilePath
        blockAllReads: false
        watchChanges: true
        onLoaded: {
            if (root._configWriteInProgress) {
                configWriteDelay.restart();
                return;
            }
            root.refreshConfig();
        }
        onLoadFailed: {
            if (root._configWriteInProgress) {
                configWriteDelay.restart();
                return;
            }
            root.refreshConfig();
        }
        onFileChanged: {
            if (root._configWriteInProgress) {
                configWriteDelay.restart();
                return;
            }
            root.refreshConfig();
        }

        function reload() {
            var text = configFileView.text();
            if (!text) {
                var fallback = Config.defaultConfig();
                root.config = Config.normalize(fallback);
                root.configLoaded = true;
                return;
            }
            root.parseAppliedConfig(text);
        }
    }

    // ── Processes ──

    Process {
        id: gsrInfoProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.gpuInfo = GpuProbe.parseGsrInfo(text);
                root.gpuDetected = true;
                var effective = Config.applyGpuProfile(root.config, root.gpuInfo);
                root.config = Config.normalize(effective);
            }
        }
        onExited: function (exitCode, exitStatus) {
            if (!root.gpuDetected) {
                root.gpuDetected = true;
            }
        }
    }

    Process {
        id: listMonitorsProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.monitors = GpuProbe.parseMonitorList(text);
                root.monitorsLoaded = true;
            }
        }
    }

    Process {
        id: listAudioProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.audioDevices = GpuProbe.parseAudioDevices(text);
                root.audioDevicesLoaded = true;
            }
        }
    }

    Process {
        id: listWebcamProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.webcamDevices = GpuProbe.parseV4L2Devices(text);
            }
        }
    }

    Process {
        id: gsr
        running: false
        // gsr has no "started" signal; promote starting -> recording as soon as the
        // process is alive. A launch that dies instantly is caught by onExited.
        onRunningChanged: {
            if (gsr.running && root.state === "starting")
                root.state = root._startingReplay ? "replay" : "recording";
            root._startingReplay = false;
        }
        onExited: function (exitCode, exitStatus) {
            stopTimeout.stop();
            if (root.state === "stopping") {
                // Don't call onRecordingSaved() immediately — gsr may
                // exit before the OS flushes write buffers to disk.
                // Wait a moment and verify the file exists and is
                // non-zero in size first.
                fileVerifyTimer.restart();
            } else if (root.state === "starting" || root.state === "recording" || root.state === "paused" || root.state === "replay") {
                root.onRecordingFailed("gpu-screen-recorder exited unexpectedly (code " + exitCode + ")");
            } else {
                root.activeTarget = null;
                root.state = "idle";
                root.restoreVolume();
            }
        }
    }

    Process {
        id: ipcStop
    }
    Process {
        id: ipcSaveReplay
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var out = String(text || "").trim();
                if (!out)
                    return;
                if (out.indexOf("error") === 0) {
                    root.sendNotification("Replay save failed", out, "critical", 8000);
                } else {
                    root.sendNotification("Replay saved", out, "normal", 10000);
                    if (out !== "ok") {
                        root._lastSavedPath = out;
                        root.runPostProcess(out);
                    }
                }
            }
        }
    }
    Process {
        id: openProc
    }

    // gsr has no pause event of its own; the state follows the IPC reply.
    // A stop issued while the reply was in flight wins.
    Process {
        id: ipcPause
        onExited: function (exitCode) {
            if (exitCode === 0 && root.state === "recording")
                root.state = "paused";
        }
    }
    Process {
        id: ipcResume
        onExited: function (exitCode) {
            if (exitCode === 0 && root.state === "paused")
                root.state = "recording";
        }
    }

    Process {
        id: regionPicker
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var out = text.trim();
                if (!out || out === "cancelled" || out === "null") {
                    root.pendingRegion = "";
                    return;
                }
                // Expected output: "WIDTHxHEIGHT+X+Y" (omarchy-capture-region fmt)
                if (out.match(/^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/)) {
                    root.pendingRegion = out;
                    root.setConfig("_lastRegion", out);
                } else {
                    // slurry format "X,Y WxH"
                    var m = out.match(/^(-?[0-9]+),(-?[0-9]+)\s+([0-9]+)x([0-9]+)$/);
                    if (m) {
                        var geom = m[3] + "x" + m[4] + "+" + m[1] + "+" + m[2];
                        root.pendingRegion = geom;
                        root.setConfig("_lastRegion", geom);
                    }
                }
            }
        }
        onExited: function (exitCode) {
            if (exitCode !== 0 && root.pendingRegion === "") {
                root.errorMessage = "Region selection was cancelled";
            }
        }
    }

    Process {
        id: bindsProc
        command: ["bash", "-c", "lua \"$1\" 2>/dev/null; printf '\\036'; hyprctl binds -j", "_", root.readBindsScriptPath]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyBindsSnapshot(text)
        }
        onExited: {
            if (root._bindsRefreshPending) {
                root._bindsRefreshPending = false;
                bindsProc.running = true;
            }
        }
    }

    // Hyprland drops runtime binds when it reloads its config, and the
    // reload may have added or removed binds of its own.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event && event.name === "configreloaded") {
                root._boundBinds = [];
                root.refreshBinds();
            }
        }
    }

    Process {
        id: prepareDir
    }
    Process {
        id: writeMarker
    }
    Process {
        id: clearMarkerProc
    }
    Process {
        id: mkdirs
    }
    Process {
        id: notifProc
    }

    Process {
        id: wpctlProc
    }

    Process {
        id: volReadProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var out = String(text || "").trim()
                var parts = out.split(/\s+/)
                var sink = parseFloat(parts[0])
                var source = parseFloat(parts[1])
                var cmds = []
                if (config.audioDesktop && !isNaN(sink)) {
                    root._savedAudioSinkVolume = sink
                    cmds.push(root.wpctlSetCommand("DEFAULT_AUDIO_SINK", config.audioVolume / 100))
                }
                if (config.audioMicrophone && !isNaN(source)) {
                    root._savedAudioSourceVolume = source
                    cmds.push(root.wpctlSetCommand("DEFAULT_AUDIO_SOURCE", config.audioMicVolume / 100))
                }
                root.runWpctl(cmds)
            }
        }
    }

    // Fallback when the IPC stop didn't terminate the recorder: SIGINT is
    // graceful (finalizes the file) and does not require the socket to reply.
    Process {
        id: fallbackStop
    }

    Timer {
        id: stopTimeout
        interval: 6000
        onTriggered: {
            if (gsr.running) {
                fallbackStop.command = ["bash", "-c", "pkill -INT -x gpu-screen-recorder || true"];
                fallbackStop.running = true;
            }
        }
    }

    // Timer to verify the recording file is fully written before
    // declaring it saved. gsr may exit before the OS flushes all write
    // buffers, so we wait briefly and check the file exists with
    // non-zero size. Prevents the "laggy playback / truncated file"
    // issue caused by reading a file that's still being flushed.
    Timer {
        id: fileVerifyTimer
        interval: 500
        onTriggered: {
            var f = root.recordingFile;
            if (f && f.length > 0) {
                var checkCmd = ["bash", "-c", "test -s '" + f + "' && echo ok || echo missing"];
                fileVerifyProc.command = checkCmd;
                fileVerifyProc.running = true;
            } else {
                // No file path means it was a stream or the path was already cleared
                root.onRecordingSaved();
            }
        }
    }

    Process {
        id: fileVerifyProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                if (text.trim() === "ok") {
                    root.onRecordingSaved();
                } else {
                    root.onRecordingFailed("Recording file missing or empty — write may have been interrupted");
                }
            }
        }
    }

    // ── State file (replacement-bar fallback) ──
    // px-shell issue #41: replacement bars (px.bar) cannot resolve
    // third-party services through their PluginBarFacade — neither
    // pluginShellForBarEntry() nor the scoped pluginShellFor() give a
    // replacement bar a service-capable handle for a different plugin's
    // id. The built-in omarchy.bar gets one via pluginShellForId(),
    // but px.bar is restricted by design. Instead, Service.qml mirrors
    // its relevant state into a JSON file that BarWidget.qml + Panel.qml
    // can read directly (same pattern px.media → px.notch uses).
    readonly property string barStatePath: runtimeDir + "/state.json"

    function statusJson() {
        var st = root.state;
        var cfg = root.config || {};
        return JSON.stringify({
            state: st,
            recordingState: st,
            recordingIsStream: root.recordingIsStream,
            recordingElapsed: root.recordingElapsed,
            recordingFile: root.recordingFile,
            lastSavedPath: root.lastSavedPath,
            replayActive: root.replayActive,
            gpuDetected: root.gpuDetected,
            gpuInfo: root.gpuInfo,
            monitors: root.monitors,
            audioDevices: root.audioDevices,
            webcamDevices: root.webcamDevices,
            config: cfg,
            configLoaded: root.configLoaded,
            active: root.active,
            paused: root.paused,
            busy: root.busy,
            errorMessage: root.errorMessage,
            outputDir: root.outputDir,
            configFilePath: root.configFilePath,
            stateFilePath: root.stateFilePath,
            barStatePath: root.barStatePath,
            recordingStateFilePath: root.recordingStateFilePath,
            ipcSocketPath: root.ipcSocketPath,
            ipcScriptPath: root.ipcScriptPath,
            captureKind: root.captureKind,
            activeTarget: root.activeTarget,
            resolvedBinds: root.resolvedBinds
        });
    }

    function flushState() {
        if (!root.gpuDetected && root.state === "idle") return;
        // Write the state file via FileView.setText with atomicWrites: false
        // so inotify watchers in BarWidget.qml can detect the change.
        stateFile.setText(root.statusJson() + "\n");
    }

    FileView {
        id: stateFile
        path: root.barStatePath
        watchChanges: false
        atomicWrites: false
        printErrors: false
    }

    // State transition bookkeeping
    onStateChanged: {
        if (state === "recording" || state === "replay") {
            recordingBaseSec = recordingElapsed;
            recordingBaseMs = Date.now();
        }
        flushState();
    }

    onRecordingElapsedChanged: { flushState() }
    onGpuDetectedChanged: { flushState() }
    onGpuInfoChanged: { flushState() }
    onMonitorsChanged: { flushState() }
    onConfigChanged: {
        flushState();
        var overrides = Binds.ACTIONS.map(function (a) { return config[a.configKey]; }).join("\n");
        if (overrides !== _bindOverrides) {
            _bindOverrides = overrides;
            refreshBinds();
        }
        syncBinds();
    }
    onCaptureKindChanged: {
        flushState();
        syncBinds();
    }
    onConfigLoadedChanged: { flushState() }
    onRecordingIsStreamChanged: { flushState() }
    onRecordingFileChanged: { flushState() }
    onErrorMessageChanged: { flushState() }

    // Elapsed timer (only while recording / replay buffer running)
    Timer {
        id: elapsedTimer
        interval: 1000
        running: root.state === "recording" || root.state === "replay"
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (root.state === "recording" || root.state === "replay") {
                root.recordingElapsed = root.recordingBaseSec + Math.floor((Date.now() - root.recordingBaseMs) / 1000);
            }
        }
    }

    ControlsOverlay {
        service: root
    }

    // IPC target so bar widgets / keybinds can toggle recording even when
    // the service object is not reachable through the host's PluginShellApi
    // (px-shell issue #41: replacement bars can't resolve third-party services).
    IpcHandler {
        target: "px-recast"

        function toggle(): string {
            root.toggle();
            return "ok";
        }

        function pause(): string {
            root.pause();
            return "ok";
        }

        function resume(): string {
            root.resume();
            return "ok";
        }

        function togglePause(): string {
            root.togglePause();
            return "ok";
        }

        function cancel(): string {
            root.cancel();
            return "ok";
        }

        function status(): string {
            return root.statusJson();
        }

        function record(): string {
            root.start("auto");
            return "ok";
        }

        function stop(): string {
            root.stop();
            return "ok";
        }

        function replay(a: string): string {
            root.startReplay();
            return "ok";
        }

        function startReplay(): string {
            root.startReplay();
            return "ok";
        }

        function saveReplay(): string {
            root.saveReplay();
            return "ok";
        }

        function stopReplay(): string {
            root.stopReplay();
            return "ok";
        }

        function openClip(): string {
            root.openPath(root.lastSavedPath);
            return "ok";
        }

        function openFolder(): string {
            root.openFolderOf(root.lastSavedPath);
            return "ok";
        }

        function refreshGpu(): string {
            root.refreshGpuInfo();
            root.refreshMonitors();
            return "ok";
        }

        function config(key: string, value: string): string {
            root.setConfig(key, value);
            return "ok";
        }

        function persist(): string {
            root.persistConfig();
            return "ok";
        }
    }
}
