import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root

    pluginId: "mpdBrowser"

    StyledText {
        width: parent.width
        text: "MPD Browser"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Dedicated album browser widget for MPD. By default it reads connection and clerk settings from the main `mpd` plugin."
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
        settingKey: "sharedPluginId"
        label: "Shared Plugin ID"
        description: "Plugin id to read shared MPD settings from."
        placeholder: "mpd"
        defaultValue: "mpd"
    }

    SelectionSetting {
        settingKey: "defaultMode"
        label: "Default Mode"
        description: "Mode used when the widget popout is opened through generic widget IPC."
        options: [{
                "label": "Albums",
                "value": "album"
            }, {
                "label": "Latest",
                "value": "latest"
            }]
        defaultValue: "album"
    }
}
