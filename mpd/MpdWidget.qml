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
    property string clerkApiBaseUrl: String(pluginData.clerkApiBaseUrl || "").trim()
    property string formatTemplate: String(pluginData.format || "{artist} - {title} ({album})")
    property bool showBarCover: {
        const value = String(pluginData.cover || "false").trim().toLowerCase();
        return value === "true" || value === "1" || value === "yes" || value === "on";
    }
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
    property bool showRandomMenu: false
    property string selectedAlbumKey: ""
    property string selectedArtistName: ""
    readonly property bool inAlbumView: selectedAlbumKey.length > 0
    readonly property bool inArtistView: !inAlbumView && selectedArtistName.length > 0
    readonly property string popupArtSource: {
        if (inAlbumView)
            return selectedAlbumInfo.art_path && String(selectedAlbumInfo.art_path).length > 0 ? "file://" + String(selectedAlbumInfo.art_path) : "";
        return artSource;
    }
    property var albumInfo: ({
            "title": "",
            "albumartist": "",
            "year": "",
            "albumrating": "",
            "clerk_id": "",
            "art_path": "",
            "track_count": 0,
            "tracks": [],
            "files": [],
            "current_index": -1
        })
    property var queueInfo: ({
            "current_pos": -1,
            "tracks": []
        })
    property var artistAlbums: ({})
    property var albumDetails: ({})
    property var trackData: ({
            "tracknumber": "",
            "artist": "",
            "title": "",
            "album": "",
            "albumartist": "",
            "date": "",
            "year": "",
            "filename": "",
            "rating": "",
            "albumrating": ""
        })
    readonly property int coverSize: Math.max(20, root.barThickness - 12)

    readonly property string watcherScriptPath: {
        const url = Qt.resolvedUrl("mpd_watch.py").toString();
        return url.startsWith("file://") ? url.substring(7) : url;
    }
    readonly property string currentAlbumKey: {
        const album = String(trackData.album || "");
        const albumartist = String(trackData.albumartist || trackData.artist || "");
        return album.length > 0 ? albumartist + "\x1f" + album : "";
    }
    readonly property string currentArtistName: {
        if (inAlbumView)
            return String(selectedAlbumInfo.albumartist || "");
        if (inArtistView)
            return String(selectedArtistName || "");
        return String(trackData.artist || trackData.albumartist || "");
    }
    readonly property var selectedArtistAlbums: {
        if (!selectedArtistName || !artistAlbums[selectedArtistName])
            return [];
        return artistAlbums[selectedArtistName];
    }
    readonly property string albumSummaryText: {
        const parts = [];
        if (albumInfo.year && albumInfo.year.length > 0)
            parts.push(albumInfo.year);
        if ((albumInfo.track_count || 0) > 0)
            parts.push(albumInfo.track_count + " tracks");
        return parts.join(" • ");
    }
    readonly property var selectedAlbumInfo: {
        if (!selectedAlbumKey || !albumDetails[selectedAlbumKey]) {
            return {
                "title": "",
                "albumartist": "",
                "year": "",
                "albumrating": "",
                "clerk_id": "",
                "art_path": "",
                "track_count": 0,
                "tracks": [],
                "files": [],
                "current_index": -1
            };
        }
        return albumDetails[selectedAlbumKey];
    }
    readonly property string selectedAlbumSummaryText: {
        const parts = [];
        if (selectedAlbumInfo.year && selectedAlbumInfo.year.length > 0)
            parts.push(selectedAlbumInfo.year);
        if ((selectedAlbumInfo.track_count || 0) > 0)
            parts.push(selectedAlbumInfo.track_count + " tracks");
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
            "filename": "",
            "rating": "",
            "albumrating": ""
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
            "filename": String(track.filename || ""),
            "rating": String(track.rating || ""),
            "albumrating": String(track.albumrating || "")
        };
    }

    function normalizedRating(value) {
        const number = parseFloat(String(value || "").trim());
        if (!isFinite(number) || number <= 0)
            return 0;
        return Math.max(0, Math.min(5, number));
    }

    function displayedStarCount(value) {
        return Math.round(normalizedRating(value));
    }

    function ratingPayloadForStar(value, starIndex) {
        const selectedStars = Math.max(1, starIndex + 1);
        return displayedStarCount(value) === selectedStars ? "Delete" : String(selectedStars * 2);
    }

    function requestWatcherRefresh() {
        ratingRefreshTimer.restart();
    }

    function setCurrentTrackRating(starIndex) {
        runControl("set_track_rating", ratingPayloadForStar(trackData.rating, starIndex));
        requestWatcherRefresh();
    }

    function setSelectedAlbumRating(starIndex) {
        if (!selectedAlbumInfo.clerk_id || selectedAlbumInfo.clerk_id.length === 0)
            return;
        runControl("set_album_rating", selectedAlbumInfo.clerk_id + ":" + ratingPayloadForStar(selectedAlbumInfo.albumrating, starIndex));
        requestWatcherRefresh();
    }

    function openArtistView(artistName) {
        const artist = String(artistName || "").trim();
        if (artist.length === 0)
            return;
        selectedAlbumKey = "";
        selectedArtistName = artist;
    }

    function openAlbumView(albumKey, keepArtistView) {
        selectedAlbumKey = String(albumKey || "");
        if (!keepArtistView)
            selectedArtistName = "";
    }

    function goBack() {
        if (inAlbumView) {
            selectedAlbumKey = "";
            return;
        }
        if (inArtistView)
            selectedArtistName = "";
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
        if (clerkApiBaseUrl.length > 0)
            args.push("--clerk-api-base-url", clerkApiBaseUrl);
        return args;
    }

    function runControl(action, arg) {
        const args = ["python3", watcherScriptPath, "--host", host.length > 0 ? host : "localhost", "--port", port.length > 0 ? port : "6600", "--action", action];
        if (arg !== undefined && arg !== null && String(arg).length > 0)
            args.push("--arg", String(arg));
        if (password.length > 0)
            args.push("--password", password);
        if (clerkApiBaseUrl.length > 0)
            args.push("--clerk-api-base-url", clerkApiBaseUrl);
        Quickshell.execDetached(args);
    }

    function runClerkAction(mode) {
        if (mode === "album")
            runControl("random_album");
        else if (mode === "tracks")
            runControl("random_tracks");
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
                    "albumrating": "",
                    "clerk_id": "",
                    "art_path": "",
                    "track_count": 0,
                    "tracks": [],
                    "files": [],
                    "current_index": -1
                });
            queueInfo = payload.queue_info || ({
                    "current_pos": -1,
                    "tracks": []
                });
            artistAlbums = payload.artist_albums || ({
                });
            albumDetails = payload.album_details || ({
                });
            if (selectedAlbumKey.length > 0 && !albumDetails[selectedAlbumKey])
                selectedAlbumKey = "";
            if (selectedArtistName.length > 0 && !artistAlbums[selectedArtistName] && !inAlbumView)
                selectedArtistName = "";
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

    Timer {
        id: ratingRefreshTimer

        interval: 350
        repeat: false
        onTriggered: root.restartWatcher()
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

            readonly property int controlsWidth: 20 + 2 + 24 + 2 + 20
            readonly property int coverWidth: root.showBarCover && root.artSource.length > 0 ? root.coverSize + Theme.spacingXS : 0
            readonly property int fixedWidth: coverWidth + controlsWidth + Theme.spacingXS
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
                    visible: root.showBarCover && root.artSource.length > 0
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
            property var parentPopout: null

            implicitWidth: 420
            implicitHeight: 460

            Connections {
                target: popoutRoot.parentPopout
                function onShouldBeVisibleChanged() {
                    if (!popoutRoot.parentPopout)
                        return;
                    if (popoutRoot.parentPopout.shouldBeVisible)
                        return;
                    root.showRandomMenu = false;
                }
            }

            StyledRect {
                anchors.fill: parent
                radius: Theme.cornerRadius
                color: Theme.surfaceContainer
                border.color: Theme.outline
                border.width: 1
            }

            Item {
                id: contentArea

                anchors.fill: parent
                anchors.margins: Theme.spacingM

                Column {
                    id: headerColumn

                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
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
                                id: popupCoverImage

                                anchors.fill: parent
                                source: root.popupArtSource
                                asynchronous: true
                                fillMode: Image.PreserveAspectCrop
                                smooth: true
                                mipmap: true
                                cache: true
                                visible: root.popupArtSource.length > 0 && status === Image.Ready
                            }

                            DankIcon {
                                anchors.centerIn: parent
                                name: root.connected ? "album" : "music_off"
                                size: 28
                                color: Theme.surfaceVariantText
                                visible: root.popupArtSource.length === 0 || popupCoverImage.status !== Image.Ready
                            }
                        }

                        Column {
                            id: headerDetails

                            readonly property int labelWidth: 52
                            readonly property color activeStarColor: "#f5c84c"

                            spacing: 2

                            Item {
                                width: headerColumn.width - 56 - Theme.spacingS
                                height: Math.max(artistLabel.implicitHeight, artistValue.implicitHeight)

                                Rectangle {
                                    anchors.fill: parent
                                    radius: 6
                                    color: artistHeaderArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18) : artistHeaderArea.containsMouse ? Theme.widgetBaseHoverColor : "transparent"
                                }

                                StyledText {
                                    id: artistLabel

                                    width: headerDetails.labelWidth
                                    text: "Artist:"
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }

                                StyledText {
                                    id: artistValue

                                    anchors.left: artistLabel.right
                                    anchors.leftMargin: Theme.spacingXS
                                    anchors.right: parent.right
                                    text: root.currentArtistName
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceText
                                    wrapMode: Text.WordWrap
                                }

                                MouseArea {
                                    id: artistHeaderArea
                                    anchors.fill: parent
                                    enabled: root.currentArtistName.length > 0
                                    hoverEnabled: true
                                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: root.openArtistView(root.currentArtistName)
                                }
                            }

                            Item {
                                width: headerColumn.width - 56 - Theme.spacingS
                                height: Math.max(titleLabel.implicitHeight, Math.max(titleValue.implicitHeight, titleStars.implicitHeight))

                                StyledText {
                                    id: titleLabel

                                    width: headerDetails.labelWidth
                                    text: root.inAlbumView ? "Album:" : root.inArtistView ? "Albums:" : "Title:"
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }

                                Row {
                                    id: titleStars

                                    visible: !root.inArtistView
                                    anchors.right: parent.right
                                    anchors.verticalCenter: titleLabel.verticalCenter
                                    spacing: 1

                                    Repeater {
                                        model: 5

                                        Item {
                                            required property int index

                                            width: starText.implicitWidth
                                            height: starText.implicitHeight

                                            StyledText {
                                                id: starText

                                                anchors.centerIn: parent
                                                text: index < root.displayedStarCount(root.inAlbumView ? root.selectedAlbumInfo.albumrating : root.trackData.rating) ? "★" : "☆"
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: starArea.pressed || starArea.containsMouse ? headerDetails.activeStarColor : index < root.displayedStarCount(root.inAlbumView ? root.selectedAlbumInfo.albumrating : root.trackData.rating) ? headerDetails.activeStarColor : Theme.surfaceVariantText
                                            }

                                            MouseArea {
                                                id: starArea
                                                anchors.fill: parent
                                                enabled: !root.inArtistView && root.connected && (root.inAlbumView ? root.selectedAlbumInfo.clerk_id.length > 0 : true)
                                                hoverEnabled: true
                                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                onClicked: {
                                                    if (root.inAlbumView)
                                                        root.setSelectedAlbumRating(index);
                                                    else
                                                        root.setCurrentTrackRating(index);
                                                }
                                            }
                                        }
                                    }
                                }

                                StyledText {
                                    id: titleValue

                                    anchors.left: titleLabel.right
                                    anchors.leftMargin: Theme.spacingXS
                                    anchors.right: titleStars.visible ? titleStars.left : parent.right
                                    anchors.rightMargin: titleStars.visible ? Theme.spacingS : 0
                                    text: root.inAlbumView ? (root.selectedAlbumInfo.title || "") : root.inArtistView ? String(root.selectedArtistAlbums.length || 0) : (root.trackData.title || root.trackData.filename || "")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    wrapMode: Text.WordWrap
                                }
                            }

                            Item {
                                width: headerColumn.width - 56 - Theme.spacingS
                                height: Math.max(albumLabel.implicitHeight, albumValue.implicitHeight)

                                Rectangle {
                                    anchors.fill: parent
                                    radius: 6
                                    color: albumHeaderArea.enabled ? (albumHeaderArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18) : albumHeaderArea.containsMouse ? Theme.widgetBaseHoverColor : "transparent") : "transparent"
                                }

                                StyledText {
                                    id: albumLabel

                                    width: headerDetails.labelWidth
                                    text: root.inAlbumView ? "Year:" : root.inArtistView ? "Tracks:" : "Album:"
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }

                                StyledText {
                                    id: albumValue

                                    anchors.left: albumLabel.right
                                    anchors.leftMargin: Theme.spacingXS
                                    anchors.right: parent.right
                                    text: {
                                        if (root.inAlbumView)
                                            return root.selectedAlbumInfo.year || "";
                                        if (root.inArtistView) {
                                            let count = 0;
                                            for (const album of root.selectedArtistAlbums)
                                                count += album.track_count || 0;
                                            return String(count);
                                        }
                                        return root.trackData.album || "";
                                    }
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    wrapMode: Text.WordWrap
                                }

                                MouseArea {
                                    id: albumHeaderArea
                                    anchors.fill: parent
                                    enabled: !root.inAlbumView && !root.inArtistView && root.currentAlbumKey.length > 0
                                    hoverEnabled: true
                                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: root.openAlbumView(root.currentAlbumKey, false)
                                }
                            }
                        }
                    }

                    Row {
                        id: transportRow

                        width: parent.width
                        spacing: Theme.spacingS

                        Rectangle {
                            id: previousButton
                            width: (parent.width - Theme.spacingS * 4) / 5
                            height: 30
                            radius: 8
                            color: previousButtonArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18) : previousButtonArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainerHigh

                            DankIcon {
                                anchors.centerIn: parent
                                name: "skip_previous"
                                size: 16
                                color: Theme.surfaceText
                            }

                            MouseArea {
                                id: previousButtonArea
                                anchors.fill: parent
                                enabled: root.connected
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.runControl("previous")
                            }
                        }

                        Rectangle {
                            id: toggleButton
                            width: (parent.width - Theme.spacingS * 4) / 5
                            height: 30
                            radius: 8
                            color: toggleButtonArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18) : toggleButtonArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainerHigh

                            DankIcon {
                                anchors.centerIn: parent
                                name: root.playbackState === "play" ? "pause" : "play_arrow"
                                size: 16
                                color: Theme.surfaceText
                            }

                            MouseArea {
                                id: toggleButtonArea
                                anchors.fill: parent
                                enabled: root.connected
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.runControl("toggle")
                            }
                        }

                        Rectangle {
                            id: stopButton
                            width: (parent.width - Theme.spacingS * 4) / 5
                            height: 30
                            radius: 8
                            color: stopButtonArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18) : stopButtonArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainerHigh

                            DankIcon {
                                anchors.centerIn: parent
                                name: "stop"
                                size: 16
                                color: Theme.surfaceText
                            }

                            MouseArea {
                                id: stopButtonArea
                                anchors.fill: parent
                                enabled: root.connected
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.runControl("stop")
                            }
                        }

                        Rectangle {
                            id: nextButton
                            width: (parent.width - Theme.spacingS * 4) / 5
                            height: 30
                            radius: 8
                            color: nextButtonArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18) : nextButtonArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainerHigh

                            DankIcon {
                                anchors.centerIn: parent
                                name: "skip_next"
                                size: 16
                                color: Theme.surfaceText
                            }

                            MouseArea {
                                id: nextButtonArea
                                anchors.fill: parent
                                enabled: root.connected
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.runControl("next")
                            }
                        }

                        Rectangle {
                            id: randomButton

                            width: (parent.width - Theme.spacingS * 4) / 5
                            height: 30
                            radius: 8
                            color: randomButtonArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18) : randomButtonArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainerHigh

                            DankIcon {
                                anchors.centerIn: parent
                                name: "casino"
                                size: 16
                                color: Theme.surfaceText
                            }

                            MouseArea {
                                id: randomButtonArea
                                anchors.fill: parent
                                enabled: root.connected
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.showRandomMenu = !root.showRandomMenu
                            }
                        }
                    }

                    StyledRect {
                        width: parent.width
                        height: 1
                        color: Theme.surfaceVariant
                    }
                }

                MouseArea {
                    visible: root.showRandomMenu
                    anchors.fill: parent
                    z: 4
                    hoverEnabled: true
                    onClicked: root.showRandomMenu = false
                }

                StyledRect {
                    id: randomMenu

                    visible: root.showRandomMenu
                    z: 5
                    width: 132
                    height: randomMenuColumn.implicitHeight + Theme.spacingXS * 2
                    radius: 8
                    color: Theme.surfaceContainerHigh
                    border.color: Theme.outline
                    border.width: 1
                    x: Math.max(0, Math.min(contentArea.width - width, transportRow.x + randomButton.x + randomButton.width - width))
                    y: headerColumn.height - 1

                    Column {
                        id: randomMenuColumn

                        anchors.fill: parent
                        anchors.margins: Theme.spacingXS
                        spacing: 2

                        Rectangle {
                            width: parent.width
                            height: 26
                            radius: 6
                            color: randomAlbumArea.containsMouse ? Theme.widgetBaseHoverColor : "transparent"

                            StyledText {
                                anchors.centerIn: parent
                                text: "Album"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                            }

                            MouseArea {
                                id: randomAlbumArea
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.showRandomMenu = false;
                                    root.runClerkAction("album");
                                }
                            }
                        }

                        Rectangle {
                            width: parent.width
                            height: 26
                            radius: 6
                            color: randomTracksArea.containsMouse ? Theme.widgetBaseHoverColor : "transparent"

                            StyledText {
                                anchors.centerIn: parent
                                text: "Tracks"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                            }

                            MouseArea {
                                id: randomTracksArea
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.showRandomMenu = false;
                                    root.runClerkAction("tracks");
                                }
                            }
                        }
                    }
                }

                Column {
                    id: footerColumn

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    spacing: Theme.spacingXS

                    StyledRect {
                        width: parent.width
                        height: 1
                        color: Theme.surfaceVariant
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS

                        Rectangle {
                            id: footerBackButton
                            visible: root.inAlbumView || root.inArtistView
                            width: 64
                            height: 28
                            radius: 8
                            color: footerBackArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18) : footerBackArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainerHigh

                            StyledText {
                                anchors.centerIn: parent
                                text: "Back"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                            }

                            MouseArea {
                                id: footerBackArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.goBack()
                            }
                        }

                        Item {
                            width: parent.width - (parent.children[0].visible ? parent.children[0].width + parent.spacing : 0)
                            height: connectionText.implicitHeight

                            StyledText {
                                id: connectionText

                                anchors.right: parent.right
                                text: "Connection: " + root.host + ":" + root.port
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }
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

                Column {
                    id: actionsColumn

                    visible: root.selectedAlbumKey.length > 0
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: footerColumn.top
                    anchors.bottomMargin: visible ? Theme.spacingS : 0
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
                            id: addAlbumButton
                            width: (parent.width - Theme.spacingS * 2) / 3
                            height: 32
                            radius: 8
                            color: addAlbumArea.enabled ? (addAlbumArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18) : addAlbumArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainerHigh) : Theme.surfaceContainerHigh

                            StyledText {
                                anchors.centerIn: parent
                                text: "Add"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                            }

                            MouseArea {
                                id: addAlbumArea
                                anchors.fill: parent
                                enabled: root.connected && (root.selectedAlbumInfo.files || []).length > 0
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.runControl("add_album", root.selectedAlbumKey)
                            }
                        }

                        Rectangle {
                            id: insertAlbumButton
                            width: (parent.width - Theme.spacingS * 2) / 3
                            height: 32
                            radius: 8
                            color: insertAlbumArea.enabled ? (insertAlbumArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18) : insertAlbumArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainerHigh) : Theme.surfaceContainerHigh

                            StyledText {
                                anchors.centerIn: parent
                                text: "Insert"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                            }

                            MouseArea {
                                id: insertAlbumArea
                                anchors.fill: parent
                                enabled: root.connected && (root.selectedAlbumInfo.files || []).length > 0
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.runControl("insert_album", root.selectedAlbumKey)
                            }
                        }

                        Rectangle {
                            id: replaceAlbumButton
                            width: (parent.width - Theme.spacingS * 2) / 3
                            height: 32
                            radius: 8
                            color: replaceAlbumArea.enabled ? (replaceAlbumArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18) : replaceAlbumArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainerHigh) : Theme.surfaceContainerHigh

                            StyledText {
                                anchors.centerIn: parent
                                text: "Replace"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                            }

                            MouseArea {
                                id: replaceAlbumArea
                                anchors.fill: parent
                                enabled: root.connected && (root.selectedAlbumInfo.files || []).length > 0
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.runControl("replace_album", root.selectedAlbumKey)
                            }
                        }
                    }
                }

                Flickable {
                    anchors.top: headerColumn.bottom
                    anchors.topMargin: Theme.spacingS
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: actionsColumn.visible ? actionsColumn.top : footerColumn.top
                    anchors.bottomMargin: Theme.spacingS
                    contentWidth: width
                    contentHeight: contentColumn.implicitHeight
                    clip: true

                    Column {
                        id: contentColumn

                        width: parent.width
                        spacing: Theme.spacingS

                        Column {
                            visible: root.inAlbumView
                            width: parent.width
                            spacing: Theme.spacingXS

                            Repeater {
                                model: root.selectedAlbumInfo.tracks || []

                                Rectangle {
                                    required property var modelData
                                    required property int index
                                    readonly property bool isCurrent: index === Number(root.selectedAlbumInfo.current_index)

                                    width: contentColumn.width
                                    height: albumTrackRow.implicitHeight + Theme.spacingXS * 2
                                    radius: 8
                                    color: isCurrent ? Theme.surfaceContainerHigh : Qt.rgba(0, 0, 0, 0)

                                    Row {
                                        id: albumTrackRow

                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingS
                                        anchors.rightMargin: Theme.spacingS
                                        spacing: Theme.spacingS

                                        StyledText {
                                            width: 28
                                            text: modelData.tracknumber && modelData.tracknumber.length > 0 ? modelData.tracknumber : "•"
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                        }

                                        StyledText {
                                            width: parent.width - 28 - Theme.spacingS
                                            text: modelData.title || ""
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: parent.parent.isCurrent ? Theme.primary : Theme.surfaceText
                                            wrapMode: Text.WordWrap
                                        }
                                    }
                                }
                            }
                        }

                        Column {
                            visible: root.inArtistView
                            width: parent.width
                            spacing: Theme.spacingXS

                            Repeater {
                                model: root.selectedArtistAlbums

                                Rectangle {
                                    required property var modelData

                                    width: contentColumn.width
                                    height: artistAlbumRow.implicitHeight + Theme.spacingXS * 2
                                    radius: 8
                                    color: artistAlbumArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.14) : artistAlbumArea.containsMouse ? Theme.widgetBaseHoverColor : "transparent"

                                    Row {
                                        id: artistAlbumRow

                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingS
                                        anchors.rightMargin: Theme.spacingS
                                        spacing: Theme.spacingS

                                        StyledText {
                                            width: 48
                                            text: modelData.year || ""
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                        }

                                        StyledText {
                                            width: parent.width - 48 - artistAlbumStars.width - Theme.spacingS * 2
                                            text: modelData.title || ""
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                            wrapMode: Text.WordWrap
                                        }

                                        Row {
                                            id: artistAlbumStars

                                            spacing: 1

                                            Repeater {
                                                model: 5

                                                StyledText {
                                                    required property int index

                                                    text: index < root.displayedStarCount(modelData.albumrating) ? "★" : "☆"
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    color: index < root.displayedStarCount(modelData.albumrating) ? "#f5c84c" : Theme.surfaceVariantText
                                                }
                                            }
                                        }
                                    }

                                    MouseArea {
                                        id: artistAlbumArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.openAlbumView(modelData.album_key, true)
                                    }
                                }
                            }
                        }

                        Column {
                            visible: !root.inAlbumView && !root.inArtistView
                            width: parent.width
                            spacing: Theme.spacingXS

                            Repeater {
                                model: root.queueInfo.tracks || []

                                Rectangle {
                                    required property var modelData

                                    width: contentColumn.width
                                    height: queueRow.implicitHeight + Theme.spacingXS * 2
                                    radius: 8
                                    color: modelData.current ? Theme.surfaceContainerHigh : queuePlayArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.14) : queuePlayArea.containsMouse ? Theme.widgetBaseHoverColor : "transparent"

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
                                            width: parent.width - 28 - 28 - Theme.spacingS * 2
                                            text: (modelData.artist && modelData.artist.length > 0 ? modelData.artist + " - " : "") + (modelData.title || "")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: modelData.current ? Theme.primary : Theme.surfaceText
                                            wrapMode: Text.WordWrap
                                        }

                                        Rectangle {
                                            width: 24
                                            height: 24
                                            radius: 12
                                            color: infoArea.containsMouse ? Theme.widgetBaseHoverColor : "transparent"
                                            visible: modelData.album_key && modelData.album_key.length > 0

                                            DankIcon {
                                                anchors.centerIn: parent
                                                name: "album"
                                                size: 14
                                                color: Theme.surfaceVariantText
                                            }

                                            MouseArea {
                                                id: infoArea
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.openAlbumView(modelData.album_key, false)
                                            }
                                        }
                                    }

                                    MouseArea {
                                        id: queuePlayArea
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        anchors.bottom: parent.bottom
                                        anchors.right: infoButtonProxy.left
                                        enabled: root.connected && modelData.pos >= 0
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.runControl("play_pos", modelData.pos)
                                    }

                                    Item {
                                        id: infoButtonProxy
                                        anchors.top: parent.top
                                        anchors.bottom: parent.bottom
                                        anchors.right: parent.right
                                        width: 40
                                    }
                                }
                            }
                        }
                    }
                }

            }
        }
    }
}
