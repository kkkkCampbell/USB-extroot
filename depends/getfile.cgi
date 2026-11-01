#!/bin/sh
# ============================================================
#  cgi/getfile.cgi — стриминг архива с read_token.
#
#  Параметры: file=<relpath.tar.gz>  token=<read_token>
#    relpath: manual/…, auto/…, emergency_backup/…  (опционально префикс)
#             либо basename.tar.gz — тогда ищем во всех трёх подкаталогах.
#  Также принимает X-Extroot-Token (write_token тоже валиден).
#
#  Whitelist путей — только <BACKUPS_DIR>/<sub>/,
#  /mnt/*/usb-extroot-backups/<sub>/,
#  /overlay/usb-extroot-backups/<sub>/.
#  Никаких .., никаких абсолютных путей, только *.tar.gz.
# ============================================================

. /opt/usb-extroot/lib/paths.sh

REMOTE="${REMOTE_ADDR:-}"
case "$REMOTE" in
	127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|::1|fe80:*|fc*|fd*) ;;
	*) printf 'Status: 403 Forbidden\n\nForbidden.\n'; exit 0 ;;
esac

EXPECTED_READ=$(uci -q get "$UCI_CONFIG.$UCI_SECTION.read_token" 2>/dev/null)
EXPECTED_WRITE=$(uci -q get "$UCI_CONFIG.$UCI_SECTION.write_token" 2>/dev/null)
[ -z "$EXPECTED_READ" ] && [ -z "$EXPECTED_WRITE" ] && {
	printf 'Status: 503 Service Unavailable\n\nno token configured\n'; exit 0
}

FILE=""
REQ_TOKEN=""
[ -n "$QUERY_STRING" ] && for pair in $(printf '%s' "$QUERY_STRING" | tr '&' ' '); do
	case "$pair" in
		file=*)  FILE="${pair#file=}" ;;
		token=*) REQ_TOKEN="${pair#token=}" ;;
	esac
done
[ -n "${HTTP_X_EXTROOT_TOKEN:-}" ] && REQ_TOKEN="$HTTP_X_EXTROOT_TOKEN"

# URL-decode (безопасно для файлов и токенов)
FILE=$(printf '%s' "$FILE" | sed 's|%2[Ff]|/|g; s|%20| |g')
REQ_TOKEN=$(printf '%s' "$REQ_TOKEN" | sed 's|%2B|+|g; s|%2[Ff]|/|g; s|%20| |g; s|%3[Dd]|=|g')

TOKEN_OK=0
[ -n "$REQ_TOKEN" ] && [ -n "$EXPECTED_READ" ]  && [ "$REQ_TOKEN" = "$EXPECTED_READ" ]  && TOKEN_OK=1
[ -n "$REQ_TOKEN" ] && [ -n "$EXPECTED_WRITE" ] && [ "$REQ_TOKEN" = "$EXPECTED_WRITE" ] && TOKEN_OK=1
[ "$TOKEN_OK" = "1" ] || { printf 'Status: 403 Forbidden\n\nBad token\n'; exit 0; }

[ -z "$FILE" ] && { printf 'Status: 400 Bad Request\n\nfile= required\n'; exit 0; }

# Отсекаем любую дрянь: .., обратные слэши, недопустимые символы.
case "$FILE" in
	*..*|*\\*) printf 'Status: 400 Bad Request\n\nInvalid path\n'; exit 0 ;;
esac

# Разбираем на <sub> и <base>.
SUBDIR=""
BASE=""
case "$FILE" in
	*/*)
		SUBDIR="${FILE%%/*}"
		BASE="${FILE##*/}"
		case "$SUBDIR" in
			manual|auto|emergency_backup) ;;
			*) printf 'Status: 400 Bad Request\n\nInvalid subdir\n'; exit 0 ;;
		esac
		;;
	*)
		BASE="$FILE"
		;;
esac

# Имя файла — только безопасные символы + .tar.gz.
case "$BASE" in
	''|*[!A-Za-z0-9_.-]*) printf 'Status: 400 Bad Request\n\nInvalid filename\n'; exit 0 ;;
	*.tar.gz) ;;
	*) printf 'Status: 400 Bad Request\n\nOnly .tar.gz\n'; exit 0 ;;
esac

# Список подкаталогов для поиска.
if [ -n "$SUBDIR" ]; then
	SEARCH_SUBS="$SUBDIR"
else
	SEARCH_SUBS="manual auto emergency_backup"
fi

FOUND=""
for sub in $SEARCH_SUBS; do
	[ -n "$FOUND" ] && break
	for root in \
		"$BACKUPS_DIR/$sub" \
		/mnt/*/usb-extroot-backups/"$sub" \
		/overlay/usb-extroot-backups/"$sub"
	do
		if [ -f "$root/$BASE" ]; then
			FOUND="$root/$BASE"
			break
		fi
	done
done

[ -n "$FOUND" ] || { printf 'Status: 404 Not Found\n\nNot found\n'; exit 0; }

NAME=$(basename "$FOUND")
SIZE=$(wc -c < "$FOUND" 2>/dev/null)
[ -z "$SIZE" ] && SIZE=0

printf 'Content-Type: application/gzip\n'
printf 'Content-Length: %s\n' "$SIZE"
printf 'Content-Disposition: attachment; filename="%s"\n' "$NAME"
printf 'Cache-Control: no-store\n'
printf 'X-Content-Type-Options: nosniff\n'
printf '\n'
cat "$FOUND"
exit 0