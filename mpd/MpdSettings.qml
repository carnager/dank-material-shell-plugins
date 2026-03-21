import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root

    pluginId: "mpd"

    StyledText {
        width: parent.width
        text: "MPD"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Connect to Music Player Daemon and render the current track with a configurable template."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledRect {
        width: parent.width
        height: 1
        color: Theme.surfaceVariant
    }

    StringSetting {
        settingKey: "host"
        label: "Host"
        description: "MPD host name or IP address"
        placeholder: "localhost"
        defaultValue: "localhost"
    }

    StringSetting {
        settingKey: "port"
        label: "Port"
        description: "MPD TCP port"
        placeholder: "6600"
        defaultValue: "6600"
    }

    StringSetting {
        settingKey: "password"
        label: "Password"
        description: "Optional MPD password"
        placeholder: "Optional password"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "clerkApiBaseUrl"
        label: "Clerk API"
        description: "Base URL for clerk-service, used for album ratings and random playback. Leave empty to read ~/.config/clerk/clerk-api-rofi.conf"
        placeholder: "http://localhost:5000/api/v1"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "watcherBinary"
        label: "Watcher Binary"
        description: "Path or command name for the mpdwatch binary."
        placeholder: "mpdwatch"
        defaultValue: "mpdwatch"
    }

    StringSetting {
        settingKey: "format"
        label: "Format"
        description: "Supported placeholders: {tracknumber}, {artist}, {title}, {album}, {albumartist}, {date}, {year}, {filename}"
        placeholder: "{artist} - {title} ({album})"
        defaultValue: "{artist} - {title} ({album})"
    }

    StringSetting {
        settingKey: "cover"
        label: "Bar Cover"
        description: "Show cover art in the horizontal bar: true or false"
        placeholder: "false"
        defaultValue: "false"
    }

    StringSetting {
        settingKey: "maxWidth"
        label: "Max Width"
        description: "Maximum bar width in pixels. Use 0 for no limit."
        placeholder: "320"
        defaultValue: "320"
    }

    StringSetting {
        settingKey: "alignment"
        label: "Alignment"
        description: "Horizontal bar alignment inside the max width: left or right"
        placeholder: "left"
        defaultValue: "left"
    }

    StyledText {
        width: parent.width
        text: "Example: {tracknumber}. {artist} - {title} [{year}]"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }
}
