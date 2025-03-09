#!/bin/sh
# vpn-speedtest-monitor.sh
#
# This script performs a VPN speed test and updates the VPN configuration if necessary.
# It sources a unique configuration file based on the VPN client instance.
#
# Usage:
#    /jffs/scripts/vpn-speedtest-monitor.sh <client_instance>
# Example:
#    /jffs/scripts/vpn-speedtest-monitor.sh wgc5

# ------------------------------
# Source the unique configuration file
# ------------------------------
if [ -n "$1" ]; then
    CONFIG_FILE="/jffs/scripts/vpn-monitor-$1.conf"
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
    else
        echo "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
else
    echo "Usage: $0 <client_instance>"
    exit 1
fi

# ------------------------------
# Define color variables for output
# ------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ------------------------------
# Logging function: prints to console (with color) and appends to LOG_FILE
# ------------------------------
log() {
    local message="$1"
    local color="$NC"
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
        *Switching*)
            color="$CYAN" ;;
        *)
            color="$NC" ;;
    esac
    echo -e "${color}${message}${NC}"
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
}

# ------------------------------
# Utility functions
# ------------------------------
bc_strip() {
    echo "$@" | bc | xargs
}

less_than() {
    bc_strip "$1 < $2"
}

colorize_load() {
    local l="$1"
    if [ "$l" -lt 20 ]; then
        echo -e "${GREEN}${l}${NC}"
    elif [ "$l" -lt 60 ]; then
        echo -e "${YELLOW}${l}${NC}"
    else
        echo -e "${RED}${l}${NC}"
    fi
}

colorize_latency() {
    local val="$1"
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
    # Use the WAN interface (retrieved from nvram) with parameters from config (PING_COUNT, PING_TIMEOUT)
    local wan_if=$(nvram get wan0_ifname)
    local raw=$(ping -I "$wan_if" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$1" 2>/dev/null | grep -oE 'time=[0-9.]+ ms' | sed -E 's/time=//; s/ ms//')
    raw=$(echo "$raw" | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')
    local sum=0
    local count=0
    for val in $raw; do
        sum=$(bc_strip "$sum + $val")
        count=$(bc_strip "$count + 1")
    done
    local avg=0
    if [ "$count" -eq 0 ]; then
        avg=50
    else
        avg=$(bc_strip "scale=2; $sum / $count")
    fi
    echo "$raw;$avg"
}

# ------------------------------
# update_vpn_config: Fetch recommended servers, calculate weight, and update VPN settings
# Weight is calculated as: (100 - load - average_latency) * 100
# ------------------------------
update_vpn_config() {
    echo -e "\n${BLUE}================= Fetching new recommended servers... =================${NC}"
    log "Fetching new recommended servers"

    # Fetch recommended servers (limit defined by MAX_SERVERS) along with .load and .station (IP)
    curl -s "https://api.nordvpn.com/v1/servers/recommendations?filters%5Bservers_technologies%5D%5Bidentifier%5D=wireguard_udp&limit=${MAX_SERVERS}" \
         | /tmp/opt/usr/bin/jq -r '.[] | .hostname, .load, .station' > /tmp/Peers.txt

    servers=""
    loads=""
    ips=""
    index=0
    while IFS= read -r line; do
        case $(( index % 3 )) in
            0) servers="$servers $line" ;;
            1) loads="$loads $line" ;;
            2) ips="$ips $line" ;;
        esac
        index=$(( index + 1 ))
    done < /tmp/Peers.txt
    rm /tmp/Peers.txt

    if [ -z "$servers" ]; then
        log "Warning: Failed to fetch VPN servers."
        exit 1
    fi

    [ "$DEBUG_MODE" -eq 1 ] && log "Debug: Raw Servers - $servers"
    [ "$DEBUG_MODE" -eq 1 ] && log "Debug: Raw Loads - $loads"
    [ "$DEBUG_MODE" -eq 1 ] && log "Debug: Raw IPs - $ips"

    echo -e "\n${CYAN}============ Fetched VPN Servers and Load Percentages ============${NC}\n"
    log ""

    servers_candidates=""
    i=1
    for server in $servers; do
        load=$(echo "$loads" | awk -v n="$i" '{print int($n)}')
        ip=$(echo "$ips" | awk -v n="$i" '{print $n}')
        ping_result=$(ping_latency "$server")
        rawTimes=$(echo "$ping_result" | cut -d ';' -f1)
        avgLatency=$(echo "$ping_result" | cut -d ';' -f2)

        cLoad=$(colorize_load "$load")

        # Format raw ping times with colors
        colored_raw=""
        for t in $rawTimes; do
            cLat=$(colorize_latency "$t")
            colored_raw="$colored_raw ${cLat}ms,"
        done
        colored_raw=$(echo "$colored_raw" | sed 's/,$//; s/^ *//')

        cAvg=$(colorize_latency "$avgLatency")
        log "  - Server: $server ($ip), Load: $cLoad%, Latency: $colored_raw Average: $cAvg ms"
        [ "$DEBUG_MODE" -eq 1 ] && log "  - Debug: Calculating weight for $server -> 100 - $load - $avgLatency"
        
        weight_decimal=$(bc_strip "scale=2; 100 - $load - $avgLatency")
        weight_int=$(bc_strip "$weight_decimal * 100" | cut -d'.' -f1)
        log "  - Assigned Weight: $weight_int (Server: $server, Latency: $avgLatency ms)"
        log ""
        servers_candidates="$servers_candidates $server:$weight_int:$load:$avgLatency:$ip"
        i=$(( i + 1 ))
    done

    echo -e "\n${MAGENTA}============ Sorting Candidates & Testing Connectivity ============${NC}\n"
    log ""

    sorted_candidates=$(echo "$servers_candidates" | tr ' ' '\n' | sort -t':' -k2 -nr)
    max_attempts="${MAX_ATTEMPTS}"
    attempt=1
    success=0

    for candidate in $sorted_candidates; do
        if [ $attempt -gt $max_attempts ]; then
            break
        fi

        candidate_server=$(echo "$candidate" | cut -d':' -f1)
        candidate_weight=$(echo "$candidate" | cut -d':' -f2)
        candidate_load=$(echo "$candidate" | cut -d':' -f3)
        candidate_avg=$(echo "$candidate" | cut -d':' -f4)
        candidate_ip=$(echo "$candidate" | cut -d':' -f5)

        log "Attempt $attempt: Applying server ${CYAN}$candidate_server${NC} ($candidate_ip) (Load: ${candidate_load}%, Latency: ${candidate_avg}ms)"
        nvram set "${CLIENT_INSTANCE}_desc"="$candidate_server ($candidate_ip, Load: $candidate_load%, Latency: $candidate_avg ms)"
        nvram set "${CLIENT_INSTANCE}_ep_addr"="$candidate_server"
        nvram commit

        log "Restarting VPN tunnel to apply new settings..."
        service restart_wgc
        sleep 2

        log "Checking VPN connectivity (attempt $attempt of $max_attempts)..."
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
        log "Warning: VPN connectivity check failed after $max_attempts attempts. Please check your VPN configuration."
        exit 1
    fi
}

# ------------------------------
# Auto-Threshold Calibration (if AUTO_THRESHOLD is true)
# ------------------------------
if [ "$AUTO_THRESHOLD" = "true" ]; then
    log "Running auto-threshold calibration..."

    # Step 1: Measure WAN speed over 5 tests
    WAN_IF=$(nvram get wan0_ifname)
    total_wan_speed=0
    num_tests=5
    i=1
    while [ $i -le $num_tests ]; do
        result=$(/usr/sbin/ookla -c https://www.speedtest.net/api/embed/vz0azjarf5enop8a/config -I "$WAN_IF" -f json 2>/dev/null)
        spd=$(echo "$result" | /tmp/opt/usr/bin/jq -r '.download.bandwidth')
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

    # Step 2: Test recommended servers via the VPN tunnel.
    # Save original VPN configuration to restore later.
    orig_ep=$(nvram get "${CLIENT_INSTANCE}_ep_addr")
    orig_desc=$(nvram get "${CLIENT_INSTANCE}_desc")

    curl -s "https://api.nordvpn.com/v1/servers/recommendations?filters%5Bservers_technologies%5D%5Bidentifier%5D=wireguard_udp&limit=${MAX_SERVERS}" \
         | /tmp/opt/usr/bin/jq -r '.[] | .hostname, .station' > /tmp/Peers.txt

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
    for server in $rec_servers; do
        ip=$(echo "$rec_ips" | awk '{print $1}')
        rec_ips=$(echo "$rec_ips" | cut -d' ' -f2-)
        log "Testing tunnel speed for server: $server ($ip)"
        nvram set "${CLIENT_INSTANCE}_ep_addr"="$server"
        nvram set "${CLIENT_INSTANCE}_desc"="$server ($ip)"
        nvram commit
        service restart_wgc
        sleep 2
        result=$(/usr/sbin/ookla -c https://www.speedtest.net/api/embed/vz0azjarf5enop8a/config -I "$CLIENT_INSTANCE" -f json 2>/dev/null)
        spd=$(echo "$result" | /tmp/opt/usr/bin/jq -r '.download.bandwidth')
        if echo "$spd" | grep -qE '^[0-9]+$'; then
            spd_mbps=$(echo "$spd" | awk '{printf "%.2f", $1 / 125000}')
            total_tunnel_speed=$(echo "$total_tunnel_speed + $spd_mbps" | bc)
            tunnel_count=$(( tunnel_count + 1 ))
            log "  Speed: $spd_mbps Mbps"
        else
            log "Warning: Invalid tunnel speed test for server $server: $spd"
        fi
    done

    if [ $tunnel_count -gt 0 ]; then
        Tunnel_avg=$(echo "scale=2; $total_tunnel_speed / $tunnel_count" | bc)
    else
        Tunnel_avg=0
    fi
    log "Tunnel average speed: $Tunnel_avg Mbps"

    overhead=$(echo "$WAN_avg - $Tunnel_avg" | bc)
    dynamic_threshold=$(echo "scale=2; $Tunnel_avg - ($overhead * 0.5)" | bc)
    log "Calculated dynamic threshold: $dynamic_threshold Mbps"

    # Restore original VPN configuration
    nvram set "${CLIENT_INSTANCE}_ep_addr"="$orig_ep"
    nvram set "${CLIENT_INSTANCE}_desc"="$orig_desc"
    nvram commit

    SPEED_THRESHOLD=$dynamic_threshold
fi

# ------------------------------
# Main Speed Test and VPN Update
# ------------------------------
log ""
echo -e "${MAGENTA}****************************  Starting VPN speed test/update  ****************************${NC}"
log ""

update_triggered=false

log "Starting VPN speed test"
SPEED_JSON=$(/usr/sbin/ookla -c https://www.speedtest.net/api/embed/vz0azjarf5enop8a/config -I "$CLIENT_INSTANCE" -f json 2>/dev/null)
SPEED_RESULT=$(echo "$SPEED_JSON" | /tmp/opt/usr/bin/jq -r '.download.bandwidth')
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

log ""
echo -e "${GREEN}==== Script Finished ====${NC}"
log ""
exit 0
