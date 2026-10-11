#!/usr/bin/env python3
"""Saves a reel note to the notes folder and rebuilds the index.

Usage: python3 -I save.py <note.md> [--no-push]

The note must start with frontmatter containing: title, source, id, author, summary, tags.
The file lands in <repo>/<subdir>/<id>.md, the index in README.md next to it.
If <repo> is a git repository, the change is committed (pulled and pushed unless --no-push).

Settings (environment variables):
  REEL_NOTES_REPO    notes folder or git repo (default ~/reel-notes)
  REEL_NOTES_SUBDIR  subfolder inside it for reel notes (default "notes")
"""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REQUIRED = ("title", "source", "id", "author", "summary", "tags")
INDEX_HEADER = """# Reel notes

Notes from watched reels (Instagram, TikTok, YouTube Shorts) — what matters in each one.
Created by the Claude Code plugin `reel-notes`. Videos and frames stay on the machine that
downloaded the reel (path in the note's `media` field).

This index is generated on every save — do not edit it by hand.

| Added | Reel | Author | Summary | Tags |
|---|---|---|---|---|
"""


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def read_frontmatter(text: str) -> dict[str, str]:
    match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not match:
        return {}
    fields: dict[str, str] = {}
    for line in match.group(1).splitlines():
        key, sep, value = line.partition(":")
        if sep and key.strip() and not key.startswith(" "):
            fields[key.strip()] = value.strip().strip('"').strip("'")
    return fields


def parse_tags(raw: str) -> list[str]:
    return [t.strip().strip("\"'") for t in raw.strip("[]").split(",") if t.strip()]


def cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def build_index(notes_dir: Path) -> str:
    rows: list[tuple[str, str, dict[str, str]]] = []
    for path in notes_dir.glob("*.md"):
        if path.name == "README.md":
            continue
        meta = read_frontmatter(path.read_text(encoding="utf-8"))
        if meta:
            rows.append((meta.get("added", ""), path.name, meta))
    rows.sort(key=lambda r: (r[0], r[1]), reverse=True)
    lines = [
        "| {} | [{}]({}) | {} | {} | {} |".format(
            cell(m.get("added", "")),
            cell(m.get("title", name)),
            name,
            cell(m.get("author", "")),
            cell(m.get("summary", "")),
            ", ".join(parse_tags(m.get("tags", ""))),
        )
        for _, name, m in rows
    ]
    return INDEX_HEADER + "\n".join(lines) + "\n"


def git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)


def has_remote(repo: Path) -> bool:
    return bool(git(repo, "remote").stdout.strip())


def commit(repo: Path, subdir: Path, meta: dict[str, str], existed: bool, push: bool) -> str:
    _ = git(repo, "add", str(subdir))
    if git(repo, "diff", "--cached", "--quiet").returncode == 0:
        return "UNCHANGED"
    verb = "update" if existed else "new"
    done = git(repo, "commit", "-q", "-m", f"notes: reel {meta['id']} ({verb}) — {meta['title']}")
    if done.returncode != 0:
        fail(f"git commit failed: {done.stderr.strip()}")
    if not push:
        return "committed, not pushed"
    pushed = git(repo, "push", "-q")
    if pushed.returncode != 0:
        fail(f"saved and committed locally, but git push failed: {pushed.stderr.strip()}")
    return "committed and pushed"


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        fail("usage: save.py <note.md> [--no-push]")

    note = Path(args[0]).expanduser()
    if not note.is_file():
        fail(f"file not found: {note}")
    meta = read_frontmatter(note.read_text(encoding="utf-8"))
    missing = [k for k in REQUIRED if not meta.get(k)]
    if missing:
        fail(f"note frontmatter is missing fields: {', '.join(missing)}")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", meta["id"]):
        fail(f"id may only contain letters, digits, - and _: {meta['id']}")

    repo = Path(os.environ.get("REEL_NOTES_REPO", "~/reel-notes")).expanduser()
    subdir = Path(os.environ.get("REEL_NOTES_SUBDIR", "notes"))
    if subdir.is_absolute() or ".." in subdir.parts:
        fail(f"REEL_NOTES_SUBDIR must be a relative path inside the repo: {subdir}")
    is_git = (repo / ".git").exists()
    push = is_git and "--no-push" not in sys.argv and has_remote(repo)

    if push:
        pulled = git(repo, "pull", "--rebase", "-q")
        if pulled.returncode != 0:
            fail(f"git pull failed: {pulled.stderr.strip()}")

    notes_dir = repo / subdir
    notes_dir.mkdir(parents=True, exist_ok=True)
    target = notes_dir / f"{meta['id']}.md"
    existed = target.exists()
    _ = shutil.copyfile(note, target)
    _ = (notes_dir / "README.md").write_text(build_index(notes_dir), encoding="utf-8")

    status = commit(repo, subdir, meta, existed, push) if is_git else "plain folder, no git"
    if status == "UNCHANGED":
        print(f"UNCHANGED: {target} already has this content")
    else:
        print(f"SAVED: {target} ({status})")


if __name__ == "__main__":
    main()
