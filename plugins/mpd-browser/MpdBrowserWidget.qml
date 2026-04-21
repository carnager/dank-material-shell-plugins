import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import "../mpd" as MpdShared
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginComponent {
    id: root

    property string sharedPluginId: String(pluginData.sharedPluginId || "mpd").trim()
    property string defaultMode: String(pluginData.defaultMode || "album").trim().toLowerCase() === "latest" ? "latest" : "album"
    property bool browserInitialized: false
    readonly property string host: runtimeConfig.host
    readonly property string port: runtimeConfig.port
    readonly property string password: runtimeConfig.password
    readonly property string clerkApiBaseUrl: runtimeConfig.clerkApiBaseUrl
    readonly property string watcherBinaryPath: runtimeConfig.watcherBinaryPath
    readonly property bool albumUploadEnabled: {
        const value = String(pluginData.uploadEnabled || "false").trim().toLowerCase();
        return value === "true" || value === "1" || value === "yes" || value === "on";
    }
    readonly property string albumUploadBinaryPath: expandHomePath(String(pluginData.uploadBinaryPath || "").trim())
    readonly property bool albumUploadAvailable: albumUploadEnabled && albumUploadBinaryPath.length > 0
    property bool albumBrowserLoading: false
    property string albumBrowserMode: defaultMode
    property string albumBrowserRequestedOpenMode: ""
    property string albumBrowserPendingMode: ""
    property string albumBrowserSearch: ""
    property string albumBrowserError: ""
    property string albumBrowserSelectedId: ""
    property string albumBrowserActionPromptId: ""
    property string albumBrowserActionMode: "actions"
    property int albumBrowserActionIndex: 0
    property var albumBrowserAlbums: []
    property var albumBrowserCache: ({})
    property var albumBrowserCacheVersions: ({})
    property string albumBrowserActiveCacheVersion: ""
    property bool showAlbumBrowserRandomMenu: false
    property bool pluginPopoutVisible: false
    property bool albumBrowserViewActive: false
    property var albumBrowserFocusScope: null
    property var albumBrowserListViewRef: null
    property bool albumBrowserRefreshQueued: false
    property bool albumBrowserStatusPollInFlight: false

    MpdShared.MpdRuntimeConfig {
        id: runtimeConfig
        pluginService: root.pluginService
        pluginId: root.sharedSettingsSourceId()
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

    function extractYear(value) {
        const match = String(value || "").match(/(\d{4})/);
        return match ? match[1] : "";
    }

    function expandHomePath(value) {
        const text = String(value || "").trim();
        if (!text.startsWith("~/"))
            return text;
        const homePath = StandardPaths.writableLocation(StandardPaths.HomeLocation);
        return homePath.length > 0 ? homePath + text.slice(1) : text;
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

    function starText(value) {
        const filled = displayedStarCount(value);
        let text = "";
        for (let i = 0; i < 5; ++i)
            text += i < filled ? "★" : "☆";
        return text;
    }

    function normalizeCacheVersion(value) {
        if (value === undefined || value === null)
            return "";
        return String(value).trim();
    }

    function buildAlbumBrowserCommand(mode) {
        const args = [watcherBinaryPath, "--host", host.length > 0 ? host : "localhost", "--port", port.length > 0 ? port : "6600", "--action", "dump_albums", "--arg", mode === "latest" ? "latest" : "album"];
        if (password.length > 0)
            args.push("--password", password);
        if (clerkApiBaseUrl.length > 0)
            args.push("--clerk-api-base-url", clerkApiBaseUrl);
        return args;
    }

    function buildClerkCacheStatusCommand() {
        const args = [watcherBinaryPath, "--host", host.length > 0 ? host : "localhost", "--port", port.length > 0 ? port : "6600", "--action", "clerk_cache_status"];
        if (password.length > 0)
            args.push("--password", password);
        if (clerkApiBaseUrl.length > 0)
            args.push("--clerk-api-base-url", clerkApiBaseUrl);
        return args;
    }

    function runControl(action, arg) {
        const args = [watcherBinaryPath, "--host", host.length > 0 ? host : "localhost", "--port", port.length > 0 ? port : "6600", "--action", action];
        if (arg !== undefined && arg !== null && String(arg).length > 0)
            args.push("--arg", String(arg));
        if (password.length > 0)
            args.push("--password", password);
        if (clerkApiBaseUrl.length > 0)
            args.push("--clerk-api-base-url", clerkApiBaseUrl);
        Quickshell.execDetached(args);
    }

    function runUpload(album) {
        const entry = album || null;
        if (!entry || !albumUploadAvailable)
            return;

        const args = [
            albumUploadBinaryPath,
            "--artist", String(entry.albumartist || ""),
            "--album", String(entry.album || ""),
            "--date", String(entry.date || entry.year || "")
        ];
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
        if (index === 4 && !albumUploadAvailable)
            return "add";
        if (index === 1)
            return "insert";
        if (index === 2)
            return "replace";
        if (index === 3)
            return "rate";
        if (index === 4)
            return "upload";
        return "add";
    }

    function albumBrowserActionCount() {
        return albumUploadAvailable ? 5 : 4;
    }

    function albumBrowserActionLabels() {
        const labels = ["Add", "Insert", "Replace", "Rate"];
        if (albumUploadAvailable)
            labels.push("Upload");
        return labels;
    }

    function syncAlbumBrowserSelection() {
        const albums = filteredAlbumBrowserAlbums || [];
        if (albums.length === 0) {
            albumBrowserSelectedId = "";
            albumBrowserActionPromptId = "";
            albumBrowserActionMode = "actions";
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
            if (!actionAlbumVisible) {
                albumBrowserActionPromptId = "";
                albumBrowserActionMode = "actions";
            }
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
        albumBrowserActionMode = "actions";
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
        const count = albumBrowserActionCount();
        albumBrowserActionIndex = (albumBrowserActionIndex + step + count) % count;
    }

    function cacheVersionForMode(mode) {
        const normalized = mode === "latest" ? "latest" : "album";
        return normalizeCacheVersion(albumBrowserCacheVersions[normalized]);
    }

    function setAlbumBrowserCacheVersion(mode, version) {
        const normalized = mode === "latest" ? "latest" : "album";
        const nextCacheVersions = {};
        for (const key in albumBrowserCacheVersions)
            nextCacheVersions[key] = albumBrowserCacheVersions[key];
        nextCacheVersions[normalized] = normalizeCacheVersion(version);
        albumBrowserCacheVersions = nextCacheVersions;
        if (normalized === albumBrowserMode)
            albumBrowserActiveCacheVersion = normalizeCacheVersion(version);
    }

    function queueAlbumBrowserRefresh() {
        if (!albumBrowserViewActive)
            return;

        if (albumBrowserFetcher.running) {
            albumBrowserRefreshQueued = true;
            return;
        }

        albumBrowserRefreshQueued = false;
        loadAlbumBrowser(albumBrowserMode, true);
    }

    function pollClerkCacheStatus() {
        if (!albumBrowserViewActive || albumBrowserStatusFetcher.running || albumBrowserStatusPollInFlight)
            return;

        albumBrowserStatusPollInFlight = true;
        albumBrowserStatusFetcher.command = buildClerkCacheStatusCommand();
        albumBrowserStatusFetcher.running = true;
    }

    function handleClerkCacheStatusLine(line) {
        const trimmed = String(line || "").trim();
        if (trimmed.length === 0)
            return;

        try {
            const payload = JSON.parse(trimmed);
            const nextVersion = normalizeCacheVersion(payload.version);
            if (String(payload.error || "").trim().length > 0 || nextVersion.length === 0)
                return;

            const currentVersion = albumBrowserActiveCacheVersion.length > 0 ? albumBrowserActiveCacheVersion : cacheVersionForMode(albumBrowserMode);
            if (currentVersion.length === 0) {
                queueAlbumBrowserRefresh();
                return;
            }

            if (currentVersion !== nextVersion)
                queueAlbumBrowserRefresh();
        } catch (e) {
        }
    }

    function loadAlbumBrowser(mode, forceRefresh) {
        const normalized = mode === "latest" ? "latest" : "album";
        albumBrowserMode = normalized;

        if (!forceRefresh && albumBrowserCache[normalized] !== undefined) {
            albumBrowserAlbums = albumBrowserCache[normalized] || [];
            albumBrowserActiveCacheVersion = cacheVersionForMode(normalized);
            albumBrowserError = "";
            albumBrowserLoading = false;
            syncAlbumBrowserSelection();
            return;
        }

        albumBrowserLoading = true;
        albumBrowserError = "";
        albumBrowserPendingMode = "";
        albumBrowserRefreshQueued = false;
        albumBrowserFetcher.command = buildAlbumBrowserCommand(normalized);
        if (albumBrowserFetcher.running) {
            albumBrowserPendingMode = normalized;
            albumBrowserFetcher.running = false;
            return;
        }
        albumBrowserFetcher.running = true;
    }

    function syncAlbumBrowserForActiveView(mode) {
        const normalized = mode === "latest" ? "latest" : "album";
        const currentVersion = cacheVersionForMode(normalized);

        albumBrowserMode = normalized;
        albumBrowserActionPromptId = "";
        albumBrowserActionMode = "actions";
        albumBrowserActionIndex = 0;

        if (albumBrowserCache[normalized] !== undefined) {
            albumBrowserAlbums = albumBrowserCache[normalized] || [];
            albumBrowserActiveCacheVersion = currentVersion;
            albumBrowserError = "";
            albumBrowserLoading = false;
            syncAlbumBrowserSelection();

            if (currentVersion.length === 0)
                loadAlbumBrowser(normalized, true);
            else
                Qt.callLater(() => pollClerkCacheStatus());
            return;
        }

        loadAlbumBrowser(normalized, true);
    }

    function setAlbumBrowserMode(mode, forceRefresh) {
        const normalized = mode === "latest" ? "latest" : "album";
        if (forceRefresh)
            loadAlbumBrowser(normalized, true);
        else
            syncAlbumBrowserForActiveView(normalized);
        if (albumBrowserFocusScope)
            albumBrowserFocusScope.forceActiveFocus();
    }

    function cycleAlbumBrowserMode(step) {
        if (step < 0)
            setAlbumBrowserMode(albumBrowserMode === "latest" ? "album" : "latest", false);
        else
            setAlbumBrowserMode(albumBrowserMode === "album" ? "latest" : "album", false);
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

        albumBrowserRequestedOpenMode = normalized;
        albumBrowserMode = normalized;
        showAlbumBrowserRandomMenu = false;
        albumBrowserActionPromptId = "";
        albumBrowserActionMode = "actions";
        albumBrowserActionIndex = 0;
        albumBrowserSearch = "";
        albumBrowserViewActive = true;
        syncAlbumBrowserForActiveView(normalized);

        if (wasVisible && sameMode) {
            albumBrowserRequestedOpenMode = "";
            albumBrowserViewActive = false;
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
        albumBrowserActionMode = "actions";
        albumBrowserActionIndex = 0;
    }

    function runAlbumBrowserAction(actionName) {
        const albumId = String(albumBrowserActionPromptId || albumBrowserSelectedId || "");
        const action = String(actionName || "").trim().toLowerCase();
        const album = albumBrowserEntryById(albumId);
        if (albumId.length === 0 || !album)
            return;

        if (action === "rate") {
            albumBrowserActionMode = "rating";
            albumBrowserActionIndex = Math.max(0, displayedStarCount(album.rating) - 1);
            return;
        }

        if (action === "upload") {
            closePopout();
            runUpload(album);
            return;
        }

        if (["add", "insert", "replace"].indexOf(action) >= 0) {
            closePopout();
            runControl("queue_clerk_album", action + ":" + albumId + ":" + albumBrowserMode);
        }
    }

    function setAlbumBrowserRating(starIndex) {
        const albumId = String(albumBrowserActionPromptId || albumBrowserSelectedId || "");
        const album = albumBrowserEntryById(albumId);
        if (albumId.length === 0 || !album)
            return;
        albumBrowserCache = ({});
        albumBrowserCacheVersions = ({});
        albumBrowserActiveCacheVersion = "";
        closePopout();
        runControl("set_album_rating", albumId + ":" + ratingPayloadForStar(album.rating, starIndex));
    }

    function handleAlbumBrowserKey(event) {
        if (!(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) && event.text && event.text.length > 0 && event.text >= " ") {
            albumBrowserSearch += event.text;
            event.accepted = true;
            return;
        }

        if (event.key === Qt.Key_Escape) {
            if (albumBrowserActionMode === "rating") {
                albumBrowserActionMode = "actions";
                albumBrowserActionIndex = 0;
            } else if (albumBrowserActionPromptId.length > 0)
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

        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            cycleAlbumBrowserMode((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1);
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
                    albumBrowserActionMode = "actions";
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
                    albumBrowserActionMode = "actions";
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
            if (albumBrowserActionPromptId.length > 0) {
                if (albumBrowserActionMode === "rating")
                    setAlbumBrowserRating(albumBrowserActionIndex);
                else
                    runAlbumBrowserAction(albumBrowserActionName(albumBrowserActionIndex));
            }
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
            setAlbumBrowserCacheVersion(mode, payload.cache_version);
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
        albumBrowserMode = defaultMode;
    }

    onSharedPluginIdChanged: runtimeConfig.reload()
    onAlbumBrowserSearchChanged: syncAlbumBrowserSelection()
    onAlbumBrowserAlbumsChanged: syncAlbumBrowserSelection()

    Connections {
        target: runtimeConfig
        function onConfigChanged() {
            if (!root.browserInitialized) {
                root.browserInitialized = true;
                Qt.callLater(() => root.loadAlbumBrowser(root.albumBrowserMode, false));
                return;
            }
            root.albumBrowserCache = ({});
            root.albumBrowserCacheVersions = ({});
            root.albumBrowserActiveCacheVersion = "";
            root.albumBrowserAlbums = [];
            root.albumBrowserSelectedId = "";
            root.albumBrowserActionPromptId = "";
            root.albumBrowserActionMode = "actions";
            root.albumBrowserRefreshQueued = false;
            root.albumBrowserStatusPollInFlight = false;
            root.albumBrowserViewActive = root.pluginPopoutVisible;
            if (root.albumBrowserStatusFetcher.running)
                root.albumBrowserStatusFetcher.running = false;
            if (root.albumBrowserViewActive)
                Qt.callLater(() => root.syncAlbumBrowserForActiveView(root.albumBrowserMode));
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

    Timer {
        id: albumBrowserCachePollTimer

        interval: 5000
        repeat: true
        running: root.albumBrowserViewActive
        onTriggered: root.pollClerkCacheStatus()
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

            if (root.albumBrowserRefreshQueued && root.albumBrowserViewActive) {
                root.albumBrowserRefreshQueued = false;
                Qt.callLater(() => root.pollClerkCacheStatus());
            }
        }
    }

    Process {
        id: albumBrowserStatusFetcher

        running: false

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => root.handleClerkCacheStatusLine(data)
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: _data => {
            }
        }

        onExited: _exitCode => {
            root.albumBrowserStatusPollInFlight = false;
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
                    const wasActive = root.albumBrowserViewActive;
                    root.pluginPopoutVisible = !!(popoutRoot.parentPopout && popoutRoot.parentPopout.shouldBeVisible);
                    root.albumBrowserViewActive = root.pluginPopoutVisible;
                    if (root.pluginPopoutVisible) {
                        root.albumBrowserFocusTimer.restart();
                        if (!wasActive) {
                            const requestedMode = root.albumBrowserRequestedOpenMode.length > 0 ? root.albumBrowserRequestedOpenMode : root.defaultMode;
                            root.albumBrowserRequestedOpenMode = "";
                            Qt.callLater(() => root.syncAlbumBrowserForActiveView(requestedMode));
                        }
                    }
                    if (!root.albumBrowserViewActive) {
                        root.albumBrowserRequestedOpenMode = "";
                        root.showAlbumBrowserRandomMenu = false;
                        root.albumBrowserActionPromptId = "";
                        root.albumBrowserActionMode = "actions";
                        root.albumBrowserActionIndex = 0;
                        root.albumBrowserSearch = "";
                        root.albumBrowserRefreshQueued = false;
                        root.albumBrowserStatusPollInFlight = false;
                        if (root.albumBrowserStatusFetcher.running)
                            root.albumBrowserStatusFetcher.running = false;
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
                                    model: root.albumBrowserActionMode === "rating" ? [1, 2, 3, 4, 5] : root.albumBrowserActionLabels()

                                    Rectangle {
                                        required property var modelData
                                        required property int index
                                        readonly property int actionIndex: index

                                        width: (parent.width - Theme.spacingXS * ((root.albumBrowserActionMode === "rating" ? 5 : root.albumBrowserActionCount()) - 1)) / (root.albumBrowserActionMode === "rating" ? 5 : root.albumBrowserActionCount())
                                        height: 26
                                        radius: 8
                                        color: root.albumBrowserActionIndex === actionIndex ? Theme.primary : "transparent"
                                        border.color: root.albumBrowserActionIndex === actionIndex ? Theme.primary : Theme.outline
                                        border.width: 1

                                        StyledText {
                                            anchors.centerIn: parent
                                            text: root.albumBrowserActionMode === "rating" ? Array(modelData + 1).join("★") : modelData
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: root.albumBrowserActionIndex === actionIndex ? Theme.background : Theme.surfaceText
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                root.albumBrowserActionIndex = actionIndex;
                                                if (root.albumBrowserActionMode === "rating")
                                                    root.setAlbumBrowserRating(actionIndex);
                                                else
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
                                            width: parent.width - 92
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
                                                text: modelData.date || modelData.year || ""
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                elide: Text.ElideRight
                                            }
                                        }

                                        StyledText {
                                            width: 68
                                            anchors.verticalCenter: parent.verticalCenter
                                            horizontalAlignment: Text.AlignRight
                                            text: root.displayedStarCount(modelData.rating) > 0 ? root.starText(modelData.rating) : ""
                                            font.pixelSize: Theme.fontSizeSmall
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
