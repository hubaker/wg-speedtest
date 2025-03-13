#!/bin/sh
# vpn-speedtest-monitor.sh
#
# Combined VPN Speed Test/Update Script with Installation, Change Location,
# Monitoring, and Uninstall Modes.
#
# Usage examples:
#
#   Installation mode (prompts for interface selection and creates new files):
#       sh vpn-speedtest-monitor.sh --install
#
#   Change location mode:
#       sh vpn-speedtest-monitor.sh wg5 --changelocation
#
#   Monitoring mode (update, speedtest, auto-threshold, etc.):
#       sh vpn-speedtest-monitor.sh wg5 --update
#       sh vpn-speedtest-monitor.sh wg5 --speedtest
#       sh vpn-speedtest-monitor.sh wg5 --autothreshold --update --debug
#
#   Uninstall mode (removes all config, log, and cron entries):
#       sh vpn-speedtest-monitor.sh --uninstall
#
# In monitoring and change-location modes, the first parameter is the VPN client
# interface name (e.g., wg5) and the corresponding configuration file is
# /jffs/scripts/vpn-monitor-<interface>.conf.

set -e

###############################################################################
#                       ANSI COLOR DEFINITIONS
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

###############################################################################
#                              LOG FUNCTION
###############################################################################
log() {
    message="$1"
    case "$message" in
        Debug:*)
            colored_message="${YELLOW}$message${NC}" ;;
        *Warning:*)
            colored_message="${RED}$message${NC}" ;;
        "Starting VPN speed test"*)
            colored_message="${MAGENTA}$message${NC}" ;;
        *"Connectivity check succeeded"*)
            colored_message="${GREEN}$message${NC}" ;;
        *"Connectivity check failed"*)
            colored_message="${RED}$message${NC}" ;;
        *"Fetching new recommended servers"*)
            colored_message="${BLUE}$message${NC}" ;;
        *"Applying server"*)
            colored_message="${CYAN}$message${NC}" ;;
        *)
            colored_message="$message" ;;
    esac
    echo -e "$colored_message"
    plain_message=$(echo -e "$colored_message" | sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g')
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $plain_message" >> "$LOG_FILE"
}

###############################################################################
#                        HELPER FUNCTIONS (WORKING LOGIC)
###############################################################################
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
    local raw
    raw=$(ping -I "$(nvram get wan0_ifname)" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$1" 2>/dev/null \
          | grep -oE 'time=[0-9.]+ ms' \
          | sed -E 's/time=//; s/ ms//')
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

###############################################################################
#                    UNINSTALLATION LOGIC (--uninstall)
###############################################################################
uninstall_script() {
    echo "Uninstalling VPN Speed Test Monitor..."
    # Remove cron job entries matching vpn-speedtest-monitor-
    if [ -f /jffs/scripts/services-start ]; then
        sed -i '/vpn-speedtest-monitor-/d' /jffs/scripts/services-start
        echo "Removed cron job entries from /jffs/scripts/services-start"
    fi

    # Remove configuration files
    rm -f /jffs/scripts/vpn-monitor-*.conf
    echo "Removed configuration files (/jffs/scripts/vpn-monitor-*.conf)"

    # Remove log files
    rm -f /var/log/vpn-speedtest-monitor-*.log
    echo "Removed log files (/var/log/vpn-speedtest-monitor-*.log)"

    echo "Uninstallation complete."
    exit 0
}

###############################################################################
#                    INSTALLATION LOGIC (--install)
###############################################################################
prompt_for_cron() {
    echo "Choose scheduling frequency:" > /dev/tty
    echo "1) Every X minutes" > /dev/tty
    echo "2) Every X hours" > /dev/tty
    echo "3) Daily" > /dev/tty
    echo "4) Weekly" > /dev/tty
    echo "5) Monthly" > /dev/tty
    echo -n "Enter choice: " > /dev/tty
    read -r choice < /dev/tty
    case "$choice" in
        1)
            echo -n "Enter the number of minutes (e.g., 15): " > /dev/tty
            read -r minutes < /dev/tty
            echo "*/$minutes * * * *" ;;
        2)
            echo -n "Enter the number of hours (e.g., 2): " > /dev/tty
            read -r hours < /dev/tty
            echo "0 */$hours * * *" ;;
        3)
            echo -n "Enter time in 24-hour format (HH:MM): " > /dev/tty
            read -r time_str < /dev/tty
            hour=$(echo "$time_str" | cut -d':' -f1)
            minute=$(echo "$time_str" | cut -d':' -f2)
            echo "$minute $hour * * *" ;;
        4)
            echo -n "Enter day of week (0=Sunday,...,6=Saturday): " > /dev/tty
            read -r dow < /dev/tty
            echo -n "Enter time in 24-hour format (HH:MM): " > /dev/tty
            read -r time_str < /dev/tty
            hour=$(echo "$time_str" | cut -d':' -f1)
            minute=$(echo "$time_str" | cut -d':' -f2)
            echo "$minute $hour * * $dow" ;;
        5)
            echo -n "Enter day of month (1-31): " > /dev/tty
            read -r dom < /dev/tty
            echo -n "Enter time in 24-hour format (HH:MM): " > /dev/tty
            read -r time_str < /dev/tty
            hour=$(echo "$time_str" | cut -d':' -f1)
            minute=$(echo "$time_str" | cut -d':' -f2)
            echo "$minute $hour $dom * *" ;;
        *)
            echo "" ;;
    esac
}

install_script() {
    echo "Starting installation..." > /dev/tty

    # System Checks
    buildno=$(nvram get buildno)
    printf "Asuswrt-Merlin version: "
    if [ "$(echo "$buildno" | cut -f1 -d.)" -lt 388 ]; then
        printf "%b\n" "${RED}${buildno}${NC}"
        printf "%b\n" "Minimum supported version is 388. Please upgrade your firmware."
        exit 1
    else
        printf "%b\n" "${GREEN}${buildno}${NC}"
    fi

    jffs_enabled=$(nvram get jffs2_scripts)
    printf "JFFS partition: "
    if [ "$jffs_enabled" != "1" ]; then
        printf "%b\n" "${RED}disabled${NC}"
        printf "%b\n" "Enable the JFFS partition on your router's Administration -> System."
        exit 1
    else
        printf "%b\n" "${GREEN}enabled${NC}"
    fi

    # Dependency Check: jq
    jq_dir="/tmp/opt/usr/bin"
    jq_file="${jq_dir}/jq"
    arch=$(uname -m)
    printf "Router architecture: "
    case "$arch" in
        "aarch64")
            printf "%b\n" "${GREEN}${arch}${NC}"
            arch="arm64" ;;
        "armv7l")
            printf "%b\n" "${GREEN}${arch}${NC}"
            arch="armel" ;;
        *)
            if ! [ -f "$jq_file" ]; then
                printf "%b\n" "${RED}${arch}${NC}"
                printf "%b\n" "Unsupported architecture or jq not found. Please install jq manually."
                exit 1
            else
                printf "%b\n" "$jq_file: ${YELLOW}installed manually${NC}"
            fi ;;
    esac
    if ! [ -f "$jq_file" ]; then
        jq_remote_file="jq-linux-$arch"
        jq_url="https://github.com/jqlang/jq/releases/download/jq-1.7.1/$jq_remote_file"
        printf "%b\n" "Downloading $jq_remote_file into $jq_dir" > /dev/tty
        mkdir -p -m 755 "$jq_dir"
        wget -qO "$jq_file" "$jq_url" || { echo "Download failed"; exit 1; }
        chmod +x "$jq_file"
    fi

    # Dependency Check: bc
    if [ -x /opt/bin/bc ] || [ -x /usr/bin/bc ] || [ -x /bin/bc ]; then
        printf "%b\n" "${GREEN}bc is installed${NC}"
    else
        printf "%b\n" "${YELLOW}bc not found. Attempting to install bc via Entware...${NC}"
        if command -v opkg >/dev/null 2>&1; then
            opkg update && opkg install bc || { echo "Failed to install bc"; exit 1; }
        else
            printf "%b\n" "${RED}opkg not found. Please install bc manually.${NC}"
            exit 1
        fi
    fi

    # Uninstall any existing configuration, log, and cron entries.
    printf "%b\n" "Removing existing VPN monitor configuration files, log files, and cron entries..." > /dev/tty
    sed -i '/vpn-speedtest-monitor-/d' /jffs/scripts/services-start
    rm -f /jffs/scripts/vpn-monitor-*.conf
    rm -f /var/log/vpn-speedtest-monitor-*.log
    printf "%b\n" "${GREEN}Old files removed.${NC}" > /dev/tty

    # List Enabled WireGuard VPN Clients
    nordvpn_addr_regex="^wgc[[:digit:]]+_ep_addr="
    nordvpn_wgc_addrs=$(nvram show 2>/dev/null | grep -E "$nordvpn_addr_regex")
    printf "%b\n" "Enabled WireGuard VPN clients:" > /dev/tty
    client_count=0
    clients=""
    for addr in $nordvpn_wgc_addrs; do
        client=$(echo "$addr" | cut -f1 -d_)
        is_enabled=$(nvram get "${client}_enable")
        if [ "$is_enabled" != "1" ]; then
            continue
        fi
        client_count=$((client_count+1))
        clients="$clients $client"
        ep_addr=$(nvram get "${client}_ep_addr")
        printf "%b\n" "[$client_count] $client ($ep_addr)" > /dev/tty
    done
    if [ $client_count -lt 1 ]; then
        printf "%b\n" "No enabled WireGuard VPN clients found." > /dev/tty
        exit 1
    fi
    while true; do
        printf "Select the VPN client instance for speed testing [1-%s, e: exit]: " "$client_count" > /dev/tty
        read -r index < /dev/tty
        index=$(echo "$index" | xargs)
        if [ "$index" = "e" ] || [ "$index" = "E" ]; then
            printf "%b\n" "Bye" > /dev/tty
            exit 0
        fi
        if ! echo "$index" | grep -qE '^[0-9]+$' || [ "$index" -lt 1 ] || [ "$index" -gt "$client_count" ]; then
            printf "%b\n" "${RED}Invalid selection${NC}" > /dev/tty
        else
            break
        fi
    done
    client_instance=$(echo "$clients" | awk -v idx="$index" '{print $idx}')
    printf "%b\n" "${GREEN}Selected VPN client instance: ${client_instance}${NC}" > /dev/tty

    # Recommended Servers Selection with Countries/Cities
    printf "%b\n" "Do you want to use the standard recommended servers? [Y/n]" > /dev/tty
    read -r use_standard < /dev/tty
    use_standard=$(echo "$use_standard" | tr '[:upper:]' '[:lower:]')
    if [ "$use_standard" = "n" ]; then
        printf "%b\n" "Fetching list of available countries..." > /dev/tty
        countries_json=$(curl --silent "https://api.nordvpn.com/v1/servers/countries")
        country_list=$(echo "$countries_json" | jq -r '.[]
            | "\(.name) [\(.id)]"')
        printf "%b\n" "Available countries:" > /dev/tty
        echo "$country_list" | awk '{print NR ") " $0}' > /tmp/countries.txt
        cat /tmp/countries.txt > /dev/tty
        printf "Enter the number for your chosen country: " > /dev/tty
        read -r country_choice < /dev/tty
        chosen_country_id=$(sed -n "${country_choice}p" /tmp/countries.txt | sed 's/.*\[\(.*\)\].*/\1/')
        if [ -z "$chosen_country_id" ]; then
            printf "%b\n" "Invalid country selection." > /dev/tty
            rm /tmp/countries.txt
            exit 1
        fi
        rm /tmp/countries.txt
        printf "You selected country id: %s\n" "$chosen_country_id" > /dev/tty

        printf "%b\n" "Fetching list of cities for the chosen country..." > /dev/tty
        city_list=$(echo "$countries_json" | jq -r --arg cid "$chosen_country_id" 'map(select(.id == ($cid|tonumber)))[0] | (.cities // [])[] | "\(.name) [\(.id)]"')
        if [ -z "$city_list" ]; then
            printf "%b\n" "No cities found for the chosen country." > /dev/tty
            exit 1
        fi
        printf "%b\n" "Available cities:" > /dev/tty
        echo "$city_list" | awk '{print NR ") " $0}' > /tmp/cities.txt
        cat /tmp/cities.txt > /dev/tty
        printf "Enter the number for your chosen city: " > /dev/tty
        read -r city_choice < /dev/tty
        chosen_city_id=$(sed -n "${city_choice}p" /tmp/cities.txt | sed 's/.*\[\(.*\)\].*/\1/')
        if [ -z "$chosen_city_id" ]; then
            printf "%b\n" "Invalid city selection." > /dev/tty
            rm /tmp/cities.txt
            exit 1
        fi
        rm /tmp/cities.txt
        printf "You selected city id: %s\n" "$chosen_city_id" > /dev/tty

        RECOMMENDED_API_URL="https://api.nordvpn.com/v1/servers/recommendations?filters%5Bservers_technologies%5D%5Bidentifier%5D=wireguard_udp&filters%5Bcountry_id%5D=${chosen_country_id}&filters%5Bcity_id%5D=${chosen_city_id}&limit=5"
    else
        RECOMMENDED_API_URL="https://api.nordvpn.com/v1/servers/recommendations?filters%5Bservers_technologies%5D%5Bidentifier%5D=wireguard_udp&limit=5"
    fi

    # Threshold Configuration
    printf "%b\n" "Threshold configuration:" > /dev/tty
    printf "%b\n" "1) Manual threshold" > /dev/tty
    printf "%b\n" "2) Auto-threshold calibration (calculate dynamically)" > /dev/tty
    read -r thresh_option < /dev/tty
    case "$thresh_option" in
        1)
            printf "Enter the manual SPEED_THRESHOLD (in Mbps): " > /dev/tty
            read -r manual_thresh < /dev/tty
            SPEED_THRESHOLD="$manual_thresh" ;;
        2)
            SPEED_THRESHOLD="9999" ;;
        *)
            printf "%b\n" "Invalid selection." > /dev/tty
            exit 1 ;;
    esac

    # Build the Configuration File
    LOG_FILE="/var/log/vpn-speedtest-monitor-${client_instance}.log"
    CONFIG_FILE="/jffs/scripts/vpn-monitor-${client_instance}.conf"
    cat > "$CONFIG_FILE" <<EOF
#!/bin/sh
# VPN Monitor Configuration File
# Location: $CONFIG_FILE

CLIENT_INSTANCE="${client_instance}"
SPEED_THRESHOLD="${SPEED_THRESHOLD}"

MAX_ATTEMPTS=3
PING_COUNT=3
PING_TIMEOUT=5

LOG_FILE="${LOG_FILE}"
MAX_LOG_SIZE=10485760
CACHE_FILE="/tmp/vpn-speedtest.cache"
LOCK_FILE="/tmp/vpn-speedtest.lock"

TEST_IP="8.8.8.8"
MAX_SERVERS=5

RECOMMENDED_API_URL="${RECOMMENDED_API_URL}"
EOF
    chmod +x "$CONFIG_FILE"
    printf "%b\n" "${GREEN}Configuration file created at $CONFIG_FILE:${NC}" > /dev/tty
    cat "$CONFIG_FILE" > /dev/tty

    # Scheduling Options
    printf "%b\n" "Do you want to schedule a Speed Test job? [Y/n]" > /dev/tty
    read -r sched_speed_opt < /dev/tty
    if [ -z "$sched_speed_opt" ] || echo "$sched_speed_opt" | grep -qi "^y"; then
        printf "%b\n" "Schedule for Speed Test:" > /dev/tty
        SCHEDULE_SPEED=$(prompt_for_cron)
    else
        SCHEDULE_SPEED=""
    fi

    printf "%b\n" "Do you want to schedule an Update job? [Y/n]" > /dev/tty
    read -r sched_update_opt < /dev/tty
    if [ -z "$sched_update_opt" ] || echo "$sched_update_opt" | grep -qi "^y"; then
        printf "%b\n" "Schedule for Update:" > /dev/tty
        SCHEDULE_UPDATE=$(prompt_for_cron)
    else
        SCHEDULE_UPDATE=""
    fi

    sed -i "/vpn-speedtest-monitor-${client_instance}-/d" /jffs/scripts/services-start

    if [ -n "$SCHEDULE_SPEED" ] && [ "$SCHEDULE_SPEED" != "Invalid" ]; then
        JOB_ID_SPEED="vpn-speedtest-monitor-${client_instance}-speed"
        CRU_CMD_SPEED="cru a $JOB_ID_SPEED \"$SCHEDULE_SPEED /bin/sh \$0 \$CONFIG_FILE --speedtest > /dev/null 2>&1\""
        printf "%b\n" "Adding Speed Test schedule: $CRU_CMD_SPEED" > /dev/tty
        eval "$CRU_CMD_SPEED"
        echo "$CRU_CMD_SPEED" >> /jffs/scripts/services-start
        printf "%b\n" "${GREEN}Speed Test scheduled task set up.${NC}" > /dev/tty
    else
        printf "%b\n" "${YELLOW}No Speed Test scheduled task set up.${NC}" > /dev/tty
    fi

    if [ -n "$SCHEDULE_UPDATE" ] && [ "$SCHEDULE_UPDATE" != "Invalid" ]; then
        JOB_ID_UPDATE="vpn-speedtest-monitor-${client_instance}-update"
        CRU_CMD_UPDATE="cru a $JOB_ID_UPDATE \"$SCHEDULE_UPDATE /bin/sh \$0 \$CONFIG_FILE --update > /dev/null 2>&1\""
        printf "%b\n" "Adding Update schedule: $CRU_CMD_UPDATE" > /dev/tty
        eval "$CRU_CMD_UPDATE"
        echo "$CRU_CMD_UPDATE" >> /jffs/scripts/services-start
        printf "%b\n" "${GREEN}Update scheduled task set up.${NC}" > /dev/tty
    else
        printf "%b\n" "${YELLOW}No Update scheduled task set up.${NC}" > /dev/tty
    fi

    if [ "$thresh_option" = "2" ]; then
        printf "%b\n" "Do you want to run an auto-threshold speed test now? [Y/n]" > /dev/tty
        read -r run_now < /dev/tty
        if [ -z "$run_now" ] || echo "$run_now" | grep -qi "^y"; then
            printf "%b\n" "Running auto-threshold speed test..." > /dev/tty
            sh "$0" "$CONFIG_FILE" --autothreshold --update
        fi
    fi

    printf "%b\n" "${GREEN}Installation completed successfully.${NC}" > /dev/tty
}

###############################################################################
#                CHANGE LOCATION LOGIC (--changelocation)
###############################################################################
change_location() {
    if [ -z "$1" ]; then
        printf "%b\n" "Usage: $0 --changelocation <config_file>" > /dev/tty
        exit 1
    fi
    CONFIG_FILE="$1"
    if [ ! -f "$CONFIG_FILE" ]; then
        printf "%b\n" "Config file not found: $CONFIG_FILE" > /dev/tty
        exit 1
    fi
    printf "%b\n" "Changing location in config file: $CONFIG_FILE" > /dev/tty
    printf "%b\n" "Fetching list of available countries..." > /dev/tty
    countries_json=$(curl --silent "https://api.nordvpn.com/v1/servers/countries")
    country_list=$(echo "$countries_json" | jq -r '.[]
        | "\(.name) [\(.id)]"')
    printf "%b\n" "Available countries:" > /dev/tty
    echo "$country_list" | awk '{print NR ") " $0}' > /tmp/countries.txt
    cat /tmp/countries.txt > /dev/tty
    printf "Enter the number for your chosen country: " > /dev/tty
    read -r country_choice < /dev/tty
    chosen_country_id=$(sed -n "${country_choice}p" /tmp/countries.txt | sed 's/.*\[\(.*\)\].*/\1/')
    if [ -z "$chosen_country_id" ]; then
        printf "%b\n" "Invalid country selection." > /dev/tty
        rm /tmp/countries.txt
        exit 1
    fi
    rm /tmp/countries.txt
    printf "You selected country id: %s\n" "$chosen_country_id" > /dev/tty

    printf "%b\n" "Fetching list of cities for the chosen country..." > /dev/tty
    city_list=$(echo "$countries_json" | jq -r --arg cid "$chosen_country_id" 'map(select(.id == ($cid|tonumber)))[0] | (.cities // [])[] | "\(.name) [\(.id)]"')
    if [ -z "$city_list" ]; then
        printf "%b\n" "No cities found for the chosen country." > /dev/tty
        exit 1
    fi
    printf "%b\n" "Available cities:" > /dev/tty
    echo "$city_list" | awk '{print NR ") " $0}' > /tmp/cities.txt
    cat /tmp/cities.txt > /dev/tty
    printf "Enter the number for your chosen city: " > /dev/tty
    read -r city_choice < /dev/tty
    chosen_city_id=$(sed -n "${city_choice}p" /tmp/cities.txt | sed 's/.*\[\(.*\)\].*/\1/')
    if [ -z "$chosen_city_id" ]; then
        printf "%b\n" "Invalid city selection." > /dev/tty
        rm /tmp/cities.txt
        exit 1
    fi
    rm /tmp/cities.txt
    printf "You selected city id: %s\n" "$chosen_city_id" > /dev/tty

    NEW_API_URL="https://api.nordvpn.com/v1/servers/recommendations?filters%5Bservers_technologies%5D%5Bidentifier%5D=wireguard_udp&filters%5Bcountry_id%5D=${chosen_country_id}&filters%5Bcity_id%5D=${chosen_city_id}&limit=5"
    sed -i '/^RECOMMENDED_API_URL=/d' "$CONFIG_FILE"
    echo "RECOMMENDED_API_URL=\"${NEW_API_URL}\"" >> "$CONFIG_FILE"
    printf "%b\n" "Location updated. New RECOMMENDED_API_URL:" > /dev/tty
    grep '^RECOMMENDED_API_URL=' "$CONFIG_FILE" > /dev/tty

    printf "%b\n" "Forcing VPN configuration update with new location..." > /dev/tty
    sh "$0" "$CONFIG_FILE" --update
}

###############################################################################
#             UPDATE VPN CONFIGURATION FUNCTION
###############################################################################
update_vpn_config() {
    log "Fetching new recommended servers"
    WAN_IF=$(nvram get wan0_ifname)
    curl -s --interface "$WAN_IF" "$RECOMMENDED_API_URL" | /opt/usr/bin/jq -r \
        '.[] | .hostname, .load, .station, ((.technologies[] | select(.identifier=="wireguard_udp") | (.metadata[]? | select(.name=="public_key") | .value)) // "")' > /tmp/Peers.txt

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

    echo -e "\n${CYAN}============ Fetched VPN Servers and Load Percentages ============${NC}\n"
    log ""

    servers_candidates=""
    i=1
    for server in $servers; do
        load=$(echo "$loads" | awk -v n="$i" '{print int($n)}')
        ip=$(echo "$ips" | awk -v n="$i" '{print $n}')
        pubkey=$(echo "$pubkeys" | awk -v n="$i" '{print $n}')
        ping_result=$(ping_latency "$server")
        rawTimes=$(echo "$ping_result" | cut -d';' -f1)
        avgLatency=$(echo "$ping_result" | cut -d';' -f2)
        cLoad=$(colorize_load "$load")
        colored_raw=""
        for t in $rawTimes; do
            cLat=$(colorize_latency "$t")
            colored_raw="$colored_raw ${cLat}ms,"
        done
        colored_raw=$(echo "$colored_raw" | sed 's/,$//; s/^ *//')
        cAvg=$(colorize_latency "$avgLatency")
        log "  - Server: $server ($ip), Load: $cLoad%, Latency: $colored_raw Average: $cAvg ms, Public Key: $pubkey"
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
        if [ $attempt -gt "$MAX_ATTEMPTS" ]; then
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
#                 MAIN MONITOR MODE (SPEEDTEST / UPDATE)
###############################################################################
main_monitor() {
    if [ -z "$1" ]; then
        echo "Usage: $0 <config_file> [--speedtest] [--update] [--autothreshold] [--debug]"
        exit 1
    fi
    CONFIG_FILE="$1"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Config file not found: $CONFIG_FILE"
        exit 1
    fi
    . "$CONFIG_FILE"
    [ -z "$LOG_FILE" ] && LOG_FILE="/var/log/vpn-speedtest-monitor-${CLIENT_INSTANCE}.log"

    speedtest_mode=false
    update_mode=false
    autothreshold_mode=false
    debug_mode=false

    shift
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --debug)
                debug_mode=true ;;
            --speedtest)
                speedtest_mode=true ;;
            --update)
                update_mode=true ;;
            --autothreshold)
                autothreshold_mode=true ;;
            -h|--help)
                echo "Usage: $0 <config_file> [--speedtest] [--update] [--autothreshold] [--debug]"
                exit 0 ;;
            *)
                echo "Unknown argument: $1"
                exit 1 ;;
        esac
        shift
    done

    log "****************************  Starting VPN speed test/update  ****************************"
    log ""

    update_triggered=false

    if [ "$autothreshold_mode" = true ]; then
        log "Running auto-threshold calibration..."

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

        orig_ep=$(nvram get "${CLIENT_INSTANCE}_ep_addr")
        orig_desc=$(nvram get "${CLIENT_INSTANCE}_desc")
        orig_ppub=$(nvram get "${CLIENT_INSTANCE}_ppub")
        curl -s --interface "$WAN_IF" "$RECOMMENDED_API_URL" | /opt/usr/bin/jq -r \
            '.[] | .hostname, .station, ((.technologies[] | select(.identifier=="wireguard_udp") | (.metadata[]? | select(.name=="public_key") | .value)) // "")' > /tmp/Peers.txt
        rec_servers=""
        rec_ips=""
        rec_pubkeys=""
        index=0
        while IFS= read -r line; do
            case $(( index % 3 )) in
                0) rec_servers="$rec_servers $line" ;;
                1) rec_ips="$rec_ips $line" ;;
                2) rec_pubkeys="$rec_pubkeys $line" ;;
            esac
            index=$(( index + 1 ))
        done < /tmp/Peers.txt
        rm /tmp/Peers.txt
        total_tunnel_speed=0
        tunnel_count=0
        j=1
        for server in $rec_servers; do
            ip=$(echo "$rec_ips" | awk -v idx="$j" '{print $idx}')
            pubkey=$(echo "$rec_pubkeys" | awk -v idx="$j" '{print $idx}')
            log "Testing tunnel speed for server: $server ($ip) with Public Key: $pubkey"
            nvram set "${CLIENT_INSTANCE}_ep_addr"="$server"
            nvram set "${CLIENT_INSTANCE}_desc"="$server ($ip)"
            nvram set "${CLIENT_INSTANCE}_ppub"="$pubkey"
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

        overhead=$(echo "$WAN_avg - $Tunnel_avg" | bc)
        dynamic_threshold=$(echo "scale=2; $Tunnel_avg - ($overhead * 0.5)" | bc)
        log "Calculated dynamic threshold: $dynamic_threshold Mbps"

        nvram set "${CLIENT_INSTANCE}_ep_addr"="$orig_ep"
        nvram set "${CLIENT_INSTANCE}_desc"="$orig_desc"
        nvram set "${CLIENT_INSTANCE}_ppub"="$orig_ppub"
        nvram commit

        SPEED_THRESHOLD="$dynamic_threshold"
        sed -i "s/^SPEED_THRESHOLD=.*/SPEED_THRESHOLD=\"$dynamic_threshold\"/" "$CONFIG_FILE"
        log "Config file updated with new SPEED_THRESHOLD."

        speedtest_mode=true
    fi

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
    printf "%b\n" "${GREEN}==== Script Finished ====${NC}"
    log ""
    exit 0
}

###############################################################################
#                           MAIN ENTRY POINT
###############################################################################
# Check for uninstall flag.
if [ "$1" = "--uninstall" ]; then
    uninstall_script
fi

# If first argument is --install, run install mode.
if [ "$1" = "--install" ]; then
    install_script
    exit 0
fi

# If second argument is --changelocation, use the first argument (interface)
# to derive the config file.
if [ "$2" = "--changelocation" ]; then
    interface="$1"
    CONFIG_FILE="/jffs/scripts/vpn-monitor-${interface}.conf"
    change_location "$CONFIG_FILE"
    exit 0
fi

# Otherwise, the first argument is the interface name.
if [ -z "$1" ]; then
    echo "Usage: $0 --install | --uninstall | <interface> [--changelocation] | <interface> [--speedtest --update --autothreshold --debug]"
    exit 1
fi
interface="$1"
CONFIG_FILE="/jffs/scripts/vpn-monitor-${interface}.conf"
shift
main_monitor "$CONFIG_FILE" "$@"
