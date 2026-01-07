#!/bin/bash

OUTPUT_FILE="txids.json"

./pigeon-cli listunspent 0 9999999 '["rLzD7RxVS1QMZ5yYrmoUvfnTNuzgUqJVVK"]' true | jq '[.[].txid]' > "$OUTPUT_FILE"

echo "Wrote txids to $OUTPUT_FILE"
