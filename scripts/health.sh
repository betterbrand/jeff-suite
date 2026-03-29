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

echo "=== Proxy-Router Health Check ==="
echo ""

# --- Check container ---
cd "$PROJECT_DIR"
if ! docker compose ps --status running 2>/dev/null | grep -q proxy-router; then
    echo "[FAIL] Container not running. Start with: ./scripts/start.sh"
    exit 1
fi
echo "[OK] Container running"

# --- Check API ---
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -u "$AUTH_USER:$AUTH_PASS" "$API_URL/healthcheck" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
    echo "[OK] API responding (HTTP $HTTP_CODE)"
elif [ "$HTTP_CODE" = "000" ]; then
    echo "[WAIT] API not responding yet. The proxy-router takes 30-60 seconds to start."
    echo "       Try again in a moment."
    exit 1
else
    echo "[WARN] API returned HTTP $HTTP_CODE"
fi

# --- Check wallet ---
WALLET_RESP=$(curl -sf -u "$AUTH_USER:$AUTH_PASS" "$API_URL/wallet" 2>/dev/null || echo "")
if [ -n "$WALLET_RESP" ]; then
    echo "[OK] Wallet loaded"
    echo "     $WALLET_RESP"
fi

echo ""
echo "  Swagger UI: $API_URL/swagger/index.html"
echo "  Next: ./scripts/list-models.sh"
echo ""
