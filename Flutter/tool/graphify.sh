#!/bin/sh
# Project-owned Graphify environment; Python itself remains managed by uv.
set -eu
workspace=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$workspace"
if [ "${1:-refresh}" = refresh ]; then
    if [ "$#" -gt 0 ]; then shift; fi
    exec uv run --managed-python --python 3.13 --project tool/graphify --locked \
        python tool/graphify_refresh.py "$@"
fi
exec uv run --managed-python --python 3.13 --project tool/graphify --locked \
    graphify "$@"
