#!/bin/sh
# Uninstallation script for vpn-speedtest-monitor.sh
#
# This script will completely remove vpn-speedtest-monitor from the router!
#
# It removes:
#   - Scheduled tasks (via cru and /jffs/scripts/services-start)
#   - The main script (/jffs/scripts/vpn-speedtest-monitor.sh)
#   - All configuration files (e.g. /jffs/scripts/vpn-monitor-*.conf)
#   - Log files (/var/log/vpn-speedtest-monitor*.log)
#
# Note: VPN client settings stored in NVRAM are left untouched.
#
# Bail out on error
set -e

# Colors
col_n="\033[0m"
col_r="\033[0;31m"
col_g="\033[0;32m"
col_y="\033[0;33m"

echo -e "${col_r}This will completely remove vpn-speedtest-monitor from the router!${col_n}"
printf "Are you sure? [y/N]: "
read -r confirm
confirm=$(echo "$confirm" | xargs)
case "$confirm" in
    "y" | "Y")
        echo "Removing scheduled tasks from cru..."
        # Remove any scheduled cru jobs that reference vpn-speedtest-monitor
        sed -i '/vpn-speedtest-monitor/d' /var/spool/cron/crontabs/"$USER"
        
        echo "Removing scheduled tasks from /jffs/scripts/services-start..."
        sed -i '/vpn-speedtest-monitor/d' /jffs/scripts/services-start
        
        echo "Removing main script and configuration files..."
        rm -rfv /jffs/scripts/vpn-speedtest-monitor.sh
        rm -rfv /jffs/scripts/vpn-monitor-*.conf
        
        echo "Removing log files..."
        rm -rfv /var/log/vpn-speedtest-monitor*.log
        
        echo -e "${col_g}Done${col_n}"
        echo
        echo "Note: Any VPN client configurations stored in NVRAM are left untouched."
        echo "To completely reset a VPN client instance, disable it via the router's web UI"
        echo "and then execute (replace \"wgcX\" with the instance you wish to reset):"
        echo "    for v in \$(nvram show | grep wgcX_ | cut -f1 -d=); do nvram unset \$v; done"
        ;;
    *)
        echo -e "${col_y}Cancelled${col_n}"
        exit 0
        ;;
esac
