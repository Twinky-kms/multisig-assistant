#!/bin/bash
set -euo pipefail

# ================= CONFIG =================
CLI="./pigeon-cli"
DAEMON="./pigeond"
CHUNKS_DIR="chunks"
OUTPUT_DIR="signed"

# Private key - can be set via environment variable or as argument
PRIVATE_KEY="${PRIVATE_KEY:-${1:-}}"
# ==========================================

if [ -z "$PRIVATE_KEY" ]; then
  echo "ERROR: Private key required."
  echo "Usage: $0 <PRIVATE_KEY>"
  echo "   OR: PRIVATE_KEY='your_key' $0"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Check for CLI
if [ ! -f "$CLI" ]; then
  echo "ERROR: $CLI not found. Make sure pigeon-cli is in the current directory."
  exit 1
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

# Count chunks processed
PROCESSED=0
SKIPPED=0
SIGNED=0
ERRORS=0

echo "Starting mass signing..."
echo "Chunks directory: $CHUNKS_DIR (self-contained with transaction hex)"
echo "Output directory: $OUTPUT_DIR"
echo ""

# Process each chunk file
for chunk_file in "$CHUNKS_DIR"/chunk_*.json; do
  [ -f "$chunk_file" ] || continue
  
  # Extract chunk index from filename (e.g., chunk_042.json -> 42, chunk_423.json -> 423)
  CHUNK_BASENAME=$(basename "$chunk_file")
  # Remove "chunk_" prefix and ".json" suffix, then convert to integer (removes leading zeros)
  CHUNK_IDX=$(echo "$CHUNK_BASENAME" | sed 's/^chunk_//; s/\.json$//' | sed 's/^0*//')
  [ -z "$CHUNK_IDX" ] && CHUNK_IDX=0
  CHUNK_IDX=$((10#$CHUNK_IDX))
  
  # Convert to 6-digit padded transaction ID (for display purposes)
  TX_ID=$(printf "%06d" "$CHUNK_IDX")
  
  # Check if chunk has the new format with embedded transaction data
  HAS_TRANSACTION=$(jq -r 'has("transaction")' "$chunk_file" 2>/dev/null || echo "false")
  
  if [ "$HAS_TRANSACTION" = "false" ]; then
    echo "SKIP: $CHUNK_BASENAME -> tx_${TX_ID} (old format chunk, missing transaction data)"
    echo "      Run build_chunks_with_hex.sh to regenerate chunks with transaction hex"
    ((SKIPPED++)) || true
    continue
  fi
  
  # Get total amount from embedded transaction data
  TOTAL_AMOUNT=$(jq -r '.transaction.total_in // 0' "$chunk_file" 2>/dev/null || echo "0")
  
  # Convert to number for comparison (handle scientific notation like 0e-8)
  # Use awk to safely convert and compare
  SHOULD_SKIP=$(awk -v a="$TOTAL_AMOUNT" 'BEGIN {
    num = a + 0;
    if (num <= 0) exit 0;  # skip
    exit 1;  # don't skip
  }' 2>/dev/null && echo "yes" || echo "no")
  
  # Skip chunks with zero or negative amount
  if [ "$SHOULD_SKIP" = "yes" ]; then
    echo "SKIP: $CHUNK_BASENAME -> tx_${TX_ID} (amount: $TOTAL_AMOUNT)"
    ((SKIPPED++)) || true
    continue
  fi
  
  ((PROCESSED++)) || true
  
  echo "Processing: $CHUNK_BASENAME -> tx_${TX_ID} (amount: $TOTAL_AMOUNT)"
  
  # Read transaction data from chunk file
  HEX=$(jq -r '.transaction.unsigned_hex' "$chunk_file")
  PREV=$(jq -c '.transaction.prevtxs' "$chunk_file")
  
  # Sign the transaction
  SIGNED_RESULT=$($CLI signrawtransaction "$HEX" "$PREV" "[\"$PRIVATE_KEY\"]" 2>&1) || {
    echo "ERROR: Failed to sign tx_${TX_ID}"
    echo "$SIGNED_RESULT" | head -3
    ((ERRORS++)) || true
    continue
  }
  
  # Extract signed hex from result
  SIGNED_HEX=$(echo "$SIGNED_RESULT" | jq -r '.hex // empty' 2>/dev/null)
  
  if [ -z "$SIGNED_HEX" ] || [ "$SIGNED_HEX" = "null" ]; then
    echo "ERROR: No hex in signing result for tx_${TX_ID}"
    echo "$SIGNED_RESULT" | head -3
    ((ERRORS++)) || true
    continue
  fi
  
  # Save signed transaction
  OUTPUT_FILE="$OUTPUT_DIR/tx_${TX_ID}_signed.hex"
  echo "$SIGNED_HEX" > "$OUTPUT_FILE"
  
  # Save full result JSON for reference
  RESULT_FILE="$OUTPUT_DIR/tx_${TX_ID}_result.json"
  echo "$SIGNED_RESULT" | jq '.' > "$RESULT_FILE" 2>/dev/null || echo "$SIGNED_RESULT" > "$RESULT_FILE"
  
  # Check if complete
  COMPLETE=$(echo "$SIGNED_RESULT" | jq -r '.complete // false' 2>/dev/null || echo "false")
  
  if [ "$COMPLETE" = "true" ]; then
    echo "  ✓ Signed and complete: $OUTPUT_FILE"
    ((SIGNED++)) || true
  else
    echo "  → Partial signature: $OUTPUT_FILE (needs more signatures)"
    ((SIGNED++)) || true
  fi
done

echo ""
echo "=========================================="
echo "Summary:"
echo "  Processed: $PROCESSED"
echo "  Signed: $SIGNED"
echo "  Skipped: $SKIPPED"
echo "  Errors: $ERRORS"
echo ""
echo "Signed transactions saved to: $OUTPUT_DIR/"

