pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "Picker.js" as Picker

// Region / window picker: dims every screen and hints the window under the
// pointer. Left drag draws a region; a bare left click takes the window (or
// monitor) under it. Right press-and-release takes a window, with a confirm
// flash. Every surface is unmapped before `picked` fires, so none of it ends
// up in the capture.
Scope {
    id: root

    signal picked(string spec)
    signal cancelled

    property string phase: "idle" // idle | loading | picking | confirming | closing
    readonly property bool busy: phase !== "idle"
    readonly property bool shown: phase === "picking" || phase === "confirming"

    property var monitors: []
    property var windows: []

    // Pointer in global layout px; drag origin while the left button is down.
    property point pointer: Qt.point(0, 0)
    property bool pointerKnown: false
    property bool dragging: false
    property point dragFrom: Qt.point(0, 0)
    property bool grabbing: false
    property var confirmRect: null
    property real pulse: 0
    property string _result: ""

    readonly property var hovered: pointerKnown ? Picker.windowAt(windows, pointer.x, pointer.y) : null
    readonly property var selection: {
        if (confirmRect)
            return confirmRect;
        if (dragging)
            return Picker.dragRect(dragFrom.x, dragFrom.y, pointer.x, pointer.y);
        return hovered;
    }

    function pick() {
        if (busy)
            return;
        monitors = [];
        windows = [];
        pointerKnown = false;
        dragging = false;
        grabbing = false;
        confirmRect = null;
        pulse = 0;
        phase = "loading";
        snapshotProc.running = true;
    }

    function cancel() {
        if (phase === "loading" || phase === "picking")
            finish("");
    }

    // The compositor needs a frame or two to drop the surfaces after they
    // unmap; the recorder must not start before that.
    function finish(spec) {
        confirmAnim.stop();
        _result = spec;
        phase = "closing";
        settleTimer.restart();
    }

    function applySnapshot(text) {
        var parts = String(text || "").split("\x1e");
        var clients, hyprMonitors, cursor;
        try {
            clients = JSON.parse(parts[0]);
            hyprMonitors = JSON.parse(parts[1]);
            cursor = JSON.parse(parts[2]);
        } catch (e) {
            finish("");
            return;
        }
        monitors = Picker.monitorRects(hyprMonitors);
        windows = Picker.windowRects(clients, hyprMonitors);
        if (monitors.length === 0) {
            finish("");
            return;
        }
        pointer = Qt.point(cursor.x, cursor.y);
        pointerKnown = true;
        phase = "picking";
    }

    function press(button, x, y) {
        if (phase !== "picking")
            return;
        pointer = Qt.point(x, y);
        pointerKnown = true;
        if (button === Qt.RightButton) {
            grabbing = true;
        } else {
            dragFrom = pointer;
            dragging = true;
        }
    }

    function release(button, x, y) {
        if (phase !== "picking")
            return;
        pointer = Qt.point(x, y);
        if (button === Qt.RightButton && grabbing) {
            grabbing = false;
            var win = Picker.windowAt(windows, x, y);
            if (win) {
                confirmRect = win;
                phase = "confirming";
                confirmAnim.restart();
            }
        } else if (button === Qt.LeftButton && dragging) {
            dragging = false;
            var rect = Picker.dragRect(dragFrom.x, dragFrom.y, x, y);
            var spec = Picker.isClick(rect) ? Picker.clickSpec(windows, monitors, x, y) : Picker.specForRect(rect, monitors);
            if (spec !== "")
                finish(spec);
        }
    }

    // Hyprland's layer fade-out would otherwise keep the dimmed overlay on
    // screen into the first frames of the capture. Runtime rules are dropped
    // on config reload, so this is re-sent then.
    function applyLayerRule() {
        Quickshell.execDetached(["hyprctl", "eval", 'hl.layer_rule({ match = { namespace = "^px-recast-picker$" }, no_anim = true, animation = "none" })']);
    }

    Component.onCompleted: applyLayerRule()

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event && event.name === "configreloaded")
                root.applyLayerRule();
        }
    }

    Process {
        id: snapshotProc
        command: ["bash", "-c", "hyprctl clients -j && printf '\\036' && hyprctl monitors -j && printf '\\036' && hyprctl cursorpos -j"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applySnapshot(text)
        }
    }

    Timer {
        id: settleTimer
        interval: 150
        onTriggered: {
            root.phase = "idle";
            root.confirmRect = null;
            if (root._result !== "")
                root.picked(root._result);
            else
                root.cancelled();
        }
    }

    SequentialAnimation {
        id: confirmAnim
        loops: 2
        onFinished: root.finish(Picker.specForRect(root.confirmRect, root.monitors))

        NumberAnimation {
            target: root
            property: "pulse"
            from: 0
            to: 1
            duration: 300
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: root
            property: "pulse"
            from: 1
            to: 0
            duration: 300
            easing.type: Easing.InCubic
        }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win

            required property ShellScreen modelData

            // The selection in this surface's coordinates, and clamped to it
            // for the dimming around it.
            readonly property var local: root.selection ? {
                x: root.selection.x - modelData.x,
                y: root.selection.y - modelData.y,
                w: root.selection.w,
                h: root.selection.h
            } : null
            readonly property var hole: {
                if (!local)
                    return { x: 0, y: 0, w: 0, h: 0 };
                var x1 = Math.max(0, Math.min(width, local.x));
                var y1 = Math.max(0, Math.min(height, local.y));
                var x2 = Math.max(0, Math.min(width, local.x + local.w));
                var y2 = Math.max(0, Math.min(height, local.y + local.h));
                return { x: x1, y: y1, w: x2 - x1, h: y2 - y1 };
            }

            screen: modelData
            visible: root.shown
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "px-recast-picker"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            component Dim: Rectangle {
                color: Qt.rgba(0, 0, 0, 0.35)
            }

            Dim {
                width: win.width
                height: win.hole.y
            }
            Dim {
                y: win.hole.y + win.hole.h
                width: win.width
                height: win.height - y
            }
            Dim {
                y: win.hole.y
                width: win.hole.x
                height: win.hole.h
            }
            Dim {
                x: win.hole.x + win.hole.w
                y: win.hole.y
                width: win.width - x
                height: win.hole.h
            }

            Rectangle {
                readonly property bool strong: root.grabbing && root.hovered !== null

                visible: win.local !== null && (root.dragging || root.confirmRect !== null || root.hovered !== null)
                x: win.local ? win.local.x : 0
                y: win.local ? win.local.y : 0
                width: win.local ? win.local.w : 0
                height: win.local ? win.local.h : 0
                color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, root.confirmRect ? 0.25 * root.pulse : (strong ? 0.18 : 0))
                border.color: Color.accent
                border.width: root.confirmRect ? Math.round(2 + 4 * root.pulse) : (strong || root.dragging ? 4 : 2)
                opacity: root.confirmRect ? 0.4 + 0.6 * root.pulse : 1
            }

            MouseArea {
                anchors.fill: parent
                focus: true
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: root.grabbing ? Qt.ClosedHandCursor : Qt.CrossCursor

                function globalX(mouse) {
                    return win.modelData.x + mouse.x;
                }
                function globalY(mouse) {
                    return win.modelData.y + mouse.y;
                }

                onPressed: mouse => root.press(mouse.button, globalX(mouse), globalY(mouse))
                onReleased: mouse => root.release(mouse.button, globalX(mouse), globalY(mouse))
                onPositionChanged: mouse => {
                    if (root.phase !== "picking")
                        return;
                    root.pointer = Qt.point(globalX(mouse), globalY(mouse));
                    root.pointerKnown = true;
                }
                Keys.onEscapePressed: root.cancel()
            }
        }
    }
}
