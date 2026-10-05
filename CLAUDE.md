# ForkSync

Native SwiftUI-Mac-App (`Sources/ForkSync`) plus Python-CLI (`forksync.py`), beide auf Basis von `gh`.
Der Sync-Workflow-Text steht doppelt: `forksync.py` (`WORKFLOW`) und `Sources/ForkSync/Model.swift`
(`WorkflowTemplate.template`) — Änderungen immer in beiden Dateien machen.

## Nach jeder Code-Änderung (Steffen, 2026-10-05)

Sobald eine neue Version fertig ist, selbständig und ohne Rückfrage:

1. `pkill ForkSync; ./build_app.sh --install && open /Applications/ForkSync.app`
2. committen und pushen

Debug-Snapshot der Oberfläche ohne Bildschirmaufnahme-Recht:
`FORKSYNC_SNAPSHOT=/pfad/bild.png build/ForkSync.app/Contents/MacOS/ForkSync`
