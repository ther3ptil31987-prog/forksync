#!/usr/bin/env python3
"""forksync - eigene GitHub-Forks automatisch mit dem Original synchron halten.

Voraussetzungen: Python 3.9+, GitHub CLI (gh), eingeloggt via `gh auth login`.
Zum Schreiben von Workflow-Dateien braucht gh den Scope "workflow":
    gh auth refresh -s workflow

Befehle:
    status   [repo ...]   Alle Forks mit Status anzeigen (eigene Commits? hinterher?)
    install  [repo ...]   Auto-Sync-Workflow in gewaehlten Forks einrichten
    adapt                 Forks mit Modus "ff", die eigene Commits haben, auf "pr" umstellen
    run      [repo ...]   Sync-Workflow im Fork anstossen
    sync     [repo ...]   Sofort mit dem eigenen Login syncen (auch bei geaenderten Workflow-Dateien)
    remove   [repo ...]   Workflow wieder entfernen

Modi:
    auto  Standard. Keine eigenen Commits -> Spiegel (Fast-Forward). Eigene Commits ->
          Original wird eingemergt, eigene Commits bleiben erhalten (nie Force-Push auf
          den Default-Branch). Bei Konflikt: Pull Request "upstream-sync".
    ff    Nur Fast-Forward. Hat der Fork eigene Commits, wird nichts veraendert.
    pr    Fast-Forward wenn moeglich, sonst immer Pull Request "upstream-sync".
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

WF_NAME = "upstream-sync.yml"
WF_PATH = f".github/workflows/{WF_NAME}"
MODES = ("auto", "ff", "pr")

WORKFLOW = """\
# mode: @@MODE@@
# Verwaltet von forksync.py - manuelle Aenderungen werden beim Update ueberschrieben.
name: Upstream sync
on:
  schedule:
    - cron: '@@CRON@@'
  workflow_dispatch:
permissions:
  contents: write
  pull-requests: write
jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: @@BRANCH@@
          fetch-depth: 0
      - name: Sync
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -e
          git remote add upstream "https://github.com/@@UPSTREAM@@.git"
          git fetch upstream "@@UPSTREAM_BRANCH@@"
          UP="upstream/@@UPSTREAM_BRANCH@@"

          if git merge-base --is-ancestor "$UP" HEAD; then
            echo "Schon aktuell"; exit 0
          fi

          if git merge-base --is-ancestor HEAD "$UP"; then
            if git push origin "$UP:refs/heads/@@BRANCH@@"; then
              echo "Fast-Forward durchgefuehrt"; exit 0
            fi
            if gh api "repos/$GITHUB_REPOSITORY/merge-upstream" -X POST -f branch="@@BRANCH@@" > /dev/null; then
              echo "Fast-Forward durchgefuehrt (GitHub-Sync-API)"; exit 0
            fi
            echo "::error::Push abgelehnt (z. B. aendert das Original .github/workflows). In der App 'Syncen' nutzen."
            exit 1
          fi

          if [ "@@MODE@@" = "ff" ]; then
            echo "::warning::Fork hat eigene Commits, Fast-Forward nicht moeglich (Modus ff). Nichts geaendert."
            exit 0
          fi

          if [ "@@MODE@@" = "auto" ]; then
            git config user.name "forksync"
            git config user.email "forksync@users.noreply.github.com"
            if git merge --no-edit "$UP" && git push origin "HEAD:refs/heads/@@BRANCH@@"; then
              echo "Original eingemergt, eigene Commits bleiben erhalten"; exit 0
            fi
            git merge --abort 2>/dev/null || true
            git reset --hard "origin/@@BRANCH@@"
            if gh api "repos/$GITHUB_REPOSITORY/merge-upstream" -X POST -f branch="@@BRANCH@@" > /dev/null 2>&1; then
              echo "Original eingemergt (GitHub-Sync-API), eigene Commits bleiben erhalten"; exit 0
            fi
            echo "::warning::Automatischer Merge nicht moeglich (Konflikt), Pull Request wird erstellt."
          fi

          if ! git push --force origin "$UP:refs/heads/upstream-sync"; then
            echo "::error::Push abgelehnt (z. B. aendert das Original .github/workflows). In der App 'Syncen' nutzen."
            exit 1
          fi
          if [ -z "$(gh pr list --repo "$GITHUB_REPOSITORY" --head upstream-sync --state open --json number -q '.[].number')" ]; then
            gh pr create --repo "$GITHUB_REPOSITORY" --base "@@BRANCH@@" --head upstream-sync \\
              --title "Sync with upstream" \\
              --body "Automatisch erstellt von forksync: neue Aenderungen aus @@UPSTREAM@@."
          fi
"""


# --------------------------------------------------------------------------- gh

class GhError(Exception):
    pass


def gh(*args: str, stdin: str | None = None) -> str:
    p = subprocess.run(["gh", *args], input=stdin, capture_output=True, text=True)
    if p.returncode != 0:
        raise GhError((p.stderr or p.stdout).strip())
    return p.stdout


def parse_json(text: str):
    """Parst eine oder mehrere aneinandergehaengte JSON-Werte (gh --paginate)."""
    text = text.strip()
    if not text:
        return None
    dec, i, items = json.JSONDecoder(), 0, []
    while i < len(text):
        obj, i = dec.raw_decode(text, i)
        items.append(obj)
        while i < len(text) and text[i].isspace():
            i += 1
    if len(items) == 1:
        return items[0]
    merged: list = []
    for it in items:
        merged.extend(it)
    return merged


def api(path: str, method: str = "GET", body: dict | None = None, paginate: bool = False):
    cmd = ["api", path, "-X", method]
    if paginate:
        cmd.append("--paginate")
    if body is not None:
        cmd += ["--input", "-"]
    out = gh(*cmd, stdin=json.dumps(body) if body is not None else None)
    return parse_json(out)


# ------------------------------------------------------------------- Fork-Daten

def inspect(repo: dict) -> dict:
    full = repo["full_name"]
    owner = repo["owner"]["login"]
    info: dict = {"full": full, "name": repo["name"], "branch": repo["default_branch"], "wf": None}
    try:
        detail = api(f"repos/{full}")
        parent = detail.get("parent")
        if not parent:
            info["error"] = "kein Original gefunden"
            return info
        info["parent"] = parent["full_name"]
        info["pbranch"] = parent["default_branch"]

        # base = Original, head = Fork:
        #   ahead_by  = eigene Commits im Fork
        #   behind_by = neue Commits im Original
        cmp_ = api(f"repos/{parent['full_name']}/compare/"
                   f"{parent['default_branch']}...{owner}:{info['branch']}")
        info["ahead"] = cmp_["ahead_by"]
        info["behind"] = cmp_["behind_by"]

        try:
            f = api(f"repos/{full}/contents/{WF_PATH}?ref={info['branch']}")
            text = base64.b64decode(f["content"]).decode()
            m = re.search(r"# mode: (\w+)", text)
            info["wf"] = {"sha": f["sha"], "mode": m.group(1) if m else "?"}
        except GhError:
            pass  # Workflow nicht vorhanden
    except GhError as e:
        info["error"] = str(e).splitlines()[0] if str(e) else "Fehler"
    return info


def load_forks() -> list[dict]:
    repos = api("user/repos?affiliation=owner&per_page=100", paginate=True) or []
    forks = [r for r in repos if r["fork"] and not r["archived"]]
    print(f"{len(forks)} Forks gefunden, pruefe Status ...", file=sys.stderr)
    with ThreadPoolExecutor(8) as ex:
        infos = list(ex.map(inspect, forks))
    return sorted(infos, key=lambda i: i["full"].lower())


def recommend(i: dict) -> str:
    return "auto"


def status_text(i: dict) -> str:
    if "error" in i:
        return f"Fehler: {i['error']}"
    a, b = i["ahead"], i["behind"]
    if a == 0 and b == 0:
        return "aktuell"
    if a == 0:
        return f"{b} neue Commits im Original"
    if b == 0:
        return f"{a} eigene Commits, Original unveraendert"
    return f"getrennt: {a} eigene / {b} neue"


def needs_adapt(i: dict) -> bool:
    return bool(i["wf"]) and i["wf"]["mode"] == "ff" and i.get("ahead", 0) > 0  # -> auto


# ------------------------------------------------------------------ Ausgabe/Wahl

def print_table(infos: list[dict]) -> None:
    rows = []
    for n, i in enumerate(infos, 1):
        auto = "-" if not i["wf"] else f"an ({i['wf']['mode']})"
        rows.append((str(n), i["name"], status_text(i), auto))
    head = ("#", "Repo", "Status", "Auto-Sync")
    widths = [max(len(r[c]) for r in rows + [head]) for c in range(4)]
    for r in [head, *rows]:
        print("  ".join(r[c].ljust(widths[c]) for c in range(4)))


def parse_selection(text: str, n: int) -> list[int]:
    text = text.strip().lower()
    if text in ("a", "alle", "all"):
        return list(range(n))
    picked: set[int] = set()
    for part in text.replace(" ", "").split(","):
        if not part:
            continue
        m = re.fullmatch(r"(\d+)(?:-(\d+))?", part)
        if not m:
            raise ValueError(f"Ungueltige Eingabe: {part}")
        lo, hi = int(m.group(1)), int(m.group(2) or m.group(1))
        if lo < 1 or hi > n or lo > hi:
            raise ValueError(f"Ausserhalb des Bereichs: {part}")
        picked.update(range(lo - 1, hi))
    return sorted(picked)


def pick(infos: list[dict], names: list[str], only: list[dict] | None = None) -> list[dict]:
    pool = infos if only is None else only
    if names:
        out = []
        for name in names:
            hit = [i for i in pool if name.lower() in (i["name"].lower(), i["full"].lower())]
            if not hit:
                sys.exit(f"Fork nicht gefunden (oder nicht passend): {name}")
            out.append(hit[0])
        return out
    if not pool:
        sys.exit("Keine passenden Forks.")
    print_table(pool)
    answer = input("\nAuswahl (z.B. 1,3,5-7 | a = alle | Enter = Abbruch): ")
    if not answer.strip():
        sys.exit("Abgebrochen.")
    try:
        return [pool[k] for k in parse_selection(answer, len(pool))]
    except ValueError as e:
        sys.exit(str(e))


def confirm(question: str, yes: bool) -> None:
    if yes:
        return
    if input(f"{question} [j/N] ").strip().lower() not in ("j", "y", "ja", "yes"):
        sys.exit("Abgebrochen.")


# ------------------------------------------------------------------------ Aktionen

def render(i: dict, mode: str, cron: str) -> str:
    return (WORKFLOW.replace("@@MODE@@", mode)
            .replace("@@CRON@@", cron)
            .replace("@@UPSTREAM@@", i["parent"])
            .replace("@@UPSTREAM_BRANCH@@", i["pbranch"])
            .replace("@@BRANCH@@", i["branch"]))


def dispatch(full: str, branch: str) -> bool:
    for _ in range(4):
        try:
            api(f"repos/{full}/actions/workflows/{WF_NAME}/dispatches", "POST", {"ref": branch})
            return True
        except GhError:
            time.sleep(3)  # frisch angelegter Workflow ist evtl. noch nicht indexiert
    return False


def enable_workflow(full: str) -> bool:
    """Forks starten mit deaktivierten Workflows (disabled_fork) - einzeln aktivieren."""
    for _ in range(4):
        try:
            api(f"repos/{full}/actions/workflows/{WF_NAME}/enable", "PUT")
            return True
        except GhError:
            time.sleep(3)
    return False


def do_install(i: dict, mode: str | None, cron: str, run: bool) -> None:
    if "error" in i:
        print(f"- {i['name']}: uebersprungen ({i['error']})")
        return
    mode = mode or recommend(i)
    body = {
        "message": f"Add upstream sync workflow (forksync, mode {mode})",
        "content": base64.b64encode(render(i, mode, cron).encode()).decode(),
    }
    if i["wf"]:
        body["sha"] = i["wf"]["sha"]
    try:
        api(f"repos/{i['full']}/contents/{WF_PATH}", "PUT", body)
    except GhError as e:
        hint = "  -> `gh auth refresh -s workflow` ausfuehren" if "workflow" in str(e).lower() else ""
        print(f"- {i['name']}: FEHLER beim Schreiben: {str(e).splitlines()[0]}{hint}")
        return

    notes = []
    try:
        api(f"repos/{i['full']}/actions/permissions", "PUT", {"enabled": True})
    except GhError:
        notes.append("Actions bitte im Reiter 'Actions' des Forks manuell aktivieren")
    if mode in ("pr", "auto"):
        try:  # noetig, damit der Workflow Pull Requests anlegen darf
            api(f"repos/{i['full']}/actions/permissions/workflow", "PUT",
                {"default_workflow_permissions": "write", "can_approve_pull_request_reviews": True})
        except GhError:
            notes.append("Settings > Actions > General: 'Allow GitHub Actions to create "
                         "and approve pull requests' manuell aktivieren")
    if not enable_workflow(i["full"]):
        notes.append("Workflow konnte nicht aktiviert werden (Reiter 'Actions' des Forks)")
    if run and not dispatch(i["full"], i["branch"]):
        notes.append("Testlauf konnte nicht gestartet werden (spaeter `run` nutzen)")

    print(f"- {i['name']}: eingerichtet (Modus {mode})" + "".join(f"\n    ! {n}" for n in notes))


def cmd_status(args, infos):
    print_table(infos)
    warn = [i for i in infos if needs_adapt(i)]
    if warn:
        print("\nAchtung: Modus 'ff' reicht hier nicht mehr (eigene Commits):")
        for i in warn:
            print(f"  - {i['name']}")
        print("Mit `forksync.py adapt` auf Modus 'auto' umstellen.")


def cmd_install(args, infos):
    chosen = pick(infos, args.repos)
    for i in chosen:
        print(f"{i['name']}: Modus {args.mode or recommend(i)}"
              + ("  (eigene Commits erkannt)" if i.get("ahead") else ""))
    confirm(f"\nIn {len(chosen)} Fork(s) einrichten?", args.yes)
    for i in chosen:
        do_install(i, args.mode, args.cron, not args.no_run)


def cmd_adapt(args, infos):
    todo = [i for i in infos if needs_adapt(i)]
    if not todo:
        print("Nichts anzupassen.")
        return
    for i in todo:
        print(f"{i['name']}: ff -> auto ({i['ahead']} eigene Commits)")
    confirm(f"\n{len(todo)} Fork(s) umstellen?", args.yes)
    for i in todo:
        do_install(i, "auto", args.cron, False)


def cmd_run(args, infos):
    for i in pick(infos, args.repos, [x for x in infos if x["wf"]]):
        ok = dispatch(i["full"], i["branch"])
        print(f"- {i['name']}: {'gestartet' if ok else 'FEHLER beim Starten'}")


def cmd_sync(args, infos):
    """Sofort mit dem eigenen Login syncen (GitHubs merge-upstream, klappt auch bei Workflow-Aenderungen)."""
    for i in pick(infos, args.repos):
        if "error" in i:
            print(f"- {i['name']}: uebersprungen ({i['error']})")
            continue
        try:
            r = api(f"repos/{i['full']}/merge-upstream", "POST", {"branch": i["branch"]}) or {}
            t = r.get("merge_type")
            print(f"- {i['name']}: " + {"none": "schon aktuell", "fast-forward": "Fast-Forward durchgefuehrt"}.get(
                t, "Original eingemergt, eigene Commits bleiben erhalten"))
        except GhError as e:
            print(f"- {i['name']}: FEHLER: {str(e).splitlines()[0]}")


def cmd_remove(args, infos):
    chosen = pick(infos, args.repos, [x for x in infos if x["wf"]])
    confirm(f"Workflow in {len(chosen)} Fork(s) entfernen?", args.yes)
    for i in chosen:
        try:
            api(f"repos/{i['full']}/contents/{WF_PATH}", "DELETE",
                {"message": "Remove upstream sync workflow (forksync)", "sha": i["wf"]["sha"]})
            print(f"- {i['name']}: entfernt")
        except GhError as e:
            print(f"- {i['name']}: FEHLER: {str(e).splitlines()[0]}")


def main() -> None:
    ap = argparse.ArgumentParser(description="GitHub-Forks automatisch synchron halten.")
    ap.add_argument("-y", "--yes", action="store_true", help="Rueckfragen ueberspringen")
    sub = ap.add_subparsers(dest="cmd", required=True)

    for name, fn, helptext in [
        ("status", cmd_status, "Forks und Status anzeigen"),
        ("install", cmd_install, "Auto-Sync einrichten"),
        ("adapt", cmd_adapt, "ff-Forks mit eigenen Commits auf pr umstellen"),
        ("run", cmd_run, "Sync-Workflow im Fork starten"),
        ("sync", cmd_sync, "Sofort mit eigenem Login syncen (ohne Workflow)"),
        ("remove", cmd_remove, "Auto-Sync entfernen"),
    ]:
        p = sub.add_parser(name, help=helptext)
        p.set_defaults(fn=fn)
        if name in ("install", "run", "remove", "sync"):
            p.add_argument("repos", nargs="*", help="Repo-Name(n); ohne Angabe: interaktive Auswahl")
        if name in ("install", "adapt"):
            p.add_argument("--cron", default="17 5 * * *", help="Zeitplan (UTC), Standard: taeglich 05:17")
        if name == "install":
            p.add_argument("--mode", choices=MODES, help="Modus erzwingen (Standard: automatisch)")
            p.add_argument("--no-run", action="store_true", help="Keinen Testlauf starten")

    args = ap.parse_args()
    try:
        gh("auth", "status")
        infos = load_forks()
        args.fn(args, infos)
    except FileNotFoundError:
        sys.exit("GitHub CLI (gh) nicht gefunden: https://cli.github.com/")
    except GhError as e:
        sys.exit(f"gh-Fehler: {e}")


if __name__ == "__main__":
    main()
