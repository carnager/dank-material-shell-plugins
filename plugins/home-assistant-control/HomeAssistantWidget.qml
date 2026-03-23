import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

PluginComponent {
    id: root

    property string baseUrl: ""
    property string accessToken: ""
    property string errorText: ""
    property bool loading: false
    property string filterText: ""
    property var areaNamesById: ({
    })
    property var entityRegistryById: ({
    })
    property var deviceAreaById: ({
    })
    readonly property bool hasConfig: baseUrl.length > 0 && accessToken.length > 0
    readonly property string fetchScriptPath: {
        const url = Qt.resolvedUrl("ha_fetch.py").toString();
        return url.startsWith("file://") ? url.substring(7) : url;
    }

    function normalizeBaseUrl(value) {
        let normalized = (value || "").trim();
        while (normalized.endsWith("/"))normalized = normalized.slice(0, -1)
        return normalized;
    }

    function domainForEntity(entityId) {
        const idx = entityId.indexOf(".");
        return idx === -1 ? "" : entityId.slice(0, idx);
    }

    function displayType(entityId, name, members) {
        const domain = domainForEntity(entityId);
        if (domain === "switch" || name.toLowerCase().includes("steckdose"))
            return "outlet";

        if (members && members.some((memberId) => {
            return domainForEntity(memberId) === "switch";
        }))
            return "outlet";

        return "light";
    }

    function roomFromRegistry(attrs, entityId) {
        const entityMeta = entityRegistryById[entityId];
        if (entityMeta && entityMeta.area_id && areaNamesById[entityMeta.area_id])
            return areaNamesById[entityMeta.area_id];

        if (entityMeta && entityMeta.device_id) {
            const deviceAreaId = deviceAreaById[entityMeta.device_id];
            if (deviceAreaId && areaNamesById[deviceAreaId])
                return areaNamesById[deviceAreaId];

        }
        if (attrs.area_name)
            return attrs.area_name;

        if (attrs.area)
            return attrs.area;

        if (attrs.room)
            return attrs.room;

        return "";
    }

    function roomForEntity(attrs, entityId, members) {
        const directRoom = roomFromRegistry(attrs, entityId);
        if (directRoom.length > 0)
            return directRoom;

        if (members && members.length > 0) {
            const memberRooms = [];
            for (let i = 0; i < members.length; i++) {
                const memberRoom = roomFromRegistry({
                }, members[i]);
                if (memberRoom.length > 0 && memberRooms.indexOf(memberRoom) === -1)
                    memberRooms.push(memberRoom);

            }
            if (memberRooms.length === 1)
                return memberRooms[0];

            if (memberRooms.length > 1)
                return "Grouped";

        }
        const domain = domainForEntity(entityId);
        if (domain === "light")
            return "Lights";

        if (domain === "switch")
            return "Switches";

        return "Unassigned";
    }

    function loadSettings() {
        if (typeof PluginService === "undefined")
            return ;

        baseUrl = normalizeBaseUrl(PluginService.loadPluginData(root.pluginId, "baseUrl", PluginService.loadPluginData(root.pluginId, "gatewayIp", "")));
        accessToken = PluginService.loadPluginData(root.pluginId, "accessToken", PluginService.loadPluginData(root.pluginId, "apiKey", ""));
    }

    function refreshDevices() {
        if (!hasConfig) {
            entityModel.clear();
            roomModel.clear();
            errorText = "Configure the Home Assistant URL and access token in plugin settings.";
            loading = false;
            return ;
        }
        if (deviceFetcher.running)
            return ;

        errorText = "";
        loading = true;
        deviceFetcher.command = ["python3", fetchScriptPath, baseUrl, accessToken];
        deviceFetcher.running = true;
    }

    function applyDeviceData(raw) {
        const trimmed = raw.trim();
        loading = false;
        if (!trimmed || trimmed[0] !== "{") {
            errorText = "Home Assistant did not return valid device data.";
            return ;
        }
        try {
            const payload = JSON.parse(trimmed);
            const states = payload && Array.isArray(payload.states) ? payload.states : null;
            if (!states) {
                errorText = "Unexpected response from Home Assistant.";
                return ;
            }
            const registry = payload.registry || {
            };
            areaNamesById = registry.areas || {
            };
            entityRegistryById = registry.entities || {
            };
            deviceAreaById = registry.devices || {
            };
            const stateByEntityId = {
            };
            const groupNamesByMember = {
            };
            const groupEntries = [];
            for (let i = 0; i < states.length; i++) {
                const item = states[i];
                if (item && item.entity_id)
                    stateByEntityId[item.entity_id] = item;

            }
            entityModel.clear();
            for (let i = 0; i < states.length; i++) {
                const item = states[i];
                if (!item || !item.entity_id)
                    continue;

                const attrs = item.attributes || {
                };
                const domain = domainForEntity(item.entity_id);
                const members = Array.isArray(attrs.entity_id) ? attrs.entity_id.filter((memberId) => {
                    const memberDomain = domainForEntity(memberId);
                    return memberDomain === "light" || memberDomain === "switch";
                }) : [];
                const isGroup = members.length > 0 && (domain === "group" || domain === "light" || domain === "switch");
                if (!isGroup)
                    continue;

                const name = attrs.friendly_name || item.entity_id;
                const state = String(item.state || "").toLowerCase();
                const memberNames = [];
                for (let m = 0; m < members.length; m++) {
                    const memberId = members[m];
                    const memberState = stateByEntityId[memberId];
                    if (memberState && memberState.attributes && memberState.attributes.friendly_name)
                        memberNames.push(memberState.attributes.friendly_name);

                    if (!groupNamesByMember[memberId])
                        groupNamesByMember[memberId] = [];

                    if (groupNamesByMember[memberId].indexOf(name) === -1)
                        groupNamesByMember[memberId].push(name);

                }
                groupEntries.push({
                    "kind": "group",
                    "name": name,
                    "room": roomForEntity(attrs, item.entity_id, members),
                    "on": state === "on",
                    "available": state !== "unavailable" && state !== "unknown",
                    "type": displayType(item.entity_id, name, members),
                    "idsJson": JSON.stringify([item.entity_id]),
                    "groupNamesJson": JSON.stringify([]),
                    "searchText": (name + " " + memberNames.join(" ")).toLowerCase()
                });
            }
            for (let g = 0; g < groupEntries.length; g++) entityModel.append(groupEntries[g])
            for (let i = 0; i < states.length; i++) {
                const item = states[i];
                if (!item || !item.entity_id)
                    continue;

                const domain = domainForEntity(item.entity_id);
                if (domain !== "light" && domain !== "switch")
                    continue;

                const attrs = item.attributes || {
                };
                const members = Array.isArray(attrs.entity_id) ? attrs.entity_id.filter((memberId) => {
                    const memberDomain = domainForEntity(memberId);
                    return memberDomain === "light" || memberDomain === "switch";
                }) : [];
                if (members.length > 0)
                    continue;

                const name = attrs.friendly_name || item.entity_id;
                const state = String(item.state || "").toLowerCase();
                const groupNames = groupNamesByMember[item.entity_id] || [];
                entityModel.append({
                    "kind": "device",
                    "name": name,
                    "room": roomForEntity(attrs, item.entity_id, []),
                    "on": state === "on",
                    "available": state !== "unavailable" && state !== "unknown",
                    "type": displayType(item.entity_id, name, []),
                    "idsJson": JSON.stringify([item.entity_id]),
                    "groupNamesJson": JSON.stringify(groupNames),
                    "searchText": (name + " " + groupNames.join(" ")).toLowerCase()
                });
            }
            rebuildRoomModel();
            if (entityModel.count === 0)
                errorText = "No Home Assistant lights, switches, or groups found.";

        } catch (e) {
            errorText = "Failed to parse the Home Assistant response.";
        }
    }

    function rebuildRoomModel() {
        roomModel.clear();
        const rooms = {
        };
        const roomOrder = [];
        for (let i = 0; i < entityModel.count; i++) {
            const entry = entityModel.get(i);
            const room = entry.room || "Unassigned";
            if (!rooms[room]) {
                rooms[room] = {
                    "groups": [],
                    "singles": []
                };
                roomOrder.push(room);
            }
            const filter = root.filterText;
            const searchText = entry.searchText || entry.name.toLowerCase();
            const matches = !filter || searchText.includes(filter);
            if (!matches)
                continue;

            const viewEntry = {
                "kind": entry.kind || "device",
                "name": entry.name,
                "on": entry.on,
                "available": entry.available,
                "type": entry.type,
                "idsJson": entry.idsJson
            };
            if (viewEntry.kind === "group") {
                rooms[room].groups.push(viewEntry);
                continue;
            }
            const groupNames = entry.groupNamesJson ? JSON.parse(entry.groupNamesJson) : [];
            if (groupNames.length === 0 || filter.length > 0)
                rooms[room].singles.push(viewEntry);

        }
        for (let r = 0; r < roomOrder.length; r++) {
            const roomName = roomOrder[r];
            const roomData = rooms[roomName];
            const entries = roomData.groups.concat(roomData.singles);
            if (entries.length > 0)
                roomModel.append({
                    "name": roomName,
                    "entriesJson": JSON.stringify(entries)
                });

        }
    }

    function handleFetchError() {
        loading = false;
        errorText = "Request failed. Check the Home Assistant URL, access token, and WebSocket access.";
    }

    function toggleDevice(ids, currentState) {
        const newState = !currentState;
        if (!ids || ids.length === 0) {
            errorText = "No entity IDs found for this item.";
            return ;
        }
        if (!hasConfig)
            return ;

        errorText = "";
        switcherComponent.createObject(root, {
            "entityIdsJson": JSON.stringify(ids),
            "targetOn": newState,
            "baseUrl": root.baseUrl,
            "key": root.accessToken
        });
        for (let i = 0; i < entityModel.count; i++) {
            const entry = entityModel.get(i);
            const entryIds = entry.idsJson ? JSON.parse(entry.idsJson) : [];
            let matched = false;
            for (let j = 0; j < entryIds.length; j++) {
                if (ids.indexOf(entryIds[j]) !== -1) {
                    matched = true;
                    break;
                }
            }
            if (matched)
                entityModel.setProperty(i, "on", newState);

        }
        rebuildRoomModel();
    }

    pluginId: "homeAssistantControl"
    popoutWidth: 980
    popoutHeight: 650
    Component.onCompleted: {
        loadSettings();
        refreshDevices();
    }

    ListModel {
        id: entityModel
    }

    ListModel {
        id: roomModel
    }

    Process {
        id: deviceFetcher

        running: false
        onExited: (exitCode) => {
            if (exitCode !== 0)
                root.handleFetchError();

        }

        stdout: StdioCollector {
            onStreamFinished: root.applyDeviceData(text)
        }

        stderr: StdioCollector {
            onStreamFinished: {
                const raw = text.trim();
                if (raw.length > 0)
                    root.errorText = raw;

            }
        }

    }

    Component {
        id: switcherComponent

        Process {
            property string entityIdsJson: "[]"
            property bool targetOn: false
            property string baseUrl: ""
            property string key: ""
            readonly property string service: targetOn ? "turn_on" : "turn_off"
            readonly property string body: "{\"entity_id\":" + entityIdsJson + "}"

            command: ["curl", "-sS", "--connect-timeout", "3", "--max-time", "6", "-k", "-X", "POST", "-H", "Authorization: Bearer " + key, "-H", "Content-Type: application/json", "-d", body, "-o", "-", "-w", "\nHTTP_STATUS:%{http_code}\n", baseUrl + "/api/services/homeassistant/" + service]
            running: true
            onExited: (exitCode) => {
                if (exitCode !== 0)
                    root.errorText = "Toggle request failed. Check the Home Assistant URL and access token.";

                destroy();
            }

            stdout: StdioCollector {
                onStreamFinished: {
                    const raw = text.trim();
                    const marker = "HTTP_STATUS:";
                    const idx = raw.lastIndexOf(marker);
                    if (idx === -1)
                        return ;

                    const statusStr = raw.slice(idx + marker.length).trim();
                    const status = parseInt(statusStr, 10);
                    if (isNaN(status) || status < 200 || status >= 300)
                        root.errorText = "Toggle failed (HTTP " + statusStr + ").";
                    else
                        root.errorText = "";
                }
            }

            stderr: StdioCollector {
                onStreamFinished: {
                    const raw = text.trim();
                    if (raw.length > 0)
                        root.errorText = "Toggle error: " + raw;

                }
            }

        }

    }

    Connections {
        function onPluginDataChanged(pluginId) {
            if (pluginId === root.pluginId) {
                root.loadSettings();
                root.refreshDevices();
            }
        }

        target: PluginService
    }

    horizontalBarPill: Component {
        DankIcon {
            name: "home_work"
            color: Theme.primary
            size: Theme.iconSize
        }

    }

    popoutContent: Component {
        Item {
            id: contentRoot

            implicitWidth: root.popoutWidth
            implicitHeight: root.popoutHeight - 50

            Connections {
                function onVisibleChanged() {
                    if (!parent.visible) {
                        searchInput.text = "";
                        root.filterText = "";
                    } else {
                        root.refreshDevices();
                        focusTimer.start();
                    }
                }

                target: parent
            }

            Timer {
                id: focusTimer

                interval: 150
                onTriggered: searchInput.forceActiveFocus()
            }

            Rectangle {
                id: filterContainer

                width: Math.min(parent.width, 520) - 48
                height: 48
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.topMargin: 10
                color: "#1c1b1f"
                radius: 24
                border.color: searchInput.activeFocus ? Theme.primary : "#3E4451"
                border.width: 1

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    spacing: 12

                    DankIcon {
                        name: "search"
                        color: searchInput.activeFocus ? Theme.primary : "#ABB2BF"
                        size: 20
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        StyledText {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            text: "Geräte filtern..."
                            color: "#938f99"
                            font.pixelSize: 14
                            visible: !searchInput.text && !searchInput.activeFocus
                        }

                        TextInput {
                            id: searchInput

                            anchors.fill: parent
                            color: "#e6e1e5"
                            font.pixelSize: 14
                            verticalAlignment: TextInput.AlignVCenter
                            selectionColor: Theme.primary
                            selectedTextColor: "#ffffff"
                            onTextChanged: {
                                root.filterText = text.toLowerCase();
                                root.rebuildRoomModel();
                            }
                        }

                    }

                    MouseArea {
                        width: 20
                        height: 20
                        visible: searchInput.text !== ""
                        onClicked: {
                            searchInput.text = "";
                            searchInput.forceActiveFocus();
                        }

                        DankIcon {
                            name: "close"
                            color: "#938f99"
                            size: 18
                            anchors.centerIn: parent
                        }

                    }

                    MouseArea {
                        width: 20
                        height: 20
                        onClicked: root.refreshDevices()

                        DankIcon {
                            name: root.loading ? "hourglass_top" : "refresh"
                            color: "#938f99"
                            size: 18
                            anchors.centerIn: parent
                        }

                    }

                }

            }

            DankFlickable {
                anchors.top: filterContainer.bottom
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.topMargin: 20
                contentHeight: roomFlow.height + 40
                clip: true

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    text: root.errorText
                    color: Theme.surfaceVariantText
                    font.pixelSize: 12
                    visible: root.errorText !== ""
                }

                Flow {
                    id: roomFlow

                    width: Math.min(parent.width, 520)
                    anchors.horizontalCenter: parent.horizontalCenter
                    padding: 24
                    spacing: 32
                    flow: Flow.LeftToRight

                    Repeater {
                        model: roomModel

                        delegate: Item {
                            readonly property string thisRoomName: model.name
                            readonly property var entries: model.entriesJson ? JSON.parse(model.entriesJson) : []

                            width: roomFlow.width - 48
                            height: roomColumn.height + 30

                            Column {
                                id: roomColumn

                                width: parent.width
                                spacing: 14

                                StyledText {
                                    text: thisRoomName
                                    font.pixelSize: 14
                                    font.bold: true
                                    color: Theme.primary
                                    width: parent.width
                                    horizontalAlignment: Text.AlignLeft
                                    leftPadding: 4
                                    visible: deviceRepeater.count > 0
                                }

                                Column {
                                    width: parent.width
                                    spacing: 8

                                    Repeater {
                                        id: deviceRepeater

                                        model: entries

                                        delegate: Item {
                                            visible: true
                                            width: parent.width
                                            height: 56

                                            StyledRect {
                                                anchors.fill: parent
                                                radius: 14
                                                color: "#2b2930"
                                                border.width: 1
                                                border.color: modelData.on ? Theme.primary : "#3E4451"
                                                opacity: modelData.available ? 1 : 0.6

                                                MouseArea {
                                                    anchors.fill: parent
                                                    preventStealing: true
                                                    enabled: modelData.available
                                                    onClicked: {
                                                        const ids = modelData.idsJson ? JSON.parse(modelData.idsJson) : [];
                                                        root.toggleDevice(ids, modelData.on);
                                                    }
                                                }

                                                RowLayout {
                                                    anchors.fill: parent
                                                    anchors.margins: 10
                                                    spacing: 12

                                                    Rectangle {
                                                        width: 34
                                                        height: 34
                                                        radius: 17
                                                        color: modelData.on ? Theme.primary : "#1c1b1f"
                                                        opacity: modelData.on ? 0.25 : 1

                                                        DankIcon {
                                                            anchors.centerIn: parent
                                                            name: modelData.type === "outlet" || modelData.name.toLowerCase().includes("steckdose") ? "power" : "lightbulb"
                                                            color: modelData.on ? "#ffffff" : Theme.primary
                                                            size: 20
                                                        }

                                                    }

                                                    StyledText {
                                                        text: modelData.name
                                                        Layout.fillWidth: true
                                                        font.pixelSize: 11
                                                        font.bold: modelData.on
                                                        color: modelData.available ? "#e6e1e5" : "#938f99"
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
