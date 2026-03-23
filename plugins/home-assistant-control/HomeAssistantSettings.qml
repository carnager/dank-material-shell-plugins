import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root

    pluginId: "homeAssistantControl"

    StyledText {
        width: parent.width
        text: "Home Assistant"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Configure the Home Assistant base URL and a long-lived access token used by the widget."
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
        settingKey: "baseUrl"
        label: "Base URL"
        description: "Include protocol and port, for example http://homeassistant.local:8123"
        placeholder: "http://homeassistant.local:8123"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "accessToken"
        label: "Access Token"
        description: "Paste a Home Assistant long-lived access token"
        placeholder: "Long-lived access token"
        defaultValue: ""
    }

    StyledText {
        width: parent.width
        text: "Existing legacy values saved as gatewayIp/apiKey are still read by the widget as a fallback."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

}
