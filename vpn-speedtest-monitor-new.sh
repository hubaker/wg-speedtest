#!/bin/sh
# vpn-speedtest.sh
#
# Combined VPN Speed Test/Update Script with Installation, Location Change, and Monitoring Modes.
#
# Usage:
#   --install
#       Run interactive installation.
#
#   --changelocation <config_file>
#       Change the country/city (location) in the configuration file and force an update.
#
#   Otherwise, the first parameter must be a configuration file and additional flags
#   (e.g., --speedtest, --update, --autothreshold, --debug) are used to run monitoring mode.
#
# This script uses a unified log file per VPN client instance.
#
# ANSI color variables:
YELLOW='\033[0;33m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

##################################
#          log() Function        #
##################################
log() {
    message="$1"
    # Use hardcoded ANSI sequences for color.
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

    # Print colored message to console (without timestamp)
    echo -e "$colored_message"

    # Strip ANSI escape sequences using sed.
    plain_message=$(echo -e "$colored_message" | sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g')
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $plain_message" >> "$LOG_FILE"
}

##################################
#   prompt_for_cron() Function   #
##################################
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
            echo -n "Enter number of minutes: " > /dev/tty
            read -r minutes < /dev/tty
            echo "*/$minutes * * * *" ;;
        2)
            echo -n "Enter number of hours: " > /dev/tty
            read -r hours < /dev/tty
            echo "0 */$hours * * *" ;;
        3)
            echo -n "Enter time in HH:MM (24h): " > /dev/tty
            read -r time_str < /dev/tty
            hour=$(echo "$time_str" | cut -d':' -f1)
            minute=$(echo "$time_str" | cut -d':' -f2)
            echo "$minute $hour * * *" ;;
        4)
            echo -n "Enter day of week (0=Sunday,...,6=Saturday): " > /dev/tty
            read -r dow < /dev/tty
            echo -n "Enter time in HH:MM (24h): " > /dev/tty
            read -r time_str < /dev/tty
            hour=$(echo "$time_str" | cut -d':' -f1)
            minute=$(echo "$time_str" | cut -d':' -f2)
            echo "$minute $hour * * $dow" ;;
        5)
            echo -n "Enter day of month (1-31): " > /dev/tty
            read -r dom < /dev/tty
            echo -n "Enter time in HH:MM (24h): " > /dev/tty
            read -r time_str < /dev/tty
            hour=$(echo "$time_str" | cut -d':' -f1)
            minute=$(echo "$time_str" | cut -d':' -f2)
            echo "$minute $hour $dom * *" ;;
        *)
            echo "" ;;
    esac
}

##################################
#    install_script() Function   #
##################################
install_script() {
    echo "Starting installation..." > /dev/tty

    # --- List Enabled VPN Clients ---
    echo "Enabled VPN clients:" > /dev/tty
    clients=""
    client_count=0
    for client in $(nvram show | grep -E '^wgc[0-9]+_ep_addr=' | cut -d'=' -f1 | cut -d'_' -f1); do
        enabled=$(nvram get "${client}_enable")
        if [ "$enabled" = "1" ]; then
            client_count=$((client_count+1))
            clients="$clients $client"
            ep=$(nvram get "${client}_ep_addr")
            echo "[$client_count] $client ($ep)" > /dev/tty
        fi
    done
    if [ $client_count -eq 0 ]; then
        echo "No enabled VPN clients found. Exiting." > /dev/tty
        exit 1
    fi

    echo -n "Enter the number of the VPN client instance to configure: " > /dev/tty
    read -r choice < /dev/tty
    client_instance=$(echo "$clients" | awk -v idx="$choice" '{print $idx}')
    echo "Selected VPN client: $client_instance" > /dev/tty

    # --- Recommended Servers Selection ---
    echo -n "Use standard recommended servers? [Y/n]: " > /dev/tty
    read -r use_std < /dev/tty
    use_std=$(echo "$use_std" | tr '[:upper:]' '[:lower:]')
    if [ "$use_std" = "n" ]; then
        echo "Fetching list of available countries..." > /dev/tty
        countries_json=$(curl --silent "https://api.nordvpn.com/v1/servers/countries")
        country_list=$(echo "$countries_json" | jq -r '.[]
            | "\(.name) [\(.id)]"')
        echo "Available countries:" > /dev/tty
        echo "$country_list" | awk '{print NR ") " $0}' > /tmp/countries.txt
        cat /tmp/countries.txt > /dev/tty
        echo -n "Enter the number for your chosen country: " > /dev/tty
        read -r country_choice < /dev/tty
        chosen_country_id=$(sed -n "${country_choice}p" /tmp/countries.txt | sed 's/.*\[\(.*\)\].*/\1/')
        if [ -z "$chosen_country_id" ]; then
            echo "Invalid country selection." > /dev/tty
            rm /tmp/countries.txt
            exit 1
        fi
        rm /tmp/countries.txt
        echo "You selected country id: $chosen_country_id" > /dev/tty

        echo "Fetching list of cities for the chosen country..." > /dev/tty
        city_list=$(echo "$countries_json" | jq -r --arg cid "$chosen_country_id" 'map(select(.id==$cid|tonumber))[0].cities[]? | "\(.name) [\(.id)]"')
        if [ -z "$city_list" ]; then
            echo "No cities found for the chosen country." > /dev/tty
            exit 1
        fi
        echo "Available cities:" > /dev/tty
        echo "$city_list" | awk '{print NR ") " $0}' > /tmp/cities.txt
        cat /tmp/cities.txt > /dev/tty
        echo -n "Enter the number for your chosen city: " > /dev/tty
        read -r city_choice < /dev/tty
        chosen_city_id=$(sed -n "${city_choice}p" /tmp/cities.txt | sed 's/.*\[\(.*\)\].*/\1/')
        if [ -z "$chosen_city_id" ]; then
            echo "Invalid city selection." > /dev/tty
            rm /tmp/cities.txt
            exit 1
        fi
        rm /tmp/cities.txt
        echo "You selected city id: $chosen_city_id" > /dev/tty

        RECOMMENDED_API_URL="https://api.nordvpn.com/v1/servers/recommendations?filters%5Bservers_technologies%5D%5Bidentifier%5D=wireguard_udp&filters%5Bcountry_id%5D=${chosen_country_id}&filters%5Bcity_id%5D=${chosen_city_id}&limit=5"
    else
        RECOMMENDED_API_URL="https://api.nordvpn.com/v1/servers/recommendations?filters%5Bservers_technologies%5D%5Bidentifier%5D=wireguard_udp&limit=5"
    fi

    # --- Threshold Configuration ---
    echo "Threshold configuration:" > /dev/tty
    echo "1) Manual threshold" > /dev/tty
    echo "2) Auto-threshold calibration (calculate dynamically)" > /dev/tty
    read -r thresh_option < /dev/tty
    if [ "$thresh_option" = "1" ]; then
        echo -n "Enter manual SPEED_THRESHOLD (in Mbps): " > /dev/tty
        read -r manual_thresh < /dev/tty
        SPEED_THRESHOLD="$manual_thresh"
    else
        SPEED_THRESHOLD="9999"
    fi

    # --- Unified Log File and Config File ---
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
    echo "Configuration file created at $CONFIG_FILE:" > /dev/tty
    cat "$CONFIG_FILE" > /dev/tty

    # --- Scheduling ---
    echo "Scheduling options for Speed Test job:" > /dev/tty
    SCHEDULE_SPEED=$(prompt_for_cron)
    echo "Scheduling options for Update job:" > /dev/tty
    SCHEDULE_UPDATE=$(prompt_for_cron)

    # Remove any existing cron jobs for this client instance.
    sed -i "/vpn-speedtest-monitor-${client_instance}-/d" /jffs/scripts/services-start

    if [ -n "$SCHEDULE_SPEED" ]; then
        JOB_ID_SPEED="vpn-speedtest-monitor-${client_instance}-speed"
        CRU_CMD_SPEED="cru a $JOB_ID_SPEED \"$SCHEDULE_SPEED /bin/sh \$0 \$CONFIG_FILE --speedtest > /dev/null 2>&1\""
        echo "Adding Speed Test schedule: $CRU_CMD_SPEED" > /dev/tty
        eval "$CRU_CMD_SPEED"
        echo "$CRU_CMD_SPEED" >> /jffs/scripts/services-start
    fi

    if [ -n "$SCHEDULE_UPDATE" ]; then
        JOB_ID_UPDATE="vpn-speedtest-monitor-${client_instance}-update"
        CRU_CMD_UPDATE="cru a $JOB_ID_UPDATE \"$SCHEDULE_UPDATE /bin/sh \$0 \$CONFIG_FILE --update > /dev/null 2>&1\""
        echo "Adding Update schedule: $CRU_CMD_UPDATE" > /dev/tty
        eval "$CRU_CMD_UPDATE"
        echo "$CRU_CMD_UPDATE" >> /jffs/scripts/services-start
    fi

    if [ "$thresh_option" = "2" ]; then
        echo "Running auto-threshold speed test now..." > /dev/tty
        sh "$0" "$CONFIG_FILE" --autothreshold --update
    fi

    echo "Installation completed successfully." > /dev/tty
}

##################################
#  change_location() Function    #
##################################
change_location() {
    if [ -z "$2" ]; then
        echo "Usage: $0 --changelocation <config_file>" > /dev/tty
        exit 1
    fi
    CONFIG_FILE="$2"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Config file not found: $CONFIG_FILE" > /dev/tty
        exit 1
    fi
    echo "Changing location in config file: $CONFIG_FILE" > /dev/tty

    echo "Fetching list of available countries..." > /dev/tty
    countries_json=$(curl --silent "https://api.nordvpn.com/v1/servers/countries")
    country_list=$(echo "$countries_json" | jq -r '.[]
        | "\(.name) [\(.id)]"')
    echo "Available countries:" > /dev/tty
    echo "$country_list" | awk '{print NR ") " $0}' > /tmp/countries.txt
    cat /tmp/countries.txt > /dev/tty
    echo -n "Enter the number for your chosen country: " > /dev/tty
    read -r country_choice < /dev/tty
    chosen_country_id=$(sed -n "${country_choice}p" /tmp/countries.txt | sed 's/.*\[\(.*\)\].*/\1/')
    if [ -z "$chosen_country_id" ]; then
        echo "Invalid country selection." > /dev/tty
        rm /tmp/countries.txt
        exit 1
    fi
    rm /tmp/countries.txt
    echo "You selected country id: $chosen_country_id" > /dev/tty

    echo "Fetching list of cities for the chosen country..." > /dev/tty
    city_list=$(echo "$countries_json" | jq -r --arg cid "$chosen_country_id" 'map(select(.id==$cid|tonumber))[0].cities[]? | "\(.name) [\(.id)]"')
    if [ -z "$city_list" ]; then
        echo "No cities found for the chosen country." > /dev/tty
        exit 1
    fi
    echo "Available cities:" > /dev/tty
    echo "$city_list" | awk '{print NR ") " $0}' > /tmp/cities.txt
    cat /tmp/cities.txt > /dev/tty
    echo -n "Enter the number for your chosen city: " > /dev/tty
    read -r city_choice < /dev/tty
    chosen_city_id=$(sed -n "${city_choice}p" /tmp/cities.txt | sed 's/.*\[\(.*\)\].*/\1/')
    if [ -z "$chosen_city_id" ]; then
        echo "Invalid city selection." > /dev/tty
        rm /tmp/cities.txt
        exit 1
    fi
    rm /tmp/cities.txt
    echo "You selected city id: $chosen_city_id" > /dev/tty

    NEW_API_URL="https://api.nordvpn.com/v1/servers/recommendations?filters%5Bservers_technologies%5D%5Bidentifier%5D=wireguard_udp&filters%5Bcountry_id%5D=${chosen_country_id}&filters%5Bcity_id%5D=${chosen_city_id}&limit=5"
    sed -i "s#^RECOMMENDED_API_URL=.*#RECOMMENDED_API_URL=\"${NEW_API_URL}\"#g" "$CONFIG_FILE"
    echo "Location updated. New RECOMMENDED_API_URL:" > /dev/tty
    grep '^RECOMMENDED_API_URL=' "$CONFIG_FILE" > /dev/tty

    echo "Forcing VPN configuration update with new location..." > /dev/tty
    sh "$0" "$CONFIG_FILE" --update
}

##################################
#  update_vpn_config() Function  #
##################################
update_vpn_config() {
    log "Fetching new recommended servers"
    # (Insert your actual server fetching and applying logic here.)
    # For simulation:
    log "   - Server: us1234.nordvpn.com (1.2.3.4), Load: 20%, Latency: 5ms, Public Key: <key>"
    log "   - Assigned Weight: 7500 (Server: us1234.nordvpn.com, Latency: 5 ms)"
    log "Attempt 1: Applying server us1234.nordvpn.com (1.2.3.4) (Load: 20%, Latency: 5ms, Public Key: <key>)"
    log "Restarting VPN tunnel to apply new settings..."
    log "Checking VPN connectivity (attempt 1 of 3)..."
    log "VPN connectivity check succeeded with server us1234.nordvpn.com (1.2.3.4)."
}

##################################
#    main_monitor() Function     #
##################################
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
            --speedtest)
                speedtest_mode=true ;;
            --update)
                update_mode=true ;;
            --autothreshold)
                autothreshold_mode=true ;;
            --debug)
                debug_mode=true ;;
            *)
                echo "Unknown flag: $1"
                exit 1 ;;
        esac
        shift
    done

    log "****************************  Starting VPN speed test/update  ****************************"
    log ""

    if [ "$autothreshold_mode" = true ]; then
        log "Running auto-threshold calibration..."
        # (Insert auto-threshold logic here.)
        # For simulation, we set a new threshold.
        SPEED_THRESHOLD="280.00"
        log "Auto-threshold calibration complete. New SPEED_THRESHOLD: $SPEED_THRESHOLD"
    fi

    if [ "$speedtest_mode" = true ]; then
        log "Starting VPN speed test"
        # (Insert actual speed test logic.)
        SPEED_Mbps="300.00"
        log "Current VPN Download Speed: ${GREEN}${SPEED_Mbps}${NC} Mbps"
        comp=$(echo "$SPEED_Mbps < $SPEED_THRESHOLD" | bc -l)
        if [ "$comp" -eq 1 ]; then
            log "Speed is below threshold ($SPEED_THRESHOLD Mbps). Updating VPN configuration..."
            update_vpn_config
        else
            log "Speed is acceptable. No VPN update triggered by speed test."
        fi
    fi

    if [ "$update_mode" = true ]; then
        log "Forcing VPN configuration update..."
        update_vpn_config
    fi

    log "==== Script Finished ===="
}

##################################
#        Main Entry Point        #
##################################
if [ "$1" = "--install" ]; then
    install_script
    exit 0
fi

if [ "$1" = "--changelocation" ]; then
    shift
    change_location "$@"
    exit 0
fi

# Otherwise, assume monitoring mode; first parameter is config file.
main_monitor "$@"
