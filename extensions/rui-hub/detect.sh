#!/usr/bin/env bash
set -euo pipefail
command -v rui-hub >/dev/null 2>&1 || [ -e "$HOME/.rplugins/rui-hub" ]
