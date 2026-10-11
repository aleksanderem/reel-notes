"""Tests for saving a note — on a temporary git repo / plain folder, without pushing."""
import os
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).parents[1] / "skills" / "reel" / "scripts" / "save.py"

NOTE = """---
title: 10 YouTube videos | a list
source: https://www.instagram.com/p/DY4APJfzrvy/
platform: instagram
id: DY4APJfzrvy
author: "@nickolai.vids"
added: 2026-10-11
tags: [youtube, inspiration]
summary: A list of 10 videos about life and learning
---

# Body
"""


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True, check=True
    ).stdout.strip()


@pytest.fixture()
def repo(tmp_path: Path) -> Path:
    path = tmp_path / "notes-repo"
    path.mkdir()
    for cmd in (
        ["init", "-q"],
        ["config", "user.email", "t@t"],
        ["config", "user.name", "t"],
        ["commit", "-q", "--allow-empty", "-m", "start"],
    ):
        _ = git(path, *cmd)
    return path


def run(note: Path, repo: Path, subdir: str = "notes") -> subprocess.CompletedProcess[str]:
    env = {**os.environ, "REEL_NOTES_REPO": str(repo), "REEL_NOTES_SUBDIR": subdir}
    return subprocess.run(
        [sys.executable, "-I", str(SCRIPT), str(note), "--no-push"],
        capture_output=True, text=True, env=env,
    )


def write(tmp_path: Path, text: str) -> Path:
    path = tmp_path / "note.md"
    _ = path.write_text(text, encoding="utf-8")
    return path


def index_of(repo: Path, subdir: str = "notes") -> str:
    return (repo / subdir / "README.md").read_text(encoding="utf-8")


def test_saves_note_builds_index_and_commits(tmp_path: Path, repo: Path) -> None:
    result = run(write(tmp_path, NOTE), repo)

    assert result.returncode == 0, result.stderr
    assert (repo / "notes" / "DY4APJfzrvy.md").read_text(encoding="utf-8") == NOTE
    index = index_of(repo)
    assert "[10 YouTube videos \\| a list](DY4APJfzrvy.md)" in index
    assert "@nickolai.vids" in index and "youtube, inspiration" in index
    assert git(repo, "log", "-1", "--format=%s").startswith("notes: reel DY4APJfzrvy (new)")


def test_custom_subdir(tmp_path: Path, repo: Path) -> None:
    result = run(write(tmp_path, NOTE), repo, subdir="notes/reels")

    assert result.returncode == 0, result.stderr
    assert (repo / "notes" / "reels" / "DY4APJfzrvy.md").exists()


def test_second_save_of_same_note_changes_nothing(tmp_path: Path, repo: Path) -> None:
    note = write(tmp_path, NOTE)
    _ = run(note, repo)
    result = run(note, repo)

    assert result.returncode == 0
    assert "UNCHANGED" in result.stdout
    assert index_of(repo).count("DY4APJfzrvy.md") == 1


def test_updated_note_is_committed_as_update(tmp_path: Path, repo: Path) -> None:
    _ = run(write(tmp_path, NOTE), repo)
    result = run(write(tmp_path, NOTE + "\nMore\n"), repo)

    assert result.returncode == 0, result.stderr
    assert "(update)" in git(repo, "log", "-1", "--format=%s")


def test_index_lists_newest_first(tmp_path: Path, repo: Path) -> None:
    _ = run(write(tmp_path, NOTE), repo)
    newer = NOTE.replace("DY4APJfzrvy", "NEW123").replace("2026-10-11", "2026-10-12")
    _ = run(write(tmp_path, newer), repo)

    index = index_of(repo)
    assert index.index("NEW123.md") < index.index("DY4APJfzrvy.md")


def test_plain_folder_without_git_still_saves(tmp_path: Path) -> None:
    folder = tmp_path / "plain"
    result = run(write(tmp_path, NOTE), folder)

    assert result.returncode == 0, result.stderr
    assert "plain folder" in result.stdout
    assert (folder / "notes" / "DY4APJfzrvy.md").exists()


def test_rejects_note_without_required_fields(tmp_path: Path, repo: Path) -> None:
    result = run(write(tmp_path, NOTE.replace("summary: A list of 10 videos about life and learning\n", "")), repo)

    assert result.returncode == 1
    assert "summary" in result.stderr
    assert not (repo / "notes").exists()


def test_rejects_id_with_path_characters(tmp_path: Path, repo: Path) -> None:
    result = run(write(tmp_path, NOTE.replace("id: DY4APJfzrvy", "id: ../../etc")), repo)

    assert result.returncode == 1
    assert "id may only contain" in result.stderr


def test_rejects_subdir_escaping_repo(tmp_path: Path, repo: Path) -> None:
    result = run(write(tmp_path, NOTE), repo, subdir="../outside")

    assert result.returncode == 1
    assert "REEL_NOTES_SUBDIR" in result.stderr
