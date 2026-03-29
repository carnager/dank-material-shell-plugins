import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginComponent {
    id: root

    pluginId: "publicTransport"
    popoutWidth: 1020
    popoutHeight: 780

    property string apiBaseUrl: "https://api.transitous.org"
    property string favoritesSpec: ""
    property string defaultFromSpec: ""
    property string defaultToSpec: ""
    property string activeTab: "journeys"
    property var favoriteStations: []
    property var selectedStation: null
    property var departures: []
    property var searchResults: []
    property var journeys: []
    property string favoriteError: ""
    property string departureError: ""
    property string searchError: ""
    property string journeyError: ""
    property bool favoritesLoading: false
    property bool departuresLoading: false
    property bool searchLoading: false
    property bool journeysLoading: false
    property string searchTarget: "from"
    property string favoriteSearchText: ""
    property string journeySearchTarget: ""
    property bool suppressJourneySuggest: false
    property string fromText: ""
    property string fromId: ""
    property string toText: ""
    property string toId: ""
    property bool pluginPopoutVisible: false
    property string expandedJourneyKey: ""
    readonly property string fetchScriptPath: {
        const url = Qt.resolvedUrl("transport_fetch.py").toString();
        return url.startsWith("file://") ? url.substring(7) : url;
    }
    function loadSettings() {
        apiBaseUrl = normalizeBaseUrl(loadPluginValue("apiBaseUrl", "https://api.transitous.org"));
        favoritesSpec = String(loadPluginValue("favorites", ""));
        defaultFromSpec = String(loadPluginValue("defaultFromStop", ""));
        defaultToSpec = String(loadPluginValue("defaultToStop", ""));

        const fromPreset = parseStationSpec(defaultFromSpec);
        if (fromText.length === 0) {
            fromText = fromPreset.label.length > 0 ? fromPreset.label : fromPreset.raw;
            fromId = fromPreset.id;
        }

        const toPreset = parseStationSpec(defaultToSpec);
        if (toText.length === 0) {
            toText = toPreset.label.length > 0 ? toPreset.label : toPreset.raw;
            toId = toPreset.id;
        }
    }

    function normalizeBaseUrl(value) {
        let normalized = String(value || "").trim();
        while (normalized.endsWith("/"))normalized = normalized.slice(0, -1)
        if (normalized === "https://v6.db.transport.rest")
            return "https://api.transitous.org";
        return normalized.length > 0 ? normalized : "https://api.transitous.org";
    }

    function loadPluginValue(key, fallback) {
        const data = root.pluginData || ({
        });
        if (data[key] !== undefined)
            return data[key];

        if (root.pluginService && root.pluginService.loadPluginData)
            return root.pluginService.loadPluginData(root.pluginId, key, fallback);

        if (typeof PluginService !== "undefined" && PluginService.loadPluginData)
            return PluginService.loadPluginData(root.pluginId, key, fallback);

        return fallback;
    }

    function savePluginValue(key, value) {
        if (root.pluginService && root.pluginService.savePluginData) {
            root.pluginService.savePluginData(root.pluginId, key, value);
            return true;
        }

        if (typeof PluginService !== "undefined" && PluginService.savePluginData) {
            PluginService.savePluginData(root.pluginId, key, value);
            return true;
        }

        return false;
    }

    function parseStationSpec(value) {
        const raw = String(value || "").trim();
        if (raw.length === 0)
            return { "raw": "", "label": "", "id": "" };
        const separator = raw.lastIndexOf("|");
        if (separator < 0)
            return { "raw": raw, "label": "", "id": "" };
        return {
            "raw": raw,
            "label": raw.slice(0, separator).trim(),
            "id": raw.slice(separator + 1).trim()
        };
    }

    function runFetcher(process, args) {
        process.command = ["python3", fetchScriptPath, apiBaseUrl].concat(args);
        process.running = true;
    }

    function serializeFavorites(stations) {
        const items = [];
        const entries = stations || [];
        for (let i = 0; i < entries.length; ++i) {
            const entry = entries[i];
            const stationId = String(entry && entry.id || "").trim();
            if (stationId.length === 0)
                continue;
            const stationName = String(entry && (entry.name || entry.displayName) || stationId).trim();
            items.push(stationName + "|" + stationId);
        }
        return items.join("; ");
    }

    function fallbackFavoriteStations() {
        const specs = String(favoritesSpec || "").split(/[;\n]+/);
        const items = [];
        const seenIds = ({
        });
        for (let i = 0; i < specs.length; ++i) {
            const parsed = parseStationSpec(specs[i]);
            const raw = String(parsed.raw || "").trim();
            const stationId = String(parsed.id || "").trim();
            const name = String(parsed.label || raw || stationId).trim();
            const resolvedId = stationId.length > 0 ? stationId : raw;
            if (resolvedId.length === 0 || seenIds[resolvedId])
                continue;
            seenIds[resolvedId] = true;
            items.push({
                "id": resolvedId,
                "name": name.length > 0 ? name : resolvedId,
                "displayName": name.length > 0 ? name : resolvedId
            });
        }
        return items;
    }

    function refreshFavorites() {
        if (favoritesFetcher.running)
            return;
        loadSettings();
        favoritesLoading = true;
        favoriteError = "";
        runFetcher(favoritesFetcher, ["favorites", favoritesSpec]);
    }

    function chooseFavorite(station) {
        selectedStation = station || null;
        departures = [];
        departureError = "";
        if (!selectedStation || !selectedStation.id)
            return;
        refreshDepartures(selectedStation.id, selectedStation.name || "");
    }

    function addFavorite(station) {
        if (!station || !station.id)
            return;

        for (let i = 0; i < favoriteStations.length; ++i) {
            if (String(favoriteStations[i].id || "") === String(station.id || "")) {
                chooseFavorite(favoriteStations[i]);
                favoriteSearchText = "";
                clearSearchResults();
                return;
            }
        }

        favoriteStations = favoriteStations.concat([{
                    "id": String(station.id || ""),
                    "name": String(station.name || station.displayName || station.id || ""),
                    "displayName": String(station.displayName || station.name || station.id || "")
                }]);
        favoritesSpec = serializeFavorites(favoriteStations);
        savePluginValue("favorites", favoritesSpec);
        favoriteSearchText = "";
        clearSearchResults();
        favoriteError = "";
        chooseFavorite(favoriteStations[favoriteStations.length - 1]);
    }

    function removeFavorite(stationId) {
        const target = String(stationId || "").trim();
        if (target.length === 0)
            return;

        const nextFavorites = [];
        for (let i = 0; i < favoriteStations.length; ++i) {
            if (String(favoriteStations[i].id || "") !== target)
                nextFavorites.push(favoriteStations[i]);

        }
        favoriteStations = nextFavorites;
        favoritesSpec = serializeFavorites(favoriteStations);
        savePluginValue("favorites", favoritesSpec);

        if (selectedStation && String(selectedStation.id || "") === target) {
            selectedStation = favoriteStations.length > 0 ? favoriteStations[0] : null;
            if (selectedStation)
                refreshDepartures(selectedStation.id, selectedStation.name || "");
            else
                departures = [];
        }
    }

    function refreshDepartures(stationSpec, stationName) {
        if (departuresFetcher.running)
            return;
        departuresLoading = true;
        departureError = "";
        if (stationName && (!selectedStation || selectedStation.id !== stationSpec))
            selectedStation = { "id": stationSpec, "name": stationName, "displayName": stationName };
        runFetcher(departuresFetcher, ["departures", stationSpec]);
    }

    function startStationSearch(target) {
        const normalizedTarget = target === "to" ? "to" : "from";
        const query = normalizedTarget === "to" ? String(toText || "").trim() : String(fromText || "").trim();
        if (query.length === 0) {
            searchResults = [];
            searchError = "Gib zuerst einen Stationsnamen ein.";
            return;
        }
        if (searchFetcher.running)
            return;
        searchTarget = normalizedTarget;
        searchResults = [];
        searchError = "";
        searchLoading = true;
        runFetcher(searchFetcher, ["locations", query]);
    }

    function startFavoriteSearch() {
        const query = String(favoriteSearchText || "").trim();
        if (query.length === 0) {
            searchResults = [];
            searchError = "Gib einen Stationsnamen fuer die Suche ein.";
            return;
        }
        if (searchFetcher.running)
            return;
        searchTarget = "favorite";
        searchResults = [];
        searchError = "";
        searchLoading = true;
        runFetcher(searchFetcher, ["locations", query]);
    }

    function applySearchResult(entry) {
        if (!entry)
            return;
        suppressJourneySuggest = true;
        if (searchTarget === "favorite") {
            addFavorite(entry);
        } else if (searchTarget === "to") {
            toText = String(entry.name || "");
            toId = String(entry.id || "");
        } else {
            fromText = String(entry.name || "");
            fromId = String(entry.id || "");
        }
        searchResults = [];
        searchError = "";
        suppressJourneySuggest = false;
    }

    function clearSearchResults() {
        searchResults = [];
        searchError = "";
    }

    function setJourneyEndpoint(target, stationName, stationId) {
        suppressJourneySuggest = true;
        journeyStationSearchTimer.stop();
        if (target === "to") {
            toText = String(stationName || "");
            toId = String(stationId || "");
        } else {
            fromText = String(stationName || "");
            fromId = String(stationId || "");
        }
        clearSearchResults();
        suppressJourneySuggest = false;
    }

    function useSelectedStationAs(target) {
        if (!selectedStation || !selectedStation.id)
            return;
        setJourneyEndpoint(target, selectedStation.name || "", selectedStation.id || "");
        activeTab = "journeys";
    }

    function useFavoriteForJourney(target, station) {
        if (!station || !station.id)
            return;
        setJourneyEndpoint(target, station.name || "", station.id || "");
    }

    function swapJourneyEndpoints() {
        const nextFromText = fromText;
        const nextFromId = fromId;
        fromText = toText;
        fromId = toId;
        toText = nextFromText;
        toId = nextFromId;
    }

    function searchJourneys() {
        const fromValue = fromId.length > 0 ? fromId : String(fromText || "").trim();
        const toValue = toId.length > 0 ? toId : String(toText || "").trim();
        if (fromValue.length === 0 || toValue.length === 0) {
            journeyError = "Setze vor der Suche sowohl Start als auch Ziel.";
            journeys = [];
            return;
        }
        if (journeysFetcher.running)
            return;
        journeysLoading = true;
        journeyError = "";
        journeys = [];
        expandedJourneyKey = "";
        runFetcher(journeysFetcher, ["journeys", fromValue, toValue]);
    }

    function scheduleJourneyStationSearch(target, query) {
        const normalizedTarget = target === "to" ? "to" : "from";
        const trimmed = String(query || "").trim();
        if (trimmed.length < 2) {
            if (searchTarget === normalizedTarget)
                clearSearchResults();
            return;
        }
        journeySearchTarget = normalizedTarget;
        journeyStationSearchTimer.restart();
    }

    function minutesLabel(value) {
        if (value === null || value === undefined || value === "")
            return "";
        const number = parseInt(String(value), 10);
        if (isNaN(number))
            return "";
        if (number <= 0)
            return "jetzt";
        return "in " + number + " Min";
    }

    function durationLabel(value) {
        const total = parseInt(String(value), 10);
        if (isNaN(total) || total <= 0)
            return "";
        const hours = Math.floor(total / 60);
        const minutes = total % 60;
        if (hours <= 0)
            return minutes + " min";
        if (minutes === 0)
            return hours + " h";
        return hours + " h " + minutes + " min";
    }

    function parsePayload(raw, fallbackMessage) {
        const trimmed = String(raw || "").trim();
        if (!trimmed || trimmed[0] !== "{")
            return { "ok": false, "message": fallbackMessage };
        try {
            const payload = JSON.parse(trimmed);
            if (payload.error)
                return { "ok": false, "message": String(payload.error) };
            return { "ok": true, "payload": payload };
        } catch (e) {
            return { "ok": false, "message": fallbackMessage };
        }
    }

    function journeyKey(index, journey) {
        return String(index) + "|" + String(journey && journey.departure || "") + "|" + String(journey && journey.arrival || "");
    }

    function toggleJourneyExpanded(index, journey) {
        const key = journeyKey(index, journey);
        expandedJourneyKey = expandedJourneyKey === key ? "" : key;
    }

    function isJourneyExpanded(index, journey) {
        return expandedJourneyKey === journeyKey(index, journey);
    }

    function expandedJourneyData() {
        for (let i = 0; i < journeys.length; ++i) {
            const journey = journeys[i];
            if (expandedJourneyKey === journeyKey(i, journey))
                return journey;
        }
        return null;
    }

    function lineSummaryText(summaryLines) {
        const items = Array.isArray(summaryLines) ? summaryLines : [];
        if (items.length === 0)
            return "";
        if (items.length <= 3)
            return items.join(" • ");
        return items.slice(0, 3).join(" • ") + " +" + String(items.length - 3);
    }

    function stopoverTimeText(stopover) {
        const arrivalText = String(stopover && stopover.arrivalText || "");
        const departureText = String(stopover && stopover.departureText || "");
        if (arrivalText.length > 0 && departureText.length > 0 && arrivalText !== departureText)
            return arrivalText + " / " + departureText;
        return arrivalText.length > 0 ? arrivalText : departureText;
    }

    function journeyDetailsText(journey) {
        const legs = Array.isArray(journey && journey.legs) ? journey.legs : [];
        const sections = [];
        for (let i = 0; i < legs.length; ++i) {
            const leg = legs[i] || {};
            const headline = [
                [String(leg.departureText || ""), "->", String(leg.arrivalText || "")].join(" ").trim(),
                [
                    String(leg.line || ""),
                    String(leg.product || ""),
                    leg.platform ? "Gl. " + String(leg.platform) : ""
                ].filter(part => part.length > 0).join(" • ")
            ].filter(part => part.length > 0).join("    ");
            const route = [
                [String(leg.origin || ""), String(leg.destination || "")].filter(part => part.length > 0).join(" -> "),
                [
                    leg.direction ? "Richtung " + String(leg.direction) : "",
                    String(leg.operator || "")
                ].filter(part => part.length > 0).join(" • ")
            ].filter(part => part.length > 0).join("    ");
            const lines = [headline, route].filter(part => part.length > 0);
            const stopovers = Array.isArray(leg.stopovers) ? leg.stopovers : [];
            for (let j = 0; j < stopovers.length; ++j) {
                const stopover = stopovers[j] || {};
                const stopLine = [stopoverTimeText(stopover), String(stopover.name || "")].filter(part => part.length > 0).join("  ");
                if (stopLine.length > 0)
                    lines.push("  • " + stopLine);
            }
            if (lines.length > 0)
                sections.push(lines.join("\n"));
        }
        return sections.join("\n\n");
    }

    Component.onCompleted: {
        loadSettings();
        refreshFavorites();
    }

    onPluginDataChanged: {
        loadSettings();
        refreshFavorites();
    }

    ccWidgetIcon: "directions_transit"
    ccWidgetPrimaryText: "Nahverkehr"
    ccWidgetSecondaryText: ""
    ccWidgetIsActive: departuresLoading || journeysLoading

    Process {
        id: favoritesFetcher

        running: false

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const result = root.parsePayload(data, "Favoriten konnten nicht geladen werden.");
                root.favoritesLoading = false;
                if (!result.ok) {
                    root.favoriteError = result.message;
                    root.favoriteStations = root.fallbackFavoriteStations();
                    if (!root.selectedStation && root.favoriteStations.length > 0)
                        root.selectedStation = root.favoriteStations[0];
                    return;
                }
                root.favoriteStations = Array.isArray(result.payload.favorites) ? result.payload.favorites : [];
                if (root.favoriteStations.length === 0 && String(root.favoritesSpec || "").trim().length > 0)
                    root.favoriteStations = root.fallbackFavoriteStations();
                const unresolved = Array.isArray(result.payload.unresolved) ? result.payload.unresolved : [];
                root.favoriteError = unresolved.length > 0 ? "Konnte nicht aufloesen: " + unresolved.join(", ") : "";
                if (!root.selectedStation && root.favoriteStations.length > 0)
                    root.chooseFavorite(root.favoriteStations[0]);
                else if (root.selectedStation) {
                    for (let i = 0; i < root.favoriteStations.length; ++i) {
                        if (String(root.favoriteStations[i].id || "") === String(root.selectedStation.id || "")) {
                            root.selectedStation = root.favoriteStations[i];
                            return;
                        }
                    }
                }
            }
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const text = String(data || "").trim();
                if (text.length > 0) {
                    root.favoriteError = text;
                    if (root.favoriteStations.length === 0)
                        root.favoriteStations = root.fallbackFavoriteStations();
                }
            }
        }

        onExited: exitCode => {
            root.favoritesLoading = false;
            if (exitCode !== 0 && root.favoriteError.length === 0)
                root.favoriteError = "Favoriten konnten nicht aufgeloest werden.";
        }
    }

    Process {
        id: departuresFetcher

        running: false

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const result = root.parsePayload(data, "Abfahrten konnten nicht geladen werden.");
                root.departuresLoading = false;
                if (!result.ok) {
                    root.departureError = result.message;
                    root.departures = [];
                    return;
                }
                root.departures = Array.isArray(result.payload.departures) ? result.payload.departures : [];
                if (result.payload.station)
                    root.selectedStation = result.payload.station;
            }
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const text = String(data || "").trim();
                if (text.length > 0)
                    root.departureError = text;
            }
        }

        onExited: exitCode => {
            root.departuresLoading = false;
            if (exitCode !== 0 && root.departureError.length === 0)
                root.departureError = "Abfrage der Abfahrten fehlgeschlagen.";
        }
    }

    Process {
        id: searchFetcher

        running: false

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const result = root.parsePayload(data, "Stationssuche fehlgeschlagen.");
                root.searchLoading = false;
                if (!result.ok) {
                    root.searchError = result.message;
                    root.searchResults = [];
                    return;
                }
                root.searchResults = Array.isArray(result.payload.locations) ? result.payload.locations : [];
                if (root.searchResults.length === 0)
                    root.searchError = "Keine passenden Stationen gefunden.";
            }
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const text = String(data || "").trim();
                if (text.length > 0)
                    root.searchError = text;
            }
        }

        onExited: exitCode => {
            root.searchLoading = false;
            if (exitCode !== 0 && root.searchError.length === 0)
                root.searchError = "Stationssuche fehlgeschlagen.";
        }
    }

    Process {
        id: journeysFetcher

        running: false

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const result = root.parsePayload(data, "Verbindungen konnten nicht geladen werden.");
                root.journeysLoading = false;
                if (!result.ok) {
                    root.journeyError = result.message;
                    root.journeys = [];
                    return;
                }
                root.journeys = Array.isArray(result.payload.journeys) ? result.payload.journeys : [];
                if (result.payload.from) {
                    if (root.fromId.length === 0 || root.fromText.length === 0)
                        root.fromText = String(result.payload.from.name || root.fromText);
                    root.fromId = String(result.payload.from.id || root.fromId);
                }
                if (result.payload.to) {
                    if (root.toId.length === 0 || root.toText.length === 0)
                        root.toText = String(result.payload.to.name || root.toText);
                    root.toId = String(result.payload.to.id || root.toId);
                }
                if (root.journeys.length === 0)
                    root.journeyError = "Keine Verbindungen gefunden.";
            }
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const text = String(data || "").trim();
                if (text.length > 0)
                    root.journeyError = text;
            }
        }

        onExited: exitCode => {
            root.journeysLoading = false;
            if (exitCode !== 0 && root.journeyError.length === 0)
                root.journeyError = "Verbindungssuche fehlgeschlagen.";
        }
    }

    Timer {
        id: journeyStationSearchTimer

        interval: 220
        repeat: false
        onTriggered: {
            if (root.journeySearchTarget === "to")
                root.startStationSearch("to");
            else
                root.startStationSearch("from");
        }
    }

    horizontalBarPill: Component {
        Rectangle {
            width: 22
            height: 22
            radius: 11
            color: pillArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18) : pillArea.containsMouse || root.pluginPopoutVisible ? Theme.widgetBaseHoverColor : "transparent"

            DankIcon {
                anchors.centerIn: parent
                name: "directions_transit"
                size: 14
                color: root.pluginPopoutVisible ? Theme.primary : Theme.widgetIconColor
            }

            MouseArea {
                id: pillArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onPressed: mouse => {
                    root.activeTab = mouse.button === Qt.RightButton ? "departures" : "journeys";
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
                name: "directions_transit"
                size: Math.max(14, Theme.barIconSize(root.barThickness) - 4)
                color: root.pluginPopoutVisible ? Theme.primary : Theme.widgetIconColor
            }
        }
    }

    popoutContent: Component {
        Item {
            id: popoutRoot
            property var parentPopout: null

            implicitWidth: root.popoutWidth
            implicitHeight: root.popoutHeight

            Connections {
                target: popoutRoot.parentPopout
                function onShouldBeVisibleChanged() {
                    root.pluginPopoutVisible = !!(popoutRoot.parentPopout && popoutRoot.parentPopout.shouldBeVisible);
                    if (root.pluginPopoutVisible) {
                        root.loadSettings();
                        root.refreshFavorites();
                    } else {
                        root.journeyStationSearchTimer.stop();
                        root.journeySearchTarget = "";
                        root.clearSearchResults();
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

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingS

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingS

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 34
                        radius: 10
                        color: Theme.surfaceContainerHigh

                        Row {
                            anchors.fill: parent
                            anchors.margins: 4
                            spacing: 4

                            Repeater {
                                model: [
                                    { "id": "departures", "label": "Abfahrten" },
                                    { "id": "journeys", "label": "Verbindungen" }
                                ]

                                Rectangle {
                                    required property var modelData

                                    width: (parent.width - 4) / 2
                                    height: parent.height
                                    radius: 8
                                    color: root.activeTab === modelData.id ? Theme.primary : "transparent"

                                    StyledText {
                                        anchors.centerIn: parent
                                        text: modelData.label
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: root.activeTab === modelData.id ? Theme.background : Theme.surfaceText
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.activeTab = modelData.id
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        width: 34
                        height: 34
                        radius: 10
                        color: refreshArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainerHigh

                        DankIcon {
                            anchors.centerIn: parent
                            name: "refresh"
                            size: 18
                            color: Theme.surfaceText
                        }

                        MouseArea {
                            id: refreshArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.refreshFavorites();
                                if (root.selectedStation && root.selectedStation.id)
                                    root.refreshDepartures(root.selectedStation.id, root.selectedStation.name || "");
                            }
                        }
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    Item {
                        id: departuresTab
                        anchors.fill: parent
                        visible: root.activeTab === "departures"
                        clip: true
                        property int sidebarWidth: 340

                        Rectangle {
                            id: departuresSidebar
                            x: 0
                            y: 0
                            width: parent.width < 760 ? Math.max(280, Math.floor(parent.width * 0.36)) : departuresTab.sidebarWidth
                            height: parent.height
                            radius: 12
                            color: Theme.surfaceContainerHigh
                            border.color: Theme.outline
                            border.width: 1

                            Item {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS

                                Column {
                                    id: departuresSidebarHeader
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    spacing: Theme.spacingS

                                    StyledText {
                                        width: parent.width
                                        text: "Favorisierte Stationen"
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                    }

                                    Item {
                                        width: parent.width
                                        height: 36

                                        Rectangle {
                                            anchors.left: parent.left
                                            anchors.top: parent.top
                                            anchors.bottom: parent.bottom
                                            anchors.right: addFavoriteButton.left
                                            anchors.rightMargin: Theme.spacingS
                                            radius: 10
                                            color: Theme.surfaceContainer
                                            border.color: favoriteSearchInput.activeFocus ? Theme.primary : Theme.outline
                                            border.width: 1

                                            Item {
                                                anchors.fill: parent
                                                anchors.leftMargin: Theme.spacingS
                                                anchors.rightMargin: Theme.spacingS

                                                StyledText {
                                                    anchors.fill: parent
                                                    verticalAlignment: Text.AlignVCenter
                                                    text: root.favoriteSearchText.length > 0 ? root.favoriteSearchText : "Station zum Hinzufuegen suchen"
                                                    color: root.favoriteSearchText.length > 0 ? Theme.surfaceText : Theme.surfaceVariantText
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    visible: !favoriteSearchInput.activeFocus
                                                    elide: Text.ElideRight
                                                }

                                                TextInput {
                                                    id: favoriteSearchInput
                                                    anchors.fill: parent
                                                    text: root.favoriteSearchText
                                                    color: activeFocus ? Theme.surfaceText : "transparent"
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    verticalAlignment: TextInput.AlignVCenter
                                                    cursorVisible: activeFocus
                                                    selectionColor: Theme.primary
                                                    selectedTextColor: Theme.background
                                                    onTextChanged: {
                                                        root.favoriteSearchText = text;
                                                        if (root.searchTarget === "favorite")
                                                            root.clearSearchResults();
                                                    }
                                                    onAccepted: root.startFavoriteSearch()
                                                }
                                            }
                                        }

                                        Rectangle {
                                            id: addFavoriteButton
                                            anchors.top: parent.top
                                            anchors.bottom: parent.bottom
                                            anchors.right: parent.right
                                            width: 76
                                            radius: 10
                                            color: addFavoriteSearchArea.containsMouse ? Theme.primaryHover : Theme.primary

                                            StyledText {
                                                anchors.centerIn: parent
                                                text: "Suchen"
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.background
                                            }

                                            MouseArea {
                                                id: addFavoriteSearchArea
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.startFavoriteSearch()
                                            }
                                        }
                                    }

                                    StyledText {
                                        width: parent.width
                                        visible: root.favoriteError.length > 0 || (root.searchTarget === "favorite" && (root.searchLoading || root.searchError.length > 0))
                                        text: root.searchTarget === "favorite" && root.searchLoading ? "Stationen werden gesucht..." : root.searchTarget === "favorite" && root.searchError.length > 0 ? root.searchError : root.favoriteError
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: root.searchTarget === "favorite" && root.searchError.length === 0 ? Theme.surfaceVariantText : Theme.error
                                        wrapMode: Text.WordWrap
                                    }

                                    Rectangle {
                                        width: parent.width
                                        height: root.searchTarget === "favorite" && root.searchResults.length > 0 ? Math.min(140, favoriteSearchResultsList.contentHeight + Theme.spacingXS * 2) : 0
                                        visible: height > 0
                                        radius: 10
                                        color: Theme.surfaceContainer
                                        border.color: Theme.outline
                                        border.width: 1

                                        ListView {
                                            id: favoriteSearchResultsList
                                            anchors.fill: parent
                                            anchors.margins: Theme.spacingXS
                                            clip: true
                                            spacing: 4
                                            model: root.searchTarget === "favorite" ? root.searchResults : []

                                            delegate: Rectangle {
                                                required property var modelData
                                                width: ListView.view.width
                                                height: 32
                                                radius: 8
                                                color: favoriteSearchResultArea.containsMouse ? Theme.widgetBaseHoverColor : "transparent"

                                                StyledText {
                                                    anchors.left: parent.left
                                                    anchors.right: addFavoriteResultButton.left
                                                    anchors.leftMargin: Theme.spacingS
                                                    anchors.rightMargin: Theme.spacingS
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: String(modelData.name || "")
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    color: Theme.surfaceText
                                                    elide: Text.ElideRight
                                                }

                                                Rectangle {
                                                    id: addFavoriteResultButton
                                                    anchors.right: parent.right
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    anchors.rightMargin: Theme.spacingS
                                                    width: 28
                                                    height: 28
                                                    radius: 8
                                                    color: addFavoriteResultArea.containsMouse ? Theme.primary : Theme.surfaceContainerHigh

                                                    DankIcon {
                                                        anchors.centerIn: parent
                                                        name: "add"
                                                        size: 16
                                                        color: addFavoriteResultArea.containsMouse ? Theme.background : Theme.surfaceText
                                                    }

                                                    MouseArea {
                                                        id: addFavoriteResultArea
                                                        anchors.fill: parent
                                                        hoverEnabled: true
                                                        cursorShape: Qt.PointingHandCursor
                                                        onClicked: root.addFavorite(modelData)
                                                    }
                                                }

                                                MouseArea {
                                                    id: favoriteSearchResultArea
                                                    anchors.fill: parent
                                                    anchors.rightMargin: 40
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.addFavorite(modelData)
                                                }
                                            }
                                        }
                                    }

                                    StyledText {
                                        width: parent.width
                                        visible: root.favoritesLoading
                                        text: "Favoriten werden aufgeloest..."
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }

                                    StyledText {
                                        width: parent.width
                                        visible: !root.favoritesLoading && root.favoriteStations.length === 0
                                        text: "Keine Favoriten konfiguriert."
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        wrapMode: Text.WordWrap
                                    }
                                }

                                ListView {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: departuresSidebarHeader.bottom
                                    anchors.topMargin: Theme.spacingS
                                    anchors.bottom: parent.bottom
                                    clip: true
                                    spacing: 4
                                    model: root.favoriteStations
                                    visible: root.favoriteStations.length > 0

                                    delegate: Rectangle {
                                        required property var modelData
                                        width: ListView.view.width
                                        height: 34
                                        radius: 10
                                        color: String(root.selectedStation && root.selectedStation.id || "") === String(modelData.id || "") ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.16) : favoriteArea.containsMouse ? Theme.widgetBaseHoverColor : "transparent"

                                        StyledText {
                                            anchors.left: parent.left
                                            anchors.right: favoriteJourneyButtons.left
                                            anchors.leftMargin: Theme.spacingS
                                            anchors.rightMargin: Theme.spacingS
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: String(modelData.name || "")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: String(root.selectedStation && root.selectedStation.id || "") === String(modelData.id || "") ? Theme.primary : Theme.surfaceText
                                            elide: Text.ElideRight
                                        }

                                        Row {
                                            id: favoriteJourneyButtons
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.rightMargin: Theme.spacingS
                                            spacing: Theme.spacingXS

                                            Rectangle {
                                                width: 30
                                                height: 30
                                                radius: 8
                                                color: departureFavoriteFromArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainerHigh

                                                DankIcon {
                                                    anchors.centerIn: parent
                                                    name: "trip_origin"
                                                    size: 16
                                                    color: Theme.surfaceText
                                                }

                                                MouseArea {
                                                    id: departureFavoriteFromArea
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.useFavoriteForJourney("from", modelData)
                                                }
                                            }

                                            Rectangle {
                                                width: 30
                                                height: 30
                                                radius: 8
                                                color: departureFavoriteToArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainerHigh

                                                DankIcon {
                                                    anchors.centerIn: parent
                                                    name: "flag"
                                                    size: 16
                                                    color: Theme.surfaceText
                                                }

                                                MouseArea {
                                                    id: departureFavoriteToArea
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.useFavoriteForJourney("to", modelData)
                                                }
                                            }

                                            Rectangle {
                                                width: 30
                                                height: 30
                                                radius: 8
                                                color: departureFavoriteRemoveArea.containsMouse ? Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.16) : Theme.surfaceContainerHigh

                                                DankIcon {
                                                    anchors.centerIn: parent
                                                    name: "close"
                                                    size: 16
                                                    color: departureFavoriteRemoveArea.containsMouse ? Theme.error : Theme.surfaceText
                                                }

                                                MouseArea {
                                                    id: departureFavoriteRemoveArea
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.removeFavorite(modelData.id || "")
                                                }
                                            }
                                        }

                                        MouseArea {
                                            id: favoriteArea
                                            anchors.fill: parent
                                            anchors.rightMargin: 108
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.chooseFavorite(modelData)
                                        }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            x: departuresSidebar.width + Theme.spacingS
                            y: 0
                            width: parent.width - x
                            height: parent.height
                            radius: 12
                            color: Theme.surfaceContainerHigh
                            border.color: Theme.outline
                            border.width: 1

                            Item {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS

                                Rectangle {
                                    id: departureHeaderCard
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    height: 64
                                    radius: 10
                                    color: Theme.surfaceContainer

                                    StyledText {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.leftMargin: Theme.spacingS
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.top: parent.top
                                        anchors.topMargin: 10
                                        text: root.selectedStation && root.selectedStation.name ? String(root.selectedStation.name) : "Favorit auswaehlen"
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                    }

                                    StyledText {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.leftMargin: Theme.spacingS
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: 10
                                        text: root.selectedStation && root.selectedStation.name ? "Naechste Abfahrten" : "Waehle links eine Station, um Abfahrten zu laden."
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        elide: Text.ElideRight
                                    }
                                }

                                StyledText {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: departureHeaderCard.bottom
                                    anchors.topMargin: Theme.spacingS
                                    visible: root.departureError.length > 0
                                    text: root.departureError
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.error
                                    wrapMode: Text.WordWrap
                                }

                                StyledText {
                                    anchors.centerIn: parent
                                    visible: root.departuresLoading
                                    text: "Abfahrten werden geladen..."
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }

                                StyledText {
                                    anchors.centerIn: parent
                                    visible: !root.departuresLoading && root.departures.length === 0 && root.departureError.length === 0 && !!root.selectedStation
                                    text: "Keine Abfahrten gefunden."
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }

                                ListView {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: departureHeaderCard.bottom
                                    anchors.topMargin: Theme.spacingS
                                    anchors.bottom: parent.bottom
                                    clip: true
                                    spacing: 6
                                    visible: root.departures.length > 0
                                    model: root.departures

                                    delegate: Rectangle {
                                        required property var modelData
                                        width: ListView.view.width
                                        height: 64
                                        radius: 10
                                        color: departureArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainer

                                        StyledText {
                                            anchors.left: parent.left
                                            anchors.top: parent.top
                                            anchors.leftMargin: Theme.spacingS
                                            anchors.topMargin: 10
                                            width: 96
                                            text: String(modelData.timeText || "")
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.DemiBold
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            anchors.left: parent.left
                                            anchors.bottom: parent.bottom
                                            anchors.leftMargin: Theme.spacingS
                                            anchors.bottomMargin: 10
                                            width: 96
                                            text: root.minutesLabel(modelData.minutes)
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                        }

                                        StyledText {
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.leftMargin: 116
                                            anchors.rightMargin: Theme.spacingS
                                            anchors.top: parent.top
                                            anchors.topMargin: 10
                                            text: [String(modelData.line || ""), String(modelData.direction || "")].filter(part => part.length > 0).join("  ")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                            elide: Text.ElideRight
                                        }

                                        StyledText {
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.leftMargin: 116
                                            anchors.rightMargin: Theme.spacingS
                                            anchors.bottom: parent.bottom
                                            anchors.bottomMargin: 10
                                            text: [
                                                modelData.platform ? "Gleis " + modelData.platform : "",
                                                modelData.delayMinutes > 0 ? "+" + modelData.delayMinutes + " Min" : ""
                                            ].filter(part => part.length > 0).join(" • ")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: modelData.delayMinutes > 0 ? Theme.primary : Theme.surfaceVariantText
                                            elide: Text.ElideRight
                                        }

                                        MouseArea {
                                            id: departureArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.useSelectedStationAs("from")
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Item {
                        id: journeysTab
                        anchors.fill: parent
                        visible: root.activeTab === "journeys"
                        clip: true
                        property int sidebarWidth: 300

                        Rectangle {
                            id: journeySidebar
                            x: 0
                            y: 0
                            width: parent.width < 900 ? Math.max(260, Math.floor(parent.width * 0.30)) : journeysTab.sidebarWidth
                            height: parent.height
                            radius: 12
                            color: Theme.surfaceContainerHigh
                            border.color: Theme.outline
                            border.width: 1

                            Item {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS

                                Column {
                                    id: journeySidebarHeader
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    spacing: Theme.spacingS

                                    StyledText {
                                        width: parent.width
                                        text: "Verbindungssuche"
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                    }

                                    Rectangle {
                                        width: parent.width
                                        height: 38
                                        radius: 10
                                        color: Theme.surfaceContainer
                                        border.color: fromInput.activeFocus ? Theme.primary : Theme.outline
                                        border.width: 1

                                        Item {
                                            anchors.fill: parent
                                            anchors.leftMargin: Theme.spacingS
                                            anchors.rightMargin: Theme.spacingS

                                            StyledText {
                                                anchors.fill: parent
                                                verticalAlignment: Text.AlignVCenter
                                                text: root.fromText.length > 0 ? root.fromText : "Start"
                                                color: root.fromText.length > 0 ? Theme.surfaceText : Theme.surfaceVariantText
                                                font.pixelSize: Theme.fontSizeSmall
                                                visible: !fromInput.activeFocus
                                                elide: Text.ElideRight
                                            }

                                            TextInput {
                                                id: fromInput
                                                anchors.fill: parent
                                                text: root.fromText
                                                color: activeFocus ? Theme.surfaceText : "transparent"
                                                font.pixelSize: Theme.fontSizeSmall
                                                verticalAlignment: TextInput.AlignVCenter
                                                cursorVisible: activeFocus
                                                selectionColor: Theme.primary
                                                selectedTextColor: Theme.background
                                                onTextChanged: {
                                                    root.fromText = text;
                                                    root.fromId = "";
                                                    if (root.suppressJourneySuggest || !activeFocus || !root.pluginPopoutVisible)
                                                        return;
                                                    root.clearSearchResults();
                                                    root.scheduleJourneyStationSearch("from", text);
                                                }
                                                onAccepted: root.searchJourneys()
                                            }
                                        }
                                    }

                                    Rectangle {
                                        width: 38
                                        height: 38
                                        radius: 10
                                        color: swapArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainer
                                        anchors.horizontalCenter: parent.horizontalCenter

                                        DankIcon {
                                            anchors.centerIn: parent
                                            name: "swap_vert"
                                            size: 18
                                            color: Theme.surfaceText
                                        }

                                        MouseArea {
                                            id: swapArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.swapJourneyEndpoints()
                                        }
                                    }

                                    Rectangle {
                                        width: parent.width
                                        height: 38
                                        radius: 10
                                        color: Theme.surfaceContainer
                                        border.color: toInput.activeFocus ? Theme.primary : Theme.outline
                                        border.width: 1

                                        Item {
                                            anchors.fill: parent
                                            anchors.leftMargin: Theme.spacingS
                                            anchors.rightMargin: Theme.spacingS

                                            StyledText {
                                                anchors.fill: parent
                                                verticalAlignment: Text.AlignVCenter
                                                text: root.toText.length > 0 ? root.toText : "Ziel"
                                                color: root.toText.length > 0 ? Theme.surfaceText : Theme.surfaceVariantText
                                                font.pixelSize: Theme.fontSizeSmall
                                                visible: !toInput.activeFocus
                                                elide: Text.ElideRight
                                            }

                                            TextInput {
                                                id: toInput
                                                anchors.fill: parent
                                                text: root.toText
                                                color: activeFocus ? Theme.surfaceText : "transparent"
                                                font.pixelSize: Theme.fontSizeSmall
                                                verticalAlignment: TextInput.AlignVCenter
                                                cursorVisible: activeFocus
                                                selectionColor: Theme.primary
                                                selectedTextColor: Theme.background
                                                onTextChanged: {
                                                    root.toText = text;
                                                    root.toId = "";
                                                    if (root.suppressJourneySuggest || !activeFocus || !root.pluginPopoutVisible)
                                                        return;
                                                    root.clearSearchResults();
                                                    root.scheduleJourneyStationSearch("to", text);
                                                }
                                                onAccepted: root.searchJourneys()
                                            }
                                        }
                                    }

                                    Rectangle {
                                        width: parent.width
                                        height: 36
                                        radius: 10
                                        color: journeysArea.containsMouse ? Theme.primaryHover : Theme.primary

                                        StyledText {
                                            anchors.centerIn: parent
                                            text: "Verbindungen suchen"
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.background
                                        }

                                        MouseArea {
                                            id: journeysArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.searchJourneys()
                                        }
                                    }

                                    StyledText {
                                        width: parent.width
                                        visible: root.favoriteStations.length > 0
                                        text: "Favoriten als Start oder Ziel verwenden"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }

                                    Column {
                                        width: parent.width
                                        spacing: Theme.spacingXS
                                        visible: root.favoriteStations.length > 0

                                        Repeater {
                                            model: root.favoriteStations

                                            Rectangle {
                                                required property var modelData
                                                width: parent.width
                                                height: 34
                                                radius: 8
                                                color: journeyFavoriteArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainer

                                                StyledText {
                                                    id: favoriteName
                                                    anchors.left: parent.left
                                                    anchors.right: favoriteFromButton.left
                                                    anchors.leftMargin: Theme.spacingS
                                                    anchors.rightMargin: Theme.spacingXS
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: String(modelData.name || "")
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    color: Theme.surfaceText
                                                    elide: Text.ElideRight
                                                }

                                                Rectangle {
                                                    id: favoriteFromButton
                                                    anchors.right: favoriteToButton.left
                                                    anchors.rightMargin: Theme.spacingXS
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: 22
                                                    height: 22
                                                    radius: 6
                                                    color: setFromFavoriteArea.containsMouse ? Theme.primary : Theme.surfaceContainerHigh

                                                    DankIcon {
                                                        anchors.centerIn: parent
                                                        name: "trip_origin"
                                                        size: 13
                                                        color: setFromFavoriteArea.containsMouse ? Theme.background : Theme.surfaceText
                                                    }

                                                    MouseArea {
                                                        id: setFromFavoriteArea
                                                        anchors.fill: parent
                                                        hoverEnabled: true
                                                        cursorShape: Qt.PointingHandCursor
                                                        onClicked: root.useFavoriteForJourney("from", modelData)
                                                    }
                                                }

                                                Rectangle {
                                                    id: favoriteToButton
                                                    anchors.right: parent.right
                                                    anchors.rightMargin: Theme.spacingS
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: 22
                                                    height: 22
                                                    radius: 6
                                                    color: setToFavoriteArea.containsMouse ? Theme.primary : Theme.surfaceContainerHigh

                                                    DankIcon {
                                                        anchors.centerIn: parent
                                                        name: "flag"
                                                        size: 13
                                                        color: setToFavoriteArea.containsMouse ? Theme.background : Theme.surfaceText
                                                    }

                                                    MouseArea {
                                                        id: setToFavoriteArea
                                                        anchors.fill: parent
                                                        hoverEnabled: true
                                                        cursorShape: Qt.PointingHandCursor
                                                        onClicked: root.useFavoriteForJourney("to", modelData)
                                                    }
                                                }

                                                MouseArea {
                                                    id: journeyFavoriteArea
                                                    anchors.fill: parent
                                                    anchors.rightMargin: 56
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        if (fromInput.activeFocus)
                                                            root.useFavoriteForJourney("from", modelData);
                                                        else
                                                            root.useFavoriteForJourney("to", modelData);
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    StyledText {
                                        width: parent.width
                                        visible: root.searchTarget !== "favorite" && (root.searchLoading || root.searchError.length > 0 || root.searchResults.length > 0)
                                        text: root.searchLoading ? "Stationen werden gesucht..." : root.searchError
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: root.searchError.length > 0 ? Theme.error : Theme.surfaceVariantText
                                        wrapMode: Text.WordWrap
                                    }

                                    Rectangle {
                                        width: parent.width
                                        height: root.searchTarget !== "favorite" && root.searchResults.length > 0 ? Math.min(220, journeySearchResultsList.contentHeight + Theme.spacingXS * 2) : 0
                                        visible: height > 0
                                        radius: 10
                                        color: Theme.surfaceContainer
                                        border.color: Theme.outline
                                        border.width: 1

                                        ListView {
                                            id: journeySearchResultsList
                                            anchors.fill: parent
                                            anchors.margins: Theme.spacingXS
                                            clip: true
                                            spacing: 4
                                            model: root.searchTarget !== "favorite" ? root.searchResults : []

                                            delegate: Rectangle {
                                                required property var modelData
                                                width: ListView.view.width
                                                height: 32
                                                radius: 8
                                                color: searchResultArea.containsMouse ? Theme.widgetBaseHoverColor : "transparent"

                                                StyledText {
                                                    anchors.left: parent.left
                                                    anchors.right: parent.right
                                                    anchors.leftMargin: Theme.spacingS
                                                    anchors.rightMargin: Theme.spacingS
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: String(modelData.name || "")
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    color: Theme.surfaceText
                                                    elide: Text.ElideRight
                                                }

                                                MouseArea {
                                                    id: searchResultArea
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.applySearchResult(modelData)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            x: journeySidebar.width + Theme.spacingS
                            y: 0
                            width: parent.width - x
                            height: parent.height
                            radius: 12
                            color: Theme.surfaceContainerHigh
                            border.color: Theme.outline
                            border.width: 1

                            Item {
                                id: journeyResultsPane
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                readonly property var selectedJourney: root.expandedJourneyData()

                                StyledText {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    visible: root.journeyError.length > 0
                                    text: root.journeyError
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.error
                                    wrapMode: Text.WordWrap
                                }

                                StyledText {
                                    anchors.centerIn: parent
                                    visible: root.journeysLoading
                                    text: "Verbindungen werden geladen..."
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }

                                StyledText {
                                    anchors.centerIn: parent
                                    visible: !root.journeysLoading && root.journeys.length === 0 && root.journeyError.length === 0
                                    text: "Suche nach Start und Ziel, um kommende Verbindungen zu sehen."
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }

                                Flickable {
                                    id: journeyResultsFlick
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.bottom: journeyDetailsPanel.visible ? journeyDetailsPanel.top : parent.bottom
                                    anchors.bottomMargin: journeyDetailsPanel.visible ? Theme.spacingS : 0
                                    clip: true
                                    visible: root.journeys.length > 0
                                    contentWidth: width
                                    contentHeight: journeyResultsColumn.childrenRect.height

                                    Column {
                                        id: journeyResultsColumn
                                        width: journeyResultsFlick.width
                                        spacing: Theme.spacingS

                                        Repeater {
                                            model: root.journeys

                                            Rectangle {
                                                required property var modelData
                                                required property int index
                                                readonly property bool expanded: root.isJourneyExpanded(index, modelData)
                                                width: journeyResultsColumn.width - 2
                                                height: 48 + Theme.spacingS * 2
                                                radius: 12
                                                color: expanded ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.14) : journeyArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainer
                                                border.color: expanded ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.5) : "transparent"
                                                border.width: expanded ? 1 : 0

                                                Column {
                                                    id: journeyCardColumn
                                                    x: Theme.spacingS
                                                    y: Theme.spacingS
                                                    width: parent.width - Theme.spacingS * 2
                                                    spacing: Theme.spacingXS

                                                    Item {
                                                        width: parent.width
                                                        height: 22

                                                        StyledText {
                                                            anchors.left: parent.left
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            width: 122
                                                            text: [String(modelData.departureText || ""), "->", String(modelData.arrivalText || "")].join(" ")
                                                            font.pixelSize: Theme.fontSizeSmall
                                                            font.weight: Font.DemiBold
                                                            color: expanded ? Theme.primary : Theme.surfaceText
                                                            elide: Text.ElideRight
                                                        }

                                                        StyledText {
                                                            anchors.left: parent.left
                                                            anchors.leftMargin: 138
                                                            anchors.right: journeyChevron.left
                                                            anchors.rightMargin: Theme.spacingS
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            text: [
                                                                root.durationLabel(modelData.durationMinutes),
                                                                String(modelData.transfers || 0) + " Umstieg" + (Number(modelData.transfers || 0) === 1 ? "" : "e"),
                                                                String(modelData.priceText || "")
                                                            ].filter(part => part.length > 0).join(" • ")
                                                            font.pixelSize: Theme.fontSizeSmall
                                                            color: Theme.surfaceVariantText
                                                            elide: Text.ElideRight
                                                        }

                                                        DankIcon {
                                                            id: journeyChevron
                                                            anchors.right: parent.right
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            name: expanded ? "expand_less" : "expand_more"
                                                            size: 18
                                                            color: expanded ? Theme.primary : Theme.surfaceVariantText
                                                        }
                                                    }

                                                    StyledText {
                                                        width: parent.width
                                                        visible: root.lineSummaryText(modelData.summaryLines).length > 0
                                                        text: root.lineSummaryText(modelData.summaryLines)
                                                        font.pixelSize: Theme.fontSizeSmall
                                                        color: Theme.primary
                                                        elide: Text.ElideRight
                                                    }
                                                }

                                                MouseArea {
                                                    id: journeyArea
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.toggleJourneyExpanded(index, modelData)
                                                }
                                            }
                                        }
                                    }
                                }

                                Rectangle {
                                    id: journeyDetailsPanel
                                    property bool active: !!journeyResultsPane.selectedJourney
                                    property real targetHeight: active ? Math.min(parent.height * 0.48, journeyDetailsColumn.childrenRect.height + 104) : 0
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    height: targetHeight
                                    visible: active || opacity > 0
                                    opacity: active ? 1 : 0
                                    radius: 14
                                    clip: true
                                    color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.08)
                                    border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.38)
                                    border.width: 1

                                    Behavior on height {
                                        NumberAnimation {
                                            duration: 180
                                            easing.type: Easing.OutCubic
                                        }
                                    }

                                    Behavior on opacity {
                                        NumberAnimation {
                                            duration: 140
                                            easing.type: Easing.OutCubic
                                        }
                                    }

                                    Rectangle {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.top: parent.top
                                        anchors.topMargin: 8
                                        width: 44
                                        height: 4
                                        radius: 2
                                        color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.4)
                                    }

                                    StyledText {
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        anchors.leftMargin: Theme.spacingS
                                        anchors.topMargin: 16
                                        text: "Verbindungsdetails"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }

                                    StyledText {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.leftMargin: Theme.spacingS
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.topMargin: 34
                                        text: journeyResultsPane.selectedJourney ? [
                                            String(journeyResultsPane.selectedJourney.departureText || ""),
                                            "->",
                                            String(journeyResultsPane.selectedJourney.arrivalText || ""),
                                            "•",
                                            root.durationLabel(journeyResultsPane.selectedJourney.durationMinutes),
                                            "•",
                                            String(journeyResultsPane.selectedJourney.transfers || 0) + " Umstieg" + (Number(journeyResultsPane.selectedJourney.transfers || 0) === 1 ? "" : "e")
                                        ].filter(part => part.length > 0).join(" ") : ""
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                    }

                                    StyledText {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.leftMargin: Theme.spacingS
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.topMargin: 56
                                        text: journeyResultsPane.selectedJourney ? root.lineSummaryText(journeyResultsPane.selectedJourney.summaryLines) : ""
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.primary
                                        elide: Text.ElideRight
                                        visible: text.length > 0
                                    }

                                    Flickable {
                                        id: journeyDetailsFlick
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.bottom: parent.bottom
                                        anchors.leftMargin: Theme.spacingS
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.topMargin: 78
                                        anchors.bottomMargin: Theme.spacingS
                                        clip: true
                                        contentWidth: width
                                        contentHeight: journeyDetailsColumn.childrenRect.height

                                        Column {
                                            id: journeyDetailsColumn
                                            width: parent.width
                                            spacing: Theme.spacingS

                                            Repeater {
                                                model: journeyResultsPane.selectedJourney && Array.isArray(journeyResultsPane.selectedJourney.legs) ? journeyResultsPane.selectedJourney.legs : []

                                                Rectangle {
                                                    required property var modelData
                                                    required property int index

                                                    width: journeyDetailsColumn.width
                                                    height: legBody.implicitHeight + Theme.spacingS * 2
                                                    radius: 12
                                                    color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.18)
                                                    border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18)
                                                    border.width: 1

                                                    Column {
                                                        id: legBody
                                                        x: Theme.spacingS
                                                        y: Theme.spacingS
                                                        width: parent.width - Theme.spacingS * 2
                                                        spacing: Theme.spacingXS

                                                        Item {
                                                            width: parent.width
                                                            height: 24

                                                            Rectangle {
                                                                anchors.left: parent.left
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                width: 28
                                                                height: 20
                                                                radius: 6
                                                                color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18)

                                                                StyledText {
                                                                    anchors.centerIn: parent
                                                                    text: String(index + 1)
                                                                    font.pixelSize: Theme.fontSizeSmall
                                                                    font.weight: Font.DemiBold
                                                                    color: Theme.primary
                                                                }
                                                            }

                                                            StyledText {
                                                                anchors.left: parent.left
                                                                anchors.leftMargin: 38
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                text: [String(modelData.departureText || ""), "->", String(modelData.arrivalText || "")].join(" ")
                                                                font.pixelSize: Theme.fontSizeSmall
                                                                font.weight: Font.DemiBold
                                                                color: Theme.surfaceText
                                                            }

                                                            StyledText {
                                                                anchors.right: parent.right
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                text: [
                                                                    String(modelData.line || ""),
                                                                    String(modelData.product || "")
                                                                ].filter(part => part.length > 0).join(" • ")
                                                                font.pixelSize: Theme.fontSizeSmall
                                                                color: Theme.primary
                                                                elide: Text.ElideRight
                                                            }
                                                        }

                                                        StyledText {
                                                            width: parent.width
                                                            text: [
                                                                String(modelData.origin || ""),
                                                                String(modelData.destination || "")
                                                            ].filter(part => part.length > 0).join(" -> ")
                                                            font.pixelSize: Theme.fontSizeSmall
                                                            color: Theme.surfaceText
                                                            wrapMode: Text.WordWrap
                                                        }

                                                        StyledText {
                                                            width: parent.width
                                                            visible: String(modelData.direction || "").length > 0 || String(modelData.operator || "").length > 0 || String(modelData.platform || "").length > 0
                                                            text: [
                                                                modelData.direction ? "Richtung " + String(modelData.direction) : "",
                                                                String(modelData.operator || ""),
                                                                modelData.platform ? "Gleis " + String(modelData.platform) : ""
                                                            ].filter(part => part.length > 0).join(" • ")
                                                            font.pixelSize: Theme.fontSizeSmall
                                                            color: Theme.surfaceVariantText
                                                            wrapMode: Text.WordWrap
                                                        }

                                                        Column {
                                                            width: parent.width
                                                            spacing: 3
                                                            visible: Array.isArray(modelData.stopovers) && modelData.stopovers.length > 0

                                                            StyledText {
                                                                width: parent.width
                                                                text: "Zwischenhalte"
                                                                font.pixelSize: Theme.fontSizeSmall
                                                                font.weight: Font.DemiBold
                                                                color: Theme.surfaceVariantText
                                                            }

                                                            Repeater {
                                                                model: Array.isArray(modelData.stopovers) ? modelData.stopovers : []

                                                                Item {
                                                                    required property var modelData
                                                                    width: parent.width
                                                                    height: 18

                                                                    Rectangle {
                                                                        anchors.left: parent.left
                                                                        anchors.verticalCenter: parent.verticalCenter
                                                                        width: 5
                                                                        height: 5
                                                                        radius: 3
                                                                        color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.75)
                                                                    }

                                                                    StyledText {
                                                                        anchors.left: parent.left
                                                                        anchors.leftMargin: 14
                                                                        anchors.verticalCenter: parent.verticalCenter
                                                                        width: 64
                                                                        text: root.stopoverTimeText(modelData)
                                                                        font.pixelSize: Theme.fontSizeSmall
                                                                        color: Theme.primary
                                                                    }

                                                                    StyledText {
                                                                        anchors.left: parent.left
                                                                        anchors.leftMargin: 84
                                                                        anchors.right: parent.right
                                                                        anchors.verticalCenter: parent.verticalCenter
                                                                        text: String(modelData.name || "")
                                                                        font.pixelSize: Theme.fontSizeSmall
                                                                        color: Theme.surfaceVariantText
                                                                        elide: Text.ElideRight
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
                            }
                        }
                    }
                }
            }
        }
    }
}
