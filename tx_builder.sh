#!/bin/bash
set -euo pipefail

# ================= CONFIG =================

CLI="./pigeon-cli"
UTXOS_DB="utxos_sorted.json"

NEW_MULTISIG_ADDRESS="rJ5rEsDFQFKugFB4LTqUyuSvsa9vQ26wfC"
OLD_REDEEM_SCRIPT="5321035f4fbe1cd72c787753afb59a6dc0273ca7db0c76d2170d4d245fa7e991127c9f2102351f708aa8b32c681f251add687cedab7c9da2bd0f41f8325493a09fcf4ca2fc2102b78dc389c1e733cc65a5bdffad994a4a7ec3435e6c49b705b4771c48363dc3882102cf97c1cbcff277f2c0692f55c9c35c39446976b3e8df719082df9e1780eec5eb2102fc82abed6874a456d356e842957e964e1da7b5f0ed89f17fe71feb1f2cdaa04c210310b9b78b5c1e3f43d42ac7f9973df7eb50f0f38ec3f69a7b66cdbaf7ce1285882103c2e59f89d0aa1c74ce1a20a5884304f7c493e92c8663392ed56c53021bc1e51157ae"

CHUNK_SIZE=25
FEE="0.0100000"

STATE_DIR="state"
BUILD_DIR="build"

USED_OUTPOINTS_FILE="$STATE_DIR/used_outpoints.json"
PROGRESS_FILE="$STATE_DIR/progress.json"

# ==========================================

mkdir -p "$STATE_DIR" "$BUILD_DIR"

[ -f "$USED_OUTPOINTS_FILE" ] || echo '[]' > "$USED_OUTPOINTS_FILE"
[ -f "$PROGRESS_FILE" ] || echo '{"next_id":0}' > "$PROGRESS_FILE"

NEXT_ID=$(jq -r '.next_id' "$PROGRESS_FILE")
TX_ID_PAD=$(printf "%06d" "$NEXT_ID")

echo "Building tx $TX_ID_PAD (largest unused UTXOs first)"

USED_JSON=$(cat "$USED_OUTPOINTS_FILE")

SELECTION_JSON=$(
jq \
  --arg rs "$OLD_REDEEM_SCRIPT" \
  --argjson n "$CHUNK_SIZE" \
  --argjson used "$USED_JSON" \
  '
  def key: (.txid + ":" + (.vout|tostring));

  [ .[]
    | select( (key | IN($used[]) | not) )
  ]
  | .[0:$n]
  | {
      picked: map({txid, vout, amount, scriptPubKey}),
      inputs: map({txid, vout}),
      prevtxs: map({
        txid,
        vout,
        scriptPubKey,
        redeemScript: $rs,
        amount
      })
    }
  ' "$UTXOS_DB"
)

COUNT=$(echo "$SELECTION_JSON" | jq '.inputs | length')

if [ "$COUNT" -eq 0 ]; then
  echo "No UTXOs left to process."
  exit 0
fi

TOTAL_IN=$(echo "$SELECTION_JSON" | jq '[.picked[].amount] | add')

AMOUNT_OUT=$(awk -v t="$TOTAL_IN" -v f="$FEE" 'BEGIN {
  o = t - f;
  if (o <= 0) exit 1;
  printf "%.8f\n", o
}')

INPUTS_JSON=$(echo "$SELECTION_JSON" | jq -c '.inputs')
PREVTXS_JSON=$(echo "$SELECTION_JSON" | jq -c '.prevtxs')
OUTPUTS_JSON=$(jq -n --arg a "$NEW_MULTISIG_ADDRESS" --arg v "$AMOUNT_OUT" '{($a): ($v|tonumber)}')

RAW_UNSIGNED=$($CLI createrawtransaction "$INPUTS_JSON" "$OUTPUTS_JSON")

RAW_FILE="$BUILD_DIR/tx_${TX_ID_PAD}_unsigned.hex"
PREV_FILE="$BUILD_DIR/tx_${TX_ID_PAD}_prevtxs.json"

echo "$RAW_UNSIGNED" > "$RAW_FILE"
echo "$PREVTXS_JSON" | jq '.' > "$PREV_FILE"

# Update used outpoints
jq \
  --argjson new "$(echo "$SELECTION_JSON" | jq '[.picked[] | (.txid + ":" + (.vout|tostring))]')" \
  '
  . + $new | unique
  ' "$USED_OUTPOINTS_FILE" > "$USED_OUTPOINTS_FILE.tmp"

mv "$USED_OUTPOINTS_FILE.tmp" "$USED_OUTPOINTS_FILE"

# Increment progress
jq --argjson n $((NEXT_ID + 1)) '.next_id = $n' "$PROGRESS_FILE" > "$PROGRESS_FILE.tmp"
mv "$PROGRESS_FILE.tmp" "$PROGRESS_FILE"

echo "----------------------------------------"
echo "TX ID:        $TX_ID_PAD"
echo "Inputs used:  $COUNT"
echo "Total in:     $TOTAL_IN"
echo "Fee:          $FEE"
echo "Amount out:   $AMOUNT_OUT"
echo "Destination:  $NEW_MULTISIG_ADDRESS"
echo
echo "Unsigned hex: $RAW_FILE"
echo "Prevtxs:      $PREV_FILE"
echo "----------------------------------------"
echo "Send BOTH files to signers."
