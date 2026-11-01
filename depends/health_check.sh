#!/bin/sh
# ============================================================
#  health_check.sh — автономная проверка состояния USB extroot.
#
#  Запуск: sh /opt/usb-extroot/health_check.sh
#          sh /opt/usb-extroot/health_check.sh --quiet
#
#  Проверяет:
#    - файлы и их права/синтаксис
#    - симлинки rpcd/LuCI/uhttpd
#    - UCI-конфиг и токены
#    - init.d + автозапуск
#    - rpcd и uhttpd запущены
#    - rpcd-методы отвечают (ubus call)
#    - CGI getfile/upload отвечают (HTTP HEAD без токена → 403)
#
#  Код возврата: 0 — всё OK, 1 — есть FAIL.
#  --quiet — печатать только [FAIL]/[WARN] и итоговую строку.
# ============================================================

BASE_DIR="/opt/usb-extroot"
UE_RT="/tmp/usb-extroot"

QUIET=0
case "${1:-}" in
	--quiet|-q) QUIET=1 ;;
	--help|-h)
		printf 'Использование: %s [--quiet]\n' "$0"
		exit 0
		;;
esac

CLR_RESET="\033[0m"
CLR_GREEN="\033[32m"
CLR_ORANGE="\033[38;5;208m"
CLR_YELLOW="\033[33m"

FAILS=0
WARNS=0

_ok()   { [ "$QUIET" = "1" ] || printf "  ${CLR_GREEN}[OK]${CLR_RESET}    %s\n" "$1"; }
_warn() { WARNS=$((WARNS+1)); printf "  ${CLR_YELLOW}[WARN]${CLR_RESET}  %s\n" "$1"; }
_fail() { FAILS=$((FAILS+1)); printf "  ${CLR_ORANGE}[FAIL]${CLR_RESET}  %s\n" "$1"; }
_head() { [ "$QUIET" = "1" ] || printf '\n== %s ==\n' "$1"; }

_have() { command -v "$1" >/dev/null 2>&1; }

_valid_token() {
	[ -n "$1" ] && [ "$1" != "fixme" ]
}

# ============================================================
#  1. Файлы
# ============================================================
_head "Файлы"

for f in \
	usb-extroot.sh \
	luci.usb-extroot \
	acl.json \
	menu.json \
	lib/paths.sh \
	cgi/getfile.cgi \
	cgi/upload.cgi \
	view/main.js \
	view/main.css \
	install.sh \
	uninstall.sh
do
	p="$BASE_DIR/$f"
	if [ -s "$p" ]; then
		_ok "$p"
	else
		_fail "$p отсутствует или пуст"
	fi
done

# ============================================================
#  2. Исполняемые биты
# ============================================================
_head "Права"

for f in usb-extroot.sh luci.usb-extroot cgi/getfile.cgi cgi/upload.cgi install.sh uninstall.sh; do
	p="$BASE_DIR/$f"
	[ -s "$p" ] || continue
	if [ -x "$p" ]; then
		_ok "$p (exec)"
	else
		_fail "$p не executable"
	fi
done

# ============================================================
#  3. Shell-синтаксис
# ============================================================
_head "Синтаксис"

for f in usb-extroot.sh luci.usb-extroot lib/paths.sh cgi/getfile.cgi cgi/upload.cgi install.sh uninstall.sh health_check.sh; do
	p="$BASE_DIR/$f"
	[ -s "$p" ] || continue
	if sh -n "$p" 2>/dev/null; then
		_ok "$p (sh -n)"
	else
		_fail "$p синтаксическая ошибка"
	fi
done

# ============================================================
#  4. Симлинки
# ============================================================
_head "Симлинки"

for l in \
	/usr/libexec/rpcd/luci.usb-extroot \
	/usr/share/rpcd/acl.d/luci-app-usb-extroot.json \
	/usr/share/luci/menu.d/luci-app-usb-extroot.json \
	/www/luci-static/resources/view/usb-extroot \
	/www/cgi-bin/usb-extroot-getfile \
	/www/cgi-bin/usb-extroot-upload
do
	if [ -L "$l" ] && [ -e "$l" ]; then
		_ok "$l -> $(readlink "$l")"
	elif [ -L "$l" ]; then
		_fail "$l висит (битый симлинк)"
	else
		_fail "$l не создан"
	fi
done

# ============================================================
#  5. init.d
# ============================================================
_head "init.d"

if [ -x /etc/init.d/usb-extroot-autobackup ]; then
	_ok "init.d/usb-extroot-autobackup executable"
else
	_fail "init.d/usb-extroot-autobackup отсутствует"
fi

if ls /etc/rc.d/S*usb-extroot-autobackup >/dev/null 2>&1; then
	_ok "автозапуск включён"
else
	_warn "автозапуск выключен (rc.d симлинка нет)"
fi

# ============================================================
#  6. UCI
# ============================================================
_head "UCI"

if [ -f /etc/config/usb-extroot ]; then
	_ok "/etc/config/usb-extroot"
else
	_fail "/etc/config/usb-extroot отсутствует"
fi

for k in read_token write_token; do
	v=$(uci -q get "usb-extroot.main.$k" 2>/dev/null)
	if _valid_token "$v"; then
		_ok "$k задан"
	else
		_fail "$k не задан"
	fi
done

for k in autobackup_enabled manual_rotate auto_rotate autobackup_delay; do
	v=$(uci -q get "usb-extroot.main.$k" 2>/dev/null)
	if [ -n "$v" ]; then
		_ok "$k=$v"
	else
		_warn "$k не задан (используется дефолт)"
	fi
done

# ============================================================
#  7. Сервисы
# ============================================================
_head "Сервисы"

if /etc/init.d/rpcd status >/dev/null 2>&1; then
	_ok "rpcd запущен"
else
	_fail "rpcd не запущен"
fi

if /etc/init.d/uhttpd status >/dev/null 2>&1; then
	_ok "uhttpd запущен"
else
	_fail "uhttpd не запущен"
fi

# ============================================================
#  8. rpcd методы
# ============================================================
_head "rpcd методы"

if ! _have ubus; then
	_warn "ubus не найден — пропускаю проверку методов"
else
	# list
	if /usr/libexec/rpcd/luci.usb-extroot list 2>/dev/null | grep -q '"run"'; then
		_ok "list содержит run"
	else
		_fail "list не содержит run (rpcd не загрузил плагин?)"
	fi

	# лёгкие вызовы
	for m in version status get_settings api_read_token; do
		if out=$(ubus call luci.usb-extroot "$m" 2>/dev/null) && [ -n "$out" ]; then
			# грубая валидация: должен начинаться с {
			case "$out" in
				\{*) _ok "ubus call $m" ;;
				*)   _fail "ubus call $m: некорректный ответ" ;;
			esac
		else
			_fail "ubus call $m не отвечает"
		fi
	done
fi

# ============================================================
#  9. Runtime
# ============================================================
_head "Runtime"

if [ -d "$UE_RT" ]; then
	_ok "$UE_RT существует"
else
	_warn "$UE_RT не создан (не запускалось ни одной операции)"
fi

if [ -f "$UE_RT/usb-extroot.pid" ]; then
	pid=$(cat "$UE_RT/usb-extroot.pid" 2>/dev/null)
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		_warn "операция выполняется прямо сейчас (PID $pid)"
	else
		_warn "stale PID-файл $UE_RT/usb-extroot.pid (процесс мёртв)"
	fi
fi

# ============================================================
#  10. CGI (без токена → 403)
# ============================================================
_head "CGI"

IP=""
IP=$(uci -q get network.lan.ipaddr 2>/dev/null)
if [ -z "$IP" ]; then
	IP=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
fi

if [ -z "$IP" ]; then
	_warn "IP роутера не определён — CGI не проверяю"
elif ! _have wget && ! _have curl; then
	_warn "ни wget, ни curl — CGI не проверяю"
else
	for path in \
		"/cgi-bin/usb-extroot-getfile?file=test.tar.gz" \
		"/cgi-bin/usb-extroot-upload?file=test.tar.gz"
	do
		url="http://$IP$path"
		code=""
		if _have curl; then
			code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null)
		elif _have wget; then
			# wget не отдаёт HTTP-код напрямую, ловим через --server-response
			code=$(wget --server-response --spider --timeout=3 "$url" 2>&1 \
				| awk '/HTTP\//{c=$2} END{print c}')
		fi
		case "$code" in
			403) _ok "$path -> 403 (ожидаемо, без токена)" ;;
			000|"") _fail "$path не отвечает" ;;
			*)
				# не должно случаться при отсутствии токена, но допустимо,
				# если CGI-фильтр ослаблен или IP не локальный
				_warn "$path -> $code (ожидалось 403)"
				;;
		esac
	done
fi

# ============================================================
#  Итог
# ============================================================
printf '\n'
if [ "$FAILS" -eq 0 ]; then
	if [ "$WARNS" -eq 0 ]; then
		printf "${CLR_GREEN}OK: всё в порядке.${CLR_RESET}\n"
	else
		printf "${CLR_GREEN}OK: критичных ошибок нет (warns: %s).${CLR_RESET}\n" "$WARNS"
	fi
	exit 0
fi

printf "${CLR_ORANGE}FAIL: критичных ошибок %s, предупреждений %s.${CLR_RESET}\n" "$FAILS" "$WARNS"
exit 1