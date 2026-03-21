import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginComponent {
    id: root

    property string sharedPluginId: String(pluginData.sharedPluginId || "mpd").trim()
    property string defaultMode: String(pluginData.defaultMode || "album").trim().toLowerCase() === "latest" ? "latest" : "album"
    property string host: "localhost"
    property string port: "6600"
    property string password: ""
    property string clerkApiBaseUrl: ""
    property bool albumBrowserLoading: false
    property string albumBrowserMode: defaultMode
    property string albumBrowserPendingMode: ""
    property string albumBrowserSearch: ""
    property string albumBrowserError: ""
    property string albumBrowserSelectedId: ""
    property string albumBrowserActionPromptId: ""
    property int albumBrowserActionIndex: 0
    property var albumBrowserAlbums: []
    property var albumBrowserCache: ({})
    property bool showAlbumBrowserRandomMenu: false
    property bool pluginPopoutVisible: false
    property var albumBrowserFocusScope: null
    property var albumBrowserListViewRef: null

    readonly property string watcherScriptPath: {
        const url = Qt.resolvedUrl("../mpd/mpd_watch.py").toString();
        return url.startsWith("file://") ? url.substring(7) : url;
    }
    readonly property var filteredAlbumBrowserAlbums: {
        const query = String(albumBrowserSearch || "").trim().toLowerCase();
        const albums = albumBrowserAlbums || [];
        if (query.length === 0)
            return albums;

        const tokens = query.split(/\s+/).filter(token => token.length > 0);
        if (tokens.length === 0)
            return albums;

        const filtered = [];
        for (const album of albums) {
            const haystack = [
                String(album.albumartist || ""),
                String(album.album || ""),
                String(album.date || ""),
                String(album.year || ""),
                String(album.rating || "")
            ].join(" ").toLowerCase();
            const ratingText = String(album.rating || "").toLowerCase();
            let matches = true;
            for (const token of tokens) {
                if (token.startsWith("r=")) {
                    const ratingQuery = token.slice(2);
                    if (ratingQuery.length > 0 && ratingText.indexOf(ratingQuery) < 0) {
                        matches = false;
                        break;
                    }
                    continue;
                }

                if (haystack.indexOf(token) < 0) {
                    matches = false;
                    break;
                }
            }

            if (matches)
                filtered.push(album);
        }
        return filtered;
    }

    function sharedSettingsSourceId() {
        return sharedPluginId.length > 0 ? sharedPluginId : "mpd";
    }

    function loadSharedConfig() {
        const sourceId = sharedSettingsSourceId();
        host = String(pluginService ? pluginService.loadPluginData(sourceId, "host", "localhost") : "localhost").trim();
        port = String(pluginService ? pluginService.loadPluginData(sourceId, "port", "6600") : "6600").trim();
        password = String(pluginService ? pluginService.loadPluginData(sourceId, "password", "") : "");
        clerkApiBaseUrl = String(pluginService ? pluginService.loadPluginData(sourceId, "clerkApiBaseUrl", "") : "").trim();
    }

    function extractYear(value) {
        const match = String(value || "").match(/(\d{4})/);
        return match ? match[1] : "";
    }

    function buildAlbumBrowserCommand(mode) {
        const args = ["python3", watcherScriptPath, "--host", host.length > 0 ? host : "localhost", "--port", port.length > 0 ? port : "6600", "--action", "dump_albums", "--arg", mode === "latest" ? "latest" : "album"];
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

    function normalizeAlbumBrowserEntry(album) {
        const entry = album || {};
        return {
            "id": String(entry.id || ""),
            "album": String(entry.album || ""),
            "albumartist": String(entry.albumartist || ""),
            "date": String(entry.date || ""),
            "year": String(entry.year || extractYear(entry.date || "")),
            "rating": String(entry.rating || "")
        };
    }

    function albumBrowserEntryById(albumId) {
        const targetId = String(albumId || "");
        if (targetId.length === 0)
            return null;
        for (const album of albumBrowserAlbums || []) {
            if (String(album.id || "") === targetId)
                return album;
        }
        return null;
    }

    function albumBrowserActionName(index) {
        if (index === 1)
            return "insert";
        if (index === 2)
            return "replace";
        return "add";
    }

    function syncAlbumBrowserSelection() {
        const albums = filteredAlbumBrowserAlbums || [];
        if (albums.length === 0) {
            albumBrowserSelectedId = "";
            albumBrowserActionPromptId = "";
            albumBrowserActionIndex = 0;
            return;
        }

        let found = false;
        for (const album of albums) {
            if (String(album.id || "") === albumBrowserSelectedId) {
                found = true;
                break;
            }
        }
        if (!found)
            albumBrowserSelectedId = String(albums[0].id || "");

        if (albumBrowserActionPromptId.length > 0) {
            let actionAlbumVisible = false;
            for (const album of albums) {
                if (String(album.id || "") === albumBrowserActionPromptId) {
                    actionAlbumVisible = true;
                    break;
                }
            }
            if (!actionAlbumVisible)
                albumBrowserActionPromptId = "";
        }
    }

    function cycleAlbumBrowserSelection(step) {
        const albums = filteredAlbumBrowserAlbums || [];
        if (albums.length === 0)
            return;

        let currentIndex = 0;
        for (let i = 0; i < albums.length; ++i) {
            if (String(albums[i].id || "") === albumBrowserSelectedId) {
                currentIndex = i;
                break;
            }
        }
        const nextIndex = (currentIndex + step + albums.length) % albums.length;
        albumBrowserSelectedId = String(albums[nextIndex].id || "");
        albumBrowserActionPromptId = "";
    }

    function albumBrowserSelectedIndex() {
        const albums = filteredAlbumBrowserAlbums || [];
        for (let i = 0; i < albums.length; ++i) {
            if (String(albums[i].id || "") === albumBrowserSelectedId)
                return i;
        }
        return albums.length > 0 ? 0 : -1;
    }

    function ensureAlbumBrowserSelectionVisible(positionMode) {
        const index = albumBrowserSelectedIndex();
        if (index < 0 || !albumBrowserListViewRef)
            return;
        const mode = positionMode === ListView.Beginning || positionMode === ListView.End || positionMode === ListView.Center ? positionMode : ListView.Contain;
        albumBrowserListViewRef.positionViewAtIndex(index, mode);
        Qt.callLater(() => {
            if (!albumBrowserListViewRef)
                return;
            albumBrowserListViewRef.positionViewAtIndex(index, mode);
        });
    }

    function pageAlbumBrowserSelection(step) {
        const albums = filteredAlbumBrowserAlbums || [];
        if (albums.length === 0)
            return;

        const currentIndex = albumBrowserSelectedIndex();
        const viewportHeight = albumBrowserListViewRef ? albumBrowserListViewRef.height : 360;
        const pageSize = Math.max(1, Math.floor(viewportHeight / 46) - 1);
        const nextIndex = Math.max(0, Math.min(albums.length - 1, currentIndex + pageSize * step));
        albumBrowserSelectedId = String(albums[nextIndex].id || "");
        albumBrowserActionPromptId = "";
        ensureAlbumBrowserSelectionVisible();
    }

    function cycleAlbumBrowserAction(step) {
        albumBrowserActionIndex = (albumBrowserActionIndex + step + 3) % 3;
    }

    function loadAlbumBrowser(mode, forceRefresh) {
        const normalized = mode === "latest" ? "latest" : "album";
        albumBrowserMode = normalized;

        if (!forceRefresh && albumBrowserCache[normalized] !== undefined) {
            albumBrowserAlbums = albumBrowserCache[normalized] || [];
            albumBrowserError = "";
            albumBrowserLoading = false;
            syncAlbumBrowserSelection();
            return;
        }

        albumBrowserLoading = true;
        albumBrowserError = "";
        albumBrowserPendingMode = "";
        albumBrowserFetcher.command = buildAlbumBrowserCommand(normalized);
        if (albumBrowserFetcher.running) {
            albumBrowserPendingMode = normalized;
            albumBrowserFetcher.running = false;
            return;
        }
        albumBrowserFetcher.running = true;
    }

    function setAlbumBrowserMode(mode, forceRefresh) {
        const normalized = mode === "latest" ? "latest" : "album";
        albumBrowserActionPromptId = "";
        albumBrowserActionIndex = 0;
        loadAlbumBrowser(normalized, !!forceRefresh);
        if (albumBrowserFocusScope)
            albumBrowserFocusScope.forceActiveFocus();
    }

    function triggerFrameworkPopout() {
        const savedClickAction = pillClickAction;
        pillClickAction = null;
        triggerPopout();
        pillClickAction = savedClickAction;
    }

    function openMode(mode) {
        const normalized = mode === "latest" ? "latest" : "album";
        const wasVisible = pluginPopoutVisible;
        const sameMode = albumBrowserMode === normalized;

        albumBrowserMode = normalized;
        showAlbumBrowserRandomMenu = false;
        albumBrowserActionPromptId = "";
        albumBrowserActionIndex = 0;
        albumBrowserSearch = "";
        loadAlbumBrowser(normalized, false);

        if (wasVisible && sameMode) {
            closePopout();
            return;
        }

        if (!wasVisible)
            Qt.callLater(() => triggerFrameworkPopout());
        albumBrowserFocusTimer.restart();
    }

    function promptAlbumBrowserActions(albumId) {
        const id = String(albumId || "");
        if (id.length === 0)
            return;
        albumBrowserSelectedId = id;
        albumBrowserActionPromptId = id;
        albumBrowserActionIndex = 0;
    }

    function runAlbumBrowserAction(actionName) {
        const albumId = String(albumBrowserActionPromptId || albumBrowserSelectedId || "");
        const action = String(actionName || "").trim().toLowerCase();
        if (albumId.length === 0 || ["add", "insert", "replace"].indexOf(action) < 0)
            return;
        closePopout();
        runControl("queue_clerk_album", action + ":" + albumId + ":" + albumBrowserMode);
    }

    function handleAlbumBrowserKey(event) {
        if (!(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) && event.text && event.text.length > 0 && event.text >= " ") {
            albumBrowserSearch += event.text;
            event.accepted = true;
            return;
        }

        if (event.key === Qt.Key_Escape) {
            if (albumBrowserActionPromptId.length > 0)
                albumBrowserActionPromptId = "";
            else
                closePopout();
            event.accepted = true;
            return;
        }

        if (event.key === Qt.Key_Backspace) {
            if (albumBrowserSearch.length > 0)
                albumBrowserSearch = albumBrowserSearch.slice(0, -1);
            event.accepted = true;
            return;
        }

        if (event.key === Qt.Key_Delete) {
            if (albumBrowserSearch.length > 0)
                albumBrowserSearch = "";
            event.accepted = true;
            return;
        }

        if (event.key === Qt.Key_Down) {
            if (albumBrowserActionPromptId.length === 0)
                cycleAlbumBrowserSelection(1);
            ensureAlbumBrowserSelectionVisible();
            event.accepted = true;
            return;
        }

        if (event.key === Qt.Key_Up) {
            if (albumBrowserActionPromptId.length === 0)
                cycleAlbumBrowserSelection(-1);
            ensureAlbumBrowserSelectionVisible();
            event.accepted = true;
            return;
        }

        if (event.key === Qt.Key_PageDown) {
            if (albumBrowserActionPromptId.length === 0)
                pageAlbumBrowserSelection(1);
            event.accepted = true;
            return;
        }

        if (event.key === Qt.Key_PageUp) {
            if (albumBrowserActionPromptId.length === 0)
                pageAlbumBrowserSelection(-1);
            event.accepted = true;
            return;
        }

        if (event.key === Qt.Key_Home) {
            if (albumBrowserActionPromptId.length === 0) {
                const albums = filteredAlbumBrowserAlbums || [];
                if (albums.length > 0) {
                    albumBrowserSelectedId = String(albums[0].id || "");
                    albumBrowserActionPromptId = "";
                    ensureAlbumBrowserSelectionVisible(ListView.Beginning);
                }
            }
            event.accepted = true;
            return;
        }

        if (event.key === Qt.Key_End) {
            if (albumBrowserActionPromptId.length === 0) {
                const albums = filteredAlbumBrowserAlbums || [];
                if (albums.length > 0) {
                    albumBrowserSelectedId = String(albums[albums.length - 1].id || "");
                    albumBrowserActionPromptId = "";
                    ensureAlbumBrowserSelectionVisible(ListView.End);
                }
            }
            event.accepted = true;
            return;
        }

        if (event.key === Qt.Key_Left && albumBrowserActionPromptId.length > 0) {
            cycleAlbumBrowserAction(-1);
            event.accepted = true;
            return;
        }

        if (event.key === Qt.Key_Right && albumBrowserActionPromptId.length > 0) {
            cycleAlbumBrowserAction(1);
            event.accepted = true;
            return;
        }

        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !event.isAutoRepeat) {
            if (albumBrowserActionPromptId.length > 0)
                runAlbumBrowserAction(albumBrowserActionName(albumBrowserActionIndex));
            else if (albumBrowserSelectedId.length > 0)
                promptAlbumBrowserActions(albumBrowserSelectedId);
            event.accepted = true;
            return;
        }

        event.accepted = false;
    }

    function handleAlbumBrowserLine(line) {
        const trimmed = String(line || "").trim();
        if (trimmed.length === 0)
            return;

        try {
            const payload = JSON.parse(trimmed);
            const mode = String(payload.mode || albumBrowserMode || "album");
            const albums = [];
            for (const album of payload.albums || [])
                albums.push(normalizeAlbumBrowserEntry(album));
            const nextCache = {};
            for (const key in albumBrowserCache)
                nextCache[key] = albumBrowserCache[key];
            nextCache[mode] = albums;
            albumBrowserCache = nextCache;
            if (mode === albumBrowserMode)
                albumBrowserAlbums = albums;
            albumBrowserError = String(payload.error || "");
            albumBrowserLoading = false;
            syncAlbumBrowserSelection();
        } catch (e) {
            albumBrowserLoading = false;
            albumBrowserError = "Failed to parse album browser data.";
        }
    }

    pluginId: "mpdBrowser"
    pillClickAction: function () {
        root.openMode("album");
    }
    pillRightClickAction: function () {
        root.openMode("latest");
    }

    Component.onCompleted: {
        loadSharedConfig();
        albumBrowserMode = defaultMode;
        loadAlbumBrowser(albumBrowserMode, false);
    }

    onPluginServiceChanged: loadSharedConfig()
    onSharedPluginIdChanged: loadSharedConfig()
    onAlbumBrowserSearchChanged: syncAlbumBrowserSelection()
    onAlbumBrowserAlbumsChanged: syncAlbumBrowserSelection()

    Connections {
        target: pluginService
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === root.sharedSettingsSourceId())
                root.loadSharedConfig();
        }
    }

    Timer {
        id: albumBrowserFocusTimer

        interval: 75
        repeat: false
        onTriggered: {
            if (root.albumBrowserFocusScope)
                root.albumBrowserFocusScope.forceActiveFocus();
        }
    }

    Process {
        id: albumBrowserFetcher

        running: false

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => root.handleAlbumBrowserLine(data)
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const text = String(data || "").trim();
                if (text.length > 0) {
                    root.albumBrowserError = text;
                    root.albumBrowserLoading = false;
                }
            }
        }

        onExited: exitCode => {
            if (root.albumBrowserPendingMode.length > 0) {
                const nextMode = root.albumBrowserPendingMode;
                root.albumBrowserPendingMode = "";
                command = root.buildAlbumBrowserCommand(nextMode);
                running = true;
                return;
            }

            if (exitCode !== 0 && root.albumBrowserError.length === 0)
                root.albumBrowserError = "Album browser request failed.";
            root.albumBrowserLoading = false;
        }
    }

    horizontalBarPill: Component {
        Rectangle {
            width: 22
            height: 22
            radius: 11
            color: browserPillArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18) : browserPillArea.containsMouse || root.pluginPopoutVisible ? Theme.widgetBaseHoverColor : "transparent"
            opacity: 1

            DankIcon {
                anchors.centerIn: parent
                name: root.albumBrowserMode === "latest" ? "schedule" : "library_music"
                size: 14
                color: root.pluginPopoutVisible ? Theme.primary : Theme.widgetTextColor
            }

            MouseArea {
                id: browserPillArea
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPressed: mouse => {
                    mouse.accepted = false;
                }
            }
        }
    }

    verticalBarPill: Component {
        Rectangle {
            width: Theme.barIconSize(root.barThickness)
            height: Theme.barIconSize(root.barThickness)
            radius: Theme.cornerRadius
            color: root.pluginPopoutVisible ? Theme.widgetBaseHoverColor : "transparent"

            DankIcon {
                anchors.centerIn: parent
                name: root.albumBrowserMode === "latest" ? "schedule" : "library_music"
                size: Math.max(14, Theme.barIconSize(root.barThickness) - 4)
                color: root.pluginPopoutVisible ? Theme.primary : Theme.widgetIconColor
            }
        }
    }

    popoutContent: Component {
        Item {
            id: popoutRoot
            property var parentPopout: null

            implicitWidth: 420
            implicitHeight: 420

            Connections {
                target: popoutRoot.parentPopout
                function onShouldBeVisibleChanged() {
                    root.pluginPopoutVisible = !!(popoutRoot.parentPopout && popoutRoot.parentPopout.shouldBeVisible);
                    if (root.pluginPopoutVisible)
                        root.albumBrowserFocusTimer.restart();
                    if (!root.pluginPopoutVisible) {
                        root.showAlbumBrowserRandomMenu = false;
                        root.albumBrowserActionPromptId = "";
                        root.albumBrowserActionIndex = 0;
                        root.albumBrowserSearch = "";
                    }
                }
            }

            StyledRect {
                anchors.fill: parent
                radius: Theme.cornerRadius
                color: Theme.surfaceContainer
                border.color: Theme.outline
                border.width: 1
            }

            FocusScope {
                id: browserContentArea

                anchors.fill: parent
                anchors.margins: Theme.spacingM
                focus: root.pluginPopoutVisible
                Component.onCompleted: root.albumBrowserFocusScope = this
                Component.onDestruction: {
                    if (root.albumBrowserFocusScope === this)
                        root.albumBrowserFocusScope = null;
                }

                Keys.onPressed: event => root.handleAlbumBrowserKey(event)

                Column {
                    anchors.fill: parent
                    spacing: Theme.spacingS

                    Row {
                        id: browserHeaderRow

                        width: parent.width
                        spacing: Theme.spacingXS

                        Item {
                            width: parent.width - browserRandomButton.width - browserHeaderRow.spacing
                            height: 30

                            Row {
                                anchors.fill: parent
                                spacing: Theme.spacingXS

                                Rectangle {
                                    width: (parent.width - Theme.spacingXS) / 2
                                    height: 30
                                    radius: 8
                                    color: root.albumBrowserMode === "album" ? Theme.primary : Theme.surfaceContainerHigh

                                    StyledText {
                                        anchors.centerIn: parent
                                        text: "Albums"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: root.albumBrowserMode === "album" ? Theme.background : Theme.surfaceText
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.setAlbumBrowserMode("album", false)
                                    }
                                }

                                Rectangle {
                                    width: (parent.width - Theme.spacingXS) / 2
                                    height: 30
                                    radius: 8
                                    color: root.albumBrowserMode === "latest" ? Theme.primary : Theme.surfaceContainerHigh

                                    StyledText {
                                        anchors.centerIn: parent
                                        text: "Latest"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: root.albumBrowserMode === "latest" ? Theme.background : Theme.surfaceText
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.setAlbumBrowserMode("latest", false)
                                    }
                                }
                            }
                        }

                        Item {
                            id: browserRandomButton

                            width: 30
                            height: 30

                            Rectangle {
                                anchors.fill: parent
                                radius: 8
                                color: browserRandomButtonArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18) : browserRandomButtonArea.containsMouse || root.showAlbumBrowserRandomMenu ? Theme.widgetBaseHoverColor : Theme.surfaceContainerHigh

                                DankIcon {
                                    anchors.centerIn: parent
                                    name: "casino"
                                    size: 16
                                    color: Theme.surfaceText
                                }

                                MouseArea {
                                    id: browserRandomButtonArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onPressed: mouse => {
                                        mouse.accepted = true;
                                        root.showAlbumBrowserRandomMenu = !root.showAlbumBrowserRandomMenu;
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        width: parent.width
                        height: 36
                        radius: 10
                        color: Theme.surfaceContainerHigh
                        border.color: browserContentArea.activeFocus ? Theme.primary : Theme.outline
                        border.width: 1

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.spacingS
                            anchors.rightMargin: Theme.spacingS
                            spacing: Theme.spacingXS

                            DankIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: "search"
                                size: 16
                                color: browserContentArea.activeFocus ? Theme.primary : Theme.surfaceVariantText
                            }

                            Item {
                                width: parent.width - 16 - clearSearchButton.width - Theme.spacingXS * 2
                                height: parent.height

                                StyledText {
                                    anchors.fill: parent
                                    text: root.albumBrowserSearch.length > 0 ? root.albumBrowserSearch : (root.albumBrowserMode === "latest" ? "Filter latest albums..." : "Filter albums...")
                                    verticalAlignment: Text.AlignVCenter
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: root.albumBrowserSearch.length > 0 ? Theme.surfaceText : Theme.surfaceVariantText
                                    elide: Text.ElideRight
                                }
                            }

                            Rectangle {
                                id: clearSearchButton

                                width: 18
                                height: 18
                                radius: 9
                                visible: root.albumBrowserSearch.length > 0
                                color: clearSearchArea.containsMouse ? Theme.widgetBaseHoverColor : "transparent"
                                anchors.verticalCenter: parent.verticalCenter

                                DankIcon {
                                    anchors.centerIn: parent
                                    name: "close"
                                    size: 12
                                    color: Theme.surfaceVariantText
                                }

                                MouseArea {
                                    id: clearSearchArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        root.albumBrowserSearch = "";
                                        browserContentArea.forceActiveFocus();
                                    }
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton
                            cursorShape: Qt.IBeamCursor
                            onPressed: mouse => {
                                mouse.accepted = false;
                                browserContentArea.forceActiveFocus();
                            }
                        }
                    }

                    Rectangle {
                        visible: root.albumBrowserActionPromptId.length > 0
                        width: parent.width
                        height: 64
                        radius: 10
                        color: Theme.surfaceContainerHigh

                        Column {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingS
                            spacing: Theme.spacingXS

                            StyledText {
                                width: parent.width
                                text: {
                                    const album = root.albumBrowserEntryById(root.albumBrowserActionPromptId);
                                    if (!album)
                                        return "";
                                    return (album.albumartist && album.albumartist.length > 0 ? album.albumartist + " - " : "") + (album.album || "");
                                }
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                            }

                            Row {
                                width: parent.width
                                spacing: Theme.spacingXS

                                Repeater {
                                    model: ["Add", "Insert", "Replace"]

                                    Rectangle {
                                        required property string modelData
                                        required property int index
                                        readonly property int actionIndex: index

                                        width: (parent.width - Theme.spacingXS * 2) / 3
                                        height: 26
                                        radius: 8
                                        color: root.albumBrowserActionIndex === actionIndex ? Theme.primary : "transparent"
                                        border.color: root.albumBrowserActionIndex === actionIndex ? Theme.primary : Theme.outline
                                        border.width: 1

                                        StyledText {
                                            anchors.centerIn: parent
                                            text: modelData
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: root.albumBrowserActionIndex === actionIndex ? Theme.background : Theme.surfaceText
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                root.albumBrowserActionIndex = actionIndex;
                                                root.runAlbumBrowserAction(root.albumBrowserActionName(actionIndex));
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    StyledText {
                        visible: root.albumBrowserError.length > 0
                        width: parent.width
                        text: root.albumBrowserError
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.error
                        wrapMode: Text.WordWrap
                    }

                    Rectangle {
                        width: parent.width
                        height: Math.max(120, parent.height - y)
                        radius: 10
                        color: Theme.surfaceContainerHigh
                        border.color: Theme.outline
                        border.width: 1
                        clip: true

                        Item {
                            anchors.fill: parent

                            StyledText {
                                anchors.centerIn: parent
                                visible: root.albumBrowserLoading
                                text: "Loading albums..."
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            StyledText {
                                anchors.centerIn: parent
                                visible: !root.albumBrowserLoading && (root.filteredAlbumBrowserAlbums || []).length === 0
                                text: root.albumBrowserSearch.length > 0 ? "No matching albums." : "No albums available."
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            ListView {
                                id: albumBrowserListView

                                anchors.fill: parent
                                anchors.margins: Theme.spacingXS
                                clip: true
                                spacing: 2
                                cacheBuffer: 720
                                boundsBehavior: Flickable.StopAtBounds
                                flickDeceleration: 2200
                                maximumFlickVelocity: 12000
                                visible: !root.albumBrowserLoading && (root.filteredAlbumBrowserAlbums || []).length > 0
                                model: root.filteredAlbumBrowserAlbums || []
                                Component.onCompleted: root.albumBrowserListViewRef = this
                                Component.onDestruction: {
                                    if (root.albumBrowserListViewRef === this)
                                        root.albumBrowserListViewRef = null;
                                }

                                delegate: Rectangle {
                                    required property var modelData

                                    readonly property bool selected: String(modelData.id || "") === root.albumBrowserSelectedId

                                    width: albumBrowserListView.width
                                    height: albumBrowserRow.implicitHeight + Theme.spacingXS * 2
                                    radius: 8
                                    color: selected ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.16) : albumBrowserItemArea.containsMouse ? Theme.widgetBaseHoverColor : "transparent"

                                    Row {
                                        id: albumBrowserRow

                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.leftMargin: Theme.spacingS
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingS

                                        Column {
                                            width: parent.width - 56
                                            spacing: 1

                                            StyledText {
                                                width: parent.width
                                                text: (modelData.albumartist && modelData.albumartist.length > 0 ? modelData.albumartist + " - " : "") + (modelData.album || "")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: selected ? Theme.primary : Theme.surfaceText
                                                elide: Text.ElideRight
                                            }

                                            StyledText {
                                                width: parent.width
                                                text: [modelData.date || modelData.year || "", modelData.rating && modelData.rating.length > 0 ? "★ " + modelData.rating : ""].filter(part => part.length > 0).join(" • ")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                elide: Text.ElideRight
                                            }
                                        }

                                        DankIcon {
                                            anchors.verticalCenter: parent.verticalCenter
                                            name: String(modelData.id || "") === root.albumBrowserActionPromptId ? "subdirectory_arrow_right" : "keyboard_return"
                                            size: 14
                                            color: selected ? Theme.primary : Theme.surfaceVariantText
                                        }
                                    }

                                    MouseArea {
                                        id: albumBrowserItemArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            root.albumBrowserSelectedId = String(modelData.id || "");
                                            root.promptAlbumBrowserActions(modelData.id || "");
                                            browserContentArea.forceActiveFocus();
                                        }
                                    }
                                }

                                WheelHandler {
                                    target: null
                                    onWheel: event => {
                                        const step = event.angleDelta.y !== 0 ? event.angleDelta.y : event.pixelDelta.y;
                                        if (!step)
                                            return;
                                        albumBrowserListView.contentY = Math.max(0, Math.min(albumBrowserListView.contentHeight - albumBrowserListView.height, albumBrowserListView.contentY - step * 1.5));
                                        event.accepted = true;
                                    }
                                }
                            }
                        }
                    }
                }

                StyledRect {
                    id: browserRandomMenu

                    visible: root.showAlbumBrowserRandomMenu
                    z: 20
                    width: 132
                    height: browserRandomMenuColumn.implicitHeight + Theme.spacingXS * 2
                    radius: 8
                    color: Theme.surfaceContainerHigh
                    border.color: Theme.outline
                    border.width: 1
                    x: browserHeaderRow.x + browserRandomButton.x + browserRandomButton.width - width
                    y: browserHeaderRow.y + browserRandomButton.y + browserRandomButton.height + Theme.spacingXS

                    Column {
                        id: browserRandomMenuColumn

                        anchors.fill: parent
                        anchors.margins: Theme.spacingXS
                        spacing: 2

                        Rectangle {
                            width: parent.width
                            height: 26
                            radius: 6
                            color: browserRandomAlbumArea.containsMouse ? Theme.widgetBaseHoverColor : "transparent"

                            StyledText {
                                anchors.centerIn: parent
                                text: "Album"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                            }

                            MouseArea {
                                id: browserRandomAlbumArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.showAlbumBrowserRandomMenu = false;
                                    root.runClerkAction("album");
                                }
                            }
                        }

                        Rectangle {
                            width: parent.width
                            height: 26
                            radius: 6
                            color: browserRandomTracksArea.containsMouse ? Theme.widgetBaseHoverColor : "transparent"

                            StyledText {
                                anchors.centerIn: parent
                                text: "Tracks"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                            }

                            MouseArea {
                                id: browserRandomTracksArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.showAlbumBrowserRandomMenu = false;
                                    root.runClerkAction("tracks");
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
