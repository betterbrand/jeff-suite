#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
KEYCHAIN_PATH="$HOME/.morpheus-wallet.keychain-db"
KEYCHAIN_PASS_FILE="$HOME/.morpheus-keychain-pass"
KEYCHAIN_SERVICE="morpheus-consumer-wallet"
KEYCHAIN_ACCOUNT="j-suite"
WALLET_ADDR_FILE="$PROJECT_DIR/data/.wallet-address"

# Source RPC fallback
. "$SCRIPT_DIR/rpc-check.sh"

# Parse arguments
USER_RPC=""
INVITE_CODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rpc) USER_RPC="$2"; shift 2 ;;
    --invite) INVITE_CODE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo "=== The J Suite Setup ==="
echo ""

# --- Check prerequisites ---
echo "Checking prerequisites..."

if ! command -v docker &>/dev/null; then
    echo "[FAIL] Docker is not installed. Install Docker Desktop: https://docker.com/products/docker-desktop"
    exit 1
fi
echo "[OK] Docker found"

if ! docker compose version &>/dev/null; then
    echo "[FAIL] Docker Compose not available. Update Docker Desktop."
    exit 1
fi
echo "[OK] Docker Compose found"

if ! command -v python3 &>/dev/null; then
    echo "[FAIL] python3 is required (ships with macOS). Something is wrong."
    exit 1
fi
echo "[OK] python3 found"

if ! command -v security &>/dev/null; then
    echo "[FAIL] macOS security command not found. This tool requires macOS."
    exit 1
fi
echo "[OK] macOS Keychain available"
echo ""

# --- Check for existing setup ---
if [ -f "$KEYCHAIN_PATH" ]; then
    echo "Existing Morpheus wallet keychain found at $KEYCHAIN_PATH"
    echo "To start fresh, delete it first: rm $KEYCHAIN_PATH $KEYCHAIN_PASS_FILE"
    if [ -f "$WALLET_ADDR_FILE" ]; then
        echo "Wallet address: $(cat "$WALLET_ADDR_FILE")"
    fi
    echo ""
    echo "Skipping wallet generation. Continuing with .env setup..."
    SKIP_WALLET=true
else
    SKIP_WALLET=false
fi

# --- Generate wallet ---
if [ "$SKIP_WALLET" = false ]; then
    echo "Generating new wallet..."

    PRIVATE_KEY=$(openssl rand -hex 32)

    # Derive address using pure Python (secp256k1 + keccak-256, no dependencies)
    WALLET_ADDRESS=$(PRIVATE_KEY="$PRIVATE_KEY" python3 "$SCRIPT_DIR/eth_address.py")

    if [ -z "$WALLET_ADDRESS" ] || [ ${#WALLET_ADDRESS} -ne 42 ]; then
        echo "[FAIL] Wallet address derivation failed."
        exit 1
    fi

    echo "[OK] Wallet generated: $WALLET_ADDRESS"
    echo ""

    # --- Store in macOS Keychain ---
    echo "Storing private key in macOS Keychain..."

    KEYCHAIN_PASS=$(openssl rand -hex 32)

    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"
    security set-keychain-settings "$KEYCHAIN_PATH"  # no auto-lock

    security add-generic-password \
        -s "$KEYCHAIN_SERVICE" \
        -a "$KEYCHAIN_ACCOUNT" \
        -w "$PRIVATE_KEY" \
        -T /usr/bin/security \
        "$KEYCHAIN_PATH"

    # Save keychain password
    echo "$KEYCHAIN_PASS" > "$KEYCHAIN_PASS_FILE"
    chmod 0400 "$KEYCHAIN_PASS_FILE"

    echo "[OK] Key stored in Keychain: $KEYCHAIN_PATH"
    echo "     Service: $KEYCHAIN_SERVICE"
    echo "     Account: $KEYCHAIN_ACCOUNT"
    echo "     Keychain password: $KEYCHAIN_PASS_FILE"

    # Clear sensitive vars from shell
    unset PRIVATE_KEY
    unset KEYCHAIN_PASS

    # Save wallet address
    mkdir -p "$PROJECT_DIR/data"
    echo "$WALLET_ADDRESS" > "$WALLET_ADDR_FILE"
    echo ""

    # --- Request funding via invite code ---
    SKIP_FUNDING_WAIT=false
    if [ -n "$INVITE_CODE" ]; then
        FAUCET_URL="${FAUCET_URL:-}"
        if [ -n "$FAUCET_URL" ]; then
            echo "Requesting funds via invite code..."
            FAUCET_RESP=$(curl -sf --max-time 15 -X POST "$FAUCET_URL/fund" \
                -H "Content-Type: application/json" \
                -d "{\"code\":\"$INVITE_CODE\",\"address\":\"$WALLET_ADDRESS\"}" \
                2>/dev/null || echo '{"error":"faucet unreachable"}')

            FAUCET_OK=$(echo "$FAUCET_RESP" | python3 -c "import sys,json; print('yes' if json.load(sys.stdin).get('success') else 'no')" 2>/dev/null || echo "no")
            if [ "$FAUCET_OK" = "yes" ]; then
                echo "[OK] Funds sent! 3 MOR + 0.003 ETH incoming (~2 seconds on BASE)"
                SKIP_FUNDING_WAIT=true
            else
                FAUCET_ERR=$(echo "$FAUCET_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null || echo "unknown")
                echo "[WARN] Faucet: $FAUCET_ERR"
                echo "  Falling back to manual funding."
            fi
        else
            echo "[WARN] Invite code provided but no FAUCET_URL set."
            echo "  Falling back to manual funding."
        fi
    else
        SKIP_FUNDING_WAIT=false
    fi
fi

# --- Configure .env ---
if [ -f "$PROJECT_DIR/.env" ]; then
    echo "Existing .env found. Keeping it."
else
    cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
    # Set RPC endpoint: user-provided > Alchemy default
    if [ -n "$USER_RPC" ]; then
        _RPC="$USER_RPC"
        echo "[OK] Using provided RPC: $_RPC"
    else
        _RPC="https://base-mainnet.g.alchemy.com/v2/KYvFy-hLFPK0JOTvzNclA"
    fi
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|^ETH_NODE_ADDRESS=.*|ETH_NODE_ADDRESS=$_RPC|" "$PROJECT_DIR/.env"
    else
        sed -i "s|^ETH_NODE_ADDRESS=.*|ETH_NODE_ADDRESS=$_RPC|" "$PROJECT_DIR/.env"
    fi
    # Validate RPC
    if check_rpc "$_RPC" >/dev/null 2>&1; then
        echo "[OK] RPC endpoint verified"
    else
        echo "[WARN] RPC endpoint did not respond. Checking for alternatives..."
        _FALLBACK=$(best_rpc 2>/dev/null || echo "")
        if [ -n "$_FALLBACK" ]; then
            echo "[OK] Using fallback: $_FALLBACK"
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s|^ETH_NODE_ADDRESS=.*|ETH_NODE_ADDRESS=$_FALLBACK|" "$PROJECT_DIR/.env"
            else
                sed -i "s|^ETH_NODE_ADDRESS=.*|ETH_NODE_ADDRESS=$_FALLBACK|" "$PROJECT_DIR/.env"
            fi
        else
            echo "[WARN] No healthy RPCs found. Continuing with default."
        fi
    fi
    unset _RPC _FALLBACK
    echo "[OK] Configuration ready"
fi

chmod 600 "$PROJECT_DIR/.env"
echo ""

# --- Create data directories ---
mkdir -p "$PROJECT_DIR/data/data"

# --- Pull Docker image ---
echo "Pulling proxy-router Docker image (this may take a minute)..."
docker pull ghcr.io/morpheusais/morpheus-lumerin-node:latest
echo "[OK] Image pulled"
echo ""


# --- Start the node ---
echo "Starting Morpheus node..."
"$SCRIPT_DIR/start.sh"

# --- Wait for funding ---
echo ""
echo ""
if [ -f "$WALLET_ADDR_FILE" ]; then
    ADDR=$(cat "$WALLET_ADDR_FILE")
    echo "  Morpheus is running."
    echo ""
    echo "  Your wallet address (BASE network):"
    echo ""
    echo "      $ADDR"
    echo ""

    if [ "${SKIP_FUNDING_WAIT:-false}" = true ]; then
        echo "  Funds arriving via invite code. Waiting for confirmation..."
        sleep 5
    else
        echo "  Send 3 MOR and 0.003 ETH to that address on BASE."
        echo ""
        echo "  Waiting for funds to arrive..."
    fi

    # Poll until funded (with RPC fallback). Min 3 MOR for faucet-funded wallets.
    RPC_URL=$(grep '^ETH_NODE_ADDRESS=' "$PROJECT_DIR/.env" | cut -d= -f2)
    MOR_TOKEN="0x7431aDa8a591C955a994a21710752EF9b882b8e3"
    ADDR_CLEAN="${ADDR#0x}"
    ADDR_PADDED=$(printf '%064s' "$ADDR_CLEAN" | tr ' ' '0')
    CALL_DATA="0x70a08231${ADDR_PADDED}"

    while true; do
        ETH_RESP=$(rpc_call "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$ADDR\",\"latest\"],\"id\":1}" "$RPC_URL" 2>/dev/null || echo "")
        ETH_HEX=$(echo "$ETH_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result','0x0'))" 2>/dev/null || echo "0x0")

        MOR_RESP=$(rpc_call "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$MOR_TOKEN\",\"data\":\"$CALL_DATA\"},\"latest\"],\"id\":2}" "$RPC_URL" 2>/dev/null || echo "")
        MOR_HEX=$(echo "$MOR_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result','0x0'))" 2>/dev/null || echo "0x0")

        ETH_DISPLAY=$(python3 -c "print(f'{int(\"$ETH_HEX\", 16) / 1e18:.6f}')")
        MOR_DISPLAY=$(python3 -c "print(f'{int(\"$MOR_HEX\", 16) / 1e18:.4f}')")

        ETH_OK=$(python3 -c "print('yes' if int('$ETH_HEX', 16) > 0 else 'no')")
        MOR_OK=$(python3 -c "print('yes' if int('$MOR_HEX', 16) >= int(3e18) else 'no')")

        if [ "$ETH_OK" = "yes" ] && [ "$MOR_OK" = "yes" ]; then
            echo "  ETH: $ETH_DISPLAY  |  MOR: $MOR_DISPLAY"
            echo ""
            echo "  Funds received. Let's go."
            break
        else
            echo "  ETH: $ETH_DISPLAY  |  MOR: $MOR_DISPLAY  -- waiting for confirmation..."
            sleep 10
        fi
    done

    # --- Launch chat ---
    echo ""
    echo "  Opening Morpheus Chat..."
    open "$PROJECT_DIR/chat.html"
    echo ""
fi
