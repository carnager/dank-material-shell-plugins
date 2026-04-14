import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginComponent {
    id: root

    pluginId: "systemdUserServices"
    popoutWidth: 420
    popoutHeight: 440

    property bool pluginPopoutVisible: false
    property bool statusRefreshQueued: false
    property string statusError: ""
    property string pickerError: ""
    property bool servicePickerVisible: false
    property string serviceSearch: ""
    property var configuredServices: []
    property var serviceStates: ({})
    property var serviceEnabledStates: ({})
    property var availableServices: []
    property var statusOutputLines: []
    property var statusErrorLines: []
    property var enabledOutputLines: []
    property var enabledErrorLines: []
    property var actionErrorLines: []
    property var availableServiceOutputLines: []
    property var availableServiceErrorLines: []
    property string actionUnit: ""
    property string actionDescription: ""
    readonly property string configuredSystemctlPath: String(loadPluginValue("systemctlBinary", "systemctl")).trim()
    readonly property string systemctlBinaryPath: configuredSystemctlPath.length > 0 ? configuredSystemctlPath : "systemctl"
    readonly property int activeServiceCount: {
        let count = 0;
        for (const service of configuredServices) {
            if (serviceIsActive(service.unit))
                count += 1;
        }
        return count;
    }
    readonly property string pillIconName: "settings_applications"
    readonly property string summaryText: {
        if (configuredServices.length === 0)
            return "No services configured";
        let enabledCount = 0;
        for (const service of configuredServices) {
            if (serviceIsEnabled(service.unit))
                enabledCount += 1;
        }
        return activeServiceCount + " active • " + enabledCount + " enabled";
    }
    readonly property var filteredAvailableServices: {
        const configuredUnits = ({});
        for (const service of configuredServices)
            configuredUnits[service.unit] = true;

        const query = String(serviceSearch || "").trim().toLowerCase();
        const filtered = [];
        for (const service of availableServices) {
            if (configuredUnits[service.unit])
                continue;

            if (query.length > 0) {
                const haystack = [
                    String(service.unit || ""),
                    String(service.label || "")
                ].join(" ").toLowerCase();
                if (haystack.indexOf(query) < 0)
                    continue;
            }

            filtered.push(service);
        }
        return filtered;
    }

    function loadPluginValue(key, fallback) {
        const data = root.pluginData || ({});
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

    function legacyServiceLabelFromUnit(unit) {
        const text = String(unit || "").trim();
        if (text.endsWith(".service"))
            return text.slice(0, -8);
        return text;
    }

    function serviceLabelFromUnit(unit) {
        const base = legacyServiceLabelFromUnit(unit);
        const normalized = base.toLowerCase();
        const knownLabels = {
            "mpdsima": "MPD SIMA",
            "mpd-sima": "MPD SIMA",
            "syncthing": "Syncthing",
            "pipewire": "PipeWire",
            "pipewire-pulse": "PipeWire Pulse",
            "wireplumber": "WirePlumber",
            "dbus-broker": "D-Bus Broker",
            "ssh-agent": "SSH Agent"
        };
        if (knownLabels[normalized] !== undefined)
            return knownLabels[normalized];

        let text = base.replace(/^(user-|app-)+/i, "");
        text = text.replace(/[._-]+/g, " ").trim();
        if (text.length === 0)
            return base;

        const acronyms = {
            "api": "API",
            "cpu": "CPU",
            "dbus": "D-Bus",
            "gpu": "GPU",
            "ip": "IP",
            "mpd": "MPD",
            "ssh": "SSH",
            "usb": "USB",
            "vpn": "VPN"
        };

        return text.split(/\s+/).map(word => {
            const lowered = word.toLowerCase();
            if (acronyms[lowered] !== undefined)
                return acronyms[lowered];
            return lowered.charAt(0).toUpperCase() + lowered.slice(1);
        }).join(" ");
    }

    function normalizeUnitName(unit) {
        const text = String(unit || "").trim();
        if (text.length === 0)
            return "";
        if (text.indexOf(".") >= 0)
            return text;
        return text + ".service";
    }

    function normalizedServiceEntry(service) {
        const raw = service || ({});
        const unit = normalizeUnitName(raw.unit !== undefined ? raw.unit : raw);
        if (unit.length === 0)
            return null;

        const providedLabel = String(raw.label || "").trim();
        const autoLabel = serviceLabelFromUnit(unit);
        const legacyLabel = legacyServiceLabelFromUnit(unit);

        return {
            "unit": unit,
            "label": providedLabel.length === 0 || providedLabel === legacyLabel || providedLabel === unit ? autoLabel : providedLabel,
            "icon": String(raw.icon || "").trim()
        };
    }

    function parseLegacyServicesSpec(value) {
        const parsed = [];
        const seen = ({});
        const lines = String(value || "").split(/\r?\n|;/);

        for (const rawLine of lines) {
            const line = String(rawLine || "").trim();
            if (line.length === 0)
                continue;

            const parts = line.split("|").map(part => String(part || "").trim());
            const entry = normalizedServiceEntry({
                "unit": parts[0] || "",
                "label": parts[1] || "",
                "icon": parts[2] || ""
            });
            if (!entry || seen[entry.unit])
                continue;

            seen[entry.unit] = true;
            parsed.push(entry);
        }

        return parsed;
    }

    function loadConfiguredServices() {
        const rawJson = String(loadPluginValue("servicesJson", "") || "").trim();
        if (rawJson.length > 0) {
            try {
                const payload = JSON.parse(rawJson);
                if (Array.isArray(payload)) {
                    const parsed = [];
                    const seen = ({});
                    for (const item of payload) {
                        const entry = normalizedServiceEntry(item);
                        if (!entry || seen[entry.unit])
                            continue;
                        seen[entry.unit] = true;
                        parsed.push(entry);
                    }
                    return parsed;
                }
            } catch (e) {
            }
        }

        return parseLegacyServicesSpec(loadPluginValue("services", ""));
    }

    function saveConfiguredServices() {
        const normalized = [];
        const seen = ({});
        for (const service of configuredServices) {
            const entry = normalizedServiceEntry(service);
            if (!entry || seen[entry.unit])
                continue;
            seen[entry.unit] = true;
            normalized.push(entry);
        }

        configuredServices = normalized;
        savePluginValue("servicesJson", JSON.stringify(normalized));
        savePluginValue("services", normalized.map(service => {
            return [service.unit, service.label, service.icon].join("|");
        }).join("\n"));
    }

    function reloadSettings() {
        configuredServices = loadConfiguredServices();

        const nextStates = ({});
        const nextEnabledStates = ({});
        for (const service of configuredServices)
            nextStates[service.unit] = serviceStates[service.unit] || "unknown";
        for (const service of configuredServices)
            nextEnabledStates[service.unit] = serviceEnabledStates[service.unit] || "unknown";
        serviceStates = nextStates;
        serviceEnabledStates = nextEnabledStates;

        if (configuredServices.length === 0) {
            statusError = "";
            return;
        }

        refreshStatus();
    }

    function serviceState(unit) {
        return String(serviceStates[unit] || "unknown");
    }

    function serviceIsActive(unit) {
        const state = serviceState(unit);
        return state === "active" || state === "activating" || state === "reloading";
    }

    function serviceEnabledState(unit) {
        return String(serviceEnabledStates[unit] || "unknown");
    }

    function serviceIsEnabled(unit) {
        const state = serviceEnabledState(unit);
        return state === "enabled" || state === "enabled-runtime" || state === "linked" || state === "linked-runtime" || state === "alias";
    }

    function serviceCanToggleEnabled(unit) {
        const state = serviceEnabledState(unit);
        return state !== "static" && state !== "generated" && state !== "transient";
    }

    function serviceActionLabel(unit) {
        return serviceIsActive(unit) ? "Stop" : "Start";
    }

    function serviceEnableActionLabel(unit) {
        if (!serviceCanToggleEnabled(unit))
            return serviceEnabledStatusLabel(unit);
        return serviceIsEnabled(unit) ? "Disable" : "Enable";
    }

    function serviceStatusLabel(unit) {
        const state = serviceState(unit);
        if (state === "active")
            return "Running";
        if (state === "activating")
            return "Starting";
        if (state === "reloading")
            return "Reloading";
        if (state === "failed")
            return "Failed";
        if (state === "inactive")
            return "Stopped";
        return "Unknown";
    }

    function serviceEnabledStatusLabel(unit) {
        const state = serviceEnabledState(unit);
        if (state === "enabled" || state === "enabled-runtime")
            return "Enabled";
        if (state === "disabled")
            return "Disabled";
        if (state === "linked" || state === "linked-runtime")
            return "Linked";
        if (state === "alias")
            return "Alias";
        if (state === "static")
            return "Static";
        if (state === "indirect")
            return "Indirect";
        if (state === "generated")
            return "Generated";
        if (state === "transient")
            return "Transient";
        if (state === "masked")
            return "Masked";
        return "Unknown";
    }

    function buildStatusCommand() {
        const args = [systemctlBinaryPath, "--user", "is-active"];
        for (const service of configuredServices)
            args.push(service.unit);
        return args;
    }

    function buildEnabledCommand() {
        const args = [systemctlBinaryPath, "--user", "is-enabled"];
        for (const service of configuredServices)
            args.push(service.unit);
        return args;
    }

    function buildAvailableServicesCommand() {
        return [
            systemctlBinaryPath,
            "--user",
            "list-unit-files",
            "--type=service",
            "--no-legend",
            "--plain"
        ];
    }

    function refreshStatus() {
        if (configuredServices.length === 0)
            return;

        if (statusChecker.running || enabledChecker.running) {
            statusRefreshQueued = true;
            return;
        }

        statusRefreshQueued = false;
        statusError = "";
        statusOutputLines = [];
        statusErrorLines = [];
        enabledOutputLines = [];
        enabledErrorLines = [];
        statusChecker.command = buildStatusCommand();
        enabledChecker.command = buildEnabledCommand();
        statusChecker.running = true;
        enabledChecker.running = true;
    }

    function loadAvailableServices() {
        if (serviceLister.running)
            return;

        pickerError = "";
        availableServiceOutputLines = [];
        availableServiceErrorLines = [];
        serviceLister.command = buildAvailableServicesCommand();
        serviceLister.running = true;
    }

    function toggleServicePicker() {
        servicePickerVisible = !servicePickerVisible;
        if (!servicePickerVisible) {
            serviceSearch = "";
            return;
        }

        loadAvailableServices();
    }

    function addService(service) {
        const entry = normalizedServiceEntry(service);
        if (!entry)
            return;

        for (const existing of configuredServices) {
            if (existing.unit === entry.unit)
                return;
        }

        configuredServices = configuredServices.concat([entry]);
        saveConfiguredServices();
        refreshStatus();
    }

    function removeService(unit) {
        const name = normalizeUnitName(unit);
        const remaining = [];
        for (const service of configuredServices) {
            if (service.unit !== name)
                remaining.push(service);
        }

        configuredServices = remaining;
        saveConfiguredServices();

        const nextStates = ({});
        const nextEnabledStates = ({});
        for (const service of configuredServices)
            nextStates[service.unit] = serviceStates[service.unit] || "unknown";
        for (const service of configuredServices)
            nextEnabledStates[service.unit] = serviceEnabledStates[service.unit] || "unknown";
        serviceStates = nextStates;
        serviceEnabledStates = nextEnabledStates;

        if (configuredServices.length === 0)
            statusError = "";
        else
            refreshStatus();
    }

    function toggleService(unit) {
        const name = normalizeUnitName(unit);
        if (name.length === 0 || actionRunner.running)
            return;

        statusError = "";
        actionUnit = name;
        actionErrorLines = [];
        actionRunner.command = [
            systemctlBinaryPath,
            "--user",
            serviceIsActive(name) ? "stop" : "start",
            name
        ];
        actionDescription = serviceIsActive(name) ? "stop " + name : "start " + name;
        actionRunner.running = true;
    }

    function toggleServiceEnabled(unit) {
        const name = normalizeUnitName(unit);
        if (name.length === 0 || actionRunner.running || !serviceCanToggleEnabled(name))
            return;

        statusError = "";
        actionUnit = name;
        actionErrorLines = [];
        actionRunner.command = [
            systemctlBinaryPath,
            "--user",
            serviceIsEnabled(name) ? "disable" : "enable",
            name
        ];
        actionDescription = serviceIsEnabled(name) ? "disable " + name : "enable " + name;
        actionRunner.running = true;
    }

    Component.onCompleted: reloadSettings()
    onPluginDataChanged: reloadSettings()

    Timer {
        id: delayedStatusRefresh

        interval: 1000
        repeat: false
        onTriggered: root.refreshStatus()
    }

    Timer {
        id: statusPollTimer

        interval: 5000
        repeat: true
        running: root.configuredServices.length > 0
        onTriggered: root.refreshStatus()
    }

    Process {
        id: statusChecker

        running: false

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const text = String(data || "").trim();
                if (text.length > 0)
                    root.statusOutputLines = root.statusOutputLines.concat([text]);
            }
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const text = String(data || "").trim();
                if (text.length > 0)
                    root.statusErrorLines = root.statusErrorLines.concat([text]);
            }
        }

        onExited: exitCode => {
            const nextStates = ({});
            for (let index = 0; index < root.configuredServices.length; index += 1) {
                const service = root.configuredServices[index];
                const state = String(root.statusOutputLines[index] || "unknown").trim().toLowerCase();
                nextStates[service.unit] = state.length > 0 ? state : "unknown";
            }
            root.serviceStates = nextStates;

            if (root.statusErrorLines.length > 0)
                root.statusError = root.statusErrorLines.join("\n");
            else if (exitCode > 3)
                root.statusError = "Failed to query user service status.";
            else
                root.statusError = "";

            if (root.statusRefreshQueued)
                Qt.callLater(() => root.refreshStatus());
        }
    }

    Process {
        id: enabledChecker

        running: false

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const text = String(data || "").trim();
                if (text.length > 0)
                    root.enabledOutputLines = root.enabledOutputLines.concat([text]);
            }
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const text = String(data || "").trim();
                if (text.length > 0)
                    root.enabledErrorLines = root.enabledErrorLines.concat([text]);
            }
        }

        onExited: exitCode => {
            const nextEnabledStates = ({});
            for (let index = 0; index < root.configuredServices.length; index += 1) {
                const service = root.configuredServices[index];
                const state = String(root.enabledOutputLines[index] || "unknown").trim().toLowerCase();
                nextEnabledStates[service.unit] = state.length > 0 ? state : "unknown";
            }
            root.serviceEnabledStates = nextEnabledStates;

            if (root.enabledErrorLines.length > 0)
                root.statusError = root.enabledErrorLines.join("\n");
            else if (exitCode > 1 && root.enabledOutputLines.length === 0)
                root.statusError = "Failed to query user service enable state.";

            if (root.statusRefreshQueued)
                Qt.callLater(() => root.refreshStatus());
        }
    }

    Process {
        id: actionRunner

        running: false

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const text = String(data || "").trim();
                if (text.length > 0)
                    root.actionErrorLines = root.actionErrorLines.concat([text]);
            }
        }

        onExited: exitCode => {
            if (exitCode !== 0) {
                if (root.actionErrorLines.length > 0)
                    root.statusError = root.actionErrorLines.join("\n");
                else
                    root.statusError = "Failed to " + root.actionDescription + ".";
            }

            root.actionUnit = "";
            root.actionDescription = "";
            root.actionErrorLines = [];
            root.delayedStatusRefresh.restart();
        }
    }

    Process {
        id: serviceLister

        running: false

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const text = String(data || "").trim();
                if (text.length > 0)
                    root.availableServiceOutputLines = root.availableServiceOutputLines.concat([text]);
            }
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const text = String(data || "").trim();
                if (text.length > 0)
                    root.availableServiceErrorLines = root.availableServiceErrorLines.concat([text]);
            }
        }

        onExited: exitCode => {
            const parsed = [];
            const seen = ({});
            for (const line of root.availableServiceOutputLines) {
                const trimmed = String(line || "").trim();
                if (trimmed.length === 0)
                    continue;

                const unit = normalizeUnitName(trimmed.split(/\s+/)[0] || "");
                const entry = normalizedServiceEntry({ "unit": unit });
                if (!entry || seen[entry.unit])
                    continue;
                seen[entry.unit] = true;
                parsed.push(entry);
            }

            parsed.sort((left, right) => String(left.label || left.unit).localeCompare(String(right.label || right.unit)));
            root.availableServices = parsed;

            if (root.availableServiceErrorLines.length > 0)
                root.pickerError = root.availableServiceErrorLines.join("\n");
            else if (exitCode !== 0 && parsed.length === 0)
                root.pickerError = "Failed to list user services.";
            else
                root.pickerError = "";
        }
    }

    horizontalBarPill: Component {
        Rectangle {
            width: 24
            height: 24
            radius: 12
            color: root.pluginPopoutVisible ? Theme.widgetBaseHoverColor : "transparent"

            DankIcon {
                anchors.centerIn: parent
                name: root.pillIconName
                size: 15
                color: root.activeServiceCount > 0 ? Theme.primary : Theme.widgetTextColor
            }

            Rectangle {
                visible: root.configuredServices.length > 0
                width: 7
                height: 7
                radius: 3.5
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.rightMargin: 2
                anchors.bottomMargin: 2
                color: root.activeServiceCount > 0 ? Theme.primary : Theme.surfaceVariantText
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
                name: root.pillIconName
                size: Math.max(14, Theme.barIconSize(root.barThickness) - 4)
                color: root.activeServiceCount > 0 ? Theme.primary : Theme.widgetIconColor
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
                        root.reloadSettings();
                        if (root.servicePickerVisible || root.availableServices.length === 0)
                            root.loadAvailableServices();
                    } else {
                        root.serviceSearch = "";
                        root.servicePickerVisible = false;
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

            Flickable {
                anchors.fill: parent
                anchors.margins: Theme.spacingM
                contentWidth: width
                contentHeight: contentColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: contentColumn

                    width: parent.width
                    spacing: Theme.spacingS

                    Row {
                        width: parent.width
                        Column {
                            width: parent.width
                            spacing: 2

                            StyledText {
                                width: parent.width
                                text: "User Services"
                                font.pixelSize: Theme.fontSizeLarge
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                            }

                            StyledText {
                                width: parent.width
                                text: root.summaryText
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }
                    }

                    StyledText {
                        visible: root.statusError.length > 0
                        width: parent.width
                        text: root.statusError
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.error
                        wrapMode: Text.WordWrap
                    }

                    Rectangle {
                        width: parent.width
                        implicitHeight: pickerContent.implicitHeight + Theme.spacingM * 2
                        radius: 12
                        color: Theme.surfaceContainerHigh
                        border.color: Theme.outline
                        border.width: 1

                        Column {
                            id: pickerContent

                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            Row {
                                width: parent.width
                                spacing: Theme.spacingS

                                StyledText {
                                    width: parent.width - pickerToggleButton.width - parent.spacing
                                    text: "Available Services"
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                    verticalAlignment: Text.AlignVCenter
                                }

                                Rectangle {
                                    id: pickerToggleButton

                                    width: 92
                                    height: 32
                                    radius: 10
                                    color: pickerToggleArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.22) : pickerToggleArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainer
                                    border.color: Theme.outline
                                    border.width: 1

                                    StyledText {
                                        anchors.centerIn: parent
                                        text: root.servicePickerVisible ? "Close" : "Add"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                    }

                                    MouseArea {
                                        id: pickerToggleArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.toggleServicePicker()
                                    }
                                }
                            }

                            StyledText {
                                visible: !root.servicePickerVisible
                                width: parent.width
                                text: "Pick additional user services from the current systemd session."
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                            }

                            Rectangle {
                                visible: root.servicePickerVisible
                                width: parent.width
                                height: 36
                                radius: 10
                                color: Theme.surfaceContainer
                                border.color: serviceSearchInput.activeFocus ? Theme.primary : Theme.outline
                                border.width: 1

                                Item {
                                    anchors.fill: parent
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.rightMargin: Theme.spacingS

                                    StyledText {
                                        anchors.fill: parent
                                        verticalAlignment: Text.AlignVCenter
                                        text: root.serviceSearch.length > 0 ? root.serviceSearch : "Search user services"
                                        color: root.serviceSearch.length > 0 ? Theme.surfaceText : Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                        visible: !serviceSearchInput.activeFocus
                                        elide: Text.ElideRight
                                    }

                                    TextInput {
                                        id: serviceSearchInput
                                        anchors.fill: parent
                                        text: root.serviceSearch
                                        color: activeFocus ? Theme.surfaceText : "transparent"
                                        font.pixelSize: Theme.fontSizeSmall
                                        verticalAlignment: TextInput.AlignVCenter
                                        cursorVisible: activeFocus
                                        selectionColor: Theme.primary
                                        selectedTextColor: Theme.background
                                        onTextChanged: root.serviceSearch = text
                                    }
                                }
                            }

                            StyledText {
                                visible: root.servicePickerVisible && root.pickerError.length > 0
                                width: parent.width
                                text: root.pickerError
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.error
                                wrapMode: Text.WordWrap
                            }

                            StyledText {
                                visible: root.servicePickerVisible && serviceLister.running
                                width: parent.width
                                text: "Loading user services..."
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            StyledText {
                                visible: root.servicePickerVisible && !serviceLister.running && root.filteredAvailableServices.length === 0 && root.pickerError.length === 0
                                width: parent.width
                                text: "No matching services available."
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            Repeater {
                                model: root.servicePickerVisible ? root.filteredAvailableServices : []

                                delegate: Rectangle {
                                    required property var modelData

                                    width: parent.width
                                    height: 44
                                    radius: 10
                                    color: addServiceRowArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainer
                                    border.color: Theme.outline
                                    border.width: 1

                                    Column {
                                        anchors.left: parent.left
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.right: parent.right
                                        anchors.rightMargin: Theme.spacingM + 36
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2

                                        StyledText {
                                            width: parent.width
                                            text: String(modelData.label || modelData.unit)
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                            elide: Text.ElideRight
                                        }

                                        StyledText {
                                            width: parent.width
                                            text: String(modelData.unit || "")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            elide: Text.ElideRight
                                        }
                                    }

                                    DankIcon {
                                        anchors.right: parent.right
                                        anchors.rightMargin: Theme.spacingM
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: "add"
                                        size: 16
                                        color: Theme.primary
                                    }

                                    MouseArea {
                                        id: addServiceRowArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.addService(modelData)
                                    }
                                }
                            }
                        }
                    }

                    StyledText {
                        visible: root.configuredServices.length === 0
                        width: parent.width
                        text: "No services added yet."
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }

                    Repeater {
                        model: root.configuredServices

                        delegate: Rectangle {
                            required property var modelData

                            width: parent.width
                            height: 52
                            radius: 12
                            color: Theme.surfaceContainerHigh
                            border.color: Theme.outline
                            border.width: 1

                            Rectangle {
                                id: enableButton

                                anchors.right: actionButton.left
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                width: 76
                                height: 30
                                radius: 10
                                color: serviceEnableButtonArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.22) : serviceEnableButtonArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainer
                                border.color: Theme.outline
                                border.width: 1
                                opacity: root.serviceCanToggleEnabled(modelData.unit) ? 1 : 0.55

                                StyledText {
                                    anchors.centerIn: parent
                                    text: root.serviceEnableActionLabel(modelData.unit)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceText
                                }

                                MouseArea {
                                    id: serviceEnableButtonArea
                                    anchors.fill: parent
                                    enabled: root.serviceCanToggleEnabled(modelData.unit)
                                    hoverEnabled: true
                                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: root.toggleServiceEnabled(modelData.unit)
                                }
                            }

                            Rectangle {
                                id: removeButton

                                anchors.right: enableButton.left
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                width: 28
                                height: 28
                                radius: 14
                                color: removeButtonArea.containsMouse ? Theme.widgetBaseHoverColor : "transparent"

                                DankIcon {
                                    anchors.centerIn: parent
                                    name: "close"
                                    size: 14
                                    color: Theme.surfaceVariantText
                                }

                                MouseArea {
                                    id: removeButtonArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.removeService(modelData.unit)
                                }
                            }

                            Rectangle {
                                id: actionButton

                                anchors.right: parent.right
                                anchors.rightMargin: Theme.spacingM
                                anchors.verticalCenter: parent.verticalCenter
                                width: 64
                                height: 30
                                radius: 10
                                color: actionButtonArea.pressed ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.22) : actionButtonArea.containsMouse ? Theme.widgetBaseHoverColor : Theme.surfaceContainer
                                border.color: Theme.outline
                                border.width: 1

                                StyledText {
                                    anchors.centerIn: parent
                                    text: root.serviceActionLabel(modelData.unit)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceText
                                }

                                MouseArea {
                                    id: actionButtonArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.toggleService(modelData.unit)
                                }
                            }

                            Column {
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingM
                                anchors.right: removeButton.left
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2

                                StyledText {
                                    width: parent.width
                                    text: String(modelData.label || modelData.unit)
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    width: parent.width
                                    text: String(modelData.unit || "") + " • " + root.serviceStatusLabel(modelData.unit) + " • " + root.serviceEnabledStatusLabel(modelData.unit)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: root.serviceIsActive(modelData.unit) ? Theme.primary : Theme.surfaceVariantText
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
