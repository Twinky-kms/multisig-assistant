#!/bin/bash
set -euo pipefail

INPUT_FILE="utxos_sorted.json"   # from your previous script
OUT_DIR="chunks"
CHUNK_SIZE=25

mkdir -p "$OUT_DIR"

# Sanity check
if [ ! -f "$INPUT_FILE" ]; then
  echo "Missing input file: $INPUT_FILE"
  echo "Run your sorter first to create it."
  exit 1
fi

# Count UTXOs
TOTAL=$(jq 'length' "$INPUT_FILE")
echo "Total UTXOs in $INPUT_FILE: $TOTAL"

# Create chunk files: each file is an array of {txid, vout}
# Named chunks/chunk_000.json, chunk_001.json, ...
jq -c --argjson n "$CHUNK_SIZE" '
  [ .[] | {txid, vout, amount} ]                      # keep amount too (useful)
  | [ range(0; length; $n) as $i
      | { idx: ($i / $n), items: .[$i : ($i + $n)] }
    ]
  | .[]
' "$INPUT_FILE" \
| while IFS= read -r chunk; do
    idx=$(echo "$chunk" | jq -r '.idx')
    file=$(printf "%s/chunk_%03d.json" "$OUT_DIR" "$idx")
    echo "$chunk" | jq '.items | map({txid, vout})' > "$file"
    count=$(jq 'length' "$file")
    echo "Wrote $file ($count inputs)"
  done

echo "Done. Chunk files are in: $OUT_DIR/"
