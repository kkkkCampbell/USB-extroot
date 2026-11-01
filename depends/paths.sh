#!/bin/sh
# ============================================================
#  lib/paths.sh — единый источник истины для путей.
#  Source'ится из luci.usb-extroot, cgi/*.cgi, usb-extroot.sh.
# ============================================================

# Корень установки (не менять после install)
APP_DIR="/opt/usb-extroot"
SCRIPT="$APP_DIR/usb-extroot.sh"

# Runtime в ОЗУ
UE_RT="${UE_RT:-/tmp/usb-extroot}"
LOG="$UE_RT/usb-extroot.log"
PID_FILE="$UE_RT/usb-extroot.pid"
LOCK_DIR="$UE_RT/lock"
REBOOT_NOW="$UE_RT/reboot-now"
REBOOT_CANCEL="$UE_RT/reboot-cancel"
AUTOBACKUP_DONE="$UE_RT/autobackup.done"
STAGE_DIR="$UE_RT/stage"
MNT_DIR="$UE_RT/mnt"
ERR_DIR="$UE_RT/err"
PKG_DIR="$UE_RT/pkg"

# Бэкапы (ОЗУ)
BACKUPS_DIR="$UE_RT/backups"
BACKUPS_MANUAL="$BACKUPS_DIR/manual"
BACKUPS_AUTO="$BACKUPS_DIR/auto"
BACKUPS_EMERGENCY="$BACKUPS_DIR/emergency_backup"

# Бэкапы на целевых носителях
TARGET_BACKUPS_SUBDIR="usb-extroot-backups"

# UCI
UCI_CONFIG="usb-extroot"
UCI_SECTION="main"