# Mein Terminplan – native iOS-App

Vollständig native SwiftUI-App für iOS 15.5+. Keine WebView, kein Capacitor und keine externen OCR-Abhängigkeiten: Die Apple-Vision-Texterkennung verarbeitet Kamerabilder lokal auf dem Gerät.

## Enthaltene Funktionen

- Kamera und Fotomediathek zum Einlesen eines Terminplans
- Layout-basierte Erkennung der drei Spalten **Zeit/Dauer**, **Bezeichnung** und **Raum**
- Zeit ohne Endzeit, etwa `12:00 Mittagessen`, wird als Termin gespeichert und dargestellt
- Zeitlose Zeilen, etwa `Wochenplan unterschreiben – ab 09:00 Uhr an der Rezeption`, erscheinen als Informationszeilen statt verworfen zu werden
- Lokale Speicherung via `UserDefaults`, mit „Clear“-Bestätigung
- „Termin“ schreibt einen Eintrag in den Standardkalender des Geräts; ist ein Outlook-Konto in iOS Kalender eingerichtet, kann dessen Kalender gewählt werden

## Starten auf macOS

1. Den Ordner `NativeTerminplan` auf den Mac kopieren.
2. `NativeTerminplan.xcodeproj` in Xcode öffnen.
3. Unter **Signing & Capabilities** ein Apple-Developer-Team auswählen und eine eigene Bundle-ID setzen.
4. Ein echtes iPhone auswählen, bauen und starten. Die genaue Kameratexterkennung von Vision ist auf realen Geräten am aussagekräftigsten.

Die App benötigt keine Pods, kein npm und keine Netzwerkverbindung für OCR oder Speicherung.
