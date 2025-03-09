#!/bin/sh
# install.sh for vpn-speedtest-monitor.sh
#
# This installation script sets up vpn-speedtest-monitor.sh.
# It will:
#   - Check firmware version, JFFS partition, and router architecture.
#   - Ensure required tools (jq and bc) are installed (bc via Entware if needed).
#   - List enabled WireGuard VPN (wgc) clients and let you choose one.
#   - Ask if you want a manual threshold or auto threshold calibration.
#   - Create a unique configuration file (e.g., /jffs/scripts/vpn-monitor-wgc5.conf) that stores your settings.
#   - Download vpn-speedtest-monitor.sh to /jffs/scripts and make it executable.
#   - Optionally schedule the script via cru.
#
# Requirements: Asuswrt-Merlin router with JFFS enabled.

# Bail out on error
set -e

# Colors
col_n="\033[0m"
col_r="\033[0;31m"
col_g="\033[0;32m"
col_y="\033[0;33m"

fail() {
    echo
    echo -e "${col_r}Installation failed${col_n}"
    exit 1
}

# --- System Checks ---
# Check Asuswrt-Merlin version
buildno=$(nvram get buildno)
printf "Asuswrt-Merlin version: "
if [ "$(echo "$buildno" | cut -f1 -d.)" -lt 388 ]; then
    echo -e "${col_r}${buildno}${col_n}"
    echo "Minimum supported version is 388. Please upgrade your firmware."
    fail
else
    echo -e "${col_g}${buildno}${col_n}"
fi

# Check if JFFS partition is enabled
jffs_enabled=$(nvram get jffs2_scripts)
printf "JFFS partition: "
if [ "$jffs_enabled" != "1" ]; then
    echo -e "${col_r}disabled${col_n}"
    echo "Enable the JFFS partition on your router's Administration -> System page."
    fail
else
    echo -e "${col_g}enabled${col_n}"
fi

# --- Dependency Check: jq ---
jq_dir="/tmp/opt/usr/bin"
jq_file="${jq_dir}/jq"
arch=$(uname -m)
printf "Router architecture: "
case "$arch" in
    "aarch64")
        echo -e "${col_g}${arch}${col_n}"
        arch="arm64"
        ;;
    "armv7l")
        echo -e "${col_g}${arch}${col_n}"
        arch="armel"
        ;;
    *)
        if ! [ -f "$jq_file" ]; then
            echo -e "${col_r}${arch}${col_n}"
            echo "Unsupported architecture or jq not found. Please install jq manually."
            fail
        else
            echo -e "$jq_file: ${col_y}installed manually${col_n}"
        fi
        ;;
esac

if ! [ -f "$jq_file" ]; then
    jq_remote_file="jq-linux-$arch"
    jq_url="https://github.com/jqlang/jq/releases/download/jq-1.7.1/$jq_remote_file"
    echo "Downloading $jq_remote_file into $jq_dir"
    mkdir -p -m 755 "$jq_dir"
    wget -qO "$jq_file" "$jq_url" || { echo "Download failed"; fail; }
    chmod +x "$jq_file"
fi

# --- Dependency Check: bc ---
if ! command -v bc >/dev/null 2>&1; then
    echo -e "${col_y}bc not found. Attempting to install bc via Entware...${col_n}"
    if command -v opkg >/dev/null 2>&1; then
        opkg update && opkg install bc || { echo "Failed to install bc with opkg"; fail; }
    else
        echo -e "${col_r}opkg not found. Please install bc manually.${col_n}"
        fail
    fi
else
    echo -e "${col_g}bc is installed${col_n}"
fi

# --- List Enabled WireGuard VPN Clients ---
nordvpn_addr_regex="^wgc[[:digit:]]+_ep_addr="
nordvpn_wgc_addrs=$(nvram show 2>/dev/null | grep -E "$nordvpn_addr_regex")

echo "Enabled WireGuard VPN clients:"
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
    echo "[$client_count] $client ($ep_addr)"
done

if [ $client_count -lt 1 ]; then
    echo "No enabled WireGuard VPN clients found."
    fail
fi

# Let the user select a VPN client instance
while true; do
    printf "Select the VPN client instance for speed testing [1-%s, e: exit]: " "$client_count"
    read -r index
    index=$(echo "$index" | xargs)
    if [ "$index" = "e" ] || [ "$index" = "E" ]; then
        echo "Bye"
        exit 0
    fi
    if ! echo "$index" | grep -qE '^[0-9]+$' || [ "$index" -lt 1 ] || [ "$index" -gt "$client_count" ]; then
        echo -e "${col_r}Invalid selection${col_n}"
    else
        break
    fi
done
client_instance=$(echo "$clients" | awk -v idx="$index" '{print $idx}')

# --- Threshold Configuration ---
echo "Threshold Configuration Options:"
echo "[1] Set a manual threshold"
echo "[2] Use auto threshold calibration (calculate dynamic threshold)"
while true; do
    printf "Select an option [1/2]: "
    read -r option
    option=$(echo "$option" | xargs)
    if [ "$option" = "1" ]; then
        # Manual threshold option
        while true; do
            printf "Enter the manual threshold value (in Mbps): "
            read -r manual_threshold
            manual_threshold=$(echo "$manual_threshold" | xargs)
            if echo "$manual_threshold" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
                THRESHOLD_VALUE="$manual_threshold"
                AUTO_THRESHOLD="false"
                break
            else
                echo -e "${col_r}Invalid value${col_n}"
            fi
        done
        break
    elif [ "$option" = "2" ]; then
        AUTO_THRESHOLD="true"
        THRESHOLD_VALUE=0
        break
    else
        echo -e "${col_r}Invalid option${col_n}"
    fi
done

# --- Configuration File Creation ---
# Create a unique config file for this VPN client instance.
CONFIG_FILE="/jffs/scripts/vpn-monitor-${client_instance}.conf"
echo "Creating configuration file at $CONFIG_FILE..."
cat > "$CONFIG_FILE" <<EOF
#!/bin/sh
# VPN Monitor Configuration File
# Location: $CONFIG_FILE

###############################################################################
#                         CLIENT SETTINGS                                     #
###############################################################################
# VPN client instance to use (e.g., ${client_instance})
CLIENT_INSTANCE="${client_instance}"

# Use auto threshold calibration? (true/false)
AUTO_THRESHOLD="${AUTO_THRESHOLD}"
# Manual threshold value (in Mbps) to use if AUTO_THRESHOLD is false
SPEED_THRESHOLD="${THRESHOLD_VALUE}"

###############################################################################
#                         PERFORMANCE SETTINGS                                #
###############################################################################
# Number of attempts to try new servers before giving up
MAX_ATTEMPTS=3

# Number of pings to test server latency
PING_COUNT=3

# Timeout for ping tests in seconds
PING_TIMEOUT=5

###############################################################################
#                           FILE LOCATIONS                                    #
###############################################################################
# Log file location
LOG_FILE="/var/log/vpn-speedtest.log"

# Maximum log file size in bytes (10MB = 10485760)
MAX_LOG_SIZE=10485760

# Temporary files location
CACHE_FILE="/tmp/vpn-speedtest.cache"
LOCK_FILE="/tmp/vpn-speedtest.lock"

###############################################################################
#                         NETWORK SETTINGS                                    #
###############################################################################
# IP address used for connectivity tests
TEST_IP="8.8.8.8"

# Maximum number of servers to check from NordVPN recommendations
MAX_SERVERS=5

###############################################################################
#                         NOTIFICATION SETTINGS                               #
###############################################################################
# Enable or disable notifications (0=disabled, 1=enabled)
NOTIFICATIONS_ENABLED=1

# Notification method (options: none, pushover, telegram, email)
NOTIFICATION_METHOD="none"

# Notification credentials (if enabled)
#PUSHOVER_TOKEN=""
#PUSHOVER_USER=""
#TELEGRAM_BOT_TOKEN=""
#TELEGRAM_CHAT_ID=""

###############################################################################
#                         ADVANCED SETTINGS                                   #
###############################################################################
# Debug mode (0=disabled, 1=enabled)
DEBUG_MODE=0

# Minimum time (in seconds) between server switches
MIN_SWITCH_INTERVAL=3600

# Weight Calculation:
# The selection weight for a VPN server is calculated as:
#     weight = (100 - load - average_latency) * 100
#
# A higher weight indicates a more desirable server.
#
# Retry delay in seconds
RETRY_DELAY=5

# Server blacklist (comma-separated list of hostnames)
#BLACKLISTED_SERVERS=""
 
###############################################################################
#                         CUSTOM COMMANDS                                     #
###############################################################################
# Commands to run before VPN switch (separate multiple commands with semicolon)
#PRE_SWITCH_COMMANDS=""

# Commands to run after VPN switch (separate multiple commands with semicolon)
#POST_SWITCH_COMMANDS=""
EOF

chmod +x "$CONFIG_FILE"
echo "Configuration file created:"
cat "$CONFIG_FILE"

# --- Download Main Script ---
SCRIPT_PATH="/jffs/scripts/vpn-speedtest-monitor.sh"
echo "Downloading vpn-speedtest-monitor.sh to $SCRIPT_PATH"
wget -qO "$SCRIPT_PATH" "https://raw.githubusercontent.com/your_repo/vpn-speedtest-monitor.sh" || { echo "Download failed"; fail; }
chmod +x "$SCRIPT_PATH"
echo -e "${col_g}vpn-speedtest-monitor.sh installed successfully${col_n}"

# --- Schedule Execution Using cru ---
echo "Do you want to schedule the VPN speed test script?"
printf "[Y/n, c: custom schedule]: "
read -r schedule_option
schedule=""
if [ -z "$schedule_option" ] || echo "$schedule_option" | grep -iqE "^(y)$"; then
    # Default: run every 15 minutes
    schedule="*/15 * * * *"
elif echo "$schedule_option" | grep -iqE "^(c)$"; then
    printf "Enter custom cron schedule (e.g., '*/15 * * * *'): "
    read -r custom_schedule
    schedule=$(echo "$custom_schedule" | xargs)
fi

if [ -n "$schedule" ]; then
    job_id="vpn-speedtest-monitor-${client_instance}"
    log_file="/var/log/vpn-speedtest-monitor-${client_instance}.log"
    cru_cmd="cru a $job_id \"$schedule /bin/sh $SCRIPT_PATH $client_instance > $log_file 2>&1\""
    echo "Adding schedule: $cru_cmd"
    eval "$cru_cmd"
    echo "Saving schedule in /jffs/scripts/services-start"
    sed -i "/$job_id/d" /jffs/scripts/services-start
    echo "$cru_cmd" >> /jffs/scripts/services-start
    echo "Scheduled task set up."
else
    echo -e "${col_y}No scheduled task will be set up.${col_n}"
fi

# --- Initial Run ---
printf "Do you wish to run vpn-speedtest-monitor.sh now? [Y/n]: "
read -r run_now
case $(echo "$run_now" | xargs) in
    "" | "y" | "Y")
        sh "$SCRIPT_PATH" "$client_instance"
        ;;
    *)
        ;;
esac

echo
echo -e "${col_g}Installation completed successfully${col_n}"
