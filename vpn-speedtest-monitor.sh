#!/bin/sh
# vpn-speedtest-monitor.sh
#
# This script performs two functions:
#
# 1) Speed Test Mode (--speedtest):
#    - Runs a speed test using the Ookla CLI.
#    - Compares the download speed to a defined threshold.
#    - If the speed is below the threshold, fetches recommended NordVPN servers,
#      ranks them based on load, latency, and public key, and switches the VPN configuration.
#
# 2) Update Mode (--update):
#    - Updates the VPN configuration by fetching and applying new recommended NordVPN servers.
#
# Additionally, there is an AutoThreshold mode (--autothreshold) which:
#    - Runs 5 WAN speed tests to compute the average raw connection speed.
#    - Fetches 5 recommended servers (using RECOMMENDED_API_URL) and runs 1 speed test on each
#      (using the VPN interface) to compute an average tunnel speed.
#    - Calculates a dynamic threshold and updates the configuration file.
#
# Usage examples:
#   ./vpn-speedtest-monitor.sh /jffs/scripts/vpn-monitor.conf --speedtest
#   ./vpn-speedtest-monitor.sh /jffs/scripts/vpn-monitor.conf --update
#   ./vpn-speedtest-monitor.sh /jffs/scripts/vpn-monitor.conf --autothreshold --speedtest
#
# Add the script to /jffs/scripts/ and make it executable:
#       chmod a+rx /jffs/scripts/vpn-speedtest-monitor.sh
#

###############################################################################
#                             COLOR DEFINITIONS                               #
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'  # No Color

###############################################################################
#                         USAGE & ARGUMENT PARSING                            #
###############################################################################
usage() {
    echo "Usage: $0 <config_file> [--speedtest] [--update] [--autothreshold] [--debug]"
    echo "  --speedtest      Run the Ookla speed test and update VPN config if below threshold."
    echo "  --update         Force an update of the VPN configuration (fetch and switch servers)."
    echo "  --autothreshold  Automatically calculate a dynamic speed threshold based on WAN and VPN tests."
    echo "  --debug          Enable debug mode for extra log details."
    echo "If no mode flag is provided, the script defaults to --speedtest mode."
}

speedtest_mode=false
update_mode=false
autothreshold_mode=false
debug_mode=false

if [ -z "$1" ]; then
    usage
    exit 1
fi
CONFIG_FILE="$1"
shift

while [ "$#" -gt 0 ]; do
    case "$1" in
        --debug)
            debug_mode=true
            ;;
        --speedtest)
            speedtest_mode=true
            ;;
        --update)
            update_mode=true
            ;;
        --autothreshold)
            autothreshold_mode=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

if [ "$speedtest_mode" = false ] && [ "$update_mode" = false ] && [ "$autothreshold_mode" = false ]; then
    speedtest_mode=true
fi

if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
else
    echo "Configuration file not found: $CONFIG_FILE"
    exit 1
fi

if [ -z "$CLIENT_INSTANCE" ]; then
    echo "CLIENT_INSTANCE is not defined in the config file."
    exit 1
fi
if [ -z "$SPEED_THRESHOLD" ]; then
    echo "SPEED_THRESHOLD is not defined in the config file."
    exit 1
fi
if [ -z "$MAX_ATTEMPTS" ]; then
    MAX_ATTEMPTS=3
fi
if [ -z "$PING_COUNT" ]; then
    PING_COUNT=3
fi
if [ -z "$PING_TIMEOUT" ]; then
    PING_TIMEOUT=5
fi
if [ -z "$TEST_IP" ]; then
    TEST_IP="8.8.8.8"
fi
if [ -z "$MAX_SERVERS" ]; then
    MAX_SERVERS=5
fi
if [ -z "$LOG_FILE" ]; then
    LOG_FILE="/var/log/vpn-speedtest.log"
fi
if [ -z "$RECOMMENDED_API_URL" ]; then
    RECOMMENDED_API_URL="https://api.nordvpn.com/v1/servers/recommendations?filters%5Bservers_technologies%5D%5Bidentifier%5D=wireguard_udp&limit=${MAX_SERVERS}"
fi

wgc_enabled=$(nvram get "${CLIENT_INSTANCE}_enable")
if [ -z "$wgc_enabled" ]; then
    echo "$(date): ${CLIENT_INSTANCE} is not set up or is disabled"
    exit 2
fi

###############################################################################
#                         CONFIGURATION & LOGGING                             #
###############################################################################
SPEEDTEST_CMD="/usr/sbin/ookla -c https://www.speedtest.net/api/embed/vz0azjarf5enop8a/config -I ${CLIENT_INSTANCE} -f json"

log() {
    message="$1"
    color="$NC"
    case "$message" in
        Debug:*)
            color="$YELLOW" ;;
        *Warning:*)
            color="$RED" ;;
        "Starting VPN speed test"*)
            color="$MAGENTA" ;;
        *"Connectivity check succeeded"*)
            color="$GREEN" ;;
        *"Connectivity check failed"*)
            color="$RED" ;;
        *"Fetching new recommended servers"*)
            color="$BLUE" ;;
        *"Switching"*)
            color="$CYAN" ;;
        *)
            color="$NC" ;;
    esac
    echo -e "${color}${message}${NC}"
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
}

###############################################################################
#                          UTILITY FUNCTIONS                                  #
###############################################################################
bc_strip() {
    echo "$@" | bc | xargs
}

less_than() {
    bc_strip "$1 < $2"
}

colorize_load() {
    l="$1"
    if [ "$l" -lt 20 ]; then
        echo -e "${GREEN}${l}${NC}"
    elif [ "$l" -lt 60 ]; then
        echo -e "${YELLOW}${l}${NC}"
    else
        echo -e "${RED}${l}${NC}"
    fi
}

colorize_latency() {
    val="$1"
    if ! echo "$val" | grep -qE '^[0-9.]+$'; then
        echo "$val"
        return
    fi
    if [ "$(less_than "$val" 10)" -eq 1 ]; then
        echo -e "${GREEN}${val}${NC}"
    elif [ "$(less_than "$val" 30)" -eq 1 ]; then
        echo -e "${YELLOW}${val}${NC}"
    else
        echo -e "${RED}${val}${NC}"
    fi
}

ping_latency() {
    raw=$(ping -I "$(nvram get wan0_ifname)" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$1" 2>/dev/null \
         | grep -oE 'time=[0-9.]+ ms' \
         | sed -E 's/time=//; s/ ms//')
    raw=$(echo "$raw" | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')
    sum=0
    count=0
    for val in $raw; do
        sum=$(bc_strip "$sum + $val")
        count=$(bc_strip "$count + 1")
    done
    if [ "$count" -eq 0 ]; then
        avg=50
    else
        avg=$(bc_strip "scale=2; $sum / $count")
    fi
    echo "$raw;$avg"
}

###############################################################################
#                    VPN CONFIGURATION UPDATE FUNCTION                        #
###############################################################################
update_vpn_config() {
    echo -e "\n${BLUE}================= Fetching new recommended servers... =================${NC}"
    log "Fetching new recommended servers"
    
    # Query for 4 values per server: hostname, load, station (IP), and public_key.
    curl -s "$RECOMMENDED_API_URL" | /opt/usr/bin/jq -r '.[] | .hostname, .load, .station, ((.technologies[] | select(.identifier=="wireguard_udp") | (.metadata[]? | select(.name=="public_key") | .value)) // "")' > /tmp/Peers.txt

    servers=""
    loads=""
    ips=""
    pubkeys=""
    index=0
    while IFS= read -r line; do
        case $(( index % 4 )) in
            0) servers="$servers $line" ;;
            1) loads="$loads $line" ;;
            2) ips="$ips $line" ;;
            3) pubkeys="$pubkeys $line" ;;
        esac
        index=$(( index + 1 ))
    done < /tmp/Peers.txt
    rm /tmp/Peers.txt

    if [ -z "$servers" ]; then
        log "Warning: Failed to fetch VPN servers."
        exit 1
    fi

    [ "$debug_mode" = true ] && log "Debug: Raw Servers - $servers"
    [ "$debug_mode" = true ] && log "Debug: Raw Loads - $loads"
    [ "$debug_mode" = true ] && log "Debug: Raw IPs - $ips"
    [ "$debug_mode" = true ] && log "Debug: Raw Public Keys - $pubkeys"

    echo -e "\n${CYAN}============ Fetched VPN Servers and Load Percentages ============${NC}\n"
    log ""

    servers_candidates=""
    i=1
    for server in $servers; do
        load=$(echo "$loads" | awk -v n="$i" '{print int($n)}')
        ip=$(echo "$ips" | awk -v n="$i" '{print $n}')
        pubkey=$(echo "$pubkeys" | awk -v n="$i" '{print $n}')
        ping_result=$(ping_latency "$server")
        rawTimes=$(echo "$ping_result" | cut -d ';' -f1)
        avgLatency=$(echo "$ping_result" | cut -d ';' -f2)
        cLoad=$(colorize_load "$load")
        colored_raw=""
        for t in $rawTimes; do
            cLat=$(colorize_latency "$t")
            colored_raw="$colored_raw ${cLat}ms,"
        done
        colored_raw=$(echo "$colored_raw" | sed 's/,$//; s/^ *//')
        cAvg=$(colorize_latency "$avgLatency")
        log "  - Server: $server ($ip), Load: $cLoad%, Latency: $colored_raw Average: $cAvg ms, Public Key: $pubkey"
        [ "$debug_mode" = true ] && log "  - Debug: Calculating weight for $server -> 100 - $load - $avgLatency"
        weight_decimal=$(bc_strip "scale=2; 100 - $load - $avgLatency")
        weight_int=$(bc_strip "$weight_decimal * 100" | cut -d'.' -f1)
        log "  - Assigned Weight: $weight_int (Server: $server, Latency: $avgLatency ms)"
        log ""
        servers_candidates="$servers_candidates $server:$weight_int:$load:$avgLatency:$ip:$pubkey"
        i=$(( i + 1 ))
    done

    echo -e "\n${MAGENTA}============ Sorting Candidates & Testing Connectivity ============${NC}\n"
    log ""

    sorted_candidates=$(echo "$servers_candidates" | tr ' ' '\n' | sort -t':' -k2 -nr)
    attempt=1
    success=0
    for candidate in $sorted_candidates; do
        if [ $attempt -gt $MAX_ATTEMPTS ]; then
            break
        fi
        candidate_server=$(echo "$candidate" | cut -d':' -f1)
        candidate_weight=$(echo "$candidate" | cut -d':' -f2)
        candidate_load=$(echo "$candidate" | cut -d':' -f3)
        candidate_avg=$(echo "$candidate" | cut -d':' -f4)
        candidate_ip=$(echo "$candidate" | cut -d':' -f5)
        candidate_pubkey=$(echo "$candidate" | cut -d':' -f6)
        log "Attempt $attempt: Applying server ${CYAN}$candidate_server${NC} ($candidate_ip) (Load: ${candidate_load}%, Latency: ${candidate_avg}ms, Public Key: $candidate_pubkey)"
        nvram set "${CLIENT_INSTANCE}_desc"="$candidate_server ($candidate_ip, Load: $candidate_load%, Latency: $candidate_avg ms)"
        nvram set "${CLIENT_INSTANCE}_ep_addr"="$candidate_server"
        nvram set "${CLIENT_INSTANCE}_ppub"="$candidate_pubkey"
        nvram commit
        log "Restarting VPN tunnel to apply new settings..."
        service restart_wgc
        sleep 2
        log "Checking VPN connectivity (attempt $attempt of $MAX_ATTEMPTS)..."
        if ping -I "$CLIENT_INSTANCE" -c 5 -W 5 "$TEST_IP" >/dev/null 2>&1; then
            log "VPN connectivity check succeeded with server ${GREEN}$candidate_server ($candidate_ip)${NC}."
            success=1
            break
        else
            log "VPN connectivity check failed with server ${RED}$candidate_server ($candidate_ip)${NC}."
        fi
        attempt=$(( attempt + 1 ))
        log ""
    done
    if [ $success -ne 1 ]; then
        log "Warning: VPN connectivity check failed after $MAX_ATTEMPTS attempts. Please check your VPN configuration."
        exit 1
    fi
}

###############################################################################
#                        AUTO-THRESHOLD CALCULATION                           #
###############################################################################
if [ "$autothreshold_mode" = true ]; then
    log "Running auto-threshold calibration..."

    # Step 1: Measure WAN speed over 5 tests
    WAN_IF=$(nvram get wan0_ifname)
    WAN_SPEEDTEST_CMD="/usr/sbin/ookla -c https://www.speedtest.net/api/embed/vz0azjarf5enop8a/config -I $WAN_IF -f json"
    total_wan_speed=0
    num_tests=5
    i=1
    while [ $i -le $num_tests ]; do
        result=$($WAN_SPEEDTEST_CMD 2>/dev/null)
        spd=$(echo "$result" | /opt/usr/bin/jq -r '.download.bandwidth')
        if echo "$spd" | grep -qE '^[0-9]+$'; then
            spd_mbps=$(echo "$spd" | awk '{printf "%.2f", $1 / 125000}')
            total_wan_speed=$(echo "$total_wan_speed + $spd_mbps" | bc)
        else
            log "Warning: Invalid WAN speed test result: $spd"
        fi
        i=$(( i + 1 ))
    done
    WAN_avg=$(echo "scale=2; $total_wan_speed / $num_tests" | bc)
    log "WAN average speed: $WAN_avg Mbps"

    # Step 2: Test recommended servers via the VPN tunnel
    orig_ep=$(nvram get "${CLIENT_INSTANCE}_ep_addr")
    orig_desc=$(nvram get "${CLIENT_INSTANCE}_desc")
    curl -s "$RECOMMENDED_API_URL" | /opt/usr/bin/jq -r '.[] | .hostname, .station' > /tmp/Peers.txt
    rec_servers=""
    rec_ips=""
    index=0
    while IFS= read -r line; do
        case $(( index % 2 )) in
            0) rec_servers="$rec_servers $line" ;;
            1) rec_ips="$rec_ips $line" ;;
        esac
        index=$(( index + 1 ))
    done < /tmp/Peers.txt
    rm /tmp/Peers.txt
    total_tunnel_speed=0
    tunnel_count=0
    j=1
    for server in $rec_servers; do
        ip=$(echo "$rec_ips" | awk -v idx="$j" '{print $idx}')
        log "Testing tunnel speed for server: $server ($ip)"
        nvram set "${CLIENT_INSTANCE}_ep_addr"="$server"
        nvram set "${CLIENT_INSTANCE}_desc"="$server ($ip)"
        nvram commit
        service restart_wgc
        sleep 2
        result=$($SPEEDTEST_CMD 2>/dev/null)
        spd=$(echo "$result" | /opt/usr/bin/jq -r '.download.bandwidth')
        if echo "$spd" | grep -qE '^[0-9]+$'; then
            spd_mbps=$(echo "$spd" | awk '{printf "%.2f", $1 / 125000}')
            total_tunnel_speed=$(echo "$total_tunnel_speed + $spd_mbps" | bc)
            tunnel_count=$(( tunnel_count + 1 ))
            log "  Speed: $spd_mbps Mbps"
        else
            log "Warning: Invalid tunnel speed test for server $server: $spd"
        fi
        j=$(( j + 1 ))
    done
    if [ $tunnel_count -gt 0 ]; then
        Tunnel_avg=$(echo "scale=2; $total_tunnel_speed / $tunnel_count" | bc)
    else
        Tunnel_avg=0
    fi
    log "Tunnel average speed: $Tunnel_avg Mbps"

    # Step 3: Calculate dynamic threshold:
    overhead=$(echo "$WAN_avg - $Tunnel_avg" | bc)
    dynamic_threshold=$(echo "scale=2; $Tunnel_avg - ($overhead * 0.5)" | bc)
    log "Calculated dynamic threshold: $dynamic_threshold Mbps"

    nvram set "${CLIENT_INSTANCE}_ep_addr"="$orig_ep"
    nvram set "${CLIENT_INSTANCE}_desc"="$orig_desc"
    nvram commit

    SPEED_THRESHOLD="$dynamic_threshold"
    sed -i "s/^SPEED_THRESHOLD=.*/SPEED_THRESHOLD=\"$dynamic_threshold\"/" "$CONFIG_FILE"
    log "Config file updated with new SPEED_THRESHOLD."
    
    # Force a speed test using the new threshold.
    speedtest_mode=true
fi

###############################################################################
#                              MAIN SCRIPT                                    #
###############################################################################
log ""
echo -e "${MAGENTA}****************************  Starting VPN speed test/update  ****************************${NC}"
log ""

update_triggered=false

if [ "$speedtest_mode" = true ]; then
    log "Starting VPN speed test"
    SPEED_JSON=$($SPEEDTEST_CMD 2>/dev/null)
    SPEED_RESULT=$(echo "$SPEED_JSON" | /opt/usr/bin/jq -r '.download.bandwidth')
    if ! echo "$SPEED_RESULT" | grep -qE '^[0-9]+$'; then
        log "Warning: Invalid speed test result: $SPEED_RESULT"
        exit 1
    fi
    SPEED_Mbps=$(echo "$SPEED_RESULT" | awk '{printf "%.2f", $1 / 125000}')
    speedComp1=$(less_than "$SPEED_Mbps" 100)
    speedComp2=$(less_than "$SPEED_Mbps" 200)
    if [ "$speedComp1" -eq 1 ]; then
        colored_speed="${RED}${SPEED_Mbps}${NC}"
    elif [ "$speedComp2" -eq 1 ]; then
        colored_speed="${YELLOW}${SPEED_Mbps}${NC}"
    else
        colored_speed="${GREEN}${SPEED_Mbps}${NC}"
    fi
    log "Current VPN Download Speed: $colored_speed Mbps"
    log ""
    speedCheck=$(bc_strip "$SPEED_Mbps < $SPEED_THRESHOLD")
    if [ "$speedCheck" -eq 1 ]; then
        log "Speed is below threshold ($SPEED_THRESHOLD Mbps). Updating VPN configuration..."
        update_vpn_config
        update_triggered=true
    else
        log "Speed is acceptable. No VPN update triggered by speed test."
    fi
fi

if [ "$update_mode" = true ] && [ "$update_triggered" = false ]; then
    log "Forcing VPN configuration update..."
    update_vpn_config
fi

log ""
echo -e "${GREEN}==== Script Finished ====${NC}"
log ""
exit 0
