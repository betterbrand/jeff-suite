#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SESSION_FILE="$PROJECT_DIR/data/.last-session"

echo "=== Jeff Suite Teardown ==="
echo ""

# --- Close active session ---
if [ -f "$SESSION_FILE" ] && [ -f "$PROJECT_DIR/.env" ]; then
    COOKIE_CONTENT=$(grep '^COOKIE_CONTENT=' "$PROJECT_DIR/.env" | cut -d= -f2)
    AUTH_USER="${COOKIE_CONTENT%%:*}"
    AUTH_PASS="${COOKIE_CONTENT#*:}"
    SESSION_ID=$(cat "$SESSION_FILE")

    echo "Closing session $SESSION_ID ..."
    curl -sf -X POST -u "$AUTH_USER:$AUTH_PASS" \
        -H "Content-Type: application/json" \
        "http://localhost:8082/blockchain/sessions/$SESSION_ID/close" 2>/dev/null || true

    rm -f "$SESSION_FILE"
    echo "[OK] Session closed (unused MOR deposit will be refunded)"
else
    echo "No active session to close."
fi

# --- Stop containers ---
echo "Stopping proxy-router..."
cd "$PROJECT_DIR"
docker compose down
echo "[OK] Containers stopped"
echo ""
