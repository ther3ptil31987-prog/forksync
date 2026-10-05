# ForkSync

Mac-App, die deine GitHub-Forks aktuell hält – ohne deine eigenen Commits zu verlieren.

- **Automatisch**: Fork ohne eigene Commits wird gespiegelt (Fast-Forward). Mit eigenen Commits wird das Original eingemergt, bei Konflikten entsteht ein Pull Request.
- **Erkennt unechte „eigene" Commits** (Bots, Original-Autor nach umgeschriebener Historie).
- **Zeitplan per Dropdown** (stündlich bis wöchentlich), läuft als GitHub Action im jeweiligen Fork.
- **Sofort syncen** per Knopfdruck, auch wenn das Original Workflow-Dateien ändert.
- **Anmeldung per GitHub** (Device-Flow), das Token liegt im macOS-Schlüsselbund. Alternativ wird eine vorhandene `gh`-Anmeldung genutzt.

## Installation

DMG aus den [Releases](../../releases) laden, `ForkSync` in den Ordner „Programme" ziehen, starten, „Anmelden" klicken. Die App ist mit Developer ID signiert und notarisiert (macOS 14+).

## Aus dem Quellcode bauen

```
./build_app.sh --install   # baut und installiert nach /Applications
./build_app.sh --release   # notarisiert und baut build/ForkSync.dmg (eigene Apple-Zugangsdaten nötig)
```

Zusätzlich gibt es die Kommandozeilen-Variante `forksync.py` (Python 3.9+, nur Standardbibliothek, benötigt `gh`).

## Datenschutz

Die App spricht nur mit der GitHub-API. Es gibt keine Telemetrie. Der Workflow im Fork nutzt den von GitHub bereitgestellten `GITHUB_TOKEN`, es werden keine Secrets abgelegt.
