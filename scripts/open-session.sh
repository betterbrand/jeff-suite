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

echo "=== Open Session ==="
echo ""

# --- Get model ID ---
MODEL_ID="${1:-}"

if [ -z "$MODEL_ID" ]; then
    echo "No model ID provided. Searching for TEE providers (glmb5 preferred)..."
    echo ""

    MODELS=$(curl -sf -u "$AUTH_USER:$AUTH_PASS" "$API_URL/blockchain/models" 2>/dev/null)

    if [ -z "$MODELS" ]; then
        echo "[FAIL] Could not fetch models. Is the proxy-router running?"
        exit 1
    fi

    if command -v jq &>/dev/null; then
        # Try glmb5 first, then any TEE, then first available
        MODEL_ID=$(echo "$MODELS" | jq -r '
            ([ .[] | select((.Name // .name // "" | ascii_downcase) | contains("glmb5")) ] | first // null) //
            ([ .[] | select((.Tags // .tags // [] | join(",") | ascii_downcase) | contains("tee")) ] | first // null) //
            (first // null)
            | .Id // .id // empty
        ' 2>/dev/null || echo "")
    fi

    if [ -z "$MODEL_ID" ]; then
        echo "Could not auto-select a model. Run ./scripts/list-models.sh and pass the ID:"
        echo "  ./scripts/open-session.sh <MODEL_ID>"
        exit 1
    fi

    echo "Auto-selected model: $MODEL_ID"
fi

echo "Model ID: $MODEL_ID"
echo ""

# --- Approve MOR spending ---
echo "Approving MOR token spending..."
APPROVE_RESP=$(curl -sf -X POST -u "$AUTH_USER:$AUTH_PASS" \
    -H "Content-Type: application/json" \
    "$API_URL/blockchain/approve" 2>/dev/null || echo "")

if [ -n "$APPROVE_RESP" ]; then
    echo "[OK] MOR spending approved"
else
    echo "[WARN] Approve call returned empty response (may already be approved)"
fi

# --- Open session ---
echo "Opening session (this sends a blockchain transaction)..."

# Default session duration: 1 hour (3600 seconds)
SESSION_RESP=$(curl -sf -X POST -u "$AUTH_USER:$AUTH_PASS" \
    -H "Content-Type: application/json" \
    -d "{\"sessionDuration\": 3600}" \
    "$API_URL/blockchain/models/$MODEL_ID/session" 2>/dev/null || echo "")

if [ -z "$SESSION_RESP" ]; then
    echo "[FAIL] Session creation failed. Check:"
    echo "  - Wallet has at least 5 MOR (run ./scripts/balance.sh)"
    echo "  - Wallet has ETH for gas"
    echo "  - Proxy-router is healthy (run ./scripts/health.sh)"
    exit 1
fi

# Extract session ID
if command -v jq &>/dev/null; then
    SESSION_ID=$(echo "$SESSION_RESP" | jq -r '.sessionId // .SessionId // .session_id // empty' 2>/dev/null || echo "")
else
    SESSION_ID=$(echo "$SESSION_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('sessionId', d.get('SessionId', d.get('session_id', ''))))" 2>/dev/null || echo "")
fi

if [ -z "$SESSION_ID" ]; then
    echo "[WARN] Could not extract session ID from response."
    echo "Full response:"
    echo "$SESSION_RESP" | python3 -m json.tool 2>/dev/null || echo "$SESSION_RESP"
    exit 1
fi

# Save session
mkdir -p "$PROJECT_DIR/data"
echo "$SESSION_ID" > "$SESSION_FILE"

echo ""
echo "[OK] Session opened"
echo "  Session ID: $SESSION_ID"
echo "  Duration:   1 hour"
echo "  Saved to:   $SESSION_FILE"
echo ""
echo "  Next: ./scripts/chat.sh \"Hello, what model are you?\""
echo ""
