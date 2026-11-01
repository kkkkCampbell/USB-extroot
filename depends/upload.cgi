#!/bin/sh
# ============================================================
#  cgi/upload.cgi — загрузка архива с ПК (write_token).
#
#  Параметры:
#    file=<name.tar.gz>       обязательный, только безопасное имя
#    token=<write_token>      либо X-Extroot-Token
#    save_usb=0|1             куда сохранять (по умолчанию 0)
#
#  save_usb=0 → /tmp/usb-extroot/<name>.tar.gz
#  save_usb=1 → <target>/usb-extroot-backups/manual/<name>.tar.gz
# ============================================================

. /opt/usb-extroot/lib/paths.sh

EXPECTED_WRITE=$(uci -q get "$UCI_CONFIG.$UCI_SECTION.write_token" 2>/dev/null)
[ -z "$EXPECTED_WRITE" ] && {
	printf 'Status: 503 Service Unavailable\n\nno write_token\n'; exit 0
}

FILE=""
REQ_TOKEN=""
SAVE_USB="0"
[ -n "$QUERY_STRING" ] && for pair in $(printf '%s' "$QUERY_STRING" | tr '&' ' '); do
	case "$pair" in
		file=*)     FILE="${pair#file=}" ;;
		token=*)    REQ_TOKEN="${pair#token=}" ;;
		save_usb=*) SAVE_USB="${pair#save_usb=}" ;;
	esac
done
[ -n "${HTTP_X_EXTROOT_TOKEN:-}" ] && REQ_TOKEN="$HTTP_X_EXTROOT_TOKEN"

[ "$REQ_TOKEN" = "$EXPECTED_WRITE" ] || {
	printf 'Status: 403 Forbidden\n\nBad token\n'; exit 0
}

case "$SAVE_USB" in 0|1) ;; *) SAVE_USB="0" ;; esac

# URL-decode, извлекаем basename
FILE=$(printf '%s' "$FILE" | sed 's|%2[Ff]|/|g; s|%20| |g')
FILE=$(basename "$FILE")
case "$FILE" in
	''|*..*|*[!A-Za-z0-9_.-]*) printf 'Status: 400 Bad Request\n\nInvalid filename\n'; exit 0 ;;
	*.tar.gz) ;;
	*) printf 'Status: 400 Bad Request\n\nOnly .tar.gz\n'; exit 0 ;;
esac

# --- выбираем целевую директорию ---
if [ "$SAVE_USB" = "1" ]; then
	OV_MP=$(awk '$2=="/overlay" {print $2; exit}' /proc/mounts)
	OV_DEV=$(awk '$2=="/overlay" {print $1; exit}' /proc/mounts)

	if [ -n "$OV_DEV" ] && [ -n "$OV_MP" ]; then
		case "$OV_DEV" in
			/dev/ubi*|/dev/mtdblock*|/dev/root)
				DST_DIR="/overlay/usb-extroot-backups/manual"
				;;
			*)
				DST_DIR="$OV_MP/$TARGET_BACKUPS_SUBDIR/manual"
				;;
		esac
	else
		DST_DIR="/overlay/usb-extroot-backups/manual"
	fi
else
	DST_DIR="$UE_RT"
fi

if ! mkdir -p "$DST_DIR" 2>/dev/null; then
	printf 'Content-Type: application/json\n\n{"error":"mkdir failed: %s"}\n' "$DST_DIR"
	exit 0
fi

TMPFILE="$DST_DIR/.$FILE.part"
FINAL="$DST_DIR/$FILE"
rm -f "$TMPFILE"

# Стримим body в файл.
cat > "$TMPFILE"

if [ ! -s "$TMPFILE" ]; then
	rm -f "$TMPFILE"
	printf 'Content-Type: application/json\n\n{"error":"no data"}\n'
	exit 0
fi

# gzip magic
MAGIC=$(hexdump -n 2 -e '2/1 "%02x"' "$TMPFILE" 2>/dev/null)
if [ "$MAGIC" != "1f8b" ]; then
	rm -f "$TMPFILE"
	printf 'Content-Type: application/json\n\n{"error":"not gzip"}\n'
	exit 0
fi

mv -f "$TMPFILE" "$FINAL" 2>/dev/null || {
	rm -f "$TMPFILE"
	printf 'Content-Type: application/json\n\n{"error":"rename failed"}\n'
	exit 0
}

sync

printf 'Content-Type: application/json\n'
printf 'Cache-Control: no-store\n'
printf '\n'
printf '{"ok":true,"path":%s,"save_usb":"%s"}\n' \
	"$(printf '%s' "$FINAL" | awk 'BEGIN{printf "\""}{gsub(/\\/,"\\\\");gsub(/"/,"\\\"");printf "%s",$0}END{printf "\""}')" \
	"$SAVE_USB"
exit 0