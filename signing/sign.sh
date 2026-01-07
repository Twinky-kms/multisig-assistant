HEX="$(cat tx_000000_unsigned.hex)"
PREV="$(cat tx_000000_prevtxs.json)"

./pigeon-cli signrawtransaction \
  "$HEX" \
  "$PREV" \
  '["PRIVATE_KEY_HERE"]'
