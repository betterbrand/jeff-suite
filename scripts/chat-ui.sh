#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Start node if not running
cd "$PROJECT_DIR"
if ! docker compose ps --status running 2>/dev/null | grep -q proxy-router; then
    "$SCRIPT_DIR/start.sh"
fi

open "$PROJECT_DIR/chat.html"
