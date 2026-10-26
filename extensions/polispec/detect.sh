#!/usr/bin/env bash
set -euo pipefail
command -v polispec >/dev/null 2>&1 || [ -e "$HOME/.rplugins/polispec" ]
