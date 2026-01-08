#!/bin/bash
set -euo pipefail

# ================= CONFIG =================
CLI="./pigeon-cli"
CHUNKS_DIR="chunks"
BUILD_DIR="build"
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

# Count chunks processed
PROCESSED=0
SKIPPED=0
SIGNED=0
ERRORS=0

echo "Starting mass signing..."
echo "Chunks directory: $CHUNKS_DIR"
echo "Build directory: $BUILD_DIR"
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
  
  # Convert to 6-digit padded transaction ID
  TX_ID=$(printf "%06d" "$CHUNK_IDX")
  
  HEX_FILE="$BUILD_DIR/tx_${TX_ID}_unsigned.hex"
  PREV_FILE="$BUILD_DIR/tx_${TX_ID}_prevtxs.json"
  
  # Check if transaction files exist
  if [ ! -f "$HEX_FILE" ] || [ ! -f "$PREV_FILE" ]; then
    echo "SKIP: $CHUNK_BASENAME -> tx_${TX_ID} (missing transaction files)"
    ((SKIPPED++)) || true
    continue
  fi
  
  # Calculate total amount in chunk
  # Try to get amount from chunk file first (if it has amount field)
  TOTAL_AMOUNT=$(jq -r '[.[].amount // empty] | add // 0' "$chunk_file" 2>/dev/null || echo "0")
  
  # If amount is 0 or empty, try to get from utxos_sorted.json by matching txid/vout
  if [ -z "$TOTAL_AMOUNT" ] || [ "$TOTAL_AMOUNT" = "0" ] || [ "$TOTAL_AMOUNT" = "null" ]; then
    if [ -f "utxos_sorted.json" ]; then
      # Build a jq filter to match all txid/vout pairs and sum amounts
      TOTAL_AMOUNT=$(jq -r --slurpfile chunk "$chunk_file" '
        . as $db |
        ($chunk[0] | map({txid, vout})) as $needles |
        [
          $db[] | 
          select(
            . as $u | 
            $needles | map(select(.txid == $u.txid and .vout == $u.vout)) | length > 0
          ) | .amount
        ] | add // 0
      ' "utxos_sorted.json" 2>/dev/null || echo "0")
    fi
  fi
  
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
  
  # Read transaction files
  HEX=$(cat "$HEX_FILE")
  PREV=$(cat "$PREV_FILE")
  
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

