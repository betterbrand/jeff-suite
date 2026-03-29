#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
KEYCHAIN_PATH="$HOME/.morpheus-wallet.keychain-db"
KEYCHAIN_PASS_FILE="$HOME/.morpheus-keychain-pass"
KEYCHAIN_SERVICE="morpheus-consumer-wallet"
KEYCHAIN_ACCOUNT="jeff-suite"
WALLET_ADDR_FILE="$PROJECT_DIR/data/.wallet-address"

echo "=== Jeff Suite Setup ==="
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
        -T "" \
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
fi

# --- Configure .env ---
if [ -f "$PROJECT_DIR/.env" ]; then
    echo "Existing .env found. Keeping it."
else
    cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
    echo "[OK] Created .env from template"
fi

chmod 600 "$PROJECT_DIR/.env"
echo "[OK] Using public BASE RPC (https://mainnet.base.org)"
echo "     To use a faster private RPC, edit ETH_NODE_ADDRESS in .env"
echo ""

# --- Create data directory ---
mkdir -p "$PROJECT_DIR/data"

# --- Pull Docker image ---
echo "Pulling proxy-router Docker image (this may take a minute)..."
docker pull ghcr.io/morpheusais/morpheus-lumerin-node:latest
echo "[OK] Image pulled"
echo ""

# --- Summary ---
echo "==========================================="
echo "  Setup Complete"
echo "==========================================="
if [ -f "$WALLET_ADDR_FILE" ]; then
    echo ""
    echo "  Wallet: $(cat "$WALLET_ADDR_FILE")"
    echo ""
    echo "  Next steps:"
    echo "    1. Send MOR + ETH (on BASE) to the wallet address above"
    echo "       Minimum: 5 MOR + 0.001 ETH"
    echo "    2. Run: ./scripts/balance.sh   (check when funds arrive)"
    echo "    3. Run: ./scripts/start.sh     (start the proxy-router)"
    echo "    4. Run: ./scripts/health.sh    (verify it's running)"
fi
echo ""
