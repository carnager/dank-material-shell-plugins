import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root

    pluginId: "systemdUserServices"

    StyledText {
        width: parent.width
        text: "User Services"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Manage systemd user services directly from the widget popout. This panel only keeps the optional systemctl override."
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
        settingKey: "systemctlBinary"
        label: "systemctl Binary"
        description: "Path or command name for systemctl."
        placeholder: "systemctl"
        defaultValue: "systemctl"
    }

    StyledText {
        width: parent.width
        text: "Use the Add button in the widget popout to pick user services from the current systemd session."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }
}
