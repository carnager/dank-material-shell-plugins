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
    property bool showAlbumBrowserRandomMenu: false
    property bool albumBrowserLoading: false
    property string albumBrowserMode: "album"
    property string albumBrowserPendingMode: ""
    property string albumBrowserSearch: ""
    property string albumBrowserError: ""
    property string albumBrowserSelectedId: ""
    property string albumBrowserActionPromptId: ""
    property int albumBrowserActionIndex: 0
    property var albumBrowserAlbums: []
    property var albumBrowserCache: ({})
    property bool pluginPopoutVisible: false
    property bool suppressNextPillClick: false
    property string queuedPopoutMode: ""
    property string popoutMode: "track"
    property var albumBrowserFocusScope: null
    property var albumBrowserListViewRef: null
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

    function buildAlbumBrowserCommand(mode) {
        const args = ["python3", watcherScriptPath, "--host", host.length > 0 ? host : "localhost", "--port", port.length > 0 ? port : "6600", "--action", "dump_albums", "--arg", mode === "latest" ? "latest" : "album"];
        if (password.length > 0)
            args.push("--password", password);
        if (clerkApiBaseUrl.length > 0)
            args.push("--clerk-api-base-url", clerkApiBaseUrl);
        return args;
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

    function setAlbumBrowserMode(mode, forceRefresh) {
        const normalized = mode === "latest" ? "latest" : "album";
        albumBrowserMode = normalized;
        albumBrowserActionPromptId = "";
        albumBrowserActionIndex = 0;
        loadAlbumBrowser(normalized, !!forceRefresh);
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

    function triggerFrameworkPopout() {
        const savedClickAction = pillClickAction;
        pillClickAction = null;
        triggerPopout();
        pillClickAction = savedClickAction;
    }

    function openManagedPopout(mode) {
        const normalized = mode === "browser" ? "browser" : "track";
        popoutMode = normalized;
        if (normalized === "browser") {
            showAlbumBrowserRandomMenu = false;
            albumBrowserActionPromptId = "";
            albumBrowserActionIndex = 0;
            albumBrowserSearch = "";
            loadAlbumBrowser(albumBrowserMode, false);
        }

        Qt.callLater(() => {
            triggerFrameworkPopout();
            if (normalized === "browser")
                albumBrowserFocusTimer.restart();
        });
    }

    function toggleManagedPopout(mode) {
        const normalized = mode === "browser" ? "browser" : "track";
        if (pluginPopoutVisible && popoutMode === normalized) {
            queuedPopoutMode = "";
            if (normalized === "browser")
                dismissAlbumBrowserPopout();
            else
                closePopout();
            return;
        }

        if (pluginPopoutVisible) {
            queuedPopoutMode = normalized;
            if (popoutMode === "browser")
                dismissAlbumBrowserPopout();
            else
                closePopout();
            return;
        }

        queuedPopoutMode = "";
        openManagedPopout(normalized);
    }

    function showAlbumBrowserPopout() {
        toggleManagedPopout("browser");
    }

    function promptAlbumBrowserActions(albumId) {
        const id = String(albumId || "");
        if (id.length === 0)
            return;
        albumBrowserSelectedId = id;
        albumBrowserActionPromptId = id;
        albumBrowserActionIndex = 0;
    }

    function dismissAlbumBrowserPopout() {
        showAlbumBrowserRandomMenu = false;
        if (albumBrowserFocusScope)
            albumBrowserFocusScope.forceActiveFocus();
        albumBrowserCloseTimer.restart();
    }

    function runAlbumBrowserAction(actionName) {
        const albumId = String(albumBrowserActionPromptId || albumBrowserSelectedId || "");
        const action = String(actionName || "").trim().toLowerCase();
        if (albumId.length === 0 || ["add", "insert", "replace"].indexOf(action) < 0)
            return;
        dismissAlbumBrowserPopout();
        runControl("queue_clerk_album", action + ":" + albumId + ":" + albumBrowserMode);
    }

    function handleAlbumBrowserKey(event) {
        if (popoutMode !== "browser") {
            event.accepted = false;
            return;
        }

        if (!(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) && event.text && event.text.length > 0 && event.text >= " ") {
            albumBrowserSearch += event.text;
            event.accepted = true;
            return;
        }

        if (event.key === Qt.Key_Escape) {
            if (albumBrowserActionPromptId.length > 0)
                albumBrowserActionPromptId = "";
            else
                dismissAlbumBrowserPopout();
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
    pillClickAction: function () {
        if (root.suppressNextPillClick) {
            root.suppressNextPillClick = false;
            return;
        }
        root.toggleManagedPopout("track");
    }

    Component.onCompleted: {
        updateFormattedText();
        startWatcher();
    }

    onPluginDataChanged: {
        updateFormattedText();
        if (watcher.running || connected || errorText.length > 0)
            root.restartWatcher();
    }
    onAlbumBrowserSearchChanged: root.syncAlbumBrowserSelection()
    onAlbumBrowserAlbumsChanged: root.syncAlbumBrowserSelection()

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

    Timer {
        id: albumBrowserFocusTimer

        interval: 100
        repeat: false
        onTriggered: {
            if (root.popoutMode === "browser" && root.albumBrowserFocusScope)
                root.albumBrowserFocusScope.forceActiveFocus();
        }
    }

    Timer {
        id: albumBrowserCloseTimer

        interval: 100
        repeat: false
        onTriggered: root.closePopout()
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
        Item {
            id: pillRoot

            readonly property int browserButtonWidth: 20
            readonly property int controlsWidth: browserButtonWidth + Theme.spacingXS + 20 + 2 + 24 + 2 + 20
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

                Rectangle {
                    width: pillRoot.browserButtonWidth
                    height: 20
                    radius: 10
                    color: albumBrowserButtonArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18) : albumBrowserButtonArea.containsMouse || root.popoutMode === "browser" ? Theme.widgetBaseHoverColor : "transparent"
                    opacity: root.connected ? 1 : 0.75
                    anchors.verticalCenter: parent.verticalCenter

                    DankIcon {
                        anchors.centerIn: parent
                        name: root.albumBrowserMode === "latest" ? "schedule" : "library_music"
                        size: 12
                        color: root.popoutMode === "browser" ? Theme.primary : Theme.widgetTextColor
                    }

                                MouseArea {
                                    id: albumBrowserButtonArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    preventStealing: true
                                    cursorShape: Qt.PointingHandCursor
                                    onPressed: mouse => {
                                        mouse.accepted = true;
                                        root.suppressNextPillClick = true;
                                        root.albumBrowserMode = mouse.button === Qt.RightButton ? "latest" : "album";
                                        root.showAlbumBrowserPopout();
                                    }
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
            implicitHeight: root.popoutMode === "browser" ? 420 : 460

            Connections {
                target: popoutRoot.parentPopout
                function onShouldBeVisibleChanged() {
                    root.pluginPopoutVisible = !!(popoutRoot.parentPopout && popoutRoot.parentPopout.shouldBeVisible);
                    if (!popoutRoot.parentPopout)
                        return;
                    if (popoutRoot.parentPopout.shouldBeVisible)
                        return;
                    root.suppressNextPillClick = false;
                    root.showAlbumBrowserRandomMenu = false;
                    root.albumBrowserActionPromptId = "";
                    root.albumBrowserActionIndex = 0;
                    root.albumBrowserSearch = "";
                    if (root.queuedPopoutMode.length > 0) {
                        const nextMode = root.queuedPopoutMode;
                        root.queuedPopoutMode = "";
                        Qt.callLater(() => root.openManagedPopout(nextMode));
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

                visible: root.popoutMode === "browser"
                anchors.fill: parent
                anchors.margins: Theme.spacingM
                focus: visible
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

            Item {
                id: contentArea
                visible: root.popoutMode !== "browser"

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
