#!/usr/bin/env python3
"""Refresh the local, code-only refactor graph using the project-pinned CLI."""

import hashlib
import json
import subprocess
import sys
import time
import tomllib
from datetime import datetime, timezone
from pathlib import Path


def main():
    root = Path(__file__).resolve().parents[1]
    environment = root / "tool/graphify/.venv"
    if Path(sys.prefix).resolve() != environment.resolve():
        raise SystemExit("Run through the project entry point: sh tool/graphify.sh refresh")
    python = Path(sys.executable)
    cli = python.parent / ("graphify.exe" if sys.platform == "win32" else "graphify")
    project = tomllib.loads((root / "tool/graphify/pyproject.toml").read_text())
    expected = next(
        line.split("==", 1)[1]
        for line in project["project"]["dependencies"]
        if line.startswith("graphifyy==")
    )
    actual = subprocess.check_output([str(cli), "--version"], text=True).strip()
    if actual != f"graphify {expected}":
        raise SystemExit(f"Version mismatch: {actual}; expected {expected}")
    if sys.argv[1:] not in ([], ["--force"]):
        raise SystemExit("Usage: sh tool/graphify.sh refresh [--force]")

    exclusions = [
        "vendor/**", "third_party/**", "src/assets/**", "desktop/assets/**",
        "packages/*/assets/**", "docs/**", "reports/**", "plans/**", "exports/**",
        "**/build/**", "**/Pods/**", "**/node_modules/**", "**/.dart_tool/**",
        "**/.fvm/**", "**/ephemeral/**", ".codex/**", ".graphify-venv/**",
        "graphify-out/**", "**/.venv/**",
    ]
    command = [str(cli), "extract", ".", "--code-only", "--no-cluster", "--out", "."]
    for pattern in exclusions:
        command.extend(["--exclude", pattern])
    command.extend(sys.argv[1:])
    output = root / "graphify-out"
    output.mkdir(exist_ok=True)
    started = time.monotonic()
    with (output / "refresh.log").open("w") as log:
        subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)

    graph_path = output / "graph.json"
    graph = json.loads(graph_path.read_text())
    source_files = sorted({
        node.get("source_file") for node in graph["nodes"] if node.get("source_file")
    })
    hashes = {}
    for relative in source_files:
        path = (root / relative).resolve()
        if path.is_relative_to(root) and path.is_file():
            hashes[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    source_digest = hashlib.sha256(
        json.dumps(hashes, sort_keys=True).encode()
    ).hexdigest()
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=root, text=True).strip()

    provenance = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "graphify": actual,
        "python": subprocess.check_output([str(python), "--version"], text=True).strip(),
        "head": git("rev-parse", "HEAD"),
        "branch": git("branch", "--show-current"),
        "dirty_worktree": bool(git("status", "--porcelain")),
        "command": command[1:],
        "duration_seconds": round(time.monotonic() - started, 3),
        "graph_sha256": hashlib.sha256(graph_path.read_bytes()).hexdigest(),
        "tool_lock_sha256": hashlib.sha256((root / "tool/graphify/uv.lock").read_bytes()).hexdigest(),
        "represented_source_sha256": source_digest,
        "nodes": len(graph["nodes"]),
        "edges": len(graph["edges"]),
        "represented_files": len(hashes),
        "source_hashes": hashes,
        "limitations": "File representation is not complete symbol/call coverage. Verify with analyzer and tests.",
    }
    (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    dependencies = subprocess.check_output([
        str(python), "-c",
        "from importlib.metadata import distributions; "
        "print('\\n'.join(sorted(f'{d.name}=={d.version}' for d in distributions())))",
    ], text=True)
    (output / "environment.txt").write_text(dependencies)
    print(f"{actual}: {len(graph['nodes'])} nodes, {len(graph['edges'])} edges; {len(hashes)} represented source files")
    print(f"Graph, provenance and log: {output}")


if __name__ == "__main__":
    main()
