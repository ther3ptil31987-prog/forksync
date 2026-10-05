# ForkSync

**Deutsch** · [English](README.md)

Mac-App, die deine GitHub-Forks aktuell hält – ohne deine eigenen Commits zu verlieren.

- **Automatisch**: Fork ohne eigene Commits wird gespiegelt (Fast-Forward). Mit eigenen Commits wird das Original eingemergt, bei Konflikten entsteht ein Pull Request.
- **Erkennt unechte „eigene" Commits** (Bots, Original-Autor nach umgeschriebener Historie).
- **Zeitplan per Dropdown** (stündlich bis wöchentlich), läuft als GitHub Action im jeweiligen Fork.
- **Sofort syncen** per Knopfdruck, auch wenn das Original Workflow-Dateien ändert.
- **Anmeldung per GitHub** (Device-Flow), das Token liegt im macOS-Schlüsselbund. Alternativ wird eine vorhandene `gh`-Anmeldung genutzt.
- **Lokale Klone aktuell halten**: Repos auswählen, ForkSync klont sie in einen Ordner auf dem Mac, vergleicht lokalen und GitHub-Stand und holt Rückstände per Fast-Forward, manuell oder zeitgesteuert, solange die App läuft. Lokale Änderungen und abweichende Historien bleiben unberührt, es wird nie gepusht.
- **Sichtbarkeit eigener Repos** (öffentlich/privat) mit deutlichen Warnhinweisen umschalten.
- **Deutsche und englische Oberfläche**, umschaltbar in der Toolbar.

## Installation

DMG aus den [Releases](../../releases) laden, `ForkSync` in den Ordner „Programme" ziehen, starten, „Anmelden" klicken. Die App ist mit Developer ID signiert und notarisiert (macOS 14+).

## Aus dem Quellcode bauen

```
./build_app.sh --install   # baut und installiert nach /Applications
./build_app.sh --release   # notarisiert und baut build/ForkSync.dmg (eigene Apple-Zugangsdaten nötig)
```

Zusätzlich gibt es die Kommandozeilen-Variante `forksync.py` (Python 3.9+, nur Standardbibliothek, benötigt `gh`).

## Lizenz

[PolyForm Noncommercial 1.0.0](LICENSE): Du darfst ForkSync **nicht-kommerziell** nutzen, ansehen, forken und verändern. **Kommerzielle Nutzung** (z. B. Verkauf, Einbau in ein bezahltes Produkt oder einen bezahlten Dienst) ist **nicht erlaubt**. Das ist damit keine Open-Source-Lizenz im Sinne der OSI, sondern „source-available". Für kommerzielle Nutzung bitte vorher beim Autor anfragen.

## Haftungsausschluss

Die Nutzung erfolgt **auf eigene Verantwortung**. Die Software wird in der vorliegenden Form und ohne Mängelgewähr bereitgestellt. Der Autor übernimmt, soweit gesetzlich zulässig, **keine Haftung** für Schäden jeder Art, insbesondere nicht für Datenverlust, veränderte, überschriebene oder gelöschte Commits, Branches, Pull Requests oder Workflows, fehlgeschlagene Synchronisierungen sowie versehentlich veröffentlichte oder zugänglich gemachte Daten (etwa durch das Umstellen eines Repos auf „öffentlich"). Prüfe Änderungen vor dem Ausführen und sichere wichtige Repositories.

## Datenschutz

Die App spricht nur mit der GitHub-API. Es gibt keine Telemetrie. Der Workflow im Fork nutzt den von GitHub bereitgestellten `GITHUB_TOKEN`, es werden keine Secrets abgelegt.
