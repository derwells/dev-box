#!/usr/bin/env python3
"""dev-inventory.py — read-only inventory of git main checkouts under ~/dev.

Writes a clone manifest (TSV: relpath, url, branch) and a markdown report of
what must be pushed or decided before the machine is replaced. Never fetches,
gcs, stashes, or writes inside a repo (GIT_OPTIONAL_LOCKS=0 stops status from
refreshing the index).

  dev-inventory.py [--root ~/dev] [--tsv PATH] [--report PATH]

Defaults: ~/.config/dev-box/repos.tsv and ~/.config/dev-box/inventory.md
(files mode 600, directory mode 700). Pair with clone-dev.sh on the new box.
"""
import argparse
import os
import subprocess
import sys

MAX_DEPTH = 3
SKIP = {"node_modules", ".venv", ".git"}
CONF = os.path.expanduser("~/.config/dev-box")


def git(repo, *args):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True,
                       text=True, env=env)
    return r.stdout.strip() if r.returncode == 0 else ""


def find(root):
    """Return (repos, non_git) as relative paths."""
    repos, non_git = [], []

    def walk(path, depth):
        found = False
        try:
            entries = sorted(os.scandir(path), key=lambda e: e.name)
        except OSError:
            return False
        for e in entries:
            if e.name in SKIP or not e.is_dir(follow_symlinks=False):
                continue
            g = os.path.join(e.path, ".git")
            if os.path.isdir(g):
                repos.append(os.path.relpath(e.path, root))
                found = True
            elif os.path.isfile(g):
                found = True  # linked worktree: not a main checkout, not "non-git"
            elif depth < MAX_DEPTH:
                if walk(e.path, depth + 1):
                    found = True
        return found

    for e in sorted(os.scandir(root), key=lambda e: e.name):
        if e.name in SKIP or e.name.startswith(".") or not e.is_dir(follow_symlinks=False):
            continue
        g = os.path.join(e.path, ".git")
        if os.path.isdir(g):
            repos.append(e.name)
        elif os.path.isfile(g):
            continue
        elif not walk(e.path, 2):
            non_git.append(e.name)
    return sorted(repos), non_git


def inspect(root, rel):
    p = os.path.join(root, rel)
    url = git(p, "config", "--get", "remote.origin.url")
    cur = git(p, "symbolic-ref", "--short", "-q", "HEAD")
    default = git(p, "symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD")
    default = default.split("/", 1)[1] if "/" in default else ""
    if not default:
        heads = set(git(p, "for-each-ref", "--format=%(refname:short)",
                        "refs/heads").splitlines())
        default = next((b for b in ("main", "master") if b in heads), "")
    unpushed = []
    for name in git(p, "for-each-ref", "--format=%(refname:short)", "refs/heads").splitlines():
        n = int(git(p, "rev-list", "--count", name, "--not", "--remotes") or 0)
        if n:
            unpushed.append((name, n))
    local_total = int(git(p, "rev-list", "--count", "--branches", "--not", "--remotes") or 0)
    dirty = untracked = 0
    for line in git(p, "status", "--porcelain").splitlines():
        if line.startswith("??"):
            untracked += 1
        else:
            dirty += 1
    stash = len(git(p, "stash", "list").splitlines())
    return dict(rel=rel, url=url, cur=cur, default=default, unpushed=unpushed,
                local_total=local_total, dirty=dirty, untracked=untracked, stash=stash)


def problems(r):
    out = []
    if not r["url"]:
        out.append(f"no remote ({r['local_total']} local-only commits)")
    elif r["unpushed"]:
        out.append("; ".join(f"{b} (+{n} not on any remote)" for b, n in r["unpushed"]))
    if r["dirty"] or r["untracked"]:
        out.append(", ".join(x for x in (f"{r['dirty']} modified" if r["dirty"] else "",
                                         f"{r['untracked']} untracked" if r["untracked"] else "") if x))
    if r["stash"]:
        out.append(f"{r['stash']} stash(es)")
    return out


def write_private(path, text):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, mode=0o700, exist_ok=True)
    if d == CONF:
        os.chmod(d, 0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(path, 0o600)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--root", default=os.path.expanduser("~/dev"))
    ap.add_argument("--tsv", default=os.path.join(CONF, "repos.tsv"))
    ap.add_argument("--report", default=os.path.join(CONF, "inventory.md"))
    a = ap.parse_args()
    root = os.path.abspath(a.root)

    repos, non_git = find(root)
    info = [inspect(root, r) for r in repos]
    bad = [(r, problems(r)) for r in info]
    must = [(r, p) for r, p in bad if p]
    clean = [r for r, p in bad if not p]

    tsv = "".join(f"{r['rel']}\t{r['url']}\t{r['cur'] or r['default']}\n"
                  for r in info if r["url"])
    write_private(a.tsv, tsv)

    summary = (f"{len(info)} repos, {sum(1 for r in info if r['url'])} cloneable, "
               f"{len(must)} needing a decision")
    md = ["# Dev inventory", "", summary, "", "## Must push or decide", ""]
    md += [f"- `{r['rel']}`: " + "; ".join(p) for r, p in must] or ["(none)"]
    md += ["", "## Clean, will be cloned", ""]
    md += [f"- `{r['rel']}` ({r['cur'] or 'detached'}, default {r['default'] or '?'})"
           for r in clean] or ["(none)"]
    md += ["", "## Not git", ""]
    md += [f"- `{n}`" for n in non_git] or ["(none)"]
    write_private(a.report, "\n".join(md) + "\n")

    print(summary + f"; {len(clean)} clean, {len(non_git)} not git")
    print(f"wrote {a.tsv} and {a.report}")


if __name__ == "__main__":
    sys.exit(main())
