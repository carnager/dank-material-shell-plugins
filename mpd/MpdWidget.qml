import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginComponent {
    id: root

    property string host: String(pluginData.host || "localhost").trim()
    property string port: String(pluginData.port || "6600").trim()
    property string password: String(pluginData.password || "")
    property string formatTemplate: String(pluginData.format || "{artist} - {title} ({album})")
    property string alignmentSetting: {
        const value = String(pluginData.alignment || "left").trim().toLowerCase();
        return value === "right" ? "right" : "left";
    }
    property int maxWidthSetting: Math.max(0, parseInt(String(pluginData.maxWidth || "320"), 10) || 0)
    property string playbackState: "stop"
    property string formattedText: ""
    property string errorText: ""
    property string artSource: ""
    property bool connected: false
    property bool restartAfterExit: false
    property string activeTab: "album"
    property var albumInfo: ({
            "title": "",
            "albumartist": "",
            "year": "",
            "track_count": 0,
            "tracks": [],
            "files": [],
            "current_index": -1
        })
    property var queueInfo: ({
            "current_pos": -1,
            "tracks": []
        })
    property var trackData: ({
            "tracknumber": "",
            "artist": "",
            "title": "",
            "album": "",
            "albumartist": "",
            "date": "",
            "year": "",
            "filename": ""
        })
    readonly property int coverSize: Math.max(20, root.barThickness - 12)

    readonly property string watcherScriptPath: {
        const url = Qt.resolvedUrl("mpd_watch.py").toString();
        return url.startsWith("file://") ? url.substring(7) : url;
    }
    readonly property string albumSummaryText: {
        const parts = [];
        if (albumInfo.year && albumInfo.year.length > 0)
            parts.push(albumInfo.year);
        if ((albumInfo.track_count || 0) > 0)
            parts.push(albumInfo.track_count + " tracks");
        return parts.join(" • ");
    }
    readonly property string statusText: {
        if (!connected)
            return errorText.length > 0 ? "Disconnected" : "Offline";
        if (playbackState === "play")
            return "Playing";
        if (playbackState === "pause")
            return "Paused";
        return "Stopped";
    }
    readonly property string displayText: {
        if (!connected)
            return errorText.length > 0 ? "MPD offline" : "MPD unavailable";
        if (formattedText.length > 0)
            return formattedText;
        if (playbackState === "stop")
            return "No track playing";
        return "Unknown track";
    }

    function defaultTrackData() {
        return {
            "tracknumber": "",
            "artist": "",
            "title": "",
            "album": "",
            "albumartist": "",
            "date": "",
            "year": "",
            "filename": ""
        };
    }

    function extractYear(value) {
        const match = String(value || "").match(/(\d{4})/);
        return match ? match[1] : "";
    }

    function normalizedTrack(data) {
        const track = data || {};
        return {
            "tracknumber": String(track.tracknumber || ""),
            "artist": String(track.artist || ""),
            "title": String(track.title || ""),
            "album": String(track.album || ""),
            "albumartist": String(track.albumartist || ""),
            "date": String(track.date || ""),
            "year": String(track.year || extractYear(track.date || "")),
            "filename": String(track.filename || "")
        };
    }

    function cleanupFormattedText(value) {
        let text = String(value || "");
        text = text.replace(/\(\s*\)/g, "");
        text = text.replace(/\[\s*\]/g, "");
        text = text.replace(/\{\s*\}/g, "");
        text = text.replace(/\s{2,}/g, " ");
        text = text.replace(/\s+([)\]])/g, "$1");
        text = text.replace(/([([])\s+/g, "$1");
        text = text.replace(/^\s*[-,:|/]+\s*/, "");
        text = text.replace(/\s*[-,:|/]+\s*$/, "");
        return text.trim();
    }

    function formatTrack(template, fields) {
        const pattern = /\{([a-z]+)\}/g;
        const rendered = String(template || "").replace(pattern, (_, key) => {
            return fields[key] !== undefined ? String(fields[key] || "") : "";
        });
        return cleanupFormattedText(rendered);
    }

    function updateFormattedText() {
        formattedText = formatTrack(formatTemplate, trackData);
    }

    function buildCommand() {
        const args = ["python3", watcherScriptPath, "--host", host.length > 0 ? host : "localhost", "--port", port.length > 0 ? port : "6600"];
        if (password.length > 0)
            args.push("--password", password);
        return args;
    }

    function runControl(action, arg) {
        const args = ["python3", watcherScriptPath, "--host", host.length > 0 ? host : "localhost", "--port", port.length > 0 ? port : "6600", "--action", action];
        if (arg !== undefined && arg !== null && String(arg).length > 0)
            args.push("--arg", String(arg));
        if (password.length > 0)
            args.push("--password", password);
        Quickshell.execDetached(args);
    }

    function runClerkAction(mode) {
        if (mode === "album")
            Quickshell.execDetached(["clerk-api-rofi", "-A"]);
        else if (mode === "tracks")
            Quickshell.execDetached(["clerk-api-rofi", "-T"]);
    }

    function startWatcher() {
        restartTimer.stop();
        restartAfterExit = false;
        watcher.command = buildCommand();
        watcher.running = true;
    }

    function restartWatcher() {
        restartTimer.stop();
        if (watcher.running) {
            restartAfterExit = true;
            watcher.running = false;
            return;
        }
        startWatcher();
    }

    function handleWatcherLine(line) {
        const trimmed = String(line || "").trim();
        if (trimmed.length === 0)
            return;

        try {
            const payload = JSON.parse(trimmed);
            connected = !!payload.connected;
            playbackState = String(payload.state || "stop");
            errorText = String(payload.error || "");
            trackData = normalizedTrack(payload.track);
            albumInfo = payload.album_info || ({
                    "title": "",
                    "albumartist": "",
                    "year": "",
                    "track_count": 0,
                    "tracks": [],
                    "files": [],
                    "current_index": -1
                });
            queueInfo = payload.queue_info || ({
                    "current_pos": -1,
                    "tracks": []
                });
            artSource = payload.art_path ? "file://" + String(payload.art_path) : "";
            updateFormattedText();
        } catch (e) {
            connected = false;
            errorText = "Failed to parse MPD watcher output.";
        }
    }

    pluginId: "mpd"

    ccWidgetIcon: connected ? (playbackState === "play" ? "music_note" : playbackState === "pause" ? "pause_circle" : "stop_circle") : "music_off"
    ccWidgetPrimaryText: "MPD"
    ccWidgetSecondaryText: connected ? displayText : (errorText.length > 0 ? errorText : displayText)
    ccWidgetIsActive: connected && playbackState === "play"

    Component.onCompleted: {
        updateFormattedText();
        startWatcher();
    }

    onPluginDataChanged: {
        updateFormattedText();
        if (watcher.running || connected || errorText.length > 0)
            root.restartWatcher();
    }

    Timer {
        id: restartTimer

        interval: 2000
        repeat: false
        onTriggered: root.startWatcher()
    }

    Process {
        id: watcher

        running: false

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => root.handleWatcherLine(data)
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const text = String(data || "").trim();
                if (text.length > 0)
                    root.errorText = text;
            }
        }

        onExited: exitCode => {
            root.connected = false;
            if (!root.connected)
                root.artSource = "";
            if (root.restartAfterExit) {
                root.restartAfterExit = false;
                root.startWatcher();
                return;
            }

            if (exitCode !== 0 && root.errorText.length === 0)
                root.errorText = "MPD watcher exited unexpectedly.";

            restartTimer.restart();
        }
    }

    horizontalBarPill: Component {
        Item {
            id: pillRoot

            readonly property int statusIconSize: Theme.barIconSize(root.barThickness, -2)
            readonly property int controlsWidth: 20 + 2 + 24 + 2 + 20
            readonly property int fixedWidth: root.coverSize + statusIconSize + controlsWidth + Theme.spacingXS * 3
            readonly property int measuredTextWidth: Math.ceil(textMeasure.implicitWidth) + 2
            readonly property int availableTextWidth: root.maxWidthSetting > 0 ? Math.max(72, root.maxWidthSetting - fixedWidth) : measuredTextWidth
            readonly property int actualTextWidth: Math.min(measuredTextWidth, availableTextWidth)
            readonly property int naturalWidth: fixedWidth + measuredTextWidth

            implicitWidth: root.maxWidthSetting > 0 ? Math.min(root.maxWidthSetting, naturalWidth) : naturalWidth
            implicitHeight: contentRow.implicitHeight

            Row {
                id: contentRow

                spacing: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: root.alignmentSetting === "left" ? parent.left : undefined
                anchors.right: root.alignmentSetting === "right" ? parent.right : undefined
                anchors.horizontalCenter: root.alignmentSetting === "left" || root.alignmentSetting === "right" ? undefined : parent.horizontalCenter

                Rectangle {
                    visible: root.artSource.length > 0
                    width: root.coverSize
                    height: root.coverSize
                    radius: 4
                    color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.1)
                    clip: true
                    anchors.verticalCenter: parent.verticalCenter

                    Image {
                        anchors.fill: parent
                        source: root.artSource
                        asynchronous: true
                        fillMode: Image.PreserveAspectCrop
                        smooth: true
                        mipmap: true
                        cache: true
                        visible: root.artSource.length > 0 && status === Image.Ready
                    }
                }

                DankIcon {
                    name: root.connected ? (root.playbackState === "play" ? "music_note" : root.playbackState === "pause" ? "pause_circle" : "stop_circle") : "music_off"
                    size: Theme.barIconSize(root.barThickness, -2)
                    color: root.connected && root.playbackState === "play" ? Theme.primary : Theme.widgetIconColor
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    width: pillRoot.actualTextWidth
                    text: root.displayText
                    font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig ? root.barConfig.fontScale : undefined)
                    color: Theme.widgetTextColor
                    elide: root.maxWidthSetting > 0 ? Text.ElideRight : Text.ElideNone
                    wrapMode: Text.NoWrap
                    anchors.verticalCenter: parent.verticalCenter
                }

                Row {
                    spacing: 2
                    anchors.verticalCenter: parent.verticalCenter

                    Rectangle {
                        width: 20
                        height: 20
                        radius: 10
                        color: previousArea.containsMouse ? Theme.widgetBaseHoverColor : "transparent"
                        opacity: root.connected ? 1 : 0.35
                        anchors.verticalCenter: parent.verticalCenter

                        DankIcon {
                            anchors.centerIn: parent
                            name: "skip_previous"
                            size: 12
                            color: Theme.widgetTextColor
                        }

                        MouseArea {
                            id: previousArea
                            anchors.fill: parent
                            enabled: root.connected
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.runControl("previous")
                        }
                    }

                    Rectangle {
                        width: 24
                        height: 24
                        radius: 12
                        color: root.playbackState === "play" ? Theme.primary : Theme.primaryHover
                        opacity: root.connected ? 1 : 0.35
                        anchors.verticalCenter: parent.verticalCenter

                        DankIcon {
                            anchors.centerIn: parent
                            name: root.playbackState === "play" ? "pause" : "play_arrow"
                            size: 14
                            color: root.playbackState === "play" ? Theme.background : Theme.primary
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: root.connected
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.runControl("toggle")
                        }
                    }

                    Rectangle {
                        width: 20
                        height: 20
                        radius: 10
                        color: nextArea.containsMouse ? Theme.widgetBaseHoverColor : "transparent"
                        opacity: root.connected ? 1 : 0.35
                        anchors.verticalCenter: parent.verticalCenter

                        DankIcon {
                            anchors.centerIn: parent
                            name: "skip_next"
                            size: 12
                            color: Theme.widgetTextColor
                        }

                        MouseArea {
                            id: nextArea
                            anchors.fill: parent
                            enabled: root.connected
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.runControl("next")
                        }
                    }
                }
            }

            StyledText {
                id: textMeasure

                visible: false
                text: root.displayText
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig ? root.barConfig.fontScale : undefined)
                wrapMode: Text.NoWrap
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            DankIcon {
                name: root.connected ? (root.playbackState === "play" ? "music_note" : root.playbackState === "pause" ? "pause_circle" : "stop_circle") : "music_off"
                size: Theme.barIconSize(root.barThickness)
                color: root.connected && root.playbackState === "play" ? Theme.primary : Theme.widgetIconColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.connected ? "MPD" : "Off"
                font.pixelSize: Math.max(10, Theme.barTextSize(root.barThickness, root.barConfig ? root.barConfig.fontScale : undefined) - 2)
                color: Theme.widgetTextColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutContent: Component {
        Item {
            id: popoutRoot

            implicitWidth: 420
            implicitHeight: 460

            StyledRect {
                anchors.fill: parent
                radius: Theme.cornerRadius
                color: Theme.surfaceContainer
                border.color: Theme.outline
                border.width: 1
            }

            Column {
                anchors.fill: parent
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingS

                Column {
                    id: headerColumn

                    width: parent.width
                    spacing: Theme.spacingS

                    Row {
                        spacing: Theme.spacingS

                        Rectangle {
                            width: 56
                            height: 56
                            radius: 8
                            color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.1)
                            clip: true
                            anchors.verticalCenter: parent.verticalCenter

                            Image {
                                anchors.fill: parent
                                source: root.artSource
                                asynchronous: true
                                fillMode: Image.PreserveAspectCrop
                                smooth: true
                                mipmap: true
                                cache: true
                                visible: root.artSource.length > 0 && status === Image.Ready
                            }

                            DankIcon {
                                anchors.centerIn: parent
                                name: root.connected ? "album" : "music_off"
                                size: 28
                                color: Theme.surfaceVariantText
                                visible: root.artSource.length === 0
                            }
                        }

                        Column {
                            spacing: 2

                            StyledText {
                                text: "Artist: " + (root.trackData.artist || root.trackData.albumartist || "")
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.DemiBold
                                color: Theme.surfaceText
                                wrapMode: Text.WordWrap
                                width: headerColumn.width - 56 - Theme.spacingS
                            }

                            StyledText {
                                text: "Title: " + (root.trackData.title || root.trackData.filename || "")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                                width: headerColumn.width - 56 - Theme.spacingS
                            }
                        }
                    }

                    StyledRect {
                        width: parent.width
                        height: 1
                        color: Theme.surfaceVariant
                    }
                }

                Flickable {
                    width: parent.width
                    height: popoutRoot.height - Theme.spacingM * 2 - headerColumn.implicitHeight - tabBarColumn.implicitHeight - footerColumn.implicitHeight - Theme.spacingS * 3
                    contentWidth: width
                    contentHeight: contentColumn.implicitHeight
                    clip: true

                    Column {
                        id: contentColumn

                        width: parent.width
                        spacing: Theme.spacingS

                        Column {
                            visible: root.activeTab === "album"
                            width: parent.width
                            spacing: Theme.spacingS

                            StyledText {
                                visible: root.albumInfo.title.length > 0
                                width: parent.width
                                text: root.albumInfo.title
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.DemiBold
                                color: Theme.surfaceText
                                wrapMode: Text.WordWrap
                            }

                            StyledText {
                                visible: root.albumInfo.albumartist.length > 0
                                width: parent.width
                                text: root.albumInfo.albumartist
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                            }

                            StyledText {
                                visible: root.albumSummaryText.length > 0
                                width: parent.width
                                text: root.albumSummaryText
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                            }

                            Row {
                                spacing: Theme.spacingS

                                Rectangle {
                                    visible: root.playbackState !== "stop"
                                    width: 74
                                    height: 28
                                    radius: 8
                                    color: Theme.surfaceContainerHigh

                                    StyledText {
                                        anchors.centerIn: parent
                                        text: "Add"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled: root.connected && (root.albumInfo.files || []).length > 0
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.runControl("add_album")
                                    }
                                }

                                Rectangle {
                                    visible: root.playbackState !== "stop"
                                    width: 74
                                    height: 28
                                    radius: 8
                                    color: Theme.surfaceContainerHigh

                                    StyledText {
                                        anchors.centerIn: parent
                                        text: "Insert"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled: root.connected && (root.albumInfo.files || []).length > 0
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.runControl("insert_album")
                                    }
                                }

                                Rectangle {
                                    visible: root.playbackState !== "stop"
                                    width: 84
                                    height: 28
                                    radius: 8
                                    color: Theme.surfaceContainerHigh

                                    StyledText {
                                        anchors.centerIn: parent
                                        text: "Replace"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled: root.connected && (root.albumInfo.files || []).length > 0
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.runControl("replace_album")
                                    }
                                }

                                Rectangle {
                                    visible: root.playbackState === "stop"
                                    width: 152
                                    height: 28
                                    radius: 8
                                    color: Theme.surfaceContainerHigh

                                    StyledText {
                                        anchors.centerIn: parent
                                        text: "Play Random Album"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled: root.connected
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.runClerkAction("album")
                                    }
                                }

                                Rectangle {
                                    visible: root.playbackState === "stop"
                                    width: 156
                                    height: 28
                                    radius: 8
                                    color: Theme.surfaceContainerHigh

                                    StyledText {
                                        anchors.centerIn: parent
                                        text: "Play Random Tracks"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled: root.connected
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.runClerkAction("tracks")
                                    }
                                }
                            }

                            Repeater {
                                model: root.albumInfo.tracks || []

                                Row {
                                    required property var modelData

                                    width: contentColumn.width
                                    spacing: Theme.spacingS

                                    StyledText {
                                        width: 32
                                        text: modelData.tracknumber && modelData.tracknumber.length > 0 ? modelData.tracknumber : "•"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }

                                    StyledText {
                                        width: parent.width - 32 - Theme.spacingS
                                        text: modelData.title || ""
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                        wrapMode: Text.WordWrap
                                    }
                                }
                            }
                        }

                        Column {
                            visible: root.activeTab === "queue"
                            width: parent.width
                            spacing: Theme.spacingXS

                            Repeater {
                                model: root.queueInfo.tracks || []

                                Rectangle {
                                    required property var modelData

                                    width: contentColumn.width
                                    height: queueRow.implicitHeight + Theme.spacingXS * 2
                                    radius: 8
                                    color: modelData.current ? Theme.surfaceContainerHigh : "transparent"

                                    Row {
                                        id: queueRow

                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingS
                                        anchors.rightMargin: Theme.spacingS
                                        spacing: Theme.spacingS

                                        StyledText {
                                            width: 28
                                            text: String((modelData.pos ?? 0) + 1)
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                        }

                                        StyledText {
                                            width: parent.width - 28 - Theme.spacingS
                                            text: (modelData.artist && modelData.artist.length > 0 ? modelData.artist + " - " : "") + (modelData.title || "")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: modelData.current ? Theme.primary : Theme.surfaceText
                                            wrapMode: Text.WordWrap
                                        }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled: root.connected && modelData.pos >= 0
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.runControl("play_pos", modelData.pos)
                                    }
                                }
                            }
                        }
                    }
                }

                Column {
                    id: tabBarColumn

                    width: parent.width
                    spacing: Theme.spacingS

                    StyledRect {
                        width: parent.width
                        height: 1
                        color: Theme.surfaceVariant
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS

                        Rectangle {
                            width: (parent.width - Theme.spacingS) / 2
                            height: 32
                            radius: 8
                            color: root.activeTab === "album" ? Theme.primary : Theme.surfaceContainerHigh

                            StyledText {
                                anchors.centerIn: parent
                                text: "Album Info"
                                font.pixelSize: Theme.fontSizeSmall
                                color: root.activeTab === "album" ? Theme.background : Theme.surfaceText
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.activeTab = "album"
                            }
                        }

                        Rectangle {
                            width: (parent.width - Theme.spacingS) / 2
                            height: 32
                            radius: 8
                            color: root.activeTab === "queue" ? Theme.primary : Theme.surfaceContainerHigh

                            StyledText {
                                anchors.centerIn: parent
                                text: "Current Queue"
                                font.pixelSize: Theme.fontSizeSmall
                                color: root.activeTab === "queue" ? Theme.background : Theme.surfaceText
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.activeTab = "queue"
                            }
                        }
                    }
                }

                Column {
                    id: footerColumn

                    width: parent.width
                    spacing: Theme.spacingS

                    StyledText {
                        width: parent.width
                        text: "Connection: " + root.host + ":" + root.port
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        visible: root.errorText.length > 0
                        width: parent.width
                        text: root.errorText
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.error
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }
}
