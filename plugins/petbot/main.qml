// PetBot ("Bloop") - a tiny sound-reactive desktop companion for Caelestia Shell.
//
// Bloop is a little WALL-E-style bot: two binocular eyes that blink on a random
// timer, tilt and squash with the music, pupils dilating with the sound level -
// and a Star Trek LCARS amber dot row for a mouth. The dots double as its VU
// meter: five lights that ripple with whatever is playing. It floats above your
// windows by default (the pin button parks it into the desktop corner), hops on
// beats, and every now and then says something nice in a comic-book action
// balloon (with a soft spatial bloom sound), aligned with the time of day.
//
// Cheap by design: everything is plain rectangles and text driven by a 20 Hz
// snapshot of the shell's audio analyser (Audio.cava) - no blur, no shaders, no
// image assets; the balloon is a Canvas painted once per message, not per frame.
//
// Behavior:
// - pin button (top-right of the plate): toggles the always-on-top floating
//   mode (two-note sci-fi ping); the plate becomes a drag surface pinned in
// - while a message shows, the widget lifts itself above windows even when
//  parked, and settles back to its saved state when the balloon hides
// - the moment a screen recording starts (the shell's Recorder service flips
//   to running), Bloop fires a recording-themed balloon
//
// Wayland notes (Quickshell 0.3.x):
// - unanchored layer surfaces get centered by the compositor, so the surface is
//   ALWAYS anchored left+top and the position is expressed purely via margins
// - a small surface loses the pointer once the cursor outruns it, so while the
//   drag button is held the window expands to a transparent full-screen surface
//   (absolute positioning, zero accumulation) and shrinks back on release

import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Wayland
import Caelestia.Services
import qs.services

PanelWindow {
    id: root

    // ---- tunables ----------------------------------------------------------
    // keep Bloop on a specific output: set the PETBOT_SCREEN environment variable
    // to the output name (e.g. "HDMI-A-1") before the shell starts - useful on
    // multi-head setups where the first reported screen is not the one you want;
    // unset/empty = the first screen Quickshell reports (primary on most setups)
    readonly property string screenName: Quickshell.env("PETBOT_SCREEN") ?? ""
    readonly property int plateWidth: 220
    readonly property int plateHeight: 96
    readonly property int edgeMargin: 24             // distance from screen edges
    readonly property int bubbleHeight: 76           // action balloon (up to 3 lines)
    readonly property int bubbleGap: 10
    readonly property int bubbleShowSecs: 10
    // ------------------------------------------------------------------------

    // snapshot of Audio.cava.values, replaced (not mutated) at 20 Hz
    property var snapshot: []

    // ---- pet state ----------------------------------------------------------
    readonly property real level: {
        let m = 0;
        for (const v of root.snapshot)
            if (v > m)
                m = v;
        return m;
    }

    property real blinkScale: 1
    property point wander: Qt.point(0, 0)
    property string bubbleText: ""
    property bool bubbleVisible: false
    property string lastMsg: ""

    readonly property real baseTop: state.alwaysOnTop
        ? (state.floatY < 0 ? edgeMargin : state.floatY)
        : edgeMargin
    readonly property bool bubbleAbove: baseTop >= bubbleHeight + bubbleGap + 4

    // ---- mood messages, bucketed by hour of day -----------------------------
    function currentMessages() {
        const morning = [
            "Morning! Small steps still count as steps.",
            "You're up. That's win number one.",
            "Coffee counts as breakfast. Almost.",
            "Today is unwritten. Be gentle with the plot.",
            "Hydrate before you caffeinate. Trust me."
        ];
        const midday = [
            "Lunch is a real appointment. Book it.",
            "Halfway there. You're doing fine.",
            "You've handled harder days before lunch.",
            "Stretch. The email can wait 30 seconds."
        ];
        const afternoon = [
            "Afternoon slump? I still believe in you.",
            "One good task beats five anxious ones.",
            "Almost evening. Momentum over perfection.",
            "Standing up counts as an achievement now."
        ];
        const evening = [
            "Evening. The to-do list can wait.",
            "You did enough today. Truly.",
            "Dinner first, worries later.",
            "Wind down. Tomorrow-you says thanks."
        ];
        const night = [
            "Still up? Be kind to tomorrow-you.",
            "The night is long. Your energy isn't.",
            "Late hours lie about being important.",
            "Sleep is the real cheat code."
        ];
        const h = new Date().getHours();
        if (h >= 5 && h < 11)
            return morning;
        if (h < 14)
            return midday;
        if (h < 18)
            return afternoon;
        if (h < 22)
            return evening;
        return night;
    }

    readonly property var recMessages: [
        "Action! You're the star of this take.",
        "Rolling! The camera loves you.",
        "Recording. Stay legendary.",
        "Lights, camera - you've got this."
    ]

    function showMessage(override) {
        let msg = override ?? "";
        if (!msg) {
            const msgs = currentMessages();
            for (let tries = 0; tries < 4; tries++) {
                msg = msgs[Math.floor(Math.random() * msgs.length)];
                if (msg !== lastMsg)
                    break;
            }
        }
        lastMsg = msg;
        bubbleText = msg;
        bubbleVisible = true;
        bubbleHideTimer.restart();
        // spatial bloom, panned to where the pet sits
        const plateX = state.alwaysOnTop
            ? (state.floatX < 0 ? cornerPos.x : state.floatX)
            : cornerPos.x;
        const pan = plateX / Math.max(1, targetScreen.width - plateWidth);
        (pan >= 0.5 ? msgPopRight : msgPopLeft).play();
    }

    // a fresh action balloon the moment the screen recording starts
    Connections {
        target: Recorder

        function onRunningChanged(): void {
            if (Recorder.running)
                root.showMessage(root.recMessages[
                    Math.floor(Math.random() * root.recMessages.length)]);
        }
    }

    // ---- always-on-top / floating mode --------------------------------------
    // Off: pinned top-right, WlrLayer.Bottom (with the wallpaper, below windows).
    // On: WlrLayer.Top, floats at (floatX, floatY) and is draggable.
    property bool dragging: false

    readonly property point cornerPos: Qt.point(
        targetScreen.width - edgeMargin - plateWidth, edgeMargin)

    readonly property ShellScreen targetScreen: {
        if (screenName !== "") {
            const found = Quickshell.screens.find(s => s.name === screenName);
            if (found)
                return found;
        }
        return Quickshell.screens[0];
    }

    // pin state + float position, persisted across shell restarts
    PersistentProperties {
        id: state
        reloadableId: "sound-sensor"
        property bool alwaysOnTop: true   // the bot floats above windows by default
        property real floatX: -1   // unset while negative
        property real floatY: -1
    }

    screen: targetScreen
    visible: true
    color: "transparent"

    // plate-sized at rest; grown for the bubble; full-screen while dragging
    implicitWidth: dragging ? targetScreen.width : plateWidth
    implicitHeight: dragging ? targetScreen.height
        : (bubbleVisible && !dragging ? plateHeight + bubbleGap + bubbleHeight : plateHeight)

    // always top-left anchored; position lives in the margins (see header)
    anchors.left: true
    anchors.top: true
    margins.left: dragging ? 0
        : (state.alwaysOnTop
            ? (state.floatX < 0 ? root.cornerPos.x : state.floatX)
            : root.cornerPos.x)
    margins.top: dragging ? 0
        : Math.max(0, root.baseTop
            - (bubbleVisible && bubbleAbove ? bubbleHeight + bubbleGap : 0))

    WlrLayershell.namespace: "sound-sensor"
    // while a message shows, the pet lifts itself above windows even when pinned,
    // and settles back to its saved state when the balloon hides
    WlrLayershell.layer: (state.alwaysOnTop || (bubbleVisible && !dragging))
        ? WlrLayer.Top
        : WlrLayer.Bottom
    WlrLayershell.exclusionMode: ExclusionMode.Ignore  // reserves no space
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // entering floating mode with no stored position: seed it at the pinned corner
    function seedFloatPos() {
        if (state.floatX < 0) {
            state.floatX = root.cornerPos.x;
            state.floatY = root.cornerPos.y;
        }
    }

    Component.onCompleted: if (state.alwaysOnTop)
        seedFloatPos()

    // pin pings - two-note sci-fi blips with an echo tail (make-pings.py)
    SoundEffect {
        id: pingOn
        source: Qt.resolvedUrl("pin-on.wav")
        volume: 0.6
    }

    SoundEffect {
        id: pingOff
        source: Qt.resolvedUrl("pin-off.wav")
        volume: 0.6
    }

    // message blooms - soft spatial bell, pan side picked from the plate position
    SoundEffect {
        id: msgPopRight
        source: Qt.resolvedUrl("msg-pop-right.wav")
        volume: 0.5
    }

    SoundEffect {
        id: msgPopLeft
        source: Qt.resolvedUrl("msg-pop-left.wav")
        volume: 0.5
    }

    // keeps the analyser hot while this widget is its only consumer
    ServiceRef {
        service: Audio.cava
    }

    Timer {
        interval: 50                       // 20 Hz
        running: root.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: root.snapshot = (Audio.cava?.values ?? []).slice()
    }

    // pet life: random blinking and pupil wandering
    Timer {
        interval: 2500 + Math.random() * 5500
        running: root.visible
        repeat: true
        onTriggered: {
            blinkScale = 0.12;
            blinkBack.restart();
            interval = 2500 + Math.random() * 5500;
        }
    }

    Timer {
        id: blinkBack
        interval: 110
        onTriggered: root.blinkScale = 1
    }

    Timer {
        interval: 2200 + Math.random() * 2600
        running: root.visible
        repeat: true
        onTriggered: {
            wander = Qt.point((Math.random() - 0.5) * 6, (Math.random() - 0.5) * 4);
            interval = 2200 + Math.random() * 2600;
        }
    }

    // mood messages: a greeting soon after start, then every 20-45 minutes
    Timer {
        id: messageTimer
        interval: 30 * 1000
        running: root.visible
        onTriggered: {
            root.showMessage();
            interval = (20 + Math.random() * 25) * 60 * 1000;
            start();
        }
    }

    Timer {
        id: bubbleHideTimer
        interval: root.bubbleShowSecs * 1000
        onTriggered: root.bubbleVisible = false
    }

    // whole-window drag surface while floating. First child so the plate (and
    // the pin inside it) stack above it and still receive their own events.
    MouseArea {
        id: dragArea

        anchors.fill: parent
        enabled: state.alwaysOnTop
        cursorShape: state.alwaysOnTop ? Qt.SizeAllCursor : Qt.ArrowCursor

        // where inside the plate the grab happened, measured while the window
        // was still plate-sized, so (mouse - grabOffset) is the plate position
        property point grabOffset

        onPressed: mouse => {
            grabOffset = Qt.point(mouse.x, mouse.y);
            root.bubbleVisible = false;
            root.dragging = true;
        }
        onPositionChanged: mouse => {
            // skip events that arrive before the full-screen resize has landed
            if (!root.dragging || root.width < root.targetScreen.width)
                return;
            state.floatX = Math.round(Math.max(0, Math.min(
                root.targetScreen.width - root.plateWidth, mouse.x - grabOffset.x)));
            state.floatY = Math.round(Math.max(0, Math.min(
                root.targetScreen.height - root.plateHeight, mouse.y - grabOffset.y)));
        }
        onReleased: root.dragging = false
        onCanceled: root.dragging = false
    }

    // speech balloon, comic action style: white burst with jagged edges, a thick
    // dark outline and a pointy tail aimed at the pet's face; above the plate when
    // there is room, below otherwise. Painted only when a message shows - no
    // per-frame cost.
    Canvas {
        id: balloon

        visible: root.bubbleVisible && !root.dragging
        x: 0
        y: root.bubbleAbove ? 0 : root.plateHeight + root.bubbleGap
        width: root.plateWidth
        height: root.bubbleHeight

        onVisibleChanged: if (visible)
            requestPaint()
        Component.onCompleted: requestPaint()

        Connections {
            target: root
            function onBubbleAboveChanged(): void {
                balloon.requestPaint();
            }
        }

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            ctx.clearRect(0, 0, width, height);
            const tail = 10;
            const spike = 5;
            const step = 9;
            const top = root.bubbleAbove ? 1 : tail + 1;
            const bottom = root.bubbleAbove ? height - tail - 1 : height - 1;
            const cx = 95;   // the pet's face center
            ctx.lineWidth = 2.5;
            ctx.strokeStyle = "#1c1b1f";
            ctx.fillStyle = "#f7f4f2";
            ctx.lineJoin = "miter";

            // jagged burst polygon around the balloon body: walk each edge,
            // pushing every other point outward
            const pts = [];
            const edge = (x0, y0, x1, y1, nx, ny) => {
                const len = Math.hypot(x1 - x0, y1 - y0);
                const n = Math.max(2, Math.round(len / step));
                for (let i = 0; i <= n; i++) {
                    const t = i / n;
                    const px = x0 + (x1 - x0) * t;
                    const py = y0 + (y1 - y0) * t;
                    if (i === 0 || i === n || i % 2 === 0) {
                        pts.push(px + nx * spike * ((i > 0 && i < n) ? 1 : 0),
                                 py + ny * spike * ((i > 0 && i < n) ? 1 : 0));
                    } else {
                        pts.push(px, py);
                    }
                }
            };
            edge(1, top, width - 1, top, 0, -1);
            edge(width - 1, top, width - 1, bottom, 1, 0);
            edge(width - 1, bottom, 1, bottom, 0, 1);
            edge(1, bottom, 1, top, -1, 0);
            ctx.beginPath();
            ctx.moveTo(pts[0], pts[1]);
            for (let i = 2; i < pts.length; i += 2)
                ctx.lineTo(pts[i], pts[i + 1]);
            ctx.closePath();
            ctx.fill();
            ctx.stroke();

            // tail: fill over the border line, then stroke its two sides only
            const base = root.bubbleAbove ? bottom : top;
            const apexY = root.bubbleAbove ? height - 1 : 1;
            ctx.beginPath();
            ctx.moveTo(cx - 10, base);
            ctx.lineTo(cx + 10, base);
            ctx.lineTo(cx + 3, apexY);
            ctx.closePath();
            ctx.fill();
            ctx.beginPath();
            ctx.moveTo(cx - 10, base);
            ctx.lineTo(cx + 3, apexY);
            ctx.lineTo(cx + 10, base);
            ctx.stroke();
        }

        Text {
            x: 14
            y: root.bubbleAbove ? 8 : 20
            width: parent.width - 28
            height: 54
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.pixelSize: 14
            font.bold: true
            font.capitalization: Font.AllUppercase
            lineHeight: 1.05
            color: "#1c1b1f"
            text: root.bubbleText
        }
    }

    Item {
        id: plate

        // window-sized at rest (window == plate); drawn at its own position
        // inside the enlarged (balloon/drag) surfaces
        x: root.dragging ? state.floatX
            : (root.bubbleVisible && root.bubbleAbove ? root.bubbleHeight + root.bubbleGap : 0)
        y: root.dragging ? state.floatY
            : (root.bubbleVisible && root.bubbleAbove ? root.bubbleHeight + root.bubbleGap : 0)
        width: root.plateWidth
        height: root.plateHeight

        opacity: state.alwaysOnTop ? 0.85 : 0.55

        Behavior on opacity {
            NumberAnimation {
                duration: 160
                easing.type: Easing.OutQuad
            }
        }

        // the body: a compact WALL-E x LCARS fusion (rounded head with the
        // binocular eyes, a torso carrying the amber dot meter, stubby arms
        // and feet) instead of a rectangular plate. Plain rounded rectangles;
        // everything animates off the 20 Hz level snapshot: the head tilts
        // with the sound, the eyes squash and dilate, the dots ripple, the
        // whole body hops on beats.
        Item {
            id: body

            property real bodyCX: (root.plateWidth - 30) / 2   // keep clear of the pin
            x: bodyCX - 70
            y: 2 - root.level * 5                              // hop on beats
            width: 140
            height: 92

            readonly property color shell: Colours.palette.m3surfaceContainer ?? "#000000"
            readonly property color edge: state.alwaysOnTop
                ? (Colours.palette.m3primary ?? "#b7c8ff")
                : Qt.rgba(1, 1, 1, 0.12)
            readonly property color lcars: "#ffb100"

            Rectangle {
                // head - tilts with the sound
                x: 32
                y: 0
                width: 76
                height: 46
                radius: 23
                color: body.shell
                border.width: 1
                border.color: body.edge
                rotation: -2 + root.level * 3

                Behavior on rotation {
                    NumberAnimation {
                        duration: 120
                        easing.type: Easing.OutQuad
                    }
                }

                Rectangle {
                    // left eye
                    x: 13
                    y: 9
                    width: 20
                    height: (24 - root.level * 1.5) * root.blinkScale
                    radius: 10
                    color: "#e8e6eb"
                    border.width: 1
                    border.color: "#b9b7bc"

                    Behavior on height {
                        NumberAnimation {
                            duration: 90
                            easing.type: Easing.OutQuad
                        }
                    }

                    Rectangle {
                        // pupil
                        x: parent.width / 2 - width / 2 + root.wander.x
                        y: parent.height / 2 - height / 2 + root.wander.y
                        width: 7 + root.level * 4
                        height: width
                        radius: width / 2
                        color: "#1c2024"

                        Behavior on width {
                            NumberAnimation {
                                duration: 60
                                easing.type: Easing.OutQuad
                            }
                        }
                        Behavior on x {
                            NumberAnimation {
                                duration: 300
                                easing.type: Easing.OutQuad
                            }
                        }
                        Behavior on y {
                            NumberAnimation {
                                duration: 300
                                easing.type: Easing.OutQuad
                            }
                        }
                    }
                }

                Rectangle {
                    // right eye
                    x: 43
                    y: 9
                    width: 20
                    height: (24 - root.level * 1.5) * root.blinkScale
                    radius: 10
                    color: "#e8e6eb"
                    border.width: 1
                    border.color: "#b9b7bc"

                    Behavior on height {
                        NumberAnimation {
                            duration: 90
                            easing.type: Easing.OutQuad
                        }
                    }

                    Rectangle {
                        // pupil
                        x: parent.width / 2 - width / 2 + root.wander.x
                        y: parent.height / 2 - height / 2 + root.wander.y
                        width: 7 + root.level * 4
                        height: width
                        radius: width / 2
                        color: "#1c2024"

                        Behavior on width {
                            NumberAnimation {
                                duration: 60
                                easing.type: Easing.OutQuad
                            }
                        }
                        Behavior on x {
                            NumberAnimation {
                                duration: 300
                                easing.type: Easing.OutQuad
                            }
                        }
                        Behavior on y {
                            NumberAnimation {
                                duration: 300
                                easing.type: Easing.OutQuad
                            }
                        }
                    }
                }
            }

            Rectangle {
                // torso
                x: 26
                y: 48
                width: 88
                height: 40
                radius: 16
                color: body.shell
                border.width: 1
                border.color: body.edge
            }

            Rectangle {
                // left arm
                x: 12
                y: 54
                width: 12
                height: 26
                radius: 6
                color: body.shell
                border.width: 1
                border.color: body.edge
            }

            Rectangle {
                // right arm
                x: 116
                y: 54
                width: 12
                height: 26
                radius: 6
                color: body.shell
                border.width: 1
                border.color: body.edge
            }

            Rectangle {
                // left foot
                x: 46
                y: 88
                width: 18
                height: 4
                radius: 2
                color: body.shell
                border.width: 1
                border.color: body.edge
            }

            Rectangle {
                // right foot
                x: 76
                y: 88
                width: 18
                height: 4
                radius: 2
                color: body.shell
                border.width: 1
                border.color: body.edge
            }

            Row {
                // LCARS dot meter: the bot's mouth - five amber dots that
                // light up with the sound level, staggered like a VU meter
                x: 36
                y: 58
                spacing: 7

                Repeater {
                    model: 5

                    Rectangle {
                        required property int index

                        width: 8
                        height: 8
                        radius: 4
                        color: body.lcars
                        opacity: root.level * 6 > index + 0.4 ? 0.95 : 0.16

                        Behavior on opacity {
                            NumberAnimation {
                                duration: 90
                                easing.type: Easing.OutQuad
                            }
                        }
                    }
                }
            }
        }

        // the pin: always visible, top-right of the window. Filled = floating & on top.
        Item {
            id: pinButton
            z: 1  // above the drag MouseArea

            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: 6
            anchors.rightMargin: 6
            width: 26
            height: 26

            readonly property bool hovered: pinHover.containsMouse

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: pinButton.hovered
                    ? (Colours.palette.m3surfaceContainerHigh ?? "#ffffff")
                    : "transparent"
                opacity: pinButton.hovered ? 0.8 : 0
            }

            // pin glyph: round head + needle, diagonal like a pushpin
            Rectangle {
                anchors.centerIn: parent
                width: 9
                height: 9
                radius: width / 2
                color: state.alwaysOnTop
                    ? (Colours.palette.m3primary ?? "#b7c8ff")
                    : (Colours.palette.m3onSurfaceVariant ?? "#aaaaaa")
            }
            Rectangle {
                x: pinButton.width / 2 - 1
                y: pinButton.height / 2 + 3
                width: 2
                height: 8
                radius: 1
                rotation: 45
                color: state.alwaysOnTop
                    ? (Colours.palette.m3primary ?? "#b7c8ff")
                    : (Colours.palette.m3onSurfaceVariant ?? "#aaaaaa")
            }

            MouseArea {
                id: pinHover
                anchors.fill: parent
                hoverEnabled: true
                onClicked: {
                    state.alwaysOnTop = !state.alwaysOnTop;
                    if (state.alwaysOnTop)
                        seedFloatPos();
                    (state.alwaysOnTop ? pingOn : pingOff).play();
                }
            }
        }
    }
}
