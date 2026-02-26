#!/bin/bash

# Usage: get_odos_swap.sh <chain_id> <input_token> <output_token> <amount> <sender>
# Env:   ODOS_API_KEY must be set
# Returns: hex-encoded calldata for an Odos V3 swap

CHAIN_ID=$1
INPUT_TOKEN=$2
OUTPUT_TOKEN=$3
AMOUNT=$4
SENDER=$5

# Get quote
QUOTE_RESPONSE=$(curl -s -X POST "https://api.odos.xyz/sor/quote/v3" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $ODOS_API_KEY" \
  -d "{
    \"chainId\": $CHAIN_ID,
    \"inputTokens\": [{\"tokenAddress\": \"$INPUT_TOKEN\", \"amount\": \"$AMOUNT\"}],
    \"outputTokens\": [{\"tokenAddress\": \"$OUTPUT_TOKEN\", \"proportion\": 1}],
    \"userAddr\": \"$SENDER\",
    \"slippageLimitPercent\": 1,
    \"compact\": true
  }")

# Extract pathId using sed (no jq dependency)
PATH_ID=$(echo "$QUOTE_RESPONSE" | sed -n 's/.*"pathId":"\([^"]*\)".*/\1/p')

if [ -z "$PATH_ID" ]; then
  echo "Error: Failed to get quote. Response: $QUOTE_RESPONSE" >&2
  exit 1
fi

# Assemble transaction
ASSEMBLE_RESPONSE=$(curl -s -X POST "https://api.odos.xyz/sor/assemble" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $ODOS_API_KEY" \
  -d "{
    \"pathId\": \"$PATH_ID\",
    \"userAddr\": \"$SENDER\"
  }")

# Extract transaction data using sed (matches "data":"0x...")
TX_DATA=$(echo "$ASSEMBLE_RESPONSE" | sed -n 's/.*"data":"\(0x[^"]*\)".*/\1/p')

if [ -z "$TX_DATA" ]; then
  echo "Error: Failed to assemble. Response: $ASSEMBLE_RESPONSE" >&2
  exit 1
fi

echo -n "$TX_DATA"
