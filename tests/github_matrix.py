"""GitHub-Testmatrix fuer den Sync-Workflow: legt 4 temporaere Repo-Paare an (auto/ff/pr/develop), spielt 12 Szenarien durch
und loescht alle Repos (Praefix forksync-t-) wieder. Braucht gh mit Scopes repo, workflow, delete_repo.
Hinweis: GitHub begrenzt das Anlegen vieler Repos - bei Rate-Limit spaeter erneut starten.
Start: python3 tests/github_matrix.py
"""
import subprocess, json, os, sys, time, shutil, re, tempfile, concurrent.futures as cf
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import forksync

U = sh_user = subprocess.run(['gh', 'api', 'user', '--jq', '.login'], capture_output=True, text=True).stdout.strip()
W = os.path.join(tempfile.gettempdir(), 'forksync-matrix')
PFX = 'forksync-t-'
os.environ.update(GIT_AUTHOR_NAME='tester', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='tester', GIT_COMMITTER_EMAIL='t@t',
                  GIT_TERMINAL_PROMPT='0')

def sh(cmd, cwd=None, check=True):
    r = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    if check and r.returncode:
        raise RuntimeError(f"{cmd}\n{r.stderr.strip()}")
    return r.stdout.strip()

def put(d, files):
    for p, c in files.items():
        os.makedirs(os.path.dirname(os.path.join(d, p)) or d, exist_ok=True)
        open(os.path.join(d, p), 'w').write(c)

def commit(d, files, msg, branch, force=False):
    put(d, files)
    sh('git add -A', d); sh(f'git commit -q -m "{msg}"', d)
    sh(f'git push -q {"-f " if force else ""}origin HEAD:{branch}', d)

def sha(repo, ref):
    return sh(f'gh api repos/{U}/{repo}/commits/{ref} --jq .sha')

def has_file(repo, path, ref):
    return subprocess.run(f'gh api "repos/{U}/{repo}/contents/{path}?ref={ref}"', shell=True, capture_output=True).returncode == 0

def prs(repo):
    return int(sh(f'gh pr list -R {U}/{repo} --state open --json number -q length'))

def setup(name, mode, branch):
    up, fk = PFX + name + '-up', PFX + name + '-fork'
    ud, fd = f'{W}/{name}-up', f'{W}/{name}-fork'
    os.makedirs(ud)
    sh(f'git init -q -b {branch}', ud)
    wf = forksync.render({'parent': f'{U}/{up}', 'pbranch': branch, 'branch': branch}, mode, '17 5 * * *')
    put(ud, {'shared.txt': 'zeile1\nzeile2\nzeile3\n', 'a.txt': 'base\n', '.github/workflows/upstream-sync.yml': wf})
    sh('git add -A && git commit -q -m base', ud)
    sh(f'gh repo create {U}/{up} --public --source=. --remote=origin --push', ud)
    sh(f'git clone -q https://github.com/{U}/{up}.git {fd}')
    sh('git remote rename origin upstream', fd)
    sh(f'gh repo create {U}/{fk} --private --source=. --remote=origin --push', fd)
    sh(f'gh api repos/{U}/{fk}/actions/permissions/workflow -X PUT -F default_workflow_permissions=write -F can_approve_pull_request_reviews=true')
    return up, fk, ud, fd

def run_wf(fk, branch):
    F = f'{U}/{fk}'
    before = sh(f'gh run list -R {F} --workflow upstream-sync.yml --limit 1 --json databaseId -q ".[0].databaseId"', check=False)
    ok = False
    for _ in range(8):
        if subprocess.run(f'gh api repos/{F}/actions/workflows/upstream-sync.yml/dispatches -X POST -f ref={branch}',
                          shell=True, capture_output=True).returncode == 0:
            ok = True; break
        time.sleep(4)
    if not ok:
        return 'dispatch-failed', []
    rid = before
    for _ in range(45):
        rid = sh(f'gh run list -R {F} --workflow upstream-sync.yml --limit 1 --json databaseId -q ".[0].databaseId"', check=False)
        if rid and rid != before: break
        time.sleep(2)
    concl = '?'
    for _ in range(80):
        concl = sh(f'gh run view {rid} -R {F} --json status,conclusion -q \'"\\(.status) \\(.conclusion)"\'', check=False)
        if concl.startswith('completed'): break
        time.sleep(3)
    log = sh(f'gh run view {rid} -R {F} --log', check=False)
    lines = []
    for l in log.splitlines():
        if '\t' in l and l.split('\t')[1] == 'Sync' and '[36;1m' not in l and '[0m' not in l:
            t = re.sub(r'^[^\t]+\t[^\t]+\t\S+ ', '', l)
            if re.search(r'Schon aktuell|Fast-Forward|eingemergt|Modus ff|Konflikt|rror|fatal|refusing|rejected|workflow|https://github.com/.*/pull/', t):
                lines.append(t.strip()[:150])
    return concl.replace('completed ', ''), lines

# ---------------------------------------------------------------- Szenarien
# Rueckgabe: (ok, Detail)
def sc_uptodate(c):
    s0 = sha(c['fk'], c['br']); r, log = run_wf(c['fk'], c['br'])
    return r == 'success' and any('Schon aktuell' in l for l in log) and sha(c['fk'], c['br']) == s0, f'{r} {log[:1]}'

def sc_own_only(c):  # eigener Commit, Original unveraendert
    commit(c['fd'], {'own.txt': 'mein\n'}, 'own', c['br']); s0 = sha(c['fk'], c['br'])
    r, log = run_wf(c['fk'], c['br'])
    return r == 'success' and any('Schon aktuell' in l for l in log) and sha(c['fk'], c['br']) == s0, f'{r} {log[:1]}'

def sc_ff(c):
    commit(c['ud'], {'b.txt': 'neu\n'}, 'up b', c['br'])
    r, log = run_wf(c['fk'], c['br'])
    return r == 'success' and any('Fast-Forward' in l for l in log) and sha(c['fk'], c['br']) == sha(c['up'], c['br']), f'{r} {log[:1]}'

def sc_merge(c):
    commit(c['fd'], {'own.txt': 'mein\n'}, 'own', c['br']); commit(c['ud'], {'up.txt': 'neu\n'}, 'up', c['br'])
    r, log = run_wf(c['fk'], c['br'])
    both = has_file(c['fk'], 'own.txt', c['br']) and has_file(c['fk'], 'up.txt', c['br'])
    return r == 'success' and both and prs(c['fk']) == 0, f'{r} beide-Dateien={both} {log[:1]}'

def sc_conflict(c):
    commit(c['fd'], {'shared.txt': 'zeile1\nzeile2 FORK\nzeile3\n'}, 'own', c['br'])
    commit(c['ud'], {'shared.txt': 'zeile1\nzeile2 UP\nzeile3\n'}, 'up', c['br'])
    s0 = sha(c['fk'], c['br']); r1, l1 = run_wf(c['fk'], c['br']); n1 = prs(c['fk'])
    r2, _ = run_wf(c['fk'], c['br']); n2 = prs(c['fk'])
    return r1 == 'success' and r2 == 'success' and n1 == 1 and n2 == 1 and sha(c['fk'], c['br']) == s0, f'{r1}/{r2} PRs={n1}/{n2} {l1[-1:]}'

def sc_workflowfile(c):
    commit(c['ud'], {'.github/workflows/other.yml': 'name: other\non: workflow_dispatch\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n'}, 'up wf', c['br'])
    s0 = sha(c['fk'], c['br']); r, log = run_wf(c['fk'], c['br'])
    return r == 'failure' and sha(c['fk'], c['br']) == s0, f'{r} (erwartet: failure, Fork unveraendert) {log[-1:]}'

def sc_rewrite(c):
    commit(c['ud'], {'c1.txt': '1\n'}, 'c1', c['br']); commit(c['ud'], {'c2.txt': '2\n'}, 'c2', c['br'])
    r1, _ = run_wf(c['fk'], c['br'])
    sh('git reset -q --hard HEAD~2', c['ud']); commit(c['ud'], {'c3.txt': '3\n'}, 'c3', c['br'], force=True)
    r2, log = run_wf(c['fk'], c['br'])
    files = [has_file(c['fk'], f, c['br']) for f in ('c1.txt', 'c2.txt', 'c3.txt')]
    return r1 == 'success' and r2 == 'success' and all(files), f'{r1}/{r2} c1,c2,c3={files} {log[:1]}'

def sc_ffmode_own(c):
    commit(c['fd'], {'own.txt': 'mein\n'}, 'own', c['br']); commit(c['ud'], {'up.txt': 'neu\n'}, 'up', c['br'])
    s0 = sha(c['fk'], c['br']); r, log = run_wf(c['fk'], c['br'])
    return r == 'success' and sha(c['fk'], c['br']) == s0 and prs(c['fk']) == 0, f'{r} {log[:1]}'

def sc_prmode_own(c):
    commit(c['fd'], {'own.txt': 'mein\n'}, 'own', c['br']); commit(c['ud'], {'up.txt': 'neu\n'}, 'up', c['br'])
    s0 = sha(c['fk'], c['br']); r, log = run_wf(c['fk'], c['br'])
    return r == 'success' and prs(c['fk']) == 1 and sha(c['fk'], c['br']) == s0, f'{r} PRs={prs(c["fk"])}'

SCEN = [  # name, mode, branch, func
    ('s01-aktuell', 'auto', 'main', sc_uptodate),
    ('s02-nur-eigener', 'auto', 'main', sc_own_only),
    ('s03-ff-auto', 'auto', 'main', sc_ff),
    ('s04-merge-sauber', 'auto', 'main', sc_merge),
    ('s05-konflikt-pr', 'auto', 'main', sc_conflict),
    ('s06-workflowdatei', 'auto', 'main', sc_workflowfile),
    ('s07-historie-umgeschrieben', 'auto', 'main', sc_rewrite),
    ('s08-ff-modus-eigener', 'ff', 'main', sc_ffmode_own),
    ('s09-ff-modus-rein', 'ff', 'main', sc_ff),
    ('s10-pr-modus-eigener', 'pr', 'main', sc_prmode_own),
    ('s11-pr-modus-rein', 'pr', 'main', sc_ff),
    ('s12-anderer-branch', 'auto', 'develop', sc_merge),
]

import threading
LOCK = threading.Lock()

def create(cmd, cwd):
    for _ in range(15):
        with LOCK:
            r = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
            if r.returncode == 0:
                time.sleep(8); return
        if 'too quickly' in r.stderr or 'too many' in r.stderr:
            time.sleep(60); continue
        raise RuntimeError(cmd + '\n' + r.stderr.strip())
    raise RuntimeError('Rate-Limit beim Anlegen')

def setup(name, mode, branch):
    up, fk = PFX + name + '-up', PFX + name + '-fork'
    ud, fd = f'{W}/{name}-up', f'{W}/{name}-fork'
    os.makedirs(ud)
    sh(f'git init -q -b {branch}', ud)
    wf = forksync.render({'parent': f'{U}/{up}', 'pbranch': branch, 'branch': branch}, mode, '17 5 * * *')
    put(ud, {'shared.txt': 'zeile1\nzeile2\nzeile3\n', 'a.txt': 'base\n', '.github/workflows/upstream-sync.yml': wf})
    sh('git add -A && git commit -q -m base', ud)
    base = sh('git rev-parse HEAD', ud)
    create(f'gh repo create {U}/{up} --public --source=. --remote=origin --push', ud)
    sh(f'git clone -q https://github.com/{U}/{up}.git {fd}')
    sh('git remote rename origin upstream', fd)
    create(f'gh repo create {U}/{fk} --private --source=. --remote=origin --push', fd)
    sh(f'gh api repos/{U}/{fk}/actions/permissions/workflow -X PUT -F default_workflow_permissions=write -F can_approve_pull_request_reviews=true')
    return dict(up=up, fk=fk, ud=ud, fd=fd, br=branch, base=base)

def reset(c):
    br, base = c['br'], c['base']
    sh(f'git reset -q --hard {base} && git push -q -f origin HEAD:{br}', c['ud'])
    sh(f'git reset -q --hard {base} && git push -q -f origin HEAD:{br}', c['fd'])
    sh(f'git push -q origin --delete upstream-sync', c['fd'], check=False)
    for n in sh(f'gh pr list -R {U}/{c["fk"]} --state open --json number -q ".[].number"', check=False).split():
        sh(f'gh pr close {n} -R {U}/{c["fk"]}', check=False)

FUNCS = {n: f for n, _, _, f in SCEN}
PAIRS = [('auto', 'auto', 'main', ['s01-aktuell', 's02-nur-eigener', 's03-ff-auto', 's04-merge-sauber', 's05-konflikt-pr',
                                   's06-workflowdatei', 's07-historie-umgeschrieben']),
         ('ff', 'ff', 'main', ['s08-ff-modus-eigener', 's09-ff-modus-rein']),
         ('pr', 'pr', 'main', ['s10-pr-modus-eigener', 's11-pr-modus-rein']),
         ('dev', 'auto', 'develop', ['s12-anderer-branch'])]

def run_pair(p):
    pname, mode, br, names = p
    out = []
    try:
        c = setup(pname, mode, br)
    except Exception as e:
        return [(n, mode, False, 'SETUP ' + str(e)[:160]) for n in names]
    for i, n in enumerate(names):
        try:
            if i: reset(c)
            ok, d = FUNCS[n](c)
        except Exception as e:
            ok, d = False, 'EXC ' + str(e)[:200]
        out.append((n, mode, ok, d))
    return out

if __name__ == '__main__':
    shutil.rmtree(W, ignore_errors=True); os.makedirs(W)
    res = []
    try:
        with cf.ThreadPoolExecutor(4) as ex:
            for part in ex.map(run_pair, PAIRS): res += part
    finally:
        names = sh(f'gh repo list {U} --limit 200 --json name -q ".[].name"', check=False).split()
        mine = [n for n in names if n.startswith(PFX)]
        with cf.ThreadPoolExecutor(4) as ex:
            list(ex.map(lambda n: sh(f'gh repo delete {U}/{n} --yes', check=False), mine))
        left = [n for n in sh(f'gh repo list {U} --limit 200 --json name -q ".[].name"', check=False).split() if n.startswith(PFX)]
        shutil.rmtree(W, ignore_errors=True)
    print('\n==== ERGEBNIS ====')
    for name, mode, ok, d in sorted(res):
        print(f"{'PASS' if ok else 'FAIL'}  {name:28} [{mode}]  {d}")
    print(f"\n{sum(1 for r in res if r[2])}/{len(res)} bestanden; Testrepos geloescht: {len(mine)}, uebrig: {len(left)}")
