pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Binds.js" as Binds
import "Placement.js" as Placement

// Capture controls: status, elapsed time and one row per action with its
// keybind. Shown while a capture runs, and as a preview while the settings
// panel is open. Docked, it's a layer surface on the screen and edge
// Placement.js picks, never taking keyboard focus, with pointer input only on
// the card (or the hover strip it tucks into). Popped out, it's a floating,
// pinned Hyprland window, so the compositor does the dragging.
Scope {
    id: root

    required property var service

    readonly property var cfg: service.config
    readonly property string captureKind: service.captureKind
    readonly property bool previewing: captureKind === ""
    readonly property bool eligible: !previewing || service.panelOpen

    readonly property var screenList: {
        var out = [];
        var screens = Quickshell.screens;
        for (var i = 0; i < screens.length; i++)
            out.push({
                name: screens[i].name,
                x: screens[i].x,
                y: screens[i].y,
                width: screens[i].width,
                height: screens[i].height
            });
        return out;
    }
    readonly property string focusedName: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    // When the target doesn't name a screen (window/portal, or a region not
    // picked yet), the screen focused when the overlay appeared stands in for
    // it. Frozen so the overlay doesn't hop away from the pointer.
    property string anchorFocus: ""
    onEligibleChanged: anchorFocus = eligible ? (anchorFocus || focusedName) : ""
    onCaptureKindChanged: {
        anchorFocus = eligible ? focusedName : "";
        Qt.callLater(flash);
    }

    readonly property var target: {
        if (!previewing && service.activeTarget)
            return service.activeTarget;
        if (cfg.targetMode === "monitor")
            return {
                type: "monitor",
                name: cfg.monitorName || cfg._lastMonitor || ""
            };
        if (cfg.targetMode === "region" && (cfg.region || cfg._lastRegion))
            return {
                type: "region",
                geometry: cfg.region || cfg._lastRegion
            };
        return {
            type: "portal"
        };
    }
    readonly property var placement: eligible
        ? Placement.choosePlacement(cfg.overlayMode, Placement.recordedScreens(target, screenList, anchorFocus || focusedName), screenList, cfg.overlayEdge)
        : null
    readonly property bool canPin: placement !== null && placement.kind === "peek"
    readonly property string kind: !placement ? "" : (canPin && cfg.overlayPinned ? "pinned" : placement.kind)
    readonly property string edge: placement ? placement.edge : "right"
    readonly property string screenName: {
        if (!placement)
            return "";
        return placement.screen;
    }

    // Peek: out for overlaySeconds after a capture starts or the panel
    // toggles, out while hovered, tucked into the edge otherwise.
    property bool timedShown: false
    property bool hoverShown: false
    readonly property bool revealed: kind !== "peek" || timedShown || hoverShown || service.panelOpen

    // Deferred by callers: the bindings this reads update after the change
    // handlers that trigger it.
    function flash() {
        if (!eligible)
            return;
        timedShown = true;
        showTimer.restart();
    }

    Connections {
        target: root.service
        function onPanelOpenChanged() {
            Qt.callLater(root.flash);
        }
    }

    Timer {
        id: showTimer
        interval: root.cfg.overlaySeconds * 1000
        onTriggered: root.timedShown = false
    }

    readonly property string statusLabel: {
        if (previewing)
            return "Controls preview";
        if (captureKind === "replay")
            return "Replay buffer";
        if (captureKind === "stream")
            return "Live";
        return service.paused ? "Paused" : "Recording";
    }
    readonly property color statusColor: {
        if (previewing || service.paused)
            return Color.muted;
        return captureKind === "replay" ? Color.accent : Color.urgent;
    }
    readonly property var actions: Binds.actionsFor(previewing ? "record" : captureKind)

    function formatElapsed(sec) {
        var pad = function (n) {
            return n < 10 ? "0" + n : String(n);
        };
        var h = Math.floor(sec / 3600);
        return (h > 0 ? pad(h) + ":" : "") + pad(Math.floor((sec % 3600) / 60)) + ":" + pad(sec % 60);
    }

    function glyph(codePoint) {
        return String.fromCodePoint(codePoint);
    }

    readonly property string floatTitle: "Better Recast controls"

    // Hyprland drops runtime rules on config reload, so this is re-sent then.
    function applyFloatRule() {
        Quickshell.execDetached(["hyprctl", "eval", 'hl.window_rule({ match = { title = "^' + floatTitle
            + '$" }, float = true, pin = true, center = true, no_initial_focus = true, no_screen_share = true })']);
    }

    Component.onCompleted: applyFloatRule()

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event && event.name === "configreloaded")
                root.applyFloatRule();
        }
    }

    function togglePopout() {
        if (cfg.overlayMode === "float")
            service.setConfigs({
                overlayMode: cfg.overlayPrevMode
            });
        else
            service.setConfigs({
                overlayPrevMode: cfg.overlayMode,
                overlayMode: "float"
            });
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win

            required property ShellScreen modelData

            readonly property bool sideEdge: root.edge === "left" || root.edge === "right"
            readonly property bool pointerInside: card.hovered || stripHover.hovered

            // 0 is tucked past the edge, 1 fully in.
            property real slide: root.revealed ? 1 : 0
            readonly property real tucked: (1 - slide) * ((sideEdge ? card.width : card.height) + 2)

            screen: modelData
            visible: root.kind !== "" && root.kind !== "float" && modelData !== null && modelData.name === root.screenName && !remap.remapping
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "px-recast-controls"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            // A strip along the whole edge, as deep as the card.
            anchors {
                left: root.edge !== "right"
                right: root.edge !== "left"
                top: root.edge !== "bottom"
                bottom: root.edge !== "top"
            }
            implicitWidth: sideEdge ? card.width : 0
            implicitHeight: sideEdge ? 0 : card.height

            mask: Region {
                item: root.revealed ? card : hotStrip

                Region {
                    item: root.kind === "peek" ? hotStrip : null
                }
            }

            Behavior on slide {
                NumberAnimation {
                    duration: 220
                    easing.type: Easing.OutCubic
                }
            }

            onPointerInsideChanged: {
                if (pointerInside) {
                    hideTimer.stop();
                    if (root.revealed)
                        root.hoverShown = true;
                    else
                        revealTimer.restart();
                } else {
                    revealTimer.stop();
                    if (root.hoverShown)
                        hideTimer.restart();
                }
            }

            ScreenMoveRemap {
                id: remap
                window: win
            }

            Timer {
                id: revealTimer
                interval: 80
                onTriggered: root.hoverShown = true
            }

            Timer {
                id: hideTimer
                interval: 400
                onTriggered: {
                    if (!win.pointerInside)
                        root.hoverShown = false;
                }
            }

            Item {
                id: hotStrip

                readonly property real depth: 6
                readonly property real margin: Style.space(24)

                width: win.sideEdge ? depth : card.width + margin * 2
                height: win.sideEdge ? card.height + margin * 2 : depth
                x: win.sideEdge ? (root.edge === "right" ? win.width - depth : 0) : card.x - margin
                y: win.sideEdge ? card.y - margin : (root.edge === "bottom" ? win.height - depth : 0)

                HoverHandler {
                    id: stripHover
                    enabled: root.kind === "peek"
                }
            }

            ControlsCard {
                id: card

                visible: win.slide > 0.001
                x: {
                    if (win.sideEdge)
                        return root.edge === "right" ? win.width - width + win.tucked : -win.tucked;
                    return Math.round((win.width - width) / 2);
                }
                y: {
                    if (win.sideEdge)
                        return Math.round((win.height - height) / 2);
                    return root.edge === "bottom" ? win.height - height + win.tucked : -win.tucked;
                }
            }
        }
    }

    FloatingWindow {
        id: floatWin

        readonly property bool wanted: root.kind === "float"
        // Set while the window is meant to be up, so a close from Hyprland
        // (not from the dock button) can be told apart and docks it.
        property bool shown: false

        visible: wanted
        title: root.floatTitle
        color: Color.background
        implicitWidth: floatCard.width
        implicitHeight: floatCard.height

        onVisibleChanged: {
            if (visible) {
                shown = true;
                return;
            }
            if (shown && wanted && root.cfg.overlayMode === "float")
                root.togglePopout();
            shown = false;
        }

        ControlsCard {
            id: floatCard
            floating: true
        }
    }

    component ControlsCard: Rectangle {
        id: cardRoot

        property bool floating: false
        readonly property bool hovered: cardHover.hovered
        readonly property real pad: Style.space(12)

        width: content.implicitWidth + pad * 2
        height: content.implicitHeight + pad * 2
        radius: floating ? 0 : Style.cornerRadius
        color: Color.background
        border.width: floating ? 0 : 1
        border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)

        HoverHandler {
            id: cardHover
        }

        ColumnLayout {
            id: content

            x: cardRoot.pad
            y: cardRoot.pad
            spacing: Style.space(8)

            RowLayout {
                id: header

                Layout.fillWidth: true
                spacing: Style.space(8)

                // Floating: the header moves the window. A DragHandler with no
                // target hands the drag to the compositor instead of
                // re-positioning from QML, which lags and jumps.
                DragHandler {
                    target: null
                    enabled: cardRoot.floating
                    dragThreshold: 0
                    acceptedButtons: Qt.LeftButton
                    onActiveChanged: {
                        if (active && header.Window.window)
                            header.Window.window.startSystemMove();
                    }
                }

                Rectangle {
                    implicitWidth: Style.space(10)
                    implicitHeight: implicitWidth
                    radius: implicitWidth / 2
                    color: root.statusColor
                    Layout.alignment: Qt.AlignVCenter
                }

                Text {
                    text: root.statusLabel
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                    font.bold: true
                    Layout.alignment: Qt.AlignVCenter
                }

                Text {
                    visible: !root.previewing
                    text: root.formatElapsed(root.service.recordingElapsed || 0)
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.subtitle
                    Layout.alignment: Qt.AlignVCenter
                }

                Item {
                    Layout.fillWidth: true
                    Layout.minimumWidth: Style.space(12)
                }

                Button {
                    visible: root.canPin && !cardRoot.floating
                    iconText: root.glyph(root.cfg.overlayPinned ? 0xF0404 : 0xF0403)
                    tooltipText: root.cfg.overlayPinned ? "Unpin (hide after a few seconds)" : "Pin (keep visible)"
                    iconSize: Style.font.title
                    horizontalPadding: Style.space(7)
                    verticalPadding: Style.space(4)
                    selected: root.cfg.overlayPinned
                    onClicked: root.service.setConfigs({
                        overlayPinned: !root.cfg.overlayPinned
                    })
                }

                Button {
                    iconText: root.glyph(0xF03CC)
                    iconRotation: cardRoot.floating ? 180 : 0
                    tooltipText: cardRoot.floating ? "Dock" : "Pop out (floating window)"
                    iconSize: Style.font.title
                    horizontalPadding: Style.space(7)
                    verticalPadding: Style.space(4)
                    onClicked: root.togglePopout()
                }
            }
            Repeater {
                model: root.actions

                Rectangle {
                    id: row

                    required property var modelData
                    readonly property var bind: root.service.resolvedBinds[modelData.id] || {
                        combo: "",
                        source: "none",
                        conflict: false
                    }

                    Layout.fillWidth: true
                    implicitWidth: rowContent.implicitWidth + Style.space(16)
                    implicitHeight: rowContent.implicitHeight + Style.space(12)
                    radius: Style.cornerRadius
                    color: rowMouse.containsMouse && rowMouse.enabled
                        ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, Style.hoverFillAlpha)
                        : "transparent"

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        enabled: !root.previewing
                        hoverEnabled: true
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: root.service[row.modelData.ipc]()
                    }

                    RowLayout {
                        id: rowContent

                        anchors.verticalCenter: parent.verticalCenter
                        x: Style.space(8)
                        width: parent.width - Style.space(16)
                        spacing: Style.space(6)

                        Text {
                            text: row.modelData.label
                            color: Color.foreground
                            font.family: Style.font.family
                            font.pixelSize: Style.font.subtitle
                            Layout.fillWidth: true
                            Layout.minimumWidth: implicitWidth
                        }

                        Repeater {
                            model: row.bind.combo === "" ? [] : row.bind.combo.split(" + ")

                            Rectangle {
                                id: chip

                                required property string modelData

                                implicitWidth: chipText.implicitWidth + Style.space(10)
                                implicitHeight: chipText.implicitHeight + Style.space(4)
                                radius: Style.space(3)
                                color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.1)

                                Text {
                                    id: chipText
                                    anchors.centerIn: parent
                                    text: chip.modelData
                                    color: row.bind.conflict ? Color.urgent : Color.foreground
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.body
                                }
                            }
                        }

                        Text {
                            visible: row.bind.conflict
                            text: root.glyph(0xF0026)
                            color: Color.urgent
                            font.family: Style.font.family
                            font.pixelSize: Style.font.subtitle
                        }

                        Text {
                            text: row.bind.conflict ? "not bound" : (Binds.SOURCE_LABELS[row.bind.source] || "")
                            color: Color.muted
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            Layout.minimumWidth: implicitWidth
                        }
                    }
                }
            }
        }
    }
}
