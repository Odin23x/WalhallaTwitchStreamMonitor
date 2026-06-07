# Walhalla Twitch Stream Monitor
### Touch Portal Plugin by odin23x

Monitor deine Lieblings-Twitch-Streamer direkt in Touch Portal.  
Sieh auf einen Blick wer live ist, was gespielt wird und wie viele Zuschauer dabei sind – ohne den Browser zu öffnen.

---

## Features

- Bis zu **10 Streamer** gleichzeitig im Blick
- Zeigt: Username, Spiel, Titel, Zuschauerzahl, Laufzeit, 18+-Status
- **Auto-Update** mit konfigurierbarem Intervall (Standard: 2 Minuten)
- Auto-Update per Button-Aktion **umschaltbar**
- Streamer-Liste einfach per Notepad bearbeiten
- **Keine hardcodierten Zugangsdaten** – alles über TP-Einstellungen
- Automatische Reconnect-Logik bei Verbindungsverlust

---

## Voraussetzungen

- [Touch Portal](https://www.touch-portal.com/) Desktop App
- Windows 10/11 mit PowerShell 5.1+
- Twitch Developer Account (kostenlos) für Client ID und Token

---

## Installation

1. Lade die neueste Version unter **Releases** herunter (`.tpp` Datei)
2. Öffne Touch Portal → Zahnrad-Icon → *Import Plugin*
3. `.tpp` Datei auswählen
4. Touch Portal neu starten falls nötig

---

## Einrichtung

### 1. Twitch API Zugangsdaten erstellen

**Client ID:**
1. [dev.twitch.tv](https://dev.twitch.tv/console) → *Register Your Application*
2. Name: beliebig, OAuth Redirect: `http://localhost`, Kategorie: `Other`
3. Client ID aus der App kopieren

**User Access Token:**  
Einfachste Methode via [Twitch Token Generator](https://twitchtokengenerator.com/):
- Benötigte Scopes: keine besonderen – ein einfacher User-Token reicht für `/streams`
- Token kopieren (ohne `oauth:` Präfix)

### 2. Plugin-Einstellungen in Touch Portal

| Einstellung | Beschreibung |
|---|---|
| Twitch Client ID | Deine App Client ID |
| Twitch User Access Token | Dein OAuth Token (ohne `oauth:`) |
| Update Interval Seconds | Wie oft geprüft wird (30–3600, Standard: 120) |
| Max Slots | Wie viele Slots aktiv sind (1–10, Standard: 10) |

### 3. Streamer eintragen

Aktion *"Streamers-Datei öffnen"* drücken → `streamers.txt` öffnet sich in Notepad.  
Einen Twitch-Login pro Zeile eintragen (lowercase):

```
xqc
pokimane
summit1g
```

Speichern → beim nächsten Refresh werden die Slots aktualisiert.

---

## States (Touch Portal Variablen)

### Übersicht

| State | Beschreibung |
|---|---|
| Monitor \| Streams Online | Anzahl aktuell live |
| Monitor \| Streams Gesamt | Gesamtanzahl in Liste |
| Monitor \| Auto-Update (AN/AUS) | Status des Auto-Updates |
| Monitor \| Nächstes Update | Countdown bis zum nächsten Check |
| Monitor \| Letztes Update | Zeitstempel des letzten Checks |
| Monitor \| Status | Plugin-Status / Fehlermeldung |

### Pro Slot (1–10)

| State | Beschreibung |
|---|---|
| Stream XX \| Username | Anzeigename des Streamers |
| Stream XX \| Spiel | Aktuell gespieltes Spiel |
| Stream XX \| Titel | Stream-Titel |
| Stream XX \| Zuschauer | Aktuelle Zuschauerzahl |
| Stream XX \| Live (TRUE/FALSE) | Ist der Streamer live? |
| Stream XX \| Laufzeit | Wie lange schon live (z.B. `2h 15m`) |
| Stream XX \| 18+ (TRUE/FALSE) | Ist der Stream als Mature markiert? |

---

## Aktionen

| Aktion | Beschreibung |
|---|---|
| Refresh now | Sofortiger API-Check |
| Auto-Update umschalten | AN/AUS Toggle |
| Streamers-Datei öffnen | Öffnet streamers.txt in Notepad |

---

## Lizenz

MIT License – frei verwendbar, veränderbar und weitergabe erlaubt mit Namensnennung.

---

## Credits

Inspiriert vom originalen [Twitch Stream Monitor](https://github.com/gitagogaming/Twitch-Stream-Monitor---TouchPortal-Plugin) von gitagogaming.  
Komplett neu geschrieben als PowerShell-Plugin mit aktueller Twitch Helix API.
