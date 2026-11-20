#!/usr/bin/env bash
set -euo pipefail
kit_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec python3 - "$kit_dir" "$@" <<'PY'
from pathlib import Path
import argparse
import hashlib
import subprocess
import sys

kit = Path(sys.argv[1])
parser = argparse.ArgumentParser(description="Apply the Himiko LineageOS 23.2 platform patches.")
parser.add_argument("--source", type=Path, default=Path.cwd(), help="Android source root (default: current directory)")
parser.add_argument("--check", action="store_true", help="check every patch without changing source files")
args = parser.parse_args(sys.argv[2:])
root = args.source.resolve()
if not (root / "build/envsetup.sh").is_file():
    sys.exit("Not an Android source root: " + str(root))

def git(repo, *arguments):
    return subprocess.run(["git", *arguments], cwd=repo, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def index_hash(path):
    return hashlib.sha256(path.read_bytes()).digest() if path.is_file() else None

patches = sorted((kit / "patches").rglob("*.patch"))
if not patches:
    sys.exit("No patches found.")
projects = {}
checks = []
for patch in patches:
    project = patch.parent.relative_to(kit / "patches")
    repo = (root / project).resolve()
    if not repo.is_relative_to(root) or not (repo / ".git").exists():
        sys.exit("Missing source project: " + str(project))
    if repo not in projects:
        top = git(repo, "rev-parse", "--show-toplevel")
        if top.returncode or Path(top.stdout.decode().strip()).resolve() != repo:
            sys.exit("Unexpected Git checkout: " + str(project))
        conflicts = git(repo, "ls-files", "--unmerged")
        if conflicts.returncode or conflicts.stdout:
            sys.exit("Unresolved Git conflicts in " + str(project))
        index = git(repo, "rev-parse", "--path-format=absolute", "--git-path", "index")
        if index.returncode:
            sys.exit("Cannot locate Git index: " + str(project))
        index = Path(index.stdout.decode().strip())
        projects[repo] = (index, index_hash(index))
    forward = git(repo, "apply", "--check", "--whitespace=nowarn", str(patch))
    reverse = git(repo, "apply", "--check", "--reverse", "--whitespace=nowarn", str(patch))
    if reverse.returncode == 0:
        state = "applied"
    elif forward.returncode == 0:
        state = "needed"
    else:
        sys.stderr.write(forward.stderr.decode(errors="replace"))
        sys.exit("Patch conflict: " + str(patch.relative_to(kit)))
    checks.append((repo, patch, state))

# Complete preflight for every project before changing any source file.
if not args.check:
    for repo, patch, state in checks:
        if state == "needed":
            result = git(repo, "apply", "--whitespace=nowarn", str(patch))
            if result.returncode:
                sys.stderr.write(result.stderr.decode(errors="replace"))
                sys.exit("Could not apply " + str(patch.relative_to(kit)))
    for repo, patch, _ in checks:
        if git(repo, "apply", "--check", "--reverse", "--whitespace=nowarn", str(patch)).returncode:
            sys.exit("Verification failed: " + str(patch.relative_to(kit)))
for index, before in projects.values():
    if index_hash(index) != before:
        sys.exit("Git index changed unexpectedly: " + str(index))

needed = sum(state == "needed" for _, _, state in checks)
if args.check:
    print(f"Checked {len(checks)} patches in {len(projects)} projects: {needed} to apply, {len(checks) - needed} already applied.")
else:
    print(f"Verified {len(checks)} patches in {len(projects)} projects: {needed} applied, {len(checks) - needed} already present.")
PY
