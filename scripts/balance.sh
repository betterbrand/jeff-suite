#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WALLET_ADDR_FILE="$PROJECT_DIR/data/.wallet-address"
MOR_TOKEN="0x7431aDa8a591C955a994a21710752EF9b882b8e3"

# Source RPC fallback
. "$SCRIPT_DIR/rpc-check.sh"

# --- Load config ---
if [ ! -f "$PROJECT_DIR/.env" ]; then
    echo "[FAIL] No .env found. Run ./scripts/setup.sh first."
    exit 1
fi

if [ ! -f "$WALLET_ADDR_FILE" ]; then
    echo "[FAIL] No wallet address found. Run ./scripts/setup.sh first."
    exit 1
fi

RPC_URL=$(grep '^ETH_NODE_ADDRESS=' "$PROJECT_DIR/.env" | cut -d= -f2)
WALLET=$(cat "$WALLET_ADDR_FILE")

echo "=== Wallet Balance Check ==="
echo "  Address: $WALLET"
echo ""

# --- Check ETH balance (with fallback) ---
ETH_RESP=$(rpc_call "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$WALLET\",\"latest\"],\"id\":1}" "$RPC_URL" 2>/dev/null || echo "")
ETH_HEX=$(echo "$ETH_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result','0x0'))" 2>/dev/null || echo "0x0")

ETH_DISPLAY=$(echo "$ETH_HEX" | python3 -c "import sys; print(f'{int(sys.stdin.read().strip(), 16) / 1e18:.6f}')")

# --- Check MOR balance (with fallback) ---
ADDR_CLEAN="${WALLET#0x}"
ADDR_PADDED=$(printf '%064s' "$ADDR_CLEAN" | tr ' ' '0')
CALL_DATA="0x70a08231${ADDR_PADDED}"

MOR_RESP=$(rpc_call "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$MOR_TOKEN\",\"data\":\"$CALL_DATA\"},\"latest\"],\"id\":2}" "$RPC_URL" 2>/dev/null || echo "")
MOR_HEX=$(echo "$MOR_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result','0x0'))" 2>/dev/null || echo "0x0")

MOR_DISPLAY=$(echo "$MOR_HEX" | python3 -c "import sys; print(f'{int(sys.stdin.read().strip(), 16) / 1e18:.4f}')")

echo "  ETH: $ETH_DISPLAY"
echo "  MOR: $MOR_DISPLAY"
echo ""

# --- Readiness check ---
ETH_OK=$(echo "$ETH_HEX" | python3 -c "import sys; print('yes' if int(sys.stdin.read().strip(), 16) > 0 else 'no')")
MOR_OK=$(echo "$MOR_HEX" | python3 -c "import sys; print('yes' if int(sys.stdin.read().strip(), 16) >= int(5e18) else 'no')")

if [ "$ETH_OK" = "yes" ] && [ "$MOR_OK" = "yes" ]; then
    echo "  [OK] Wallet funded. Ready to go."
    echo "  Next: ./scripts/start.sh"
else
    echo "  [WAITING] Wallet needs funding:"
    [ "$ETH_OK" = "no" ] && echo "    - Send ETH (BASE) for gas (~0.001 ETH minimum)"
    [ "$MOR_OK" = "no" ] && echo "    - Send at least 5 MOR (BASE) for session deposits"
    echo ""
    echo "  Run this script again to recheck."
fi
echo ""
