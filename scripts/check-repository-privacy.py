#!/usr/bin/env python3
"""Check Git's staged bytes or reachable history without printing secret values."""

import argparse
import os
import re
import subprocess
import sys
from pathlib import PurePosixPath


ROOT_FILES = {".gitignore", "README.md", "LICENSE", "Package.swift"}
SCRIPT_FILES = {
    "scripts/package-local-app.sh", "scripts/run-tests.sh",
    "scripts/render-menu-icon.swift", "scripts/check-repository-privacy.py",
}
HOOK_FILES = {".githooks/pre-commit", ".githooks/pre-push"}
IMAGE_FILES = {
    "assets/AppIcon.svg", "assets/AppIcon.icns",
    "Sources/CodexAccountSwitcher/Resources/account-switcher-logo.png",
    "Sources/CodexAccountSwitcher/Resources/menu-icon-template.png",
}
BINARY_FILES = {name for name in IMAGE_FILES if not name.endswith(".svg")}
RUNTIME_NAMES = {
    "auth.json", "accounts.json", "settings.json", "usage-cache.json",
    "subscription-cache.json", "pending-login", "credential-operation",
}
BLOCKED_SUFFIXES = {
    ".app", ".zip", ".dmg", ".pkg", ".tar", ".gz", ".sqlite", ".db",
    ".jsonl", ".key", ".pem", ".p12", ".pfx", ".keychain", ".keychain-db",
}
SECRET_RULES = [
    ("private key", re.compile(rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----")),
    ("GitHub token", re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b")),
    ("API key", re.compile(rb"\bsk-[A-Za-z0-9_-]{24,}\b")),
    ("JWT", re.compile(rb"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b")),
    ("AWS access key", re.compile(rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("credential in URL", re.compile(rb"https?://[^\s/\"<>:]+:[^\s/\"<>]+@")),
]
EMAIL = re.compile(rb"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")
USER_PATH = re.compile(rb"/(?:Users|home)/([A-Za-z0-9._-]+)")
EXAMPLE_DOMAINS = {b"example.com", b"example.net", b"example.org", b"example.test", b"example.invalid"}


def git(*arguments):
    return subprocess.check_output(["git", *arguments], stderr=subprocess.PIPE)


def path_problem(name):
    path = PurePosixPath(name)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        return "unsafe path"
    for part in path.parts:
        if part in RUNTIME_NAMES or part.startswith(".env"):
            return "runtime data or environment file"
        if any(part.endswith(suffix) for suffix in BLOCKED_SUFFIXES):
            return "installer, archive or private data"
    if name in ROOT_FILES | SCRIPT_FILES | HOOK_FILES | IMAGE_FILES:
        return None
    if path.parts[0] == "Sources" and path.suffix in {".swift", ".c", ".h"}:
        return None
    if path.parts[0] == "Tests" and path.suffix == ".swift":
        return None
    return "file is outside the publication allowlist"


def content_problems(name, data, binary=False):
    problems = []
    if len(data) > 1_048_576:
        problems.append("file exceeds the source/resource size limit")
    if not binary:
        try:
            data.decode("utf-8")
        except UnicodeDecodeError:
            problems.append("unexpected binary content")
        if b"\0" in data:
            problems.append("unexpected NUL byte")
    for rule, pattern in SECRET_RULES:
        for match in pattern.finditer(data):
            line = data.count(b"\n", 0, match.start()) + 1
            problems.append(f"{rule} at line {line}")
    for match in EMAIL.finditer(data):
        domain = match.group(1).lower()
        if domain not in EXAMPLE_DOMAINS and domain != b"users.noreply.github.com":
            line = data.count(b"\n", 0, match.start()) + 1
            problems.append(f"non-example email at line {line}")
    for match in USER_PATH.finditer(data):
        fixture = name.startswith("Tests/") and match.group(1) == b"fixture"
        if not fixture:
            line = data.count(b"\n", 0, match.start()) + 1
            problems.append(f"machine-specific home path at line {line}")
    return problems


def staged_entries():
    for entry in git("ls-files", "--stage", "-z").split(b"\0"):
        if not entry:
            continue
        attributes, name = entry.split(b"\t", 1)
        mode, oid, stage = attributes.decode("ascii").split()
        if stage != "0":
            raise ValueError("Unmerged paths must be resolved before publication.")
        yield mode, oid, name.decode("utf-8")


def history_entries():
    for commit in git("rev-list", "--all").decode("ascii").splitlines():
        for entry in git("ls-tree", "-r", "-z", commit).split(b"\0"):
            if not entry:
                continue
            attributes, name = entry.split(b"\t", 1)
            mode, kind, oid = attributes.decode("ascii").split()
            yield mode, oid, name.decode("utf-8")


def check(entries):
    seen = set()
    failures = []
    for mode, oid, name in entries:
        key = (mode, oid, name)
        if key in seen:
            continue
        seen.add(key)
        problem = path_problem(name)
        if problem:
            failures.append((name, problem))
            continue
        if mode not in {"100644", "100755"}:
            failures.append((name, "symbolic links and submodules are not allowed"))
            continue
        data = git("cat-file", "blob", oid)
        for problem in content_problems(name, data, binary=name in BINARY_FILES):
            failures.append((name, problem))
    return len(seen), failures


def self_test():
    # Construct fake values at runtime rather than storing token-shaped literals.
    cases = [
        ("Sources/Example.swift", b"let value = 1\n", False, False),
        ("Tests/Example.swift", b"a@example.test /Users/" + b"fixture", False, False),
        ("Sources/Example.swift", b"gh" + b"p_" + b"A" * 36, False, True),
        ("Sources/Example.swift", b"sk" + b"-" + b"x" * 40, False, True),
        ("Sources/Example.swift", b"ey" + b"J" + b"a" * 20 + b"." + b"b" * 20 + b"." + b"c" * 20, False, True),
        ("Sources/Example.swift", b"-----BEGIN " + b"PRIVATE KEY-----", False, True),
        ("Sources/Example.swift", b"person@" + b"mail.invalid", False, True),
        ("Sources/Example.swift", b"/Users/" + b"someone/private", False, True),
        ("Sources/Example.swift", b"https://name:" + b"secret" + b"@" + b"host.invalid", False, True),
        ("Sources/Example.swift", b"\0binary", False, True),
        ("assets/AppIcon.icns", b"icns\0resource", True, False),
        ("assets/AppIcon.icns", b"icns\0person@" + b"mail.invalid", True, True),
    ]
    for name, data, binary, expected in cases:
        if bool(content_problems(name, data, binary)) != expected:
            raise ValueError("Content-rule self-test failed.")
    for name in ["gptswap.zip", "gptswap.app/Contents/MacOS/gptswap", "task_plan.md",
                 ".codex/notes.md", "Sources/auth.json", "Tests/accounts.json",
                 "Sources/unknown.png", "assets/unknown.icns", "../README.md"]:
        if not path_problem(name):
            raise ValueError("Publication allowlist self-test failed.")
    for name in ROOT_FILES | SCRIPT_FILES | HOOK_FILES | IMAGE_FILES:
        if path_problem(name):
            raise ValueError("Expected publication file was rejected.")
    print("Privacy rule self-tests passed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", action="store_true", help="also inspect every locally reachable commit tree")
    parser.add_argument("--self-test", action="store_true", help="check rules using synthetic values only")
    arguments = parser.parse_args()
    if arguments.self_test:
        self_test()
        return 0
    root = git("rev-parse", "--show-toplevel").decode().strip()
    os.chdir(root)
    count, failures = check(staged_entries())
    if arguments.history:
        history_count, history_failures = check(history_entries())
        count += history_count
        failures += history_failures
        metadata = git("log", "--all", "--format=%an <%ae>%n%cn <%ce>%n%B")
        failures += [("Git commit metadata", rule) for rule in content_problems("metadata", metadata)]
    if failures:
        for name, rule in sorted(set(failures)):
            print(f"BLOCKED: {name!r}: {rule}", file=sys.stderr)
        print("Nothing was uploaded by this check. Review privately before retrying.", file=sys.stderr)
        return 1
    print(f"Privacy check passed: {count} source/resource versions inspected.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (subprocess.CalledProcessError, UnicodeError, ValueError) as error:
        # Git stderr may contain URLs or private paths; do not echo it.
        print(f"Privacy check could not complete ({type(error).__name__}). Nothing was uploaded.", file=sys.stderr)
        sys.exit(1)
