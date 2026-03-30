#!/usr/bin/env bash
# RPC endpoint discovery, health-check, and fallback for BASE mainnet.
# Standalone tool: ./scripts/rpc-check.sh [--best|--json]
# Sourceable library: . scripts/rpc-check.sh (provides rpc_call, best_rpc, etc.)

BASE_RPCS=(
  "https://base.llamarpc.com"
  "https://1rpc.io/base"
  "https://base-rpc.publicnode.com"
  "https://base.meowrpc.com"
  "https://rpc.ankr.com/base"
  "https://base.drpc.org"
  "https://base.blockpi.network/v1/rpc/public"
  "https://mainnet.base.org"
)

RPC_TIMEOUT=3

# Check a single RPC endpoint. Returns "url latency_ms block_number" or empty on failure.
check_rpc() {
  local url="$1"
  local start_ms body block_hex block_dec end_ms latency_ms

  start_ms=$(python3 -c "import time; print(int(time.time()*1000))")

  body=$(curl -sf --max-time "$RPC_TIMEOUT" -X POST "$url" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null) || return 1

  end_ms=$(python3 -c "import time; print(int(time.time()*1000))")
  latency_ms=$((end_ms - start_ms))

  [ -z "$body" ] && return 1

  block_hex=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',''))" 2>/dev/null)
  [ -z "$block_hex" ] || [ "$block_hex" = "None" ] && return 1

  block_dec=$(python3 -c "print(int('$block_hex', 16))" 2>/dev/null)

  echo "$url $latency_ms $block_dec"
}

# Discover all healthy RPCs, sorted by latency.
discover_rpcs() {
  local results=()
  for url in "${BASE_RPCS[@]}"; do
    local line
    line=$(check_rpc "$url" 2>/dev/null || echo "")
    if [ -n "$line" ]; then
      results+=("$line")
    fi
  done

  if [ ${#results[@]} -gt 0 ]; then
    printf '%s\n' "${results[@]}" | sort -t' ' -k2 -n
  fi
}

# Return the single fastest healthy RPC URL.
best_rpc() {
  discover_rpcs | head -1 | awk '{print $1}'
}

# Make an RPC call with fallback. Tries primary first, then public endpoints.
# Usage: rpc_call '{"jsonrpc":"2.0",...}' [primary_url]
rpc_call() {
  local payload="$1"
  local primary="${2:-}"
  local result

  # Try primary first
  if [ -n "$primary" ]; then
    result=$(curl -sf --max-time "$RPC_TIMEOUT" -X POST "$primary" \
      -H "Content-Type: application/json" \
      -d "$payload" 2>/dev/null)
    if [ -n "$result" ]; then
      local has_result
      has_result=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('result') else 'no')" 2>/dev/null)
      if [ "$has_result" = "yes" ]; then
        echo "$result"
        return 0
      fi
    fi
  fi

  # Fallback through public RPCs
  for url in "${BASE_RPCS[@]}"; do
    [ "$url" = "$primary" ] && continue
    result=$(curl -sf --max-time "$RPC_TIMEOUT" -X POST "$url" \
      -H "Content-Type: application/json" \
      -d "$payload" 2>/dev/null)
    if [ -n "$result" ]; then
      local has_result
      has_result=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('result') else 'no')" 2>/dev/null)
      if [ "$has_result" = "yes" ]; then
        echo "$result"
        return 0
      fi
    fi
  done

  return 1
}

# --- Standalone execution ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail

  MODE="${1:-}"

  if [ "$MODE" = "--best" ]; then
    best_rpc
  elif [ "$MODE" = "--json" ]; then
    echo "["
    FIRST=true
    while IFS=' ' read -r url latency block; do
      [ "$FIRST" = true ] && FIRST=false || echo ","
      printf '  {"url": "%s", "latency_ms": %s, "block": %s}' "$url" "$latency" "$block"
    done < <(discover_rpcs)
    echo ""
    echo "]"
  else
    echo "=== BASE RPC Health Check ==="
    echo ""
    COUNT=0
    while IFS=' ' read -r url latency block; do
      COUNT=$((COUNT + 1))
      printf "  [OK] %3dms  block #%-10s  %s\n" "$latency" "$block" "$url"
    done < <(discover_rpcs)
    echo ""
    if [ "$COUNT" -eq 0 ]; then
      echo "  No healthy endpoints found."
    else
      echo "  $COUNT healthy endpoint(s) found."
      echo "  Fastest: $(best_rpc)"
    fi
    echo ""
  fi
fi
