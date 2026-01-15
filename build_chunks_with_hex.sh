#!/bin/bash
set -euo pipefail

# ================= CONFIG =================
CLI="./pigeon-cli"
DAEMON="./pigeond"

INPUT_FILE="utxos_sorted.json"
OUTPUT_DIR="chunks"
CHUNK_SIZE=25

NEW_MULTISIG_ADDRESS="rJ5rEsDFQFKugFB4LTqUyuSvsa9vQ26wfC"
OLD_REDEEM_SCRIPT="5321035f4fbe1cd72c787753afb59a6dc0273ca7db0c76d2170d4d245fa7e991127c9f2102351f708aa8b32c681f251add687cedab7c9da2bd0f41f8325493a09fcf4ca2fc2102b78dc389c1e733cc65a5bdffad994a4a7ec3435e6c49b705b4771c48363dc3882102cf97c1cbcff277f2c0692f55c9c35c39446976b3e8df719082df9e1780eec5eb2102fc82abed6874a456d356e842957e964e1da7b5f0ed89f17fe71feb1f2cdaa04c210310b9b78b5c1e3f43d42ac7f9973df7eb50f0f38ec3f69a7b66cdbaf7ce1285882103c2e59f89d0aa1c74ce1a20a5884304f7c493e92c8663392ed56c53021bc1e51157ae"
FEE="0.00100000"
# ==========================================

mkdir -p "$OUTPUT_DIR"

# Sanity check
if [ ! -f "$INPUT_FILE" ]; then
  echo "ERROR: Missing input file: $INPUT_FILE"
  echo "Run your UTXO sorter first to create it."
  exit 1
fi

# Check for CLI
if [ ! -f "$CLI" ]; then
  # Try alternative location
  if [ -f "pgn/bin/pigeon-cli" ]; then
    CLI="pgn/bin/pigeon-cli"
  else
    echo "ERROR: pigeon-cli not found. Make sure pigeon-cli is available."
    echo "  Tried: ./pigeon-cli"
    echo "  Tried: ./pgn/bin/pigeon-cli"
    exit 1
  fi
fi

# Function to check if daemon is running
check_daemon_running() {
  "$CLI" getinfo >/dev/null 2>&1 || return 1
}

# Function to wait for daemon to be ready
wait_for_daemon() {
  local max_attempts=30
  local attempt=0
  
  echo "Waiting for daemon to be ready..."
  while [ $attempt -lt $max_attempts ]; do
    if check_daemon_running; then
      echo "Daemon is ready!"
      return 0
    fi
    attempt=$((attempt + 1))
    echo "  Attempt $attempt/$max_attempts..."
    sleep 2
  done
  
  echo "ERROR: Daemon failed to start or become ready after $max_attempts attempts"
  return 1
}

# Check if daemon is already running
echo "Checking if pigeon daemon is running..."
if check_daemon_running; then
  echo "Daemon is already running."
else
  echo "Daemon is not running. Starting daemon..."
  
  # Check for daemon executable
  if [ ! -f "$DAEMON" ]; then
    # Try alternative location
    if [ -f "pgn/bin/pigeond" ]; then
      DAEMON="pgn/bin/pigeond"
    else
      echo "ERROR: $DAEMON not found. Make sure pigeond is available."
      echo "  Tried: ./pigeond"
      echo "  Tried: ./pgn/bin/pigeond"
      exit 1
    fi
  fi
  
  # Start daemon in background
  echo "Starting $DAEMON..."
  "$DAEMON" -daemon >/dev/null 2>&1 || {
    echo "ERROR: Failed to start daemon"
    exit 1
  }
  
  # Wait for daemon to be ready
  if ! wait_for_daemon; then
    exit 1
  fi
fi

echo ""

# Count UTXOs
TOTAL_UTXOS=$(jq 'length' "$INPUT_FILE")
echo "Total UTXOs in $INPUT_FILE: $TOTAL_UTXOS"

if [ "$TOTAL_UTXOS" -eq 0 ]; then
  echo "No UTXOs found."
  exit 0
fi

# Calculate expected chunks
EXPECTED_CHUNKS=$(( (TOTAL_UTXOS + CHUNK_SIZE - 1) / CHUNK_SIZE ))
echo "Will create $EXPECTED_CHUNKS chunk files with up to $CHUNK_SIZE inputs each"
echo "Output directory: $OUTPUT_DIR/"
echo ""

CHUNKS_CREATED=0
CHUNKS_SKIPPED=0

# Stream chunks and build transactions
jq -c \
  --arg rs "$OLD_REDEEM_SCRIPT" \
  --argjson n "$CHUNK_SIZE" \
  -f /dev/stdin \
  "$INPUT_FILE" <<'JQ'
[ .[] | {txid, vout, amount, scriptPubKey} ] as $u
| [ range(0; ($u|length); $n) as $i
    | {
        idx: ($i / $n),
        inputs: ($u[$i:($i+$n)]),
        inputs_only: ($u[$i:($i+$n)] | map({txid, vout})),
        prevtxs: ($u[$i:($i+$n)] | map({txid, vout, scriptPubKey, redeemScript: $rs, amount}))
      }
  ]
| .[]
JQ
while IFS= read -r chunk_data; do
  IDX=$(echo "$chunk_data" | jq -r '.idx')
  CHUNK_FILE=$(printf "%s/chunk_%03d.json" "$OUTPUT_DIR" "$IDX")
  
  COUNT=$(echo "$chunk_data" | jq -r '.inputs | length')
  TOTAL_IN=$(echo "$chunk_data" | jq -r '[.inputs[].amount] | add // 0')
  
  # Calculate amount out (total_in - fee)
  AMOUNT_OUT=$(awk -v t="$TOTAL_IN" -v f="$FEE" 'BEGIN {
    o = t - f;
    if (o <= 0) { exit 2; }
    printf "%.8f\n", o
  }') || {
    echo "SKIP: chunk_$(printf "%03d" "$IDX") - output amount <= 0 (total_in=$TOTAL_IN fee=$FEE)"
    ((CHUNKS_SKIPPED++)) || true
    continue
  }
  
  # Prepare transaction data
  INPUTS_JSON=$(echo "$chunk_data" | jq -c '.inputs_only')
  PREVTXS_JSON=$(echo "$chunk_data" | jq -c '.prevtxs')
  OUTPUTS_JSON=$(jq -n --arg a "$NEW_MULTISIG_ADDRESS" --arg v "$AMOUNT_OUT" '{($a): ($v|tonumber)}')
  
  # Create raw unsigned transaction
  RAW_UNSIGNED=$($CLI createrawtransaction "$INPUTS_JSON" "$OUTPUTS_JSON" 2>&1) || {
    echo "ERROR: Failed to create transaction for chunk_$(printf "%03d" "$IDX")"
    echo "$RAW_UNSIGNED" | head -3
    ((CHUNKS_SKIPPED++)) || true
    continue
  }
  
  # Build final chunk file with all data
  echo "$chunk_data" | jq \
    --arg hex "$RAW_UNSIGNED" \
    --argjson prevtxs "$PREVTXS_JSON" \
    --arg total_in "$TOTAL_IN" \
    --arg total_out "$AMOUNT_OUT" \
    --arg fee "$FEE" \
    '{
      inputs: .inputs,
      transaction: {
        unsigned_hex: $hex,
        prevtxs: $prevtxs,
        total_in: ($total_in | tonumber),
        total_out: ($total_out | tonumber),
        fee: ($fee | tonumber)
      }
    }' > "$CHUNK_FILE"
  
  ((CHUNKS_CREATED++)) || true
  echo "Created: chunk_$(printf "%03d" "$IDX").json  ($COUNT inputs, total_in=$TOTAL_IN, out=$AMOUNT_OUT)"
done

echo ""
echo "=========================================="
echo "Summary:"
echo "  Chunks created: $CHUNKS_CREATED"
echo "  Chunks skipped: $CHUNKS_SKIPPED"
echo ""
echo "Self-contained chunk files saved to: $OUTPUT_DIR/"
echo "Each chunk includes transaction hex and all data needed for signing."

