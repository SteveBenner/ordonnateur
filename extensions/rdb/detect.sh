#!/usr/bin/env bash
set -euo pipefail
command -v rdb >/dev/null 2>&1 || [ -e "$HOME/.rplugins/rdb" ] || [ -e "$HOME/.rdb" ] || [ -n "${RDB_WRITE_URL:-}" ]
