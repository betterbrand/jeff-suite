#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
API_URL="http://localhost:8082"

# --- Load auth ---
if [ ! -f "$PROJECT_DIR/.env" ]; then
    echo "[FAIL] No .env found. Run ./scripts/setup.sh first."
    exit 1
fi

COOKIE_CONTENT=$(grep '^COOKIE_CONTENT=' "$PROJECT_DIR/.env" | cut -d= -f2)
AUTH_USER="${COOKIE_CONTENT%%:*}"
AUTH_PASS="${COOKIE_CONTENT#*:}"

echo "=== Available Models on Morpheus Marketplace ==="
echo ""

RESPONSE=$(curl -sf -u "$AUTH_USER:$AUTH_PASS" "$API_URL/blockchain/models" 2>/dev/null)

if [ -z "$RESPONSE" ]; then
    echo "[FAIL] Could not fetch models. Is the proxy-router running?"
    echo "       Run: ./scripts/health.sh"
    exit 1
fi

# Pretty-print and highlight TEE providers
if command -v jq &>/dev/null; then
    MODEL_COUNT=$(echo "$RESPONSE" | jq 'if type == "array" then length else 0 end')
    echo "Found $MODEL_COUNT model(s):"
    echo ""
    echo "$RESPONSE" | jq -r '
        if type == "array" then
            .[] | "  ID:       \(.Id // .id // "unknown")\n  Name:     \(.Name // .name // "unknown")\n  Provider: \(.Owner // .owner // "unknown")\n  Fee:      \(.Fee // .fee // "unknown")\n  Tags:     \(.Tags // .tags // [] | join(", "))\n"
        else
            . | tostring
        end
    '
    echo ""
    echo "--- TEE Providers ---"
    TEE_MODELS=$(echo "$RESPONSE" | jq '[.[] | select((.Tags // .tags // [] | join(",") | ascii_downcase) | contains("tee"))]')
    TEE_COUNT=$(echo "$TEE_MODELS" | jq 'length')
    if [ "$TEE_COUNT" -gt 0 ]; then
        echo "Found $TEE_COUNT TEE provider(s):"
        echo "$TEE_MODELS" | jq -r '.[] | "  [TEE] \(.Id // .id) -- \(.Name // .name // "unknown")"'
    else
        echo "No TEE-tagged models found in current listing."
        echo "TEE providers may still be available -- check the full list above."
    fi
else
    # Fallback: python pretty-print
    echo "$RESPONSE" | python3 -m json.tool
fi

echo ""
echo "To open a session: ./scripts/open-session.sh <MODEL_ID>"
echo "Look for TEE providers -- glmb5 if available."
echo ""
