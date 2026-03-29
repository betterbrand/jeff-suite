#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
API_URL="http://localhost:8082"
SESSION_FILE="$PROJECT_DIR/data/.last-session"

# --- Load auth ---
if [ ! -f "$PROJECT_DIR/.env" ]; then
    echo "[FAIL] No .env found. Run ./scripts/setup.sh first."
    exit 1
fi

COOKIE_CONTENT=$(grep '^COOKIE_CONTENT=' "$PROJECT_DIR/.env" | cut -d= -f2)
AUTH_USER="${COOKIE_CONTENT%%:*}"
AUTH_PASS="${COOKIE_CONTENT#*:}"

# --- Get message ---
MESSAGE="${1:-}"
if [ -z "$MESSAGE" ]; then
    echo "Usage: ./scripts/chat.sh \"Your message here\" [SESSION_ID]"
    exit 1
fi

# --- Get session ID ---
SESSION_ID="${2:-}"
if [ -z "$SESSION_ID" ]; then
    if [ -f "$SESSION_FILE" ]; then
        SESSION_ID=$(cat "$SESSION_FILE")
    else
        echo "[FAIL] No active session. Run ./scripts/open-session.sh first."
        exit 1
    fi
fi

# --- Build request body ---
# Write to temp file to avoid shell quoting issues
BODY_FILE=$(mktemp)
python3 -c "
import json, sys
body = {
    'model': 'auto',
    'messages': [{'role': 'user', 'content': sys.argv[1]}],
    'stream': False
}
json.dump(body, open(sys.argv[2], 'w'))
" "$MESSAGE" "$BODY_FILE"

# --- Send request ---
RESPONSE=$(curl -sf -X POST -u "$AUTH_USER:$AUTH_PASS" \
    -H "Content-Type: application/json" \
    -H "session_id: $SESSION_ID" \
    -d @"$BODY_FILE" \
    "$API_URL/v1/chat/completions" 2>/dev/null || echo "")

rm -f "$BODY_FILE"

if [ -z "$RESPONSE" ]; then
    echo "[FAIL] No response. Check:"
    echo "  - Session is still active (sessions expire after their duration)"
    echo "  - Proxy-router is healthy (./scripts/health.sh)"
    exit 1
fi

# --- Display response ---
if command -v jq &>/dev/null; then
    CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null || echo "")
    if [ -n "$CONTENT" ]; then
        echo "$CONTENT"
    else
        echo "$RESPONSE" | jq .
    fi
else
    python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    c = d.get('choices', [{}])[0].get('message', {}).get('content', '')
    if c:
        print(c)
    else:
        print(json.dumps(d, indent=2))
except:
    print(sys.argv[1])
" "$RESPONSE"
fi
