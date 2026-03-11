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

# helper: convert BTC/kvB feerate to sat/vB and avoid scientific notation
btc_kvb_to_sat_vb() {
  local value="${1:-}"
  if [[ -z "$value" || "$value" == "null" ]]; then
    echo "0"
  else
    bc <<< "$value * 100000"
  fi
}

blockchain_info="$($bitcoin_cli getblockchaininfo)"
network_info="$($bitcoin_cli getnetworkinfo)"
rpc_info="$($bitcoin_cli getrpcinfo)"
peer_info="$($bitcoin_cli getpeerinfo)"
net_totals="$($bitcoin_cli getnettotals)"
networkhashps="$($bitcoin_cli getnetworkhashps)"

bestblockhash="$(jq -r '.bestblockhash' <<<"$blockchain_info")"
bestblockheader="$($bitcoin_cli getblockheader "$bestblockhash")"

# fee histogram support detection
mempool_fee_histogram_rate_groups=(0 2 3 4 5 6 7 8 10 12 14 17 20 25 30 40 50 60 70 80 100 120 140 170 200 250 300 400 500 600)
check="$($bitcoin_cli getmempoolinfo '[0]' 2>/dev/null || true)"
if [[ -n "$check" ]]; then
  mempool_fee_histogram_rate_groups_str="${mempool_fee_histogram_rate_groups[*]}"
  mempool_fee_histogram_rate_groups_arg="[${mempool_fee_histogram_rate_groups_str// /,}]"
  mempool_info="$($bitcoin_cli getmempoolinfo "$mempool_fee_histogram_rate_groups_arg")"
else
  mempool_fee_histogram_rate_groups_arg=""
  mempool_info="$($bitcoin_cli getmempoolinfo)"
fi

rpc_active_commands="$(jq '.active_commands | length' <<<"$rpc_info")"
rpc_active_commands=$(( rpc_active_commands - 1 ))
if (( rpc_active_commands < 0 )); then
  rpc_active_commands=0
fi

mempool_mempoolminfee_raw="$(jq -r '.mempoolminfee // 0' <<<"$mempool_info")"
mempool_mempoolminfee="$(btc_kvb_to_sat_vb "$mempool_mempoolminfee_raw")"

# estimatesmartfee targets
estimatesmartfee_targets=(1 2 3 4 6 12 24 48 72 108 144 504 1008)

# derived metrics
header_gap="$(jq -r '(.headers // 0) - (.blocks // 0)' <<<"$blockchain_info")"

bestblock_time="$(jq -r '.time // 0' <<<"$bestblockheader")"
now_ts="$(date +%s)"
bestblock_age="$(( now_ts - bestblock_time ))"
if (( bestblock_age < 0 )); then
  bestblock_age=0
fi

mempool_usage_bytes="$(jq -r '.usage // 0' <<<"$mempool_info")"
mempool_max_bytes="$(jq -r '.maxmempool // 0' <<<"$mempool_info")"
if [[ "$mempool_max_bytes" != "0" ]]; then
  mempool_usage_percent="$(awk "BEGIN { printf \"%.6f\", ($mempool_usage_bytes / $mempool_max_bytes) * 100 }")"
else
  mempool_usage_percent="0"
fi

peer_total="$(jq 'length' <<<"$peer_info")"
peer_ipv4="$(jq '[.[] | select(.network=="ipv4")] | length' <<<"$peer_info")"
peer_ipv6="$(jq '[.[] | select(.network=="ipv6")] | length' <<<"$peer_info")"
peer_onion="$(jq '[.[] | select(.network=="onion")] | length' <<<"$peer_info")"
peer_i2p="$(jq '[.[] | select(.network=="i2p")] | length' <<<"$peer_info")"
peer_not_publicly_routable="$(jq '[.[] | select(.network=="not_publicly_routable")] | length' <<<"$peer_info")"

peer_avg_ping="$(jq -r '
  [ .[] | select(.pingtime != null) | .pingtime ] as $p
  | if ($p|length) > 0 then (($p | add) / ($p|length)) else 0 end
' <<<"$peer_info")"

peer_avg_conntime="$(jq -r '
  [ .[] | select(.conntime != null) | (now - .conntime) ] as $p
  | if ($p|length) > 0 then (($p | add) / ($p|length)) else 0 end
' <<<"$peer_info")"

peer_max_conntime="$(jq -r '
  [ .[] | select(.conntime != null) | (now - .conntime) ] | max // 0
' <<<"$peer_info")"

peer_seen_1h="$(jq -r '
  [ .[] | select(((.lastrecv // 0) > (now - 3600)) or ((.lastsend // 0) > (now - 3600))) ] | length
' <<<"$peer_info")"

peer_seen_24h="$(jq -r '
  [ .[] | select(((.lastrecv // 0) > (now - 86400)) or ((.lastsend // 0) > (now - 86400))) ] | length
' <<<"$peer_info")"

json="$(jq -n \
  --argjson blockchain "$blockchain_info" \
  --argjson network "$network_info" \
  --argjson mempool "$mempool_info" \
  --argjson rpc_active "$rpc_active_commands" \
  --argjson net_totals "$net_totals" \
  --argjson networkhashps "$networkhashps" \
  --arg mempoolminfee "$mempool_mempoolminfee" \
  --arg header_gap "$header_gap" \
  --arg bestblock_time "$bestblock_time" \
  --arg bestblock_age "$bestblock_age" \
  --arg mempool_usage_percent "$mempool_usage_percent" \
  --arg peer_total "$peer_total" \
  --arg peer_ipv4 "$peer_ipv4" \
  --arg peer_ipv6 "$peer_ipv6" \
  --arg peer_onion "$peer_onion" \
  --arg peer_i2p "$peer_i2p" \
  --arg peer_not_publicly_routable "$peer_not_publicly_routable" \
  --arg peer_avg_ping "$peer_avg_ping" \
  --arg peer_avg_conntime "$peer_avg_conntime" \
  --arg peer_max_conntime "$peer_max_conntime" \
  --arg peer_seen_1h "$peer_seen_1h" \
  --arg peer_seen_24h "$peer_seen_24h" \
  '{
    blockchain: {
      tip: {
        blocks: $blockchain.blocks,
        headers: $blockchain.headers
      },
      verificationprogress: $blockchain.verificationprogress,
      size_on_disk: $blockchain.size_on_disk,
      header_gap: ($header_gap | tonumber),
      bestblocktime: ($bestblock_time | tonumber),
      bestblockage: ($bestblock_age | tonumber),
      difficulty: $blockchain.difficulty,
      initialblockdownload: (if $blockchain.initialblockdownload then 1 else 0 end),
      pruned: (if $blockchain.pruned then 1 else 0 end)
    },
    network: {
      version: $network.version,
      subversion: $network.subversion,
      protocolversion: $network.protocolversion,
      connections: $network.connections,
      connections_in: $network.connections_in,
      connections_out: $network.connections_out,
      totalbytesrecv: $net_totals.totalbytesrecv,
      totalbytessent: $net_totals.totalbytessent,
      networkhashps: $networkhashps
    },
    mempool: {
      tx_count: $mempool.size,
      size_vbytes: $mempool.bytes,
      usage_bytes: $mempool.usage,
      maxmempool_bytes: $mempool.maxmempool,
      mempoolminfee_sat_vb: ($mempoolminfee | tonumber),
      usage_percent: ($mempool_usage_percent | tonumber)
    },
    peers: {
      total: ($peer_total | tonumber),
      ipv4: ($peer_ipv4 | tonumber),
      ipv6: ($peer_ipv6 | tonumber),
      onion: ($peer_onion | tonumber),
      i2p: ($peer_i2p | tonumber),
      not_publicly_routable: ($peer_not_publicly_routable | tonumber),
      avg_ping: ($peer_avg_ping | tonumber),
      avg_connection_age: ($peer_avg_conntime | tonumber),
      max_connection_age: ($peer_max_conntime | tonumber),
      seen_1h: ($peer_seen_1h | tonumber),
      seen_24h: ($peer_seen_24h | tonumber)
    },
    rpc: {
      active_commands: ($rpc_active | tonumber)
    }
  }'
)"

# add fee histogram if present
if [[ -n "$mempool_fee_histogram_rate_groups_arg" ]]; then
  fee_hist="$(jq -c '.fee_histogram // empty' <<<"$mempool_info" || true)"
  if [[ -n "$fee_hist" ]]; then
    json="$(jq --argjson fh "$fee_hist" '.mempool.fee_histogram = $fh' <<<"$json")"
  fi
fi

# add estimatesmartfee map
fees_obj='{}'
for t in "${estimatesmartfee_targets[@]}"; do
  fee_json="$($bitcoin_cli estimatesmartfee "$t" 2>/dev/null || true)"
  feerate_raw="$(jq -r '.feerate // empty' <<<"$fee_json" 2>/dev/null || true)"
  if [[ -n "$feerate_raw" ]]; then
    feerate="$(btc_kvb_to_sat_vb "$feerate_raw")"
    fees_obj="$(jq --arg k "$t" --arg v "$feerate" '. + {($k): ($v | tonumber)}' <<<"$fees_obj")"
  else
    fees_obj="$(jq --arg k "$t" '. + {($k): 0}' <<<"$fees_obj")"
  fi
done
json="$(jq --argjson fees "$fees_obj" '.fees.estimatesmartfee_sat_vb = $fees' <<<"$json")"

echo "$json"
