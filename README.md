# Zabbix Monitoring of bitcoind (Agent Active)

This is rewrite of [zbx-bitcoin](https://github.com/zkSNACKs/zbx-bitcoin) using Zabbix agent active checks and JSON output, instead of `zabbix_sender`.

Dependencies:

- `bc` is required for calculations in the script
- `bitcoin-cli` must be installed and configured on the monitored host
- `jq` is required for JSON parsing in the script

Compatible with **Zabbix 7.4**.

------------------------------------------------------------------------

## 1. Install Script

Place the script on the monitored host:

    /usr/local/bin/bitcoind-zbx-json.sh

Make it executable and accessible to the `zabbix` user:

    chmod +x /usr/local/bin/bitcoind-zbx-json.sh
    chown zabbix:zabbix /usr/local/bin/bitcoind-zbx-json.sh

Test it manually (default, GBT monitoring disabled):

    sudo -u zabbix /usr/local/bin/bitcoind-zbx-json.sh | jq .

Optional: enable getblocktemplate monitoring (for mining setups):

    sudo -u zabbix /usr/local/bin/bitcoind-zbx-json.sh -- 1 | jq .

It must output valid JSON.

------------------------------------------------------------------------

## Optional: getblocktemplate (GBT) Monitoring

The script supports optional monitoring of `getblocktemplate`, useful for:

- mining pools
- solo miners
- systems relying on block template freshness

By default, this feature is **disabled** to avoid unnecessary RPC load.

### Enable manually

Run script with argument:

    bitcoind-zbx-json.sh -- 1

### Zabbix integration

In the template, this is controlled via macro:

    {$BITCOIN.GBT.MONITOR}

Values:

- `0` = disabled (default)
- `1` = enabled

### Metrics added

When enabled, the following values are exported under the `mining` object in the JSON output:

- `.mining.getblocktemplate_latency_ms` — RPC latency
- `.mining.getblocktemplate_error` — RPC failure indicator
- `.mining.getblocktemplate_tx_count` — transactions in template
- `.mining.getblocktemplate_tip_match` — template built on current tip (1/0)
- `.mining.getblocktemplate_age` — template age in seconds

### Notes

- This adds extra RPC load (~1 call per collection interval)
- Recommended polling interval: >= 60 seconds
- Not needed for standard full nodes

------------------------------------------------------------------------

## 2. Configure Zabbix Agent (agentd)

Add UserParameter to agent config (or included `.conf` file):

    UserParameter=bitcoin.status[*],/usr/local/bin/bitcoind-zbx-json.sh -- "$1"

Ensure it is inside the config file actually used by `zabbix_agentd`.

Verify key is loaded:

    zabbix_agentd -p | grep bitcoin.status[0]

Restart agent (Debian / Ubuntu systemd example):

    sudo systemctl restart zabbix-agent

Test locally:

    zabbix_agentd -t bitcoin.status[0]

Expected:

    bitcoin.status [t|{...JSON...}]

------------------------------------------------------------------------

## 3. Active Checks Configuration

In `zabbix_agentd.conf` ensure:

    ServerActive=<zabbix_server_or_proxy_ip>
    Hostname=<exact_hostname_from_Zabbix_UI>

Check log:

    tail -f /var/log/zabbix-agentd/zabbix_agentd.log

You should NOT see:

    Unsupported item key

------------------------------------------------------------------------

## 4. Import Template

Import the provided Zabbix 7.4 template:

-   Master item: `bitcoin.status`
-   Type: Zabbix agent (active)
-   Dependent items extract JSON fields

Link template to host.

------------------------------------------------------------------------

## 5. Verify from Zabbix Server

Optional remote test:

    zabbix_get -s <host_ip> -k bitcoin.status[0]

------------------------------------------------------------------------

## Common Issues

### Unsupported item key

-   UserParameter not loaded
-   Wrong config file edited
-   Agent not restarted
-   Script permission problem

### Permission problems

Ensure `zabbix` user can:

-   Execute script
-   Run `bitcoin-cli`
-   Access Bitcoin data directory

Test as:

    sudo -u zabbix bitcoin-cli getblockchaininfo
