import QtQuick

Item {
    id: root

    property var pluginService: null
    property var pluginData: ({})
    property string pluginId: "mpd"
    property string host: "localhost"
    property string port: "6600"
    property string password: ""
    property string clerkApiBaseUrl: ""
    property string watcherBinaryPath: "mpdwatch"
    property bool initialized: false

    signal configChanged()

    function savedSetting(key, fallback) {
        const data = pluginData || ({});
        const pluginFallback = data[key] !== undefined ? data[key] : fallback;
        return pluginService ? pluginService.loadPluginData(pluginId, key, pluginFallback) : pluginFallback;
    }

    function normalizeWatcherBinary(value) {
        const text = String(value || "").trim();
        return text.length > 0 ? text : "mpdwatch";
    }

    function reload() {
        const nextHost = String(savedSetting("host", "localhost")).trim();
        const nextPort = String(savedSetting("port", "6600")).trim();
        const nextPassword = String(savedSetting("password", ""));
        const nextClerkApiBaseUrl = String(savedSetting("clerkApiBaseUrl", "")).trim();
        const nextWatcherBinaryPath = normalizeWatcherBinary(savedSetting("watcherBinary", "mpdwatch"));

        const changed = !initialized
                || host !== nextHost
                || port !== nextPort
                || password !== nextPassword
                || clerkApiBaseUrl !== nextClerkApiBaseUrl
                || watcherBinaryPath !== nextWatcherBinaryPath;

        host = nextHost;
        port = nextPort;
        password = nextPassword;
        clerkApiBaseUrl = nextClerkApiBaseUrl;
        watcherBinaryPath = nextWatcherBinaryPath;

        if (!initialized || changed) {
            initialized = true;
            configChanged();
        }
    }

    Component.onCompleted: reload()
    onPluginServiceChanged: reload()
    onPluginDataChanged: reload()
    onPluginIdChanged: reload()

    Connections {
        target: pluginService
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === root.pluginId)
                root.reload();
        }
    }
}
