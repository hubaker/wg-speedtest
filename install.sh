#!/bin/sh
# install.sh for vpn-speedtest-monitor.sh
#
# This installation script sets up vpn-speedtest-monitor.sh.
# It will:
#   - Check firmware version, JFFS partition, and router architecture.
#   - Ensure required tools (jq and bc) are installed (bc via Entware if needed).
#   - List enabled WireGuard VPN (wgc) clients and let you choose one.
#   - Ask if you want to use standard recommended servers or specify country/city.
#   - Ask if you want to manually specify a threshold speed or use auto-threshold calibration.
#   - Optionally ask for scheduling details.
#   - Create a unique configuration file (e.g., /jffs/scripts/vpn-monitor-wgc5.conf) that stores your settings.
#   - Download vpn-speedtest-monitor.sh to /jffs/scripts and make it executable.
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
if [ -x /opt/bin/bc ] || [ -x /usr/bin/bc ] || [ -x /bin/bc ]; then
    echo -e "${col_g}bc is installed${col_n}"
else
    echo -e "${col_y}bc not found. Attempting to install bc via Entware...${col_n}"
    if command -v opkg >/dev/null 2>&1; then
        opkg update && opkg install bc || { echo "Failed to install bc with opkg"; fail; }
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
        SPEED_THRESHOLD="370"  # Dummy initial value; will be auto-calibrated later.
        ;;
    *)
        echo -e "${col_r}Invalid selection.${col_n}"
        fail
        ;;
esac

# --- Scheduling Option ---
echo "Do you want to schedule the script? [Y/n]"
read -r schedule_opt
if [ -z "$schedule_opt" ] || echo "$schedule_opt" | grep -qi "^y"; then
    echo "Enter the desired cron schedule (e.g., '*/15 * * * *' for every 15 minutes):"
    read -r cron_schedule
    SCHEDULE_CRON="$cron_schedule"
else
    SCHEDULE_CRON=""
fi

if [ -n "$SCHEDULE_CRON" ]; then
    echo "Which mode do you want to schedule?"
    echo "[1] Speed Test Mode (default)"
    echo "[2] Update Mode"
    read -r mode_opt
    case "$mode_opt" in
        2)
            SCHEDULE_MODE="--update"
            ;;
        *)
            SCHEDULE_MODE="--speedtest"
            ;;
    esac
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

# --- Schedule the Script if Requested ---
if [ -n "$SCHEDULE_CRON" ]; then
    JOB_ID="vpn-speedtest-monitor-${client_instance}"
    LOG_FILE_SCHED="/var/log/vpn-speedtest-monitor-${client_instance}.log"
    CRU_CMD="cru a $JOB_ID \"$SCHEDULE_CRON /bin/sh $SCRIPT_PATH $CONFIG_FILE $SCHEDULE_MODE > $LOG_FILE_SCHED 2>&1\""
    echo "Adding schedule: $CRU_CMD"
    eval "$CRU_CMD"
    sed -i "/$JOB_ID/d" /jffs/scripts/services-start
    echo "$CRU_CMD" >> /jffs/scripts/services-start
    echo -e "${col_g}Scheduled task set up.${col_n}"
else
    echo -e "${col_y}No scheduled task set up.${col_n}"
fi

echo -e "${col_g}Installation completed successfully.${col_n}"
