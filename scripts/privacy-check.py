#!/usr/bin/env python3
"""Check source intended for publication, without printing matched secrets.

The rules catch common accidental disclosures; manual disclosure review remains
necessary. No files are uploaded and no external service is contacted.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    rule: str


# Only generic, explicitly synthetic account names are permitted in examples.
RULES = (
    ("personal-home-path", re.compile(r"/(?:Users|home)/(?!Shared(?:/|\b)|runner(?:/|\b)|example(?:/|\b)|synthetic(?:/|\b)|test-user(?:/|\b))[A-Za-z0-9._-]+/")),
    ("private-project-path", re.compile(r"(?:~/|\$HOME/)(?:proj|projects)/[A-Za-z0-9._-]+")),
    ("private-infrastructure-alias", re.compile(r"\b(?:devprod[0-9]+|web[0-9]+|ci[0-9]+)\b", re.IGNORECASE)),
    ("private-network-address", re.compile(r"\b(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})\b")),
    ("private-key-material", re.compile(r"-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----")),
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("github-token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{40,})\b")),
    ("credential-in-url", re.compile(r"[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]+@", re.IGNORECASE)),
)

FORBIDDEN_NAMES = {
    ".env", "local.xcconfig", "destinations.json", "known_hosts",
    "id_rsa", "id_ed25519", "id_ecdsa", "secrets.json",
}
FORBIDDEN_SUFFIXES = {
    ".p12", ".pfx", ".pem", ".key", ".mobileprovision", ".provisionprofile",
    ".log", ".sqlite", ".sqlite-wal", ".sqlite-shm", ".dmg", ".zip",
}
SKIP_DIRECTORIES = {".git", ".build", "build", ".swiftpm", "__pycache__"}


def inspect(path: str, data: bytes) -> list[Finding]:
    name = Path(path).name.lower()
    result: list[Finding] = []
    if (name in FORBIDDEN_NAMES or Path(name).suffix in FORBIDDEN_SUFFIXES
            or name.startswith(".env.") and not name.endswith((".example", ".sample"))):
        result.append(Finding(path, 0, "private-or-generated-file"))
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        # Native artwork is allowed; executable archives and credentials are not.
        if Path(name).suffix not in {".png", ".jpg", ".jpeg", ".webp", ".icns", ".pdf"}:
            result.append(Finding(path, 0, "unexpected-binary"))
        return result
    for number, line in enumerate(text.splitlines(), 1):
        for rule, pattern in RULES:
            if pattern.search(line):
                result.append(Finding(path, number, rule))
    return result


def git_output(root: Path, *arguments: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *arguments], stderr=subprocess.PIPE)


def source_files(root: Path, mode: str):
    if mode == "all":
        for path in sorted(root.rglob("*")):
            relative = path.relative_to(root)
            if path.name == ".DS_Store" or any(part in SKIP_DIRECTORIES or part.endswith(".xcodeproj") for part in relative.parts):
                continue
            if path.is_symlink():
                yield str(relative), None
            elif path.is_file():
                yield str(relative), path.read_bytes()
        return
    if mode == "staged":
        names = git_output(root, "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z")
        staged_modes = {}
        for row in git_output(root, "ls-files", "--stage", "-z").split(b"\0"):
            header, separator, name = row.partition(b"\t")
            if separator:
                staged_modes[name.decode("utf-8")] = header.split()[0]
    else:
        names = git_output(root, "ls-files", "-z")
    for encoded in names.split(b"\0"):
        if not encoded:
            continue
        name = encoded.decode("utf-8")
        path = root / name
        if mode == "staged" and staged_modes.get(name) == b"120000" or path.is_symlink():
            yield name, None
        elif mode == "staged":
            yield name, git_output(root, "show", ":" + name)
        elif path.is_file():
            yield name, path.read_bytes()


class PrivacyCheckTests(unittest.TestCase):
    def test_detects_sensitive_material_without_copying_it_into_findings(self):
        values = [
            "/" + "Users" + "/person/private.txt",
            "~" + "/proj/another-project/README.md",
            "dev" + "prod" + "7",
            ".".join(["192", "168", "2", "9"]),
            "-" * 5 + "BEGIN PRIVATE" + " KEY" + "-" * 5,
            "AK" + "IA" + "A" * 16,
            "ghp_" + "x" * 36,
            "https://" + "account:" + "secret@example.test",
        ]
        for value in values:
            findings = inspect("example.txt", value.encode())
            self.assertTrue(findings, value)
            self.assertNotIn(value, repr(findings))

    def test_allows_synthetic_and_platform_paths(self):
        safe = "/Applications/Xcode.app\n/Users/example/data\n/home/runner/work\n~/.ssh/config\nhttps://example.test"
        self.assertEqual(inspect("README.md", safe.encode()), [])

    def test_refuses_actual_configuration_and_signing_files(self):
        for path in ["Config/Local.xcconfig", ".env", ".env.production", "signing.p12", "destinations.json", "diagnostics.log", "state.sqlite"]:
            self.assertTrue(inspect(path, b"{}"), path)
        self.assertEqual(inspect("Config/Local.xcconfig.example", b"DEVELOPMENT_TEAM = YOURTEAMID"), [])

    def test_reports_only_location_and_rule(self):
        value = "ghp_" + "y" * 36
        findings = inspect("sample.swift", ("safe\n" + value).encode())
        self.assertEqual(findings, [Finding("sample.swift", 2, "github-token")])

    def test_all_source_mode_skips_generated_files_and_never_follows_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "source"
            root.mkdir()
            (root / "README.md").write_text("Synthetic source")
            for folder in ["build", ".build", ".git", "App.xcodeproj"]:
                directory = root / folder
                directory.mkdir()
                (directory / "generated.txt").write_text("generated")
            external = Path(temporary) / "outside.txt"
            external.write_text("Do not read this file through a symlink")
            (root / "link.txt").symlink_to(external)
            files = dict(source_files(root, "all"))
            self.assertEqual(set(files), {"README.md", "link.txt"})
            self.assertIsNone(files["link.txt"])
            self.assertEqual(files["README.md"], b"Synthetic source")

    def test_staged_mode_reads_index_blobs_and_refuses_staged_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "README.md").write_text("Different working-tree content")
            responses = {
                ("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"): b"README.md\0link.txt\0",
                ("ls-files", "--stage", "-z"): b"100644 abc 0\tREADME.md\0" + b"120000 def 0\tlink.txt\0",
                ("show", ":README.md"): b"Published index content",
            }
            with mock.patch(__name__ + ".git_output", side_effect=lambda _root, *args: responses[args]):
                files = dict(source_files(root, "staged"))
            self.assertEqual(files["README.md"], b"Published index content")
            self.assertIsNone(files["link.txt"])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--tracked", action="store_true", help="scan tracked working-tree source (default; CI)")
    modes.add_argument("--staged", action="store_true", help="scan staged blob contents before publishing")
    modes.add_argument("--all", action="store_true", help="scan source before git initialization, omitting generated directories")
    modes.add_argument("--self-test", action="store_true", help="exercise disclosure rules with synthetic strings")
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(PrivacyCheckTests)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    root = Path(__file__).resolve().parent.parent
    mode = "all" if args.all else "staged" if args.staged else "tracked"
    findings: list[Finding] = []
    checked = 0
    try:
        for name, data in source_files(root, mode):
            checked += 1
            findings.extend([Finding(name, 0, "source-symlink")] if data is None else inspect(name, data))
    except (OSError, UnicodeError, subprocess.CalledProcessError):
        print("Could not enumerate source. Use --all before git initialization.", file=sys.stderr)
        return 2
    for finding in findings:
        print(f"{finding.path}:{finding.line}: {finding.rule}")
    print(f"Checked {checked} source files; {len(findings)} potential disclosures.")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
