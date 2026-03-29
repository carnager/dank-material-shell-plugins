import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root

    pluginId: "publicTransport"

    StyledText {
        width: parent.width
        text: "Nahverkehr"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Konfiguriere Favoriten fuer Abfahrten sowie optionale Standard-Start- und Zielhalte fuer die Verbindungssuche."
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
        settingKey: "favorites"
        label: "Favoriten"
        description: "Verwende ';' oder Zeilenumbrueche. Jeder Eintrag kann ein Stationsname, eine Transitous-Stop-ID oder 'Bezeichnung|StationsId' sein. Beispiel: Berlin Hbf|de-DELFI_de:11000:900003201; Berlin Suedkreuz"
        placeholder: "Berlin Hbf|de-DELFI_de:11000:900003201; Berlin Suedkreuz"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "defaultFromStop"
        label: "Standard Start"
        description: "Optionaler Standard-Start. Akzeptiert dieselben Formate wie Favoriten."
        placeholder: "Berlin Hbf|de-DELFI_de:11000:900003201"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "defaultToStop"
        label: "Standard Ziel"
        description: "Optionales Standard-Ziel. Akzeptiert dieselben Formate wie Favoriten."
        placeholder: "Leipzig Hbf"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "apiBaseUrl"
        label: "API-Basis-URL"
        description: "Basis-URL der Nahverkehrs-API fuer Stationssuche, Abfahrten und Verbindungen. Standardmaessig wird Transitous verwendet."
        placeholder: "https://api.transitous.org"
        defaultValue: "https://api.transitous.org"
    }

    StyledText {
        width: parent.width
        text: "Tipp: Wenn du nur den Stationsnamen kennst, gib ihn zuerst ein. Das Widget loest ihn bei Bedarf auf und du kannst ihn ueber die Suchergebnisse im Popout verfeinern."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }
}
