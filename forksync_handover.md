# Übergabe: forksync

## Ziel
Kleines CLI-Tool (Python, eine Datei, nur Standardbibliothek), das alle eigenen
GitHub-Forks auflistet, den Status gegenüber dem Original prüft und für
ausgewählte Forks einen Auto-Sync als GitHub-Actions-Workflow einrichtet.
Ersatz für die GitHub-App "Pull" (wei/pull), die aktuell nicht installierbar ist
("This application cannot be installed at this time").

## Voraussetzungen
- Python 3.9+
- GitHub CLI `gh`, eingeloggt: `gh auth login`
- Scope zum Schreiben von Workflow-Dateien: `gh auth refresh -s workflow`
- Keine Tokens/Secrets im Tool oder Repo, Authentifizierung läuft nur über gh.

## Befehle
- `status [repo...]`  Alle Forks mit Status (aktuell / hinterher / eigene Commits / getrennt) und Auto-Sync-Modus
- `install [repo...]` Workflow einrichten; ohne Angabe interaktive Auswahl (z.B. `1,3,5-7` oder `a`)
- `adapt`             Forks mit Modus `ff`, die inzwischen eigene Commits haben, auf `pr` umstellen
- `run [repo...]`     Sync sofort anstoßen (workflow_dispatch)
- `remove [repo...]`  Workflow wieder löschen
- Optionen: `-y` (keine Rückfragen), `--mode ff|pr`, `--cron "..."` (Standard `17 5 * * *`, UTC), `--no-run`

## Funktionsweise
1. Eigene Repos laden (`user/repos?affiliation=owner`), nur Forks, keine archivierten.
2. Pro Fork per Compare-API (base = Original, head = Fork) ermitteln:
   `ahead_by` = eigene Commits im Fork, `behind_by` = neue Commits im Original.
3. Modus-Empfehlung: keine eigenen Commits -> `ff`, sonst `pr`.
4. Workflow `.github/workflows/upstream-sync.yml` per Contents-API in den Fork schreiben
   (erste Zeile `# mode: ff|pr` dient dem Tool zum Erkennen des Modus).
5. Zusätzlich per API: Actions im Fork aktivieren; im Modus `pr` die Einstellung
   "Allow GitHub Actions to create and approve pull requests" setzen.
6. Testlauf per workflow_dispatch (bis zu 4 Versuche, weil frische Workflows verzögert indexiert werden).

## Workflow-Logik (im Fork, täglich per Cron)
- Original schon enthalten -> nichts tun
- Fork hat keine eigenen Commits -> Fast-Forward auf den Default-Branch
- Fork hat eigene Commits:
  - Modus `ff`: nur Warnung, nichts ändern
  - Modus `pr`: Branch `upstream-sync` (force) pushen und PR gegen den Default-Branch anlegen, falls noch keiner offen ist

## Teststand
Getestet (in einer Sandbox ohne GitHub-Login):
- Syntax, YAML-Rendering beider Modi, JSON-Parsing der paginierten gh-Ausgabe, Auswahl-Parser, Status-Texte
- Shell-Logik des Workflows mit echtem git (lokale Repos): aktuell, Fast-Forward, Skip bei `ff`, PR-Branch bei `pr`

NICHT getestet:
- Alles gegen die echte GitHub-API (Aktivieren von Actions, PR-Berechtigung, workflow_dispatch)
- Der `gh pr create`-Teil im Workflow

Empfohlener erster Test: mit EINEM Fork starten, z.B. `python3 forksync.py install MEIN-FORK`,
Ergebnis im Reiter "Actions" des Forks prüfen.

## Bekannte Einschränkungen
- Nur Forks im eigenen Account, keine aus Organisationen.
- Ändert das Original Dateien unter `.github/workflows/`, lehnt GitHub den Push mit dem
  Standard-Token ab. Lösung wäre ein PAT mit `workflow`-Recht als Repo-Secret (bewusst nicht eingebaut).
- Es wird immer der Default-Branch des Forks mit dem Default-Branch des Originals verglichen/gesynct.
- Geplante Workflows in Forks pausiert GitHub nach ca. 60 Tagen ohne Repo-Aktivität.

## Mögliche nächste Schritte
- Gegen die echte API testen und Fehlerfälle nachziehen (Rate Limits, Fork ohne Parent, private Forks)
- Mehrere Branches pro Fork
- Optionaler Auto-Merge des Sync-PRs
- Organisationen unterstützen (`--org`)
- Status-Ausgabe als JSON (`--json`)
