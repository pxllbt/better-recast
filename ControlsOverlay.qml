pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Binds.js" as Binds
import "Placement.js" as Placement

// Capture controls on a layer surface: status, elapsed time and one row per
// action with its keybind. Shown while a capture runs, and as a preview while
// the settings panel is open. Placement.js picks the screen and edge; the
// surface never takes keyboard focus and only the card (or the hover strip it
// tucks into) takes pointer input.
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
    // A window/portal capture counts as the screen focused when it started,
    // so the overlay doesn't hop screens as focus moves during it.
    property string captureFocus: ""
    onCaptureKindChanged: {
        captureFocus = captureKind === "" ? "" : (captureFocus || focusedName);
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
        return {
            type: "portal"
        };
    }
    readonly property var placement: eligible
        ? Placement.choosePlacement(cfg.overlayMode, Placement.recordedScreens(target, screenList, captureFocus || focusedName), screenList, cfg.overlayEdge)
        : null
    readonly property bool canPin: placement !== null && placement.kind === "peek"
    readonly property string kind: !placement ? "" : (canPin && cfg.overlayPinned ? "pinned" : placement.kind)
    readonly property string edge: placement ? placement.edge : "right"
    readonly property string screenName: {
        if (!placement)
            return "";
        if (kind === "float" && screenList.some(function (s) { return s.name === root.cfg.overlayFloatScreen; }))
            return cfg.overlayFloatScreen;
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

    readonly property var sourceLabels: ({
            override: "plugin",
            config: "bindings.lua",
            auto: "auto",
            none: "not bound"
        })

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

    function togglePopout(win, card) {
        if (cfg.overlayMode === "float") {
            service.setConfigs({
                overlayMode: cfg.overlayPrevMode
            });
            return;
        }
        // Pop out where it is, so the card doesn't jump. The docked surface
        // only spans its edge, so offset by where that strip sits on screen.
        var originX = edge === "right" ? win.modelData.width - win.width : 0;
        var originY = edge === "bottom" ? win.modelData.height - win.height : 0;
        service.setConfigs({
            overlayPrevMode: cfg.overlayMode,
            overlayMode: "float",
            overlayFloatScreen: win.modelData.name,
            overlayFloatX: Math.round(originX + card.x),
            overlayFloatY: Math.round(originY + card.y)
        });
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win

            required property ShellScreen modelData

            readonly property bool floating: root.kind === "float"
            readonly property bool sideEdge: root.edge === "left" || root.edge === "right"
            readonly property bool pointerInside: cardHover.hovered || stripHover.hovered

            // 0 is tucked past the edge, 1 fully in.
            property real slide: root.revealed ? 1 : 0
            readonly property real tucked: (1 - slide) * ((sideEdge ? card.width : card.height) + 2)

            property point pressAt: Qt.point(0, 0)
            property real dragX: 0
            property real dragY: 0

            screen: modelData
            visible: root.kind !== "" && modelData !== null && modelData.name === root.screenName && !remap.remapping
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "px-recast-controls"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            // Pinned/peek: a strip along the whole edge, as deep as the card.
            // Float: the whole screen, so the card can be dragged anywhere.
            anchors {
                left: win.floating || root.edge !== "right"
                right: win.floating || root.edge !== "left"
                top: win.floating || root.edge !== "bottom"
                bottom: win.floating || root.edge !== "top"
            }
            implicitWidth: !floating && sideEdge ? card.width : 0
            implicitHeight: !floating && !sideEdge ? card.height : 0

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
                    if (!win.pointerInside && !drag.active)
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

            Rectangle {
                id: card

                readonly property real pad: Style.space(10)
                readonly property real homeX: root.cfg.overlayFloatX < 0 ? (win.width - width) / 2 : root.cfg.overlayFloatX
                readonly property real homeY: root.cfg.overlayFloatY < 0 ? (win.height - height) / 2 : root.cfg.overlayFloatY

                width: content.implicitWidth + pad * 2
                height: content.implicitHeight + pad * 2
                visible: win.slide > 0.001
                radius: Style.cornerRadius
                color: Color.background
                border.width: 1
                border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)

                x: {
                    if (win.floating)
                        return Math.max(0, Math.min(win.width - width, homeX + win.dragX));
                    if (win.sideEdge)
                        return root.edge === "right" ? win.width - width + win.tucked : -win.tucked;
                    return Math.round((win.width - width) / 2);
                }
                y: {
                    if (win.floating)
                        return Math.max(0, Math.min(win.height - height, homeY + win.dragY));
                    if (win.sideEdge)
                        return Math.round((win.height - height) / 2);
                    return root.edge === "bottom" ? win.height - height + win.tucked : -win.tucked;
                }

                HoverHandler {
                    id: cardHover
                }

                ColumnLayout {
                    id: content

                    x: card.pad
                    y: card.pad
                    spacing: Style.space(6)

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(8)

                        // Float: the header is the drag handle.
                        DragHandler {
                            id: drag
                            target: null
                            enabled: win.floating
                            onActiveChanged: {
                                if (active) {
                                    win.pressAt = centroid.scenePosition;
                                    return;
                                }
                                root.service.setConfigs({
                                    overlayFloatScreen: win.modelData.name,
                                    overlayFloatX: Math.round(card.x),
                                    overlayFloatY: Math.round(card.y)
                                });
                                win.dragX = 0;
                                win.dragY = 0;
                            }
                            onCentroidChanged: {
                                if (!active)
                                    return;
                                win.dragX = centroid.scenePosition.x - win.pressAt.x;
                                win.dragY = centroid.scenePosition.y - win.pressAt.y;
                            }
                        }

                        Rectangle {
                            implicitWidth: Style.space(8)
                            implicitHeight: implicitWidth
                            radius: implicitWidth / 2
                            color: root.statusColor
                            Layout.alignment: Qt.AlignVCenter
                        }

                        Text {
                            text: root.statusLabel
                            color: Color.foreground
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            Layout.alignment: Qt.AlignVCenter
                        }

                        Text {
                            visible: !root.previewing
                            text: root.formatElapsed(root.service.recordingElapsed || 0)
                            color: Color.muted
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            Layout.alignment: Qt.AlignVCenter
                        }

                        Item {
                            Layout.fillWidth: true
                            Layout.minimumWidth: Style.space(12)
                        }

                        Button {
                            visible: root.canPin
                            iconText: root.glyph(root.cfg.overlayPinned ? 0xF0404 : 0xF0403)
                            tooltipText: root.cfg.overlayPinned ? "Unpin (hide after a few seconds)" : "Pin (keep visible)"
                            iconSize: Style.font.caption
                            horizontalPadding: Style.space(4)
                            verticalPadding: Style.space(2)
                            selected: root.cfg.overlayPinned
                            onClicked: root.service.setConfigs({
                                overlayPinned: !root.cfg.overlayPinned
                            })
                        }

                        Button {
                            iconText: root.glyph(0xF03CC)
                            iconRotation: win.floating ? 180 : 0
                            tooltipText: win.floating ? "Dock" : "Pop out (drag to move)"
                            iconSize: Style.font.caption
                            horizontalPadding: Style.space(4)
                            verticalPadding: Style.space(2)
                            onClicked: root.togglePopout(win, card)
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
                            implicitWidth: rowContent.implicitWidth + Style.space(12)
                            implicitHeight: rowContent.implicitHeight + Style.space(8)
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
                                x: Style.space(6)
                                width: parent.width - Style.space(12)
                                spacing: Style.space(6)

                                Text {
                                    text: row.modelData.label
                                    color: Color.foreground
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: implicitWidth
                                }

                                Repeater {
                                    model: row.bind.combo === "" ? [] : row.bind.combo.split(" + ")

                                    Rectangle {
                                        id: chip

                                        required property string modelData

                                        implicitWidth: chipText.implicitWidth + Style.space(8)
                                        implicitHeight: chipText.implicitHeight + Style.space(2)
                                        radius: Style.space(3)
                                        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.1)

                                        Text {
                                            id: chipText
                                            anchors.centerIn: parent
                                            text: chip.modelData
                                            color: row.bind.conflict ? Color.urgent : Color.foreground
                                            font.family: Style.font.family
                                            font.pixelSize: Style.font.bodySmall
                                        }
                                    }
                                }

                                Text {
                                    visible: row.bind.conflict
                                    text: root.glyph(0xF0026)
                                    color: Color.urgent
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                }

                                Text {
                                    text: row.bind.conflict ? "not bound" : (root.sourceLabels[row.bind.source] || "")
                                    color: Color.muted
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.bodySmall
                                    Layout.minimumWidth: implicitWidth
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
