#!/bin/bash

OUTPUT_FILE="utxos_sorted.json"
ADDRESS="rLzD7RxVS1QMZ5yYrmoUvfnTNuzgUqJVVK"

./pigeon-cli listunspent 0 9999999 "[\"$ADDRESS\"]" true \
| jq 'sort_by(.amount) | reverse' \
> "$OUTPUT_FILE"

echo "Wrote sorted UTXOs to $OUTPUT_FILE"
