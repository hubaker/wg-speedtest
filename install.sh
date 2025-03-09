#!/bin/sh
# install.sh for vpn-speedtest-monitor.sh
#
# This installation script sets up vpn-speedtest-monitor.sh.
# It will:
#   - Check firmware version, JFFS partition, and router architecture.
#   - Ensure required tools (jq and bc) are installed (bc via Entware if needed).
#   - List enabled WireGuard VPN (wgc) clients and let you choose one.
#   - Ask if you want to use standard recommended servers or specify country/city.
#   - Ask if you want to manually specify a threshold speed or use auto‑threshold calibration.
#   - Ask separately if you want to create a scheduled job for Speed Test mode and for Update mode.
#   - Create a unique configuration file (e.g., /jffs/scripts/vpn-monitor-wgc5.conf) with your settings.
#   - Download vpn-speedtest-monitor.sh to /jffs/scripts and make it executable.
#   - If auto‑threshold was chosen, prompt to run the main script immediately with --autothreshold.
#
# Requirements: Asuswrt-Merlin router with JFFS enabled.

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
buildno=$(nvram get buildno)
printf "Asuswrt-Merlin version: "
if [ "$(echo "$buildno" | cut -f1 -d.)" -lt 388 ]; then
    echo -e "${col_r}${buildno}${col_n}"
    echo "Minimum supported version is 388. Please upgrade your firmware."
    fail
else
    echo -e "${col_g}${buildno}${col_n}"
fi

jffs_enabled=$(nvram get jffs2_scripts)
printf "JFFS partition: "
if [ "$jffs_enabled" != "1" ]; then
    echo -e "${col_r}disabled${col_n}"
    echo "Enable JFFS in Administration -> System."
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
            echo "Unsupported architecture or jq not found."
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
if [ -x /opt/bin/bc ] || [ -x /usr/bin/bc ] || [ -x /bin/bc ]; then
    echo -e "${col_g}bc is installed${col_n}"
else
    echo -e "${col_y}bc not found. Attempting to install bc via Entware...${col_n}"
    if command -v opkg >/dev/null 2>&1; then
        opkg update && opkg install bc || { echo "Failed to install bc"; fail; }
    else
        echo -e "${col_r}opkg not found. Please install bc manually.${col_n}"
        fail
    fi
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
echo -e "${col_g}Selected VPN client instance: ${client_instance}${col_n}"

# --- Recommended Servers Selection ---
echo "Do you want to use the standard recommended servers? [Y/n]"
read -r use_standard
use_standard=$(echo "$use_standard" | tr '[:upper:]' '[:lower:]')
if [ "$use_standard" = "n" ]; then
    echo "Enter the Country ID (from NordVPN list):"
    read -r country_id
    echo "Enter the City ID (from NordVPN list):"
    read -r city_id
    RECOMMENDED_API_URL="https://api.nordvpn.com/v1/servers/recommendations?filters%5Bservers_technologies%5D%5Bidentifier%5D=wireguard_udp&filters%5Bcountry_id%5D=${country_id}&filters%5Bcity_id%5D=${city_id}&limit=5"
else
    RECOMMENDED_API_URL="https://api.nordvpn.com/v1/servers/recommendations?filters%5Bservers_technologies%5D%5Bidentifier%5D=wireguard_udp&limit=5"
fi

# --- Threshold Configuration ---
echo "Threshold configuration:"
echo "[1] Manual threshold"
echo "[2] Auto-threshold calibration (calculate dynamically)"
read -r thresh_option
case "$thresh_option" in
    1)
        echo "Enter the manual SPEED_THRESHOLD (in Mbps):"
        read -r manual_thresh
        SPEED_THRESHOLD="$manual_thresh"
        ;;
    2)
        SPEED_THRESHOLD="370"  # Dummy initial value; auto-threshold will update this.
        ;;
    *)
        echo -e "${col_r}Invalid selection.${col_n}"
        fail
        ;;
esac

# --- Scheduling Options ---
# Ask separately for Speed Test schedule and Update schedule.
echo "Do you want to schedule a Speed Test job? [Y/n]"
read -r sched_speed_opt
if [ -z "$sched_speed_opt" ] || echo "$sched_speed_opt" | grep -qi "^y"; then
    echo "Enter the desired cron schedule for Speed Test (e.g., '*/15 * * * *'):"
    read -r cron_speed
    SCHEDULE_SPEED="$cron_speed"
else
    SCHEDULE_SPEED=""
fi

echo "Do you want to schedule an Update job? [Y/n]"
read -r sched_update_opt
if [ -z "$sched_update_opt" ] || echo "$sched_update_opt" | grep -qi "^y"; then
    echo "Enter the desired cron schedule for Update (e.g., '0 */2 * * *'):"
    read -r cron_update
    SCHEDULE_UPDATE="$cron_update"
else
    SCHEDULE_UPDATE=""
fi

# --- Build the Configuration File ---
CONFIG_FILE="/jffs/scripts/vpn-monitor-${client_instance}.conf"
cat > "$CONFIG_FILE" <<EOF
#!/bin/sh
# VPN Monitor Configuration File
# Location: $CONFIG_FILE

###############################################################################
#                         CLIENT SETTINGS                                     #
###############################################################################
CLIENT_INSTANCE="${client_instance}"
SPEED_THRESHOLD="${SPEED_THRESHOLD}"

###############################################################################
#                         PERFORMANCE SETTINGS                                #
###############################################################################
MAX_ATTEMPTS=3
PING_COUNT=3
PING_TIMEOUT=5

###############################################################################
#                           FILE LOCATIONS                                    #
###############################################################################
LOG_FILE="/var/log/vpn-speedtest.log"
MAX_LOG_SIZE=10485760
CACHE_FILE="/tmp/vpn-speedtest.cache"
LOCK_FILE="/tmp/vpn-speedtest.lock"

###############################################################################
#                         NETWORK SETTINGS                                    #
###############################################################################
TEST_IP="8.8.8.8"
MAX_SERVERS=5

###############################################################################
#                    RECOMMENDED SERVERS SETTINGS                           #
###############################################################################
RECOMMENDED_API_URL="${RECOMMENDED_API_URL}"
EOF

chmod +x "$CONFIG_FILE"
echo -e "${col_g}Configuration file created at $CONFIG_FILE:${col_n}"
cat "$CONFIG_FILE"

# --- Download the Main Script ---
SCRIPT_PATH="/jffs/scripts/vpn-speedtest-monitor.sh"
echo "Downloading vpn-speedtest-monitor.sh to $SCRIPT_PATH..."
wget -qO "$SCRIPT_PATH" "https://raw.githubusercontent.com/hubaker/wg-speedtest/refs/heads/main/vpn-speedtest-monitor.sh" || { echo "Download failed"; fail; }
chmod a+rx "$SCRIPT_PATH"
echo -e "${col_g}vpn-speedtest-monitor.sh installed successfully.${col_n}"

# --- Schedule the Scripts if Requested ---
if [ -n "$SCHEDULE_SPEED" ]; then
    JOB_ID_SPEED="vpn-speedtest-monitor-${client_instance}-speed"
    LOG_FILE_SPEED="/var/log/vpn-speedtest-monitor-${client_instance}-speed.log"
    CRU_CMD_SPEED="cru a $JOB_ID_SPEED \"$SCHEDULE_SPEED /bin/sh $SCRIPT_PATH $CONFIG_FILE --speedtest > $LOG_FILE_SPEED 2>&1\""
    echo "Adding Speed Test schedule: $CRU_CMD_SPEED"
    eval "$CRU_CMD_SPEED"
    sed -i "/$JOB_ID_SPEED/d" /jffs/scripts/services-start
    echo "$CRU_CMD_SPEED" >> /jffs/scripts/services-start
    echo -e "${col_g}Speed Test scheduled task set up.${col_n}"
else
    echo -e "${col_y}No Speed Test scheduled task set up.${col_n}"
fi

if [ -n "$SCHEDULE_UPDATE" ]; then
    JOB_ID_UPDATE="vpn-speedtest-monitor-${client_instance}-update"
    LOG_FILE_UPDATE="/var/log/vpn-speedtest-monitor-${client_instance}-update.log"
    CRU_CMD_UPDATE="cru a $JOB_ID_UPDATE \"$SCHEDULE_UPDATE /bin/sh $SCRIPT_PATH $CONFIG_FILE --update > $LOG_FILE_UPDATE 2>&1\""
    echo "Adding Update schedule: $CRU_CMD_UPDATE"
    eval "$CRU_CMD_UPDATE"
    sed -i "/$JOB_ID_UPDATE/d" /jffs/scripts/services-start
    echo "$CRU_CMD_UPDATE" >> /jffs/scripts/services-start
    echo -e "${col_g}Update scheduled task set up.${col_n}"
else
    echo -e "${col_y}No Update scheduled task set up.${col_n}"
fi

# --- Auto-Threshold Immediate Run Option ---
if [ "$thresh_option" = "2" ]; then
    echo "Do you want to run an auto-threshold speed test now? [Y/n]"
    read -r run_now
    if [ -z "$run_now" ] || echo "$run_now" | grep -qi "^y"; then
        echo "Running auto-threshold speed test..."
        /bin/sh "$SCRIPT_PATH" "$CONFIG_FILE" --autothreshold --speedtest
    fi
fi

echo -e "${col_g}Installation completed successfully.${col_n}"
