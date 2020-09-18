#!/bin/bash

# Set this to the maximum allowed latency in seconds.
# All servers that repond slower than this will be ignore.
# The value is currently set to 50 milliseconds.
maximum_allowed_latency=0.05
export maximum_allowed_latency

serverlist_url='https://serverlist.piaservers.net/vpninfo/servers/v4'

# This function checks the latency you have to a specific region.
# It will print a human-readable message to stderr,
# and it will print the variables to stdout
printServerLatency() {
  serverIP="$1"
  regionID="$2"
  regionName="${@:3}"
  time=$(curl -o /dev/null -s \
    --connect-timeout $maximum_allowed_latency \
    --write-out "%{time_connect}" \
    http://$serverIP:443)
  if [ $? -eq 0 ]; then
    >&2 echo The region \"$regionName\" responded in $time seconds
    echo $time $regionID $serverIP
  fi
}
export -f printServerLatency

echo -n "Getting the server list... "
# Get all region data since we will need this on multiple ocasions
all_region_data=$(curl -s "$serverlist_url" | head -1)

# If the server list has less than 1000 characters, it means curl failed.
if [[ ${#all_region_data} < 1000 ]]; then
  echo "Could not get correct region data. To debug this, run:"
  echo "$ curl -v $serverlist_url"
  echo "If it works, you will get a huge JSON as a response."
  exit 1
fi
# Notify the user that we got the server list.
echo "OK!"

# Test one server from each region to get the closest region:
echo Testing servers that respond \
  faster than $maximum_allowed_latency seconds:
region_latency_report="$( echo $all_region_data |
  jq -r '.regions[] | .servers.meta[0].ip + " " + .id + " " + .name' )"

# Get the best region
bestRegion="$(echo "$region_latency_report" |
  xargs -i bash -c 'printServerLatency {}' |
  sort | head -1 | awk '{ print $2 }')"

# Get all data for the best region
regionData="$( echo $all_region_data |
  jq --arg REGION_ID "$bestRegion" -r \
  '.regions[] | select(.id==$REGION_ID)')"

echo The closest region is "$(echo $regionData | jq -r '.name')".
echo
bestServer_meta_IP="$(echo $regionData | jq -r '.servers.meta[0].ip')"
bestServer_meta_hostname="$(echo $regionData | jq -r '.servers.meta[0].cn')"
bestServer_WG_IP="$(echo $regionData | jq -r '.servers.wg[0].ip')"
bestServer_WG_hostname="$(echo $regionData | jq -r '.servers.wg[0].cn')"
bestServer_OT_IP="$(echo $regionData | jq -r '.servers.ovpntcp[0].ip')"
bestServer_OT_hostname="$(echo $regionData | jq -r '.servers.ovpntcp[0].cn')"
bestServer_OU_IP="$(echo $regionData | jq -r '.servers.ovpnudp[0].ip')"
bestServer_OU_hostname="$(echo $regionData | jq -r '.servers.ovpnudp[0].cn')"

echo "The script found the best servers from the region closest to you.
When connecting to an IP (no matter which protocol), please verify
the SSL/TLS certificate actually contains the hostname so that you
are sure you are connecting to a secure server, validated by the
PIA authority. Please find bellow the list of best IPs and matching
hostnames for each protocol:
Meta Services: $bestServer_meta_IP // $bestServer_meta_hostname
WireGuard: $bestServer_WG_IP // $bestServer_WG_hostname
OpenVPN TCP: $bestServer_OT_IP // $bestServer_OT_hostname
OpenVPN UDP: $bestServer_OU_IP // $bestServer_OU_hostname
"

if [[ ! $PIA_USER || ! $PIA_PASS ]]; then
  echo If you want this script to automatically get a token from the Meta
  echo service, please add the variables PIA_USER and PIA_PASS. Example:
  echo $ PIA_USER=p0123456 PIA_PASS=xxx ./get_region_and_token.sh
  exit 1
fi

echo "The ./get_region_and_token.sh script got started with PIA_USER and PIA_PASS,
so we will also use a meta service to get a new VPN token."

echo "Trying to get a new token by authenticating with the meta service..."
generateTokenResponse=$(curl -s -u "$PIA_USER:$PIA_PASS" \
  --connect-to "$bestServer_meta_hostname::$bestServer_meta_IP:" \
  --cacert "ca.rsa.4096.crt" \
  "https://$bestServer_meta_hostname/authv3/generateToken")
echo "$generateTokenResponse"

if [ "$(echo "$generateTokenResponse" | jq -r '.status')" != "OK" ]; then
  echo "Could not get a token. Please check your account credentials."
  echo "You can also try debugging by manually running the curl command:"
  echo $ curl -vs -u "$PIA_USER:$PIA_PASS" --cacert ca.rsa.4096.crt \
    --connect-to "$bestServer_meta_hostname::$bestServer_meta_IP:" \
    https://$bestServer_meta_hostname/authv3/generateToken
  exit 1
fi

token="$(echo "$generateTokenResponse" | jq -r '.token')"
echo "This token will expire in 24 hours.
"

if [ "$WG_AUTOCONNECT" != true ]; then
  echo If you wish to automatically connect to WireGuard after detecting the best
  echo region, please run the script with the env var WG_AUTOCONNECT=true. You can
  echo also specify the env var PIA_PF=true to get port forwarding. Example:
  echo $ PIA_USER=p0123456 PIA_PASS=xxx \
    WG_AUTOCONNECT=true PIA_PF=true ./sort_regions_by_latency.sh
  echo
  echo You can connect by running:
  echo WG_TOKEN=\"$token\" WG_SERVER_IP=$bestServer_WG_IP \
    WG_HOSTNAME=$bestServer_WG_hostname ./wireguard_and_pf.sh
  exit
fi

if [ "$PIA_PF" != true ]; then
  PIA_PF="false"
fi

echo "The ./get_region_and_token.sh script got started with WG_AUTOCONNECT=true,
so we will automatically connect to WireGuard, by running this command:
$ WG_TOKEN=\"$token\" \\
  WG_SERVER_IP=$bestServer_WG_IP WG_HOSTNAME=$bestServer_WG_hostname \\
  PIA_PF=$PIA_PF ./wireguard_port_forwarding.sh
"

PIA_PF=$PIA_PF WG_TOKEN="$token" WG_SERVER_IP=$bestServer_WG_IP \
  WG_HOSTNAME=$bestServer_WG_hostname ./wireguard_and_pf.sh