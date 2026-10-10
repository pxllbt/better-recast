pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "Config.js" as Config
import "GpuProbe.js" as GpuProbe

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
    property string gsrVersion: ""
    property string gsrLatest: ""
    property bool gsrProbeDone: false
    property string gsrUpdateOutput: ""
    readonly property bool gsrUpdateAvailable: !!(root.gsrVersion && root.gsrLatest && root.gsrVersion !== root.gsrLatest)
    /**
     * True only once a probe has actually run and found no binary. Before the
     * first probe completes this stays false on purpose: the plugin must not
     * block recording on a check that has not reported yet, and gsr is
     * overwhelmingly present. A missing binary is caught the moment the probe
     * says so.
     */
    readonly property bool gsrMissing: root.gsrProbeDone && root.gsrVersion === ""
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
    property int recordingElapsed: 0
    property int recordingBaseSec: 0
    property double recordingBaseMs: 0
    property string lastTarget: ""      // for panel display / notification
    property string pendingRegion: ""   // set by pickRegion before start
    property string errorMessage: ""
    // Pre-roll countdown state (see start()).
    property bool countdownPending: false
    property var countdownTarget: "auto"
    property int countdownRemaining: 0

    // Driving the starting→replay promotion in gsr.onRunningChanged, and
    // tagging the stop-notification so a closed buffer isn't announced as a
    // saved recording.
    property bool _startingReplay: false
    property bool _wasReplay: false
    property string _lastSavedPath: ""
    readonly property string lastSavedPath: _lastSavedPath

    // Saved volumes so we can restore the user's listening level
    // when recording stops. applyVolume() saves via volReadProc before
    // overriding; restoreVolume() restores them on stop/fail.
    property var _savedAudioSinkVolume: 1.0
    property var _savedAudioSourceVolume: 0.0

    readonly property bool active: state === "recording" || state === "paused"
    readonly property bool paused: state === "paused"
    readonly property bool replayActive: state === "replay"
    readonly property bool busy: state === "starting" || state === "stopping"

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
    readonly property string ipcScriptPath: {
        // Resolve relative to this plugin's source directory.
        var url = Qt.resolvedUrl("scripts/gsr-ipc.py");
        var s = String(url);
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

    // ── gpu-screen-recorder version check ──
    function refreshVersion() {
        gsrVerProc.running = true;
        gsrLatestProc.running = true;
    }
    function notifyUpdate(summary, body) {
        // Surface update activity as a desktop notification so the user can
        // actually see progress — previously the whole step was silent.
        // Reuses sendNotification() (Omarchy-native, urgency + timeout) rather
        // than a second notify-send Process, so the update notice follows the
        // same path as the recording/stream/replay notices.
        sendNotification(summary, body, "normal", 0);
    }
    function updateGsr() {
        // Promotes gsr through the Omarchy-supported package path. Direct
        // pacman is blocked by Omarchy's transaction hook, so bypass it
        // explicitly with OMARCHY_ALLOW_DIRECT_PACMAN=1.
        //
        // `-S --needed`, never `-Syu`: the user asked to update one
        // package, not to upgrade the whole system. A bare `-Syu` here
        // silently pulled in unrelated upgrades (kernel, drivers) every
        // time the notice was tapped. `--needed` also skips the reinstall
        // when the installed version already matches, so the notice no
        // longer "does nothing".
        notifyUpdate("Updating gpu-screen-recorder", "Fetching the latest build from your package repositories…");
        gsrUpdateProc.running = false;
        gsrUpdateProc.command = ["bash", "-c", "pkexec env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed --noconfirm gpu-screen-recorder 2>&1"];
        gsrUpdateProc.running = true;
    }
    Process {
        id: gsrVerProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.gsrProbeDone = true;
                if (text.indexOf("__GSR_MISSING__") !== -1)
                    return;
                // `gpu-screen-recorder --version` prints a bare "6.1.0"; older
                // builds prefix it with the program name. Accept both.
                var m = text.match(/gpu-screen-recorder\s*(\d+\.\d+\.\d+)/i);
                if (!m) m = text.match(/(\d+\.\d+\.\d+)/);
                if (m) root.gsrVersion = m[1];
            }
        }
        // `command -v` has to run through bash on purpose. Running
        // "gpu-screen-recorder" directly does not work for this check: when the
        // binary is absent the Process never spawns, so neither stdout nor
        // onExited ever fires and the probe silently never completes. Bash
        // always exists, so this always exits and always reports.
        onExited: root.gsrProbeDone = true
        command: ["bash", "-c", "if command -v gpu-screen-recorder >/dev/null 2>&1; then gpu-screen-recorder --version 2>/dev/null; else echo __GSR_MISSING__; fi"]
    }
    Process {
        id: gsrLatestProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                // `pacman -Si` reports the version the package manager
                // can actually install, e.g. "Version   : 6.1.0-1". Strip
                // the pkgrel suffix so it compares against the bare
                // "6.1.0" that `gpu-screen-recorder --version` prints.
                var m = text.match(/Version\s*:\s*(\d+\.\d+\.\d+)/);
                if (m) root.gsrLatest = m[1];
            }
        }
        // The check must compare against the package manager's version,
        // not the upstream git tag: the update installs through pacman,
        // so an upstream-only release (e.g. 6.1.3 while Arch carries
        // 6.1.0) would advertise an update pacman can never deliver —
        // which is exactly why tapping the notice "did nothing".
        command: ["bash", "-c", "pacman -Si gpu-screen-recorder 2>/dev/null || true"]
    }
    Process {
        id: gsrUpdateProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                gsrUpdateOutput = text;
            }
        }
        // pacman and pkexec write their diagnostics to stderr, merged in
        // above via 2>&1. Surface them only when the transaction actually
        // failed — on success the output is just pacman's progress noise.
        onExited: function (exitCode, exitStatus) {
            if (exitCode !== 0) {
                var lines = (gsrUpdateOutput || "").trim().split("\n");
                var msg = lines.length ? lines[lines.length - 1] : "update failed";
                root.errorMessage = "gpu-screen-recorder update failed: " + msg;
                notifyUpdate("gpu-screen-recorder update failed", msg);
                return;
            }
            notifyUpdate("gpu-screen-recorder updated", "Installed " + (root.gsrVersion || "the latest version") + ".");
            // Re-probe so the update notice clears once the new build is in place.
            Qt.callLater(root.refreshVersion);
        }
    }
    Timer {
        id: gsrVersionTimer
        interval: 12 * 60 * 60 * 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refreshVersion()
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
        Qt.callLater(function() { flushState() });
        Qt.callLater(function() { applyVolume() });
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
        // A press during the pre-roll countdown means "never mind".
        if (countdownPending) {
            cancelCountdown();
            return;
        }
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
        if (!gsrPresent())
            return;
        // Never launch a second recorder on top of a live one: `running = true`
        // on an already-running Process emits no runningChanged, so the
        // starting->recording promotion never happens and the state machine
        // sticks on "starting". Reap the orphan and let the user retry.
        if (gsr.running) {
            errorMessage = "Closed a leftover recorder session — press record again";
            stop();
            return;
        }
        errorMessage = "";
        applyVolume();

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
        state = "starting";
        recordingElapsed = 0;
        startWatchdog.restart();
        gsr.command = ["gpu-screen-recorder"].concat(args, ["-o", outputDir, "-ipc", ipcSocketPath]);
        prepareDir.command = ["bash", "-c", "mkdir -p " + outputDir + " && mkdir -p " + runtimeDir];
        prepareDir.running = true;
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
        if (state !== "replay" && state !== "starting")
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

    // Abort an in-flight pre-roll countdown (stop / pause / a second press).
    function cancelCountdown() {
        countdownTimer.running = false;
        countdownPending = false;
        countdownRemaining = 0;
        flushState();
    }

    /**
     * Block a launch when the recorder binary is known to be absent.
     *
     * Without this the panel lies twice before failing: `starting` is promoted
     * to `recording` on the spawn attempt, then the process dies with shell exit
     * code 127 and the user sees "gpu-screen-recorder exited unexpectedly (code
     * 127)" -- which does not say what is wrong or how to fix it. Returns true
     * when the launch may proceed.
     */
    function gsrPresent() {
        if (!gsrMissing)
            return true;
        // Re-probe on the press: the user may have just installed it, and
        // without this the panel would stay broken until the next 12h timer.
        refreshVersion();
        errorMessage = "gpu-screen-recorder isn't installed — install it with: pacman -S gpu-screen-recorder";
        state = "error";
        return false;
    }

    function start(targetType) {
        if (countdownPending)
            return;
        if (active || busy)
            return;
        if (!gsrPresent())
            return;
        // See startReplay(): a live gsr would swallow this launch silently and
        // strand state on "starting". Reap it instead.
        if (gsr.running) {
            errorMessage = "Closed a leftover recorder session — press record again";
            stop();
            return;
        }
        errorMessage = "";
        applyVolume();

        // Pre-roll countdown. Deliberately does NOT set state to
        // "starting": that would flip `busy`, and the deferred start()
        // below would early-return on `if (active || busy)`. Keep the
        // real target type aside -- lastTarget is a display string, not
        // something start() can consume.
        var secs = Math.max(0, parseInt(config.countdown) || 0);
        if (secs > 0) {
            countdownPending = true;
            countdownTarget = targetType;
            countdownRemaining = secs;
            sendNotification("Better Recast", "Recording starts in " + secs + "s…");
            countdownTimer.interval = 1000;
            countdownTimer.running = true;
            return;
        }

        beginRecording(targetType);
    }

    // The countdown hands off here rather than re-entering start(). A re-entrant
    // "countdown already ran" flag was tried first and did not work: start()
    // cleared the flag before reaching the countdown branch, so every timer tick
    // queued a fresh countdown and it looped 3-2-1 forever without recording.
    function beginRecording(targetType) {
        // Reached both directly (no countdown) and from the countdown timer.
        if (!gsrPresent())
            return;
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
            state = "starting";
            recordingElapsed = 0;
            startWatchdog.restart();
            gsr.command = ["gpu-screen-recorder"].concat(args);
            gsr.environment = {"GSR_AUTH": streamKey};
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
        state = "starting";
        recordingElapsed = 0;
        startWatchdog.restart();
        gsr.command = args;
        gsr.running = true;

        // compatibility marker for stock pyxis indicators
        writeMarker.command = ["bash", "-c", "mkdir -p " + runtimeDir + " && printf '%s\n' '" + recordingFile + "' > " + recordingStateFilePath + " && printf '%s\n' '" + String(lastTarget) + "' > " + stateFilePath];
        writeMarker.running = true;
    }

    function pickRegion() {
        regionPicker.command = ["omarchy-capture-region", "smart", "--match-monitor"];
        regionPicker.running = true;
    }

    function stop() {
        // A pending pre-roll has no recorder behind it yet, so the guards
        // below would all fail and the countdown would fire afterwards --
        // pressing stop during the countdown has to cancel it outright.
        if (countdownPending) {
            cancelCountdown();
            return;
        }
        // gsr.running matters as much as `active`: a session can outlive our
        // state (e.g. mode switched away from replay while the buffer kept
        // recording). Without this, stop() no-ops and the orphan never dies.
        if (!active && state !== "starting" && !gsr.running)
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

    function setConfig(key, value) {
        var copy = Object.assign({}, config);
        copy[key] = value;
        config = Config.normalize(copy);
        persistConfig();
        // Leaving replay mode while the buffer is live used to just reset the
        // state, which orphaned a still-running gsr (and stranded the next
        // launch on "starting"). Shut the buffer down properly instead.
        if (key === "mode" && config.mode !== "replay" && (state === "replay" || gsr.running))
            stopReplay();
        if (key === "audioVolume" || key === "audioMicVolume" || key === "audioDesktop" || key === "audioMicrophone")
            applyVolume();
        if (key === "webcamEnabled" || key === "webcamDevice" || key === "webcamSize")
            refreshWebcamDevices();
    }

    // Update config in memory only — never persist. Used for session-scoped
    // stream credentials while `streamRemember` is off.
    function applyVolume() {
        if (!config.audioEnabled) {
            setWpctlVolume("DEFAULT_AUDIO_SINK", 0);
            setWpctlVolume("DEFAULT_AUDIO_SOURCE", 0);
            return;
        }
        // Read both volumes first, then override. Reading must complete
        // before setting so restoreVolume() has the correct old levels.
        _savedAudioSinkVolume = 1.0;
        _savedAudioSourceVolume = 0.0;
        volReadProc.command = ["bash", "-c",
            "wpctl get-volume @DEFAULT_AUDIO_SINK@ @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | awk '{print $2, $4}'"
        ];
        volReadProc.running = true;
    }

    function setWpctlVolume(node, volumePercent) {
        wpctlProc.command = ["bash", "-c", "wpctl set-volume @" + node + "@ " + (volumePercent / 100).toFixed(2)];
        wpctlProc.running = true;
    }

    function restoreVolume() {
        setWpctlVolume("DEFAULT_AUDIO_SINK", _savedAudioSinkVolume * 100);
        setWpctlVolume("DEFAULT_AUDIO_SOURCE", _savedAudioSourceVolume * 100);
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

    function onRecordingSaved() {
        var wasStream = recordingIsStream;
        var wasReplay = _wasReplay;
        var saved = recordingFile;
        recordingFile = "";
        recordingIsStream = false;
        _wasReplay = false;
        state = "idle";
        clearMarkerProc.command = ["bash", "-c", "rm -f " + recordingStateFilePath + " " + stateFilePath];
        clearMarkerProc.running = true;
        if (wasReplay) {
            sendNotification("Replay buffer stopped", "The rolling buffer was closed without saving.", "normal", 10000);
        } else if (wasStream) {
            sendNotification("Stream ended", "Your live stream has stopped.", "normal", 10000);
        } else if (saved) {
            root._lastSavedPath = saved;
            sendNotification("Screen recording saved", saved, "normal", 10000);
        }
        restoreVolume();
    }

    function onRecordingFailed(msg) {
        _startingReplay = false;
        errorMessage = msg;
        var wasStream = recordingIsStream;
        var wasReplay = _wasReplay;
        var saved = recordingFile;
        recordingFile = "";
        recordingIsStream = false;
        _wasReplay = false;
        state = "idle";
        clearMarkerProc.command = ["bash", "-c", "rm -f " + recordingStateFilePath + " " + stateFilePath];
        clearMarkerProc.running = true;
        if (wasReplay) {
            sendNotification("Replay buffer crashed", msg, "critical", 8000);
        } else {
            sendNotification(wasStream ? "Stream ended unexpectedly" : "Screen recording failed", msg, "critical", 8000);
        }
        restoreVolume();
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
                root.state = "idle";
                restoreVolume();
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
                    if (out !== "ok")
                        root._lastSavedPath = out;
                    root.sendNotification("Replay saved", out, "normal", 10000);
                }
            }
        }
    }
    Process {
        id: openProc
    }

    Process {
        id: ipcPause
    }
    Process {
        id: ipcResume
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
                if (!isNaN(sink)) root._savedAudioSinkVolume = sink
                if (!isNaN(source)) root._savedAudioSourceVolume = source
                if (config.audioDesktop)
                    setWpctlVolume("DEFAULT_AUDIO_SINK", config.audioVolume || 100)
                else
                    setWpctlVolume("DEFAULT_AUDIO_SINK", 0)
                if (config.audioMicrophone)
                    setWpctlVolume("DEFAULT_AUDIO_SOURCE", config.audioMicVolume || 100)
                else
                    setWpctlVolume("DEFAULT_AUDIO_SOURCE", 0)
            }
        }
    }

    // Fallback when the IPC stop didn't terminate the recorder: SIGINT is
    // graceful (finalizes the file) and does not require the socket to reply.
    Process {
        id: fallbackStop
    }

    // gsr exposes no "ready" signal, so `runningChanged` is the only hint that a
    // launch took. If that hint is missed for any reason the state machine can
    // sit on "starting" forever while the UI claims a file is being written.
    // This watchdog reconciles the state against the real process on a timer.
    Timer {
        id: startWatchdog
        interval: 1500
        repeat: false
        onTriggered: {
            if (root.state !== "starting")
                return;
            if (gsr.running) {
                // Alive after the grace period: adopt it. The session is real,
                // it just didn't announce itself.
                root.state = root._startingReplay ? "replay" : "recording";
            } else {
                root.onRecordingFailed("gpu-screen-recorder did not start");
            }
            root._startingReplay = false;
        }
    }

    Timer {
        id: stopTimeout
        interval: 6000
        onTriggered: {
            if (gsr.running) {
                // Match on this session's IPC socket rather than the bare process
                // name: `pkill -x gpu-screen-recorder` would also SIGINT an
                // unrelated recorder the user is running (another plugin, a
                // second instance, a hand-typed capture).
                fallbackStop.command = ["bash", "-c",
                    "pkill -INT -f 'gpu-screen-recorder.*-ipc " + ipcSocketPath + "' || true"];
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
            countdownPending: root.countdownPending,
            countdownRemaining: root.countdownRemaining,
            gsrVersion: root.gsrVersion,
            gsrProbeDone: root.gsrProbeDone,
            gsrMissing: root.gsrMissing,
            gsrLatest: root.gsrLatest,
            gsrUpdateAvailable: root.gsrUpdateAvailable,
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
            ipcScriptPath: root.ipcScriptPath
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
    // The countdown lives outside the recorder state machine, so its own
    // change handlers must push state.json for the replacement bar.
    onCountdownPendingChanged: { flushState() }
    onCountdownRemainingChanged: { flushState() }
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
    onConfigChanged: { flushState() }
    onConfigLoadedChanged: { flushState() }
    onRecordingIsStreamChanged: { flushState() }
    onRecordingFileChanged: { flushState() }
    onErrorMessageChanged: { flushState() }

    // Elapsed timer (only while recording / replay buffer running)
    Timer {
        id: countdownTimer
        interval: 1000
        repeat: false
        running: false
        onTriggered: {
            countdownRemaining = countdownRemaining - 1;
            if (countdownRemaining > 0) {
                sendNotification("Better Recast", "Recording starts in " + countdownRemaining + "s…");
                countdownTimer.restart();
                return;
            }
            var t = countdownTarget;
            root.cancelCountdown();
            root.beginRecording(t);
        }
    }

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

        function updateGsr(): string {
            root.updateGsr();
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
