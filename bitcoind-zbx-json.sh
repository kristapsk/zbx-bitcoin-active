#!/usr/bin/env bash
set -euo pipefail

bitcoin_cli="bitcoin-cli"
bitcoin_cli_options=""

# allow passing bitcoin-cli flags (same pattern you already use)
while (( ${#} > 0 )) && [[ ${1:0:1} == "-" ]]; do
  bitcoin_cli_options="$bitcoin_cli_options $1"
  shift
done
bitcoin_cli="$bitcoin_cli $bitcoin_cli_options"

blockchain_info="$($bitcoin_cli getblockchaininfo)"
network_info="$($bitcoin_cli getnetworkinfo)"

# fee histogram support detection (same logic as your current script)
mempool_fee_histogram_rate_groups=(0 2 3 4 5 6 7 8 10 12 14 17 20 25 30 40 50 60 70 80 100 120 140 170 200 250 300 400 500 600)
check="$($bitcoin_cli getmempoolinfo [0] 2>/dev/null || true)"
if [[ -n "${check}" ]]; then
  mempool_fee_histogram_rate_groups_str="${mempool_fee_histogram_rate_groups[*]}"
  mempool_fee_histogram_rate_groups_arg="[${mempool_fee_histogram_rate_groups_str// /,}]"
  mempool_info="$($bitcoin_cli getmempoolinfo "$mempool_fee_histogram_rate_groups_arg")"
else
  mempool_fee_histogram_rate_groups_arg=""
  mempool_info="$($bitcoin_cli getmempoolinfo)"
fi

rpc_active_commands="$($bitcoin_cli getrpcinfo | jq '.active_commands | length')"
rpc_active_commands=$(( rpc_active_commands - 1 ))  # don’t count ourselves

# mempoolminfee conversion (same intent as your current script)
mempool_mempoolminfee="$(bc <<< "$(echo "$mempool_info" | grep ".mempoolminfee" | grep -Eo "[0-9]+\.[0-9]+") * 100000")"

# estimatesmartfee targets (same as your script)
estimatesmartfee_targets=(1 2 3 4 6 12 24 48 72 108 144 504 1008)

# Build JSON
json="$(jq -n \
  --argjson blockchain "$blockchain_info" \
  --argjson network "$network_info" \
  --argjson mempool "$mempool_info" \
  --argjson rpc_active "$rpc_active_commands" \
  --arg mempoolminfee "$mempool_mempoolminfee" \
  '{
    blockchain: {
      tip: { blocks: $blockchain.blocks, headers: $blockchain.headers },
      verificationprogress: $blockchain.verificationprogress,
      size_on_disk: $blockchain.size_on_disk
    },
    network: {
      version: $network.version,
      subversion: $network.subversion,
      protocolversion: $network.protocolversion,
      connections: $network.connections,
      connections_in: $network.connections_in,
      connections_out: $network.connections_out
    },
    mempool: {
      tx_count: $mempool.size,
      size_vbytes: $mempool.bytes,
      usage_bytes: $mempool.usage,
      maxmempool_bytes: $mempool.maxmempool,
      mempoolminfee_sat_vb: ($mempoolminfee|tonumber)
    },
    rpc: { active_commands: ($rpc_active|tonumber) }
  }'
)"

# Add fee_histogram (if present)
if [[ -n "$mempool_fee_histogram_rate_groups_arg" ]]; then
  fee_hist="$(jq -c '.fee_histogram // empty' <<<"$mempool_info" || true)"
  if [[ -n "$fee_hist" ]]; then
    json="$(jq --argjson fh "$fee_hist" '.mempool.fee_histogram=$fh' <<<"$json")"
  fi
fi

# Add estimatesmartfee map
fees_obj="{}"
for t in "${estimatesmartfee_targets[@]}"; do
  # keep your “avoid scientific notation” approach
  feerate="$(bc <<< "$($bitcoin_cli estimatesmartfee "$t" | grep ".feerate" | grep -Eo "[0-9]+\.[0-9]+") * 100000")"
  fees_obj="$(jq --arg k "$t" --arg v "$feerate" '. + {($k): ($v|tonumber)}' <<<"$fees_obj")"
done
json="$(jq --argjson fees "$fees_obj" '.fees.estimatesmartfee_sat_vb=$fees' <<<"$json")"

echo "$json"
