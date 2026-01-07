## 🔑 Updating the Private Key in `signing.sh`

You already have a script named `signing.sh` that looks like this:

```bash
HEX="$(cat tx_000000_unsigned.hex)"
PREV="$(cat tx_000000_prevtxs.json)"

./pigeon-cli signrawtransaction \
  "$HEX" \
  "$PREV" \
  '["PRIVATE_KEY_HERE"]'
```

You should see a result similar to this: 

```json
{
  "hex": "02000000...",
  "complete": false
}
```

send that result in the group chat.
