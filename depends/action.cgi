#!/bin/sh
# ============================================================
#  cgi/action.cgi — прямое управление usb-extroot.sh в обход rpcd
# ============================================================

. /opt/usb-extroot/lib/paths.sh

EXPECTED_WRITE=$(uci -q get "$UCI_CONFIG.$UCI_SECTION.write_token" 2>/dev/null)
EXPECTED_READ=$(uci -q get "$UCI_CONFIG.$UCI_SECTION.read_token" 2>/dev/null)

MODE=""
DEVICE=""
ACTION=""
ARCHIVE=""
REQ_TOKEN=""
[ -n "$QUERY_STRING" ] && for pair in $(printf '%s' "$QUERY_STRING" | tr '&' ' '); do
	case "$pair" in
		mode=*)    MODE="${pair#mode=}" ;;
		device=*)  DEVICE="${pair#device=}" ;;
		action=*)  ACTION="${pair#action=}" ;;
		archive=*) ARCHIVE="${pair#archive=}" ;;
		token=*)   REQ_TOKEN="${pair#token=}" ;;
	esac
done
[ -n "${HTTP_X_EXTROOT_TOKEN:-}" ] && REQ_TOKEN="$HTTP_X_EXTROOT_TOKEN"

# URL-декодирование
MODE=$(printf '%s' "$MODE" | sed 's|%2[Ff]|/|g; s|%20| |g; s|%3[Aa]|:|g')
DEVICE=$(printf '%s' "$DEVICE" | sed 's|%2[Ff]|/|g; s|%20| |g; s|%3[Aa]|:|g')
ACTION=$(printf '%s' "$ACTION" | sed 's|%2[Ff]|/|g; s|%20| |g; s|%3[Aa]|:|g')
ARCHIVE=$(printf '%s' "$ARCHIVE" | sed 's|%2[Ff]|/|g; s|%20| |g; s|%3[Aa]|:|g')
REQ_TOKEN=$(printf '%s' "$REQ_TOKEN" | sed 's|%2[Ff]|/|g; s|%20| |g; s|%3[Aa]|:|g')

# --- Чтение (action) ---
if [ -n "$ACTION" ]; then
	printf 'Content-Type: text/plain\n\n'
	case "$ACTION" in
		get-tokens)
			echo "read_token=$EXPECTED_READ"
			echo "write_token=$EXPECTED_WRITE"
			exit 0
			;;
		version)
			/opt/usb-extroot/usb-extroot.sh --version
			exit 0
			;;
	esac

	TOKEN_OK=0
	[ -n "$REQ_TOKEN" ] && [ "$REQ_TOKEN" = "$EXPECTED_READ" ] && TOKEN_OK=1
	[ -n "$REQ_TOKEN" ] && [ "$REQ_TOKEN" = "$EXPECTED_WRITE" ] && TOKEN_OK=1
	[ "$TOKEN_OK" = "1" ] || { echo "Bad token"; exit 0; }

	case "$ACTION" in
		status)
			/opt/usb-extroot/usb-extroot.sh --batch --action=status 2>&1
			if [ -f "$PID_FILE" ]; then
				pid=$(cat "$PID_FILE" 2>/dev/null)
				if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
					echo "running=true"
				else
					echo "running=false"
				fi
			else
				echo "running=false"
			fi
			;;
		devices|switch-targets|backup-sources|archive-list)
			/opt/usb-extroot/usb-extroot.sh --batch --action="$ACTION" 2>&1
			;;
		log)
			[ -f "$LOG" ] && cat "$LOG" 2>/dev/null
			;;
		get-settings)
			echo "autobackup_enabled=$(uci -q get usb-extroot.main.autobackup_enabled)"
			echo "manual_rotate=$(uci -q get usb-extroot.main.manual_rotate)"
			echo "auto_rotate=$(uci -q get usb-extroot.main.auto_rotate)"
			;;
		reboot-now)
			touch "$REBOOT_NOW" 2>/dev/null || true
			;;
		reboot-cancel)
			touch "$REBOOT_CANCEL" 2>/dev/null || true
			;;
		emergency-archive)
			ls -t "$BACKUPS_EMERGENCY"/*.tar.gz 2>/dev/null | head -1
			;;
		*)
			echo "invalid action"
			;;
	esac
	exit 0
fi

# --- Запись (mode) ---
[ -z "$MODE" ] && { printf 'Status: 400 Bad Request\n\nmode required\n'; exit 0; }

[ "$REQ_TOKEN" = "$EXPECTED_WRITE" ] || {
	printf 'Status: 403 Forbidden\n\nBad token\n'; exit 0
}

case "$MODE" in
	format|noformat|restore_archive|revert_extroot|fallback_fix|switch_overlay|reset_keep_extroot|backup_manual) ;;
	*) printf 'Content-Type: application/json\n\n{"error":"invalid mode"}\n'; exit 0 ;;
esac

AARGS="--batch --mode=$MODE --confirm=yes --backup=no"
[ -n "$DEVICE" ] && AARGS="$AARGS --device=$DEVICE"
[ -n "$ARCHIVE" ] && AARGS="$AARGS --archive=$ARCHIVE"

mkdir -p "$UE_RT" 2>/dev/null || true

: > "$LOG"
echo "=== $(date '+%F %T') CGI RUN: $MODE $DEVICE ===" >> "$LOG"

setsid /opt/usb-extroot/usb-extroot.sh $AARGS </dev/null >> "$LOG" 2>&1 &

printf 'Content-Type: application/json\n\n{"ok":true,"started":true}\n'
exit 0