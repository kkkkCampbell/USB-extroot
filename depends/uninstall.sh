#!/bin/sh
# ============================================================
#  uninstall.sh — удаление USB extroot.
#
#  Запуск: sh /opt/usb-extroot/uninstall.sh
#          sh /opt/usb-extroot/uninstall.sh --keep-backups
#
#  Удаляет:
#    - init.d/usb-extroot-autobackup (stop + disable + rm)
#    - 6 симлинков LuCI/rpcd/uhttpd
#    - /etc/config/usb-extroot
#    - /opt/usb-extroot/
#    - /tmp/usb-extroot/           (всегда, если не --keep-backups)
#
#  С --keep-backups:
#    - /tmp/usb-extroot/backups/   не удаляется (ОЗУ, но всё же)
#    - /overlay/usb-extroot-backups/         не удаляется
#    - /mnt/*/usb-extroot-backups/           не удаляется
#    - <active-extroot>/usb-extroot-backups/ не удаляется
#
#  После: rpcd + uhttpd перезапускаются.
# ============================================================

BASE_DIR="/opt/usb-extroot"
UE_RT="/tmp/usb-extroot"

CLR_RESET="\033[0m"
CLR_GREEN="\033[32m"
CLR_ORANGE="\033[38;5;208m"
CLR_YELLOW="\033[33m"

die()  { printf "${CLR_ORANGE}ОШИБКА: %s${CLR_RESET}\n" "$1" >&2; exit 1; }
ok()   { printf "  ${CLR_GREEN}[OK]${CLR_RESET}    %s\n" "$1"; }
warn() { printf "  ${CLR_YELLOW}[WARN]${CLR_RESET}  %s\n" "$1"; }

KEEP_BACKUPS=0
case "${1:-}" in
	--keep-backups) KEEP_BACKUPS=1 ;;
	--help|-h)
		printf 'Использование: %s [--keep-backups]\n' "$0"
		exit 0
		;;
	"") ;;
	*) die "Неизвестный аргумент: $1" ;;
esac

[ "$(id -u)" = "0" ] || die "Запустите от root"

printf '============================================================\n'
printf ' usb-extroot uninstall  (keep_backups=%s)\n' "$KEEP_BACKUPS"
printf '============================================================\n\n'

# ============================================================
#  init.d
# ============================================================
printf '==> init.d\n'
if [ -x /etc/init.d/usb-extroot-autobackup ]; then
	/etc/init.d/usb-extroot-autobackup stop    >/dev/null 2>&1 || true
	/etc/init.d/usb-extroot-autobackup disable >/dev/null 2>&1 || true
	rm -f /etc/init.d/usb-extroot-autobackup
	ok "init.d удалён"
else
	warn "init.d отсутствует"
fi
for rc in /etc/rc.d/S*usb-extroot-autobackup /etc/rc.d/K*usb-extroot-autobackup; do
	[ -e "$rc" ] && rm -f "$rc" 2>/dev/null || true
done

# ============================================================
#  Symlinks
# ============================================================
printf '\n==> Симлинки\n'
for l in \
	/usr/libexec/rpcd/luci.usb-extroot \
	/usr/share/rpcd/acl.d/luci-app-usb-extroot.json \
	/usr/share/luci/menu.d/luci-app-usb-extroot.json \
	/www/luci-static/resources/view/usb-extroot \
	/www/cgi-bin/usb-extroot-getfile \
	/www/cgi-bin/usb-extroot-upload
do
	if [ -L "$l" ] || [ -e "$l" ]; then
		rm -rf "$l"
		ok "удалён $l"
	else
		warn "не найден $l"
	fi
done

# Защита от оставшегося каталога (не симлинка)
if [ -d /www/luci-static/resources/view/usb-extroot ] && \
   [ ! -L /www/luci-static/resources/view/usb-extroot ]; then
	rm -rf /www/luci-static/resources/view/usb-extroot
	warn "удалён реальный каталог /www/.../usb-extroot"
fi

# ============================================================
#  UCI
# ============================================================
printf '\n==> UCI\n'
if [ -f /etc/config/usb-extroot ]; then
	rm -f /etc/config/usb-extroot
	ok "/etc/config/usb-extroot удалён"
else
	warn "/etc/config/usb-extroot отсутствует"
fi

# ============================================================
#  Бэкапы
# ============================================================
printf '\n==> Бэкапы\n'

if [ "$KEEP_BACKUPS" = "1" ]; then
	warn "--keep-backups: архивы НЕ удаляю"

	# Сообщаем, где они лежат — чтобы юзер знал.
	for d in \
		"$UE_RT/backups" \
		/overlay/usb-extroot-backups \
		/mnt/*/usb-extroot-backups
	do
		[ -d "$d" ] || continue
		n=$(ls -1 "$d"/*.tar.gz "$d"/*/*.tar.gz 2>/dev/null | wc -l)
		[ "$n" -gt 0 ] && printf '    сохранено: %s (%s архивов)\n' "$d" "$n"
	done

	# Удаляем только служебные подкаталоги, сами backups — оставляем.
	for d in \
		"$UE_RT/stage" \
		"$UE_RT/mnt" \
		"$UE_RT/err" \
		"$UE_RT/pkg" \
		"$UE_RT/lock"
	do
		[ -d "$d" ] && rm -rf "$d" && ok "удалён $d"
	done
	rm -f "$UE_RT/usb-extroot.log" \
	      "$UE_RT/usb-extroot.pid" \
	      "$UE_RT/reboot-now" \
	      "$UE_RT/reboot-cancel" \
	      "$UE_RT/autobackup.done" \
	      "$UE_RT/run.sh" 2>/dev/null || true
else
	if [ -d "$UE_RT/backups" ]; then
		rm -rf "$UE_RT/backups"
		ok "удалён $UE_RT/backups"
	fi
	if [ -d /overlay/usb-extroot-backups ]; then
		rm -rf /overlay/usb-extroot-backups
		ok "удалён /overlay/usb-extroot-backups"
	fi
	for d in /mnt/*/usb-extroot-backups; do
		[ -d "$d" ] || continue
		rm -rf "$d"
		ok "удалён $d"
	done
fi

# ============================================================
#  Runtime
# ============================================================
printf '\n==> Runtime\n'
if [ -d "$UE_RT" ]; then
	rm -rf "$UE_RT"
	ok "удалён $UE_RT"
else
	warn "$UE_RT отсутствует"
fi

# ============================================================
#  Base dir
# ============================================================
printf '\n==> Base dir\n'
if [ -d "$BASE_DIR" ]; then
	rm -rf "$BASE_DIR"
	ok "удалён $BASE_DIR"
else
	warn "$BASE_DIR отсутствует"
fi

# ============================================================
#  Перезапуск сервисов
# ============================================================
printf '\n==> Перезапуск сервисов\n'
/etc/init.d/rpcd   restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
ok "rpcd и uhttpd перезапущены"

printf '\n'
printf "${CLR_GREEN}============================================================${CLR_RESET}\n"
printf "${CLR_GREEN} usb-extroot удалён.${CLR_RESET}\n"
if [ "$KEEP_BACKUPS" = "1" ]; then
	printf "${CLR_YELLOW} Архивы сохранены (--keep-backups).${CLR_RESET}\n"
fi
printf "${CLR_GREEN}============================================================${CLR_RESET}\n"

exit 0