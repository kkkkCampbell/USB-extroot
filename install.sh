#!/bin/sh
# ============================================================
#  install.sh — установка USB extroot.
#
#  Структура в git:
#    /                          ← этот файл (install.sh)
#    /depends/<filename>        ← все остальные файлы, плоско
#
#  При установке они раскладываются по /opt/usb-extroot/ с
#  правильной структурой (lib/, cgi/, view/).
#
#  Установка:   sh install.sh
#  Удаление:    sh install.sh --uninstall
# ============================================================

BASE_DIR="/opt/usb-extroot"
SRC_BASE="https://raw.githubusercontent.com/kkkkCampbell/USB-extroot/refs/heads/draft-ref---tored"
TEST_MODE="${TEST_MODE:-0}"

CLR_RESET="\033[0m"
CLR_GREEN="\033[32m"
CLR_ORANGE="\033[38;5;208m"
CLR_YELLOW="\033[33m"

die()  { printf "${CLR_ORANGE}ОШИБКА: %s${CLR_RESET}\n" "$1" >&2; exit 1; }
ok()   { printf "  ${CLR_GREEN}[OK]${CLR_RESET}    %s\n" "$1"; }
warn() { printf "  ${CLR_YELLOW}[WARN]${CLR_RESET}  %s\n" "$1"; }
fail() { printf "  ${CLR_ORANGE}[FAIL]${CLR_RESET}  %s\n" "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

safe_ln() {
	local target="$1" link="$2"
	mkdir -p "$(dirname "$link")" || die "mkdir $(dirname "$link")"
	if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then return 0; fi
	rm -f "$link" || die "rm -f $link"
	ln -s "$target" "$link" || die "ln $link -> $target"
}

valid_token() {
	[ -n "$1" ] && [ "$1" != "fixme" ]
}

gen_token() {
	local t
	t=$(head -c 16 /dev/urandom 2>/dev/null | hexdump -e '16/1 "%02x"' 2>/dev/null)
	[ -z "$t" ] && t="fixme${RANDOM}${RANDOM}${RANDOM}"
	printf '%s' "$t"
}

# ============================================================
#  UNINSTALL
# ============================================================
do_uninstall() {
	printf '==> Удаляю usb-extroot...\n'

	if [ -x /etc/init.d/usb-extroot-autobackup ]; then
		/etc/init.d/usb-extroot-autobackup stop    >/dev/null 2>&1 || true
		/etc/init.d/usb-extroot-autobackup disable >/dev/null 2>&1 || true
	fi
	rm -f /etc/init.d/usb-extroot-autobackup

	for l in \
		/usr/share/luci/menu.d/luci-app-usb-extroot.json \
		/www/luci-static/resources/view/usb-extroot \
		/www/cgi-bin/usb-extroot-getfile \
		/www/cgi-bin/usb-extroot-upload \
		/www/cgi-bin/usb-extroot-action
	do
		[ -L "$l" ] || [ -e "$l" ] && rm -rf "$l"
	done
	if [ -d /www/luci-static/resources/view/usb-extroot ] && \
	   [ ! -L /www/luci-static/resources/view/usb-extroot ]; then
		rm -rf /www/luci-static/resources/view/usb-extroot
	fi

	rm -f  /etc/config/usb-extroot
	rm -rf "$BASE_DIR"
	rm -rf /tmp/usb-extroot

	/etc/init.d/rpcd   restart >/dev/null 2>&1 || true
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

	printf 'Удалено.\n'
	exit 0
}

[ "${1:-}" = "--uninstall" ] && do_uninstall

# ============================================================
#  INSTALL
# ============================================================
[ "$(id -u)" = "0" ] || die "Запустите от root"

printf '============================================================\n'
printf ' usb-extroot install  (TEST_MODE=%s)\n' "$TEST_MODE"
printf '============================================================\n\n'

mkdir -p "$BASE_DIR/lib" "$BASE_DIR/cgi" "$BASE_DIR/view" \
	|| die "mkdir $BASE_DIR"

# --- чистка legacy ---
for old in \
	"$BASE_DIR/main.js" \
	"$BASE_DIR/archive.cgi" \
	"$BASE_DIR/upload.cgi" \
	"$BASE_DIR/lib/rpcd_helpers.sh" \
	"$BASE_DIR/view/rpc.js" \
	"$BASE_DIR/view/panel.js" \
	"$BASE_DIR/view/log.js" \
	"$BASE_DIR/luci.usb-extroot" \
	"$BASE_DIR/acl.json"
do
	[ -e "$old" ] && rm -f "$old" && warn "удалён legacy: $old"
done
[ -d "$BASE_DIR/view/modals" ] && rm -rf "$BASE_DIR/view/modals" && warn "удалён legacy: view/modals"
[ -d "$BASE_DIR/lib/rpcd_methods" ] && rm -rf "$BASE_DIR/lib/rpcd_methods" && warn "удалён legacy: lib/rpcd_methods"

if [ -L /www/cgi-bin/usb-extroot-archive ]; then
	rm -f /www/cgi-bin/usb-extroot-archive
	warn "удалён legacy-симлинк: archive"
fi
if [ -L /usr/libexec/rpcd/luci.usb-extroot ]; then
	rm -f /usr/libexec/rpcd/luci.usb-extroot
	warn "удалён legacy-симлинк: rpcd"
fi
if [ -L /usr/share/rpcd/acl.d/luci-app-usb-extroot.json ]; then
	rm -f /usr/share/rpcd/acl.d/luci-app-usb-extroot.json
	warn "удалён legacy-симлинк: acl.json"
fi
if [ -d /www/luci-static/resources/view/usb-extroot ] && \
   [ ! -L /www/luci-static/resources/view/usb-extroot ]; then
	rm -rf /www/luci-static/resources/view/usb-extroot
	warn "удалён legacy-каталог: /www/.../usb-extroot"
fi

# ============================================================
#  FETCH / CHECK FILES
# ============================================================
MISSING_CRITICAL=0
MISSING_OPTIONAL=0

_fetch() {
	local rel="$1" marker="$2" level="$3"
	local dst="$BASE_DIR/$rel"
	local fname=$(basename "$rel")
	local url="$SRC_BASE/depends/$fname"
	local tmp

	if [ "$TEST_MODE" = "1" ]; then
		if [ -s "$dst" ] && grep -q "$marker" "$dst"; then
			ok "$rel (local)"
			return 0
		fi
		if [ -s "$dst" ]; then
			warn "$rel (local, маркер '$marker' не найден)"
			return 0
		fi
		fail "$rel (local, отсутствует)"
		[ "$level" = "critical" ] && MISSING_CRITICAL=$((MISSING_CRITICAL+1))
		[ "$level" = "optional" ] && MISSING_OPTIONAL=$((MISSING_OPTIONAL+1))
		return 1
	fi

	mkdir -p "$(dirname "$dst")" 2>/dev/null
	tmp="${dst}.part"
	rm -f "$tmp"

	if have wget; then
		wget --timeout=10 -qO "$tmp" "$url" 2>/dev/null || true
	elif have curl; then
		curl -fsSL --connect-timeout 5 "$url" -o "$tmp" 2>/dev/null || true
	fi

	if [ ! -s "$tmp" ]; then
		fail "$rel (download failed: $url)"
		[ "$level" = "critical" ] && MISSING_CRITICAL=$((MISSING_CRITICAL+1))
		[ "$level" = "optional" ] && MISSING_OPTIONAL=$((MISSING_OPTIONAL+1))
		rm -f "$tmp"
		return 1
	fi

	if grep -q "$marker" "$tmp"; then
		mv "$tmp" "$dst"
		ok "$rel"
		return 0
	fi

	fail "$rel (маркер '$marker' не найден)"
	rm -f "$tmp"
	[ "$level" = "critical" ] && MISSING_CRITICAL=$((MISSING_CRITICAL+1))
	[ "$level" = "optional" ] && MISSING_OPTIONAL=$((MISSING_OPTIONAL+1))
	return 1
}

printf '==> Файлы (source: %s/depends/)\n' "$SRC_BASE"

_fetch "usb-extroot.sh"      "_wait_for_reboot_action"          critical
_fetch "lib/paths.sh"        "BACKUPS_EMERGENCY"                 critical
_fetch "cgi/getfile.cgi"     "getfile.cgi"                       critical
_fetch "cgi/upload.cgi"      "upload.cgi"                        critical
_fetch "cgi/action.cgi"      "action.cgi"                        critical
_fetch "view/main.js"        "view.extend"                       critical
_fetch "view/main.css"       ".usb-extroot-log"                  critical
_fetch "menu.json"           "admin/services/usb-extroot"        critical

_fetch "clone-overlay.sh"    "clone_overlay_interactive"         optional
_fetch "switch-overlay.sh"   "second_drive_menu"                 optional
_fetch "uninstall.sh"        "keep-backups"                      optional
_fetch "health_check.sh"     "FAILS"                             optional

if [ "$MISSING_CRITICAL" -gt 0 ]; then
	die "Отсутствуют $MISSING_CRITICAL критичных файлов. Установка прервана."
fi

chmod +x \
	"$BASE_DIR/usb-extroot.sh" \
	"$BASE_DIR/cgi/getfile.cgi" \
	"$BASE_DIR/cgi/upload.cgi" \
	"$BASE_DIR/cgi/action.cgi"

# ============================================================
#  UCI CONFIG + MIGRATION
# ============================================================
printf '\n==> UCI /etc/config/usb-extroot\n'

if [ ! -f /etc/config/usb-extroot ]; then
	NEW_READ=$(gen_token)
	NEW_WRITE=$(gen_token)
	cat > /etc/config/usb-extroot <<EOF
config usb-extroot 'main'
	option autobackup_delay '300'
	option autobackup_enabled '1'
	option manual_rotate '50'
	option auto_rotate '10'
	option read_token '$NEW_READ'
	option write_token '$NEW_WRITE'
EOF
	ok "/etc/config/usb-extroot создан"
else
	OLD_TOKEN=$(uci -q get usb-extroot.main.api_token 2>/dev/null)
	if [ -n "$OLD_TOKEN" ]; then
		uci set usb-extroot.main.read_token="$OLD_TOKEN"
		NEW_WRITE=$(gen_token)
		uci set usb-extroot.main.write_token="$NEW_WRITE"
		uci -q delete usb-extroot.main.api_token
		ok "api_token -> read_token/write_token"
	fi

	for k in read_token write_token; do
		v=$(uci -q get "usb-extroot.main.$k" 2>/dev/null)
		if ! valid_token "$v"; then
			nv=$(gen_token)
			uci set "usb-extroot.main.$k=$nv"
			ok "дописан $k"
		fi
	done

	for k in autobackup_enabled:1 manual_rotate:50 auto_rotate:10 autobackup_delay:300; do
		n="${k%%:*}"
		d="${k##*:}"
		v=$(uci -q get "usb-extroot.main.$n" 2>/dev/null)
		if [ -z "$v" ]; then
			uci set "usb-extroot.main.$n=$d"
			ok "дописан $n=$d"
		fi
	done
	uci commit usb-extroot 2>/dev/null
fi

# ============================================================
#  SYMLINKS
# ============================================================
printf '\n==> Симлинки\n'
safe_ln "$BASE_DIR/menu.json"        /usr/share/luci/menu.d/luci-app-usb-extroot.json
safe_ln "$BASE_DIR/view"             /www/luci-static/resources/view/usb-extroot
safe_ln "$BASE_DIR/cgi/getfile.cgi"  /www/cgi-bin/usb-extroot-getfile
safe_ln "$BASE_DIR/cgi/upload.cgi"   /www/cgi-bin/usb-extroot-upload
safe_ln "$BASE_DIR/cgi/action.cgi"   /www/cgi-bin/usb-extroot-action
ok "симлинки установлены"

# ============================================================
#  INIT.D — autobackup
# ============================================================
printf '\n==> init.d/usb-extroot-autobackup\n'

cat > /etc/init.d/usb-extroot-autobackup <<'INITD_EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10

start() {
	[ -x /opt/usb-extroot/usb-extroot.sh ] || return 0

	local enabled
	enabled=$(uci -q get usb-extroot.main.autobackup_enabled 2>/dev/null)
	[ "$enabled" = "0" ] && return 0

	local ovmnt ovdev parent
	ovmnt=$(awk '$2=="/overlay" {print $2; exit}' /proc/mounts)
	[ -z "$ovmnt" ] && return 0
	ovdev=$(awk -v m="$ovmnt" '$2==m {print $1; exit}' /proc/mounts)
	[ -z "$ovdev" ] && return 0

	case "$ovdev" in /dev/ubi*|/dev/mtdblock*|/dev/root) return 0 ;; esac
	case "$ovdev" in
		/dev/mmcblk*p[0-9]*) parent="${ovdev%p[0-9]*}" ;;
		/dev/sd[a-z][0-9]*)  parent="${ovdev%[0-9]*}"  ;;
		*) return 0 ;;
	esac
	parent=$(basename "$parent")
	case "$parent" in
		sd[a-z])
			case "$(readlink -f /sys/block/$parent 2>/dev/null)" in
				*"/usb"*) ;;
				*) return 0 ;;
			esac
			;;
		mmcblk[0-9]*)
			[ "$(cat /sys/block/$parent/removable 2>/dev/null)" = "1" ] || return 0
			;;
		*) return 0 ;;
	esac

	local delay
	delay=$(uci -q get usb-extroot.main.autobackup_delay 2>/dev/null)
	[ -z "$delay" ] && delay=300
	case "$delay" in ''|*[!0-9]*) delay=300 ;; esac

	if [ "$delay" -gt 0 ]; then
		setsid sh -c "sleep $delay; /opt/usb-extroot/usb-extroot.sh --batch --mode=backup --confirm=yes" >/dev/null 2>&1 &
	else
		setsid /opt/usb-extroot/usb-extroot.sh --batch --mode=backup --confirm=yes >/dev/null 2>&1 &
	fi
}

stop() { :; }
INITD_EOF

chmod +x /etc/init.d/usb-extroot-autobackup
/etc/init.d/usb-extroot-autobackup enable >/dev/null 2>&1 || true
ok "init.d установлен и включён"

# ============================================================
#  RESTART SERVICES
# ============================================================
printf '\n==> Перезапуск uhttpd и rpcd\n'
/etc/init.d/rpcd   restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
ok "сервисы перезапущены"

# ============================================================
#  HEALTH CHECK
# ============================================================
health_check() {
	local fails=0

	printf '\n=== Health check ===\n'

	# 1. файлы
	for f in \
		usb-extroot.sh \
		menu.json \
		lib/paths.sh \
		cgi/getfile.cgi \
		cgi/upload.cgi \
		cgi/action.cgi \
		view/main.js \
		view/main.css
	do
		p="$BASE_DIR/$f"
		if [ -s "$p" ]; then
			ok "$p"
		else
			fail "$p отсутствует"
			fails=$((fails+1))
		fi
	done

	# 2. исполняемые
	for f in usb-extroot.sh cgi/getfile.cgi cgi/upload.cgi cgi/action.cgi; do
		p="$BASE_DIR/$f"
		[ -s "$p" ] || continue
		if [ -x "$p" ]; then
			ok "$p (exec)"
		else
			fail "$p не exec"
			fails=$((fails+1))
		fi
	done

	# 3. shell syntax
	for f in usb-extroot.sh lib/paths.sh cgi/getfile.cgi cgi/upload.cgi cgi/action.cgi; do
		p="$BASE_DIR/$f"
		[ -s "$p" ] || continue
		if sh -n "$p" 2>/dev/null; then
			ok "$p (sh -n)"
		else
			fail "$p (синтаксис)"
			fails=$((fails+1))
		fi
	done

	# 4. симлинки
	for l in \
		/usr/share/luci/menu.d/luci-app-usb-extroot.json \
		/www/luci-static/resources/view/usb-extroot \
		/www/cgi-bin/usb-extroot-getfile \
		/www/cgi-bin/usb-extroot-upload \
		/www/cgi-bin/usb-extroot-action
	do
		if [ -L "$l" ] && [ -e "$l" ]; then
			ok "$l -> $(readlink "$l")"
		elif [ -L "$l" ]; then
			fail "$l висит"
			fails=$((fails+1))
		else
			fail "$l не создан"
			fails=$((fails+1))
		fi
	done

	# 5. init.d
	if [ -x /etc/init.d/usb-extroot-autobackup ]; then
		ok "init.d executable"
	else
		fail "init.d нет"
		fails=$((fails+1))
	fi
	if ls /etc/rc.d/S*usb-extroot-autobackup >/dev/null 2>&1; then
		ok "автозапуск включён"
	else
		warn "автозапуск выключен"
	fi

	# 6. UCI
	if [ -f /etc/config/usb-extroot ]; then
		ok "/etc/config/usb-extroot"
	else
		fail "нет UCI"
		fails=$((fails+1))
	fi
	for k in read_token write_token; do
		v=$(uci -q get "usb-extroot.main.$k" 2>/dev/null)
		if valid_token "$v"; then
			ok "$k задан"
		else
			fail "$k не задан"
			fails=$((fails+1))
		fi
	done

	# 7. сервисы
	/etc/init.d/rpcd   status >/dev/null 2>&1 && ok "rpcd запущен"   || warn "rpcd не запущен"
	/etc/init.d/uhttpd status >/dev/null 2>&1 && ok "uhttpd запущен" || warn "uhttpd не запущен"

	printf '\n'
	if [ "$fails" -eq 0 ]; then
		printf "${CLR_GREEN}============================================================${CLR_RESET}\n"
		printf "${CLR_GREEN} Установка завершена успешно.${CLR_RESET}\n"
		printf "${CLR_GREEN} Службы → USB extroot${CLR_RESET}\n"
		printf "${CLR_GREEN}============================================================${CLR_RESET}\n"
		return 0
	fi

	printf "${CLR_ORANGE}============================================================${CLR_RESET}\n"
	printf "${CLR_ORANGE} Установка завершена с %s критичными ошибками.${CLR_RESET}\n" "$fails"
	printf "${CLR_ORANGE}============================================================${CLR_RESET}\n"
	return 1
}

health_check
exit $?