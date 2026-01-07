#!/bin/bash
set -euo pipefail

# ================= CONFIG =================
CLI="./pigeon-cli"

UTXOS_DB="utxos_sorted.json"            # sorted listunspent results (DESC by amount)
NEW_MULTISIG_ADDRESS="rJ5rEsDFQFKugFB4LTqUyuSvsa9vQ26wfC"
OLD_REDEEM_SCRIPT="5321035f4fbe1cd72c787753afb59a6dc0273ca7db0c76d2170d4d245fa7e991127c9f2102351f708aa8b32c681f251add687cedab7c9da2bd0f41f8325493a09fcf4ca2fc2102b78dc389c1e733cc65a5bdffad994a4a7ec3435e6c49b705b4771c48363dc3882102cf97c1cbcff277f2c0692f55c9c35c39446976b3e8df719082df9e1780eec5eb2102fc82abed6874a456d356e842957e964e1da7b5f0ed89f17fe71feb1f2cdaa04c210310b9b78b5c1e3f43d42ac7f9973df7eb50f0f38ec3f69a7b66cdbaf7ce1285882103c2e59f89d0aa1c74ce1a20a5884304f7c493e92c8663392ed56c53021bc1e51157ae"
CHUNK_SIZE=25
FEE="0.00100000"                        # fee per tx, in coins

BUILD_DIR="build"
# ==========================================

mkdir -p "$BUILD_DIR"

if [ ! -f "$UTXOS_DB" ]; then
  echo "ERROR: Missing $UTXOS_DB"
  exit 1
fi

TOTAL_UTXOS=$(jq 'length' "$UTXOS_DB")
echo "UTXOs in $UTXOS_DB: $TOTAL_UTXOS"
if [ "$TOTAL_UTXOS" -eq 0 ]; then
  echo "No UTXOs found."
  exit 0
fi

# Stream chunks as one JSON object per line: {idx, picked, inputs, prevtxs}
jq -c \
  --arg rs "$OLD_REDEEM_SCRIPT" \
  --argjson n "$CHUNK_SIZE" \
  -f /dev/stdin \
  "$UTXOS_DB" <<'JQ'
[ .[] | {txid, vout, amount, scriptPubKey} ] as $u
| [ range(0; ($u|length); $n) as $i
    | {
        idx: ($i / $n),
        picked: ($u[$i:($i+$n)]),
        inputs: ($u[$i:($i+$n)] | map({txid, vout})),
        prevtxs: ($u[$i:($i+$n)] | map({txid, vout, scriptPubKey, redeemScript: $rs, amount}))
      }
  ]
| .[]
JQ
while IFS= read -r chunk; do
  IDX=$(echo "$chunk" | jq -r '.idx')
  TX_ID_PAD=$(printf "%06d" "$IDX")

  COUNT=$(echo "$chunk" | jq -r '.inputs | length')
  TOTAL_IN=$(echo "$chunk" | jq -r '[.picked[].amount] | add // 0')

  # total_in - fee -> amount_out (8 decimals)
  AMOUNT_OUT=$(awk -v t="$TOTAL_IN" -v f="$FEE" 'BEGIN {
    o = t - f;
    if (o <= 0) { exit 2; }
    printf "%.8f\n", o
  }') || {
    echo "ERROR: tx $TX_ID_PAD output amount <= 0 (total_in=$TOTAL_IN fee=$FEE)"
    exit 1
  }

  INPUTS_JSON=$(echo "$chunk" | jq -c '.inputs')
  PREVTXS_JSON=$(echo "$chunk" | jq -c '.prevtxs')
  OUTPUTS_JSON=$(jq -n --arg a "$NEW_MULTISIG_ADDRESS" --arg v "$AMOUNT_OUT" '{($a): ($v|tonumber)}')

  RAW_UNSIGNED=$($CLI createrawtransaction "$INPUTS_JSON" "$OUTPUTS_JSON")

  RAW_FILE="$BUILD_DIR/tx_${TX_ID_PAD}_unsigned.hex"
  PREV_FILE="$BUILD_DIR/tx_${TX_ID_PAD}_prevtxs.json"
  META_FILE="$BUILD_DIR/tx_${TX_ID_PAD}_meta.json"

  echo "$RAW_UNSIGNED" > "$RAW_FILE"
  echo "$PREVTXS_JSON" | jq '.' > "$PREV_FILE"

  jq -n \
    --arg id "$TX_ID_PAD" \
    --arg fee "$FEE" \
    --arg dest "$NEW_MULTISIG_ADDRESS" \
    --arg total_in "$TOTAL_IN" \
    --arg amount_out "$AMOUNT_OUT" \
    --arg raw_file "$RAW_FILE" \
    --arg prev_file "$PREV_FILE" \
    --argjson inputs "$INPUTS_JSON" \
    '{
      id: $id,
      inputs_count: ($inputs|length),
      total_in: ($total_in|tonumber),
      fee: ($fee|tonumber),
      amount_out: ($amount_out|tonumber),
      destination: $dest,
      files: { unsigned_hex: $raw_file, prevtxs: $prev_file },
      inputs: $inputs
    }' > "$META_FILE"

  echo "Built tx $TX_ID_PAD  inputs=$COUNT  total_in=$TOTAL_IN  out=$AMOUNT_OUT"
done

echo "Done. Outputs in: $BUILD_DIR/"
