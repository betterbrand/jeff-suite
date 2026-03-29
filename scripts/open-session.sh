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
    echo "Searching for TEE providers (glmb5 preferred)..."
    echo ""

    # Wait for the proxy-router API to be ready and return models
    MODELS=""
    RETRIES=0
    MAX_RETRIES=12
    while [ $RETRIES -lt $MAX_RETRIES ]; do
        MODELS=$(curl -sf -u "$AUTH_USER:$AUTH_PASS" "$API_URL/blockchain/models" 2>/dev/null || echo "")
        # Check if we got a non-empty response with actual models
        HAS_MODELS=$(echo "$MODELS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('models', data) if isinstance(data, dict) else data
    print('yes' if isinstance(models, list) and len(models) > 0 else 'no')
except:
    print('no')
" 2>/dev/null || echo "no")
        if [ "$HAS_MODELS" = "yes" ]; then
            break
        fi
        RETRIES=$((RETRIES + 1))
        if [ $RETRIES -eq 1 ]; then
            echo "  Waiting for the node to sync with the blockchain..."
        fi
        echo "  Checking for models... (attempt $RETRIES/$MAX_RETRIES)"
        sleep 10
    done

    if [ -z "$MODELS" ] || [ "$MODELS" = "null" ] || [ "$MODELS" = "[]" ]; then
        echo "[FAIL] No models found after ${MAX_RETRIES} attempts."
        echo ""
        echo "  The node may still be syncing. Try again in a minute:"
        echo "    ./scripts/list-models.sh"
        echo "    ./scripts/open-session.sh"
        exit 1
    fi

    # Auto-select: glm-5 TEE > any TEE with glm > any TEE > glm-5 > first LLM
    MODEL_ID=$(echo "$MODELS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('models', data) if isinstance(data, dict) else data
    if not isinstance(models, list):
        models = []
    # Filter to LLMs only
    llms = [m for m in models if (m.get('ModelType') or m.get('modelType') or '') == 'LLM']
    if not llms:
        llms = models
    def tags_lower(m):
        t = m.get('Tags') or m.get('tags') or []
        return ','.join(t).lower() if isinstance(t, list) else str(t).lower()
    def name_lower(m):
        return (m.get('Name') or m.get('name') or '').lower()
    # Priority 1: glm-5 with TEE
    for m in llms:
        if 'glm' in name_lower(m) and 'tee' in tags_lower(m):
            print(m.get('Id') or m.get('id', '')); sys.exit(0)
    # Priority 2: any TEE provider
    for m in llms:
        if 'tee' in tags_lower(m) and 'negtest' not in tags_lower(m) and 'fake' not in name_lower(m):
            print(m.get('Id') or m.get('id', '')); sys.exit(0)
    # Priority 3: glm-5 (non-web preferred)
    for m in llms:
        if 'glm-5' in name_lower(m) and ':web' not in name_lower(m):
            print(m.get('Id') or m.get('id', '')); sys.exit(0)
    for m in llms:
        if 'glm-5' in name_lower(m):
            print(m.get('Id') or m.get('id', '')); sys.exit(0)
    # Priority 4: first LLM
    if llms:
        print(llms[0].get('Id') or llms[0].get('id', ''))
except Exception as e:
    print('', file=sys.stderr)
" 2>/dev/null || echo "")

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
# The Diamond contract address is the spender; approve a large amount
DIAMOND="0x6aBE1d282f72B474E54527D93b979A4f64d3030a"
echo "Approving MOR token spending..."
APPROVE_RESP=$(curl -s -u "$AUTH_USER:$AUTH_PASS" \
    -X POST \
    "$API_URL/blockchain/approve?spender=$DIAMOND&amount=100" 2>/dev/null || echo "")

if [ -n "$APPROVE_RESP" ]; then
    echo "[OK] MOR spending approved"
    # Wait for the approval tx to confirm
    echo "  Waiting for approval transaction..."
    sleep 15
else
    echo "[WARN] Approve returned empty (may already be approved)"
fi

# --- Open session ---
echo "Opening session (this sends a blockchain transaction)..."

# 10 minute session to start with
SESSION_RESP=$(curl -s -u "$AUTH_USER:$AUTH_PASS" \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{"sessionDuration": 600}' \
    "$API_URL/blockchain/models/$MODEL_ID/session" 2>/dev/null || echo "")

if [ -z "$SESSION_RESP" ]; then
    echo "[FAIL] Session creation returned empty response."
    echo "  Check ./scripts/health.sh and ./scripts/balance.sh"
    exit 1
fi

# Check for error in response
ERROR_MSG=$(echo "$SESSION_RESP" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('error', ''))
except:
    print('')
" 2>/dev/null || echo "")

if [ -n "$ERROR_MSG" ]; then
    echo "[FAIL] $ERROR_MSG"
    exit 1
fi

# Extract session ID
SESSION_ID=$(echo "$SESSION_RESP" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    sid = d.get('sessionId') or d.get('SessionId') or d.get('session_id') or d.get('sessionID') or ''
    print(sid)
except:
    print('')
" 2>/dev/null || echo "")

if [ -z "$SESSION_ID" ]; then
    echo "[WARN] Could not extract session ID from response:"
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
