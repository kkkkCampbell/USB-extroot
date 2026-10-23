#!/bin/sh
# ============================================================
#  usb-extroot.sh  v0.1.39-draft
#  Перенос overlay OpenWrt на USB-накопитель (extroot)
#  Лог: /tmp/usb-extroot.log
#  Бэкап: /tmp/.usb-extroot-x7k2m9q4p1w8/
#
#  sh <( wget -qO- https://raw.githubusercontent.com/kkkkCampbell/USB-extroot/refs/heads/draft/usb-extroot-install.sh )
#  sh /usb-extroot-install.sh
# ============================================================
ver="v0.1.39-draft"

# ------------------------------------------------------------
#  1. Парсинг аргументов.
# ------------------------------------------------------------
BATCH=0
BATCH_MODE=""
BATCH_DEVICE=""
BATCH_TARGET=""
BATCH_CONFIRM=""
BATCH_ACTION=""
BATCH_ARCHIVE=""
ARCHIVE_WAIT=30

for _a in "$@"; do
	case "$_a" in
		--version)          echo "$ver"; exit 0 ;;
		--batch)            BATCH=1 ;;
		--mode=*)           BATCH_MODE="${_a#*=}" ;;
		--device=*)         BATCH_DEVICE="${_a#*=}" ;;
		--target=*)         BATCH_TARGET="${_a#*=}" ;;
		--confirm=*)        BATCH_CONFIRM="${_a#*=}" ;;
		--action=*)         BATCH_ACTION="${_a#*=}" ;;
		--archive=*)        BATCH_ARCHIVE="${_a#*=}" ;;
		--archive-wait=*)   ARCHIVE_WAIT="${_a#*=}" ;;
	esac
done

if [ "$BATCH" = "1" ]; then
	export BATCH BATCH_MODE BATCH_DEVICE BATCH_TARGET BATCH_CONFIRM BATCH_ACTION BATCH_ARCHIVE ARCHIVE_WAIT
fi

# ------------------------------------------------------------
#  МГНОВЕННАЯ ИНИЦИАЛИЗАЦИЯ PID И ЛОГА
# ------------------------------------------------------------
PID_FILE="${USB_EXTROOT_PID_FILE:-/tmp/usb-extroot.pid}"
LOG=/tmp/usb-extroot.log
LOCK_DIR="${USB_EXTROOT_LOCK_DIR:-}"

_cleanup_pid_and_lock() {
	rm -f "$PID_FILE"
	if [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then
		rm -rf "$LOCK_DIR"
	fi
}

if [ "$BATCH" = "1" ] && [ -z "$BATCH_ACTION" ]; then
	if [ "$BATCH_MODE" = "backup" ] && [ -f "$PID_FILE" ]; then
		existing_pid=$(cat "$PID_FILE" 2>/dev/null)
		if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
			echo "autobackup: другое действие выполняется (PID $existing_pid), пропуск"
			exit 0
		fi
		rm -f "$PID_FILE"
	fi

	if [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then
		echo $$ > "$LOCK_DIR/pid"
	fi

	echo $$ > "$PID_FILE"
	trap '_cleanup_pid_and_lock; pkg_repair_finish; share_down; exit 130' INT TERM HUP
	trap '_cleanup_pid_and_lock' EXIT

	exec > "$LOG" 2>&1
	echo "=== СТАРТ ОПЕРАЦИИ: $(date) ==="
fi

# ------------------------------------------------------------
#  2. Самопереезд в RAM.
# ------------------------------------------------------------
path="/opt/usb-extroot"
TEST_MODE=0
if [ ! -d "/opt/usb-extroot" ]; then mkdir -p "/opt/usb-extroot"; fi

case "$0" in
	/tmp/*|/dev/shm/*|/run/*) ;;
	*)
		if [ -z "$BATCH_ACTION" ] && [ "$BATCH" != "1" ] && [ -f "$0" ] && [ -w /tmp ]; then
			SELF_RAM=/tmp/.usb-extroot-run.sh
			if cp "$0" "$SELF_RAM" 2>/dev/null; then
				chmod +x "$SELF_RAM" 2>/dev/null
				exec /bin/sh "$SELF_RAM" "$@"
			fi
		fi
		;;
esac

# ------------------------------------------------------------
#  3. Цвета
# ------------------------------------------------------------
if [ "$BATCH" = "1" ]; then
	CLR_RESET=""
	CLR_GREEN=""
	CLR_ORANGE=""
	CLR_YELLOW=""
else
	CLR_RESET="\033[0m"
	CLR_GREEN="\033[32m"
	CLR_ORANGE="\033[38;5;208m"
	CLR_YELLOW="\033[33m"
fi

TEST_MODE="${TEST_MODE:-0}"

PKG_REPAIR_ACTIVE=0
PKG_REPAIR_OLD_DNS=""
PKG_REPAIR_Z_STAT=""
PKG_REPAIR_Z2_STAT=""
PKG_REPAIR_Y_STAT=""
PKG_REPAIR_DNS_CHANGED=0
PKG_REPAIR_SVC_STOPPED=0

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------
#  Универсальный пакетный менеджер
# ------------------------------------------------------------
opkg_cmd="opkg"
pkg_install_cmd="install"
pkg_update_cmd="update"
if have apk; then
	opkg_cmd="apk"
	pkg_install_cmd="add"
fi

WANT_PKGS="block-mount uci tar e2fsprogs kmod-usb-storage kmod-usb-storage-uas kmod-fs-vfat kmod-fs-exfat kmod-fs-ext4"

# ------------------------------------------------------------
#  Проверки пакетов
# ------------------------------------------------------------
fs_in_kernel() {
	local fs="$1"
	grep -qw "$fs" /proc/filesystems 2>/dev/null && return 0
	find "/lib/modules/$(uname -r)" -name "${fs}.ko*" 2>/dev/null | grep -q . && return 0
	return 1
}

ext4_in_kernel() { fs_in_kernel ext4; }

usb_storage_in_kernel() {
	lsmod 2>/dev/null | grep -q '^usb_storage[[:space:]]' && return 0
	find "/lib/modules/$(uname -r)" -name 'usb-storage.ko*' 2>/dev/null | grep -q . && return 0
	return 1
}

uas_in_kernel() {
	lsmod 2>/dev/null | grep -q '^uas[[:space:]]' && return 0
	find "/lib/modules/$(uname -r)" -name 'uas.ko*' 2>/dev/null | grep -q . && return 0
	return 1
}

tar_is_full() {
	local t
	t=$(command -v tar 2>/dev/null) || return 1
	case "$(readlink -f "$t" 2>/dev/null)" in
		*/busybox|*/busybox.*) return 1 ;;
	esac
	tar --version 2>/dev/null | grep -qE 'GNU tar|bsdtar' && return 0
	return 1
}

pkg_present() {
	case "$1" in
		block-mount)          have block ;;
		uci)                  have uci ;;
		tar)                  tar_is_full ;;
		e2fsprogs)            have mkfs.ext4 ;;
		kmod-fs-ext4)         fs_in_kernel ext4 ;;
		kmod-fs-vfat)         fs_in_kernel vfat ;;
		kmod-fs-exfat)        fs_in_kernel exfat ;;
		kmod-usb-storage)     usb_storage_in_kernel ;;
		kmod-usb-storage-uas) uas_in_kernel ;;
		wget-ssl)             have wget ;;
		*)                    return 1 ;;
	esac
}

# ============================================================
#  Поиск устройства внутреннего overlay.
# ============================================================
find_internal_overlay_dev() {
	local nf d existing tmpmnt ok fs_type cur_overlay_dev
	local found=""
	local count=0

	cur_overlay_dev=$(quick_overlay_dev)

	for nf in /sys/class/ubi/ubi*_*/name; do
		[ -f "$nf" ] || continue
		[ "$(cat "$nf" 2>/dev/null)" = "rootfs_data" ] || continue
		d=$(basename "$(dirname "$nf")")
		[ -c "/dev/$d" ] || continue
		found="$found /dev/$d"
		count=$((count + 1))
	done

	for d in $(block info 2>/dev/null | awk -F: '{print $1}'); do
		[ -b "$d" ] || continue
		[ "$d" = "$cur_overlay_dev" ] && continue
		is_removable_storage "$d" && continue
		case " $found " in *" $d "*) continue ;; esac

		fs_type=$(block info "$d" 2>/dev/null | grep -o 'TYPE="[^"]*"' | cut -d'"' -f2)
		case "$fs_type" in
			ext4|f2fs|btrfs|ubifs) ;;
			*) continue ;;
		esac

		existing=$(awk -v x="$d" '$1==x {print $2; exit}' /proc/mounts)
		ok=0

		if [ -n "$existing" ]; then
			if [ -d "$existing/upper" ] && [ -d "$existing/work" ] && [ -d "$existing/upper/etc/config" ]; then
				ok=1
			fi
		else
			tmpmnt="/tmp/.ovl_probe.$$"
			mkdir -p "$tmpmnt" 2>/dev/null || continue
			if timeout 10 mount -o ro "$d" "$tmpmnt" 2>/dev/null; then
				if [ -d "$tmpmnt/upper" ] && [ -d "$tmpmnt/work" ] && [ -d "$tmpmnt/upper/etc/config" ]; then
					ok=1
				fi
				umount "$tmpmnt" 2>/dev/null || umount -l "$tmpmnt" 2>/dev/null || true
			fi
			rmdir "$tmpmnt" 2>/dev/null || true
		fi

		if [ "$ok" = "1" ]; then
			found="$found $d"
			count=$((count + 1))
		fi
	done

	case "$count" in
		0) return 1 ;;
		1) echo "$found" | sed 's/^ //'; return 0 ;;
		*) echo "$found" | sed 's/^ //'; return 2 ;;
	esac
}

# ============================================================
#  Шара для доступа к бэкапу по локалке
# ============================================================
share_up() {
	if [ "$BATCH" = "1" ]; then return 0; fi

	grep -q "^12345:" /etc/passwd || \
		echo "12345:x:1000:1000:12345:/var:/bin/false" >> /etc/passwd
	if have ksmbd.useradmin; then
		printf "12345\n12345\n" | ksmbd.useradmin -a 12345 >/dev/null 2>&1
	fi

	if [ -x /etc/init.d/ksmbd ]; then
		uci -q set ksmbd.global=ksmbd
		uci -q set ksmbd.global.interface='br-lan'
		uci -q set ksmbd.global.workgroup='WORKGROUP'
		uci -q set ksmbd.global.allow_guest_ipc='1'

		uci -q delete ksmbd.overlaybackup
		uci -q set ksmbd.overlaybackup=share
		uci -q set ksmbd.overlaybackup.name='overlaybackup'
		uci -q set ksmbd.overlaybackup.path="${BACKUP_DIR:-/tmp/.usb-extroot-x7k2m9q4p1w8}"
		uci -q set ksmbd.overlaybackup.comment='Extroot Emergency Backup'
		uci -q set ksmbd.overlaybackup.browseable='yes'
		uci -q set ksmbd.overlaybackup.read_only='no'
		uci -q set ksmbd.overlaybackup.guest_ok='yes'
		uci -q set ksmbd.overlaybackup.users='12345'
		uci -q commit ksmbd

		/etc/init.d/ksmbd restart >/dev/null 2>&1 &
	fi
}

share_down() {
	if uci -q get ksmbd.overlaybackup >/dev/null 2>&1; then
		uci -q delete ksmbd.overlaybackup
		uci -q commit ksmbd
	fi

	if have ksmbd.useradmin; then
		ksmbd.useradmin -d 12345 >/dev/null 2>&1
	fi

	sed -i '/^12345:/d' /etc/passwd 2>/dev/null
	if [ -f /etc/shadow ]; then
		sed -i '/^12345:/d' /etc/shadow 2>/dev/null
	fi
}

trap 'echo; echo "Прервано. Восстанавливаю состояние..."; pkg_repair_finish; share_down; exit 130' INT TERM HUP

pkg_repair_finish() {
	[ "$PKG_REPAIR_ACTIVE" = "1" ] || return 0

	if [ "$PKG_REPAIR_DNS_CHANGED" = "1" ]; then
		uci -q del dhcp.@dnsmasq[0].noresolv
		if [ -n "$PKG_REPAIR_OLD_DNS" ]; then
			uci set dhcp.@dnsmasq[0].server="$PKG_REPAIR_OLD_DNS"
		else
			uci -q del dhcp.@dnsmasq[0].server
		fi
		uci commit dhcp 2>/dev/null
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
	fi

	if [ "$PKG_REPAIR_Z_STAT" = "running" ] && [ -x /etc/init.d/zapret ]; then
		/etc/init.d/zapret start >/dev/null 2>&1
	fi
	if [ "$PKG_REPAIR_Z2_STAT" = "running" ] && [ -x /etc/init.d/zapret2 ]; then
		/etc/init.d/zapret2 start >/dev/null 2>&1
	fi
	if [ "$PKG_REPAIR_Y_STAT" = "running" ] && [ -x /etc/init.d/youtubeUnblock ]; then
		/etc/init.d/youtubeUnblock start >/dev/null 2>&1
	fi

	PKG_REPAIR_ACTIVE=0
}

soft_reboot_with_fallback() {
	local delay="${1:-40}"

	sync
	sleep 3

	if [ "$BATCH" = "1" ] && [ -n "$ARCHIVE_WAIT" ] && [ "$ARCHIVE_WAIT" -gt 0 ]; then
		echo
		echo -e "${CLR_GREEN}================================================================${CLR_RESET}"
		echo -e "${CLR_GREEN} Подготовка к перезагрузке.${CLR_RESET}"
		echo
		echo -e "${CLR_YELLOW} Доступ к бэкапу (если создан):${CLR_RESET}"
		echo -e "   SMB: \\\\\\\\$(get_router_ip)\\overlaybackup"
		echo -e "   user: 12345   password: 12345"
		echo
		echo -e "${CLR_ORANGE} Перезагрузка через ${ARCHIVE_WAIT} секунд...${CLR_RESET}"
		echo -e "${CLR_GREEN}================================================================${CLR_RESET}"
		sleep "$ARCHIVE_WAIT"
	fi

	setsid sh -c "
		trap '' TERM
		sleep $delay
		echo b > /proc/sysrq-trigger
		sleep 1
		reboot -f
	" &

	sleep 2
	if [ "$MODE" = "noformat" ] || [ "$MODE" = "restore" ]; then
		reboot -f
	fi
	reboot
	echo "Перезагружаю роутер..."
}

confirm_reboot_or_die() {
	local need_share_down="${1:-0}"
	local cancel=0 i

	if [ "$BATCH" = "1" ]; then
		[ "$need_share_down" = "1" ] && share_down
		sync
		sleep 2
		soft_reboot_with_fallback 40
		return
	fi

	echo
	echo -e "${CLR_ORANGE}!!! ПЕРЕЗАГРУЗКА ЧЕРЕЗ 10 СЕКУНД !!!${CLR_RESET}"
	echo "    Любая клавиша — отмена."

	i=10
	while [ $i -gt 0 ]; do
		printf "\r    осталось: %2d " "$i"
		if read -t 1 -n 1 _ 2>/dev/null; then
			cancel=1
			break
		fi
		i=$((i-1))
	done
	printf "\r    осталось:  0 \n"

	if [ "$cancel" = "1" ]; then
		echo
		echo -e "${CLR_ORANGE}############################################################${CLR_RESET}"
		echo -e "${CLR_ORANGE}#  ПЕРЕЗАГРУЗКА НЕ ВЫПОЛНЕНА${CLR_RESET}"
		echo -e "${CLR_ORANGE}############################################################${CLR_RESET}"
		echo
		echo "Система в неопределённом состоянии!"
		echo
		echo "НИЧЕГО НЕ ТРОГАЙ и не запускай скрипт повторно,"
		echo "пока не перезагрузишь роутер командой:"
		echo
		echo -e "    ${CLR_YELLOW}reboot${CLR_RESET}"
		echo
		exit 1
	fi

	[ "$need_share_down" = "1" ] && share_down

	echo "    Перезагружаюсь..."
	echo -e "${CLR_ORANGE}    При перезагрузке  возможно зависание роутера!"
	echo -e "    Перезапустите роутер отключив и подав питание.${CLR_RESET}"
	sync
	sleep 2
	soft_reboot_with_fallback 40
}

die() {
	pkg_repair_finish
	echo
	echo -e "${CLR_ORANGE}############################################################${CLR_RESET}"
	echo -e "${CLR_ORANGE}#  ОШИБКА: $1${CLR_RESET}"
	echo -e "${CLR_ORANGE}############################################################${CLR_RESET}"
	echo
	echo "$2"
	echo
	echo -e "${CLR_ORANGE}############################################################${CLR_RESET}"
	echo
	exit 1
}

fatal() {
	pkg_repair_finish
	FATAL_STAGE="$1"
	echo
	echo -e "${CLR_ORANGE}############################################################${CLR_RESET}"
	echo -e "${CLR_ORANGE}#  СТОП: $1${CLR_RESET}"
	echo -e "${CLR_ORANGE}############################################################${CLR_RESET}"
	echo
	echo "$2"
	echo
	cp /tmp/usb-extroot.log "${BACKUP_DIR:-/tmp/.usb-extroot-x7k2m9q4p1w8}/" 2>/dev/null || true
	shout_fatal
	exit 1
}

detect_pm() {
	if command -v apk  >/dev/null 2>&1; then echo apk
	elif command -v opkg >/dev/null 2>&1; then echo opkg
	else echo none
	fi
}

parent_dev() {
	local d="$1"
	case "$d" in
		/dev/mmcblk*p[0-9]*) echo "${d%p[0-9]*}" ;;
		/dev/sd[a-z][0-9]*)  echo "${d%[0-9]*}" ;;
		/dev/nvme*n*p[0-9]*) echo "${d%p[0-9]*}" ;;
		/dev/vd[a-z][0-9]*)  echo "${d%[0-9]*}" ;;
		*)                   echo "$d" ;;
	esac
}

is_usb() {
	local b=$(basename "$1")
	case "$b" in
		sd[a-z][0-9]*|mmcblk[0-9]*p[0-9]*)
			b=$(basename "$(parent_dev "/dev/$b")")
			;;
	esac

	case "$(readlink -f /sys/block/$b 2>/dev/null)" in *"/usb"*) return 0;; esac

	case "$(cat /sys/block/$b/device/uevent 2>/dev/null)" in
		*DRIVER=uas*|*DRIVER=usb-storage*|*USB*) return 0;;
	esac

	case "$(cat /sys/block/$b/device/../../uevent 2>/dev/null)" in
		*DRIVER=uas*|*DRIVER=usb-storage*|*USB*) return 0;;
	esac

	return 1
}

is_internal_dev() {
	local parent
	case "$1" in
		/dev/ubi*|/dev/mtdblock*|/dev/root) return 0;;
	esac

	parent=$(basename "$(parent_dev "$1")")
	case "$parent" in
		mmcblk[0-9]*)
			[ "$(cat /sys/block/$parent/removable 2>/dev/null)" = "0" ] && return 0
			;;
	esac
	return 1
}

is_removable_storage() {
	local parent
	parent=$(basename "$(parent_dev "$1")")

	case "$parent" in
		sd[a-z])
			is_usb "/dev/$parent"
			return $?
			;;
		mmcblk[0-9]*)
			[ "$(cat /sys/block/$parent/removable 2>/dev/null)" = "1" ]
			return $?
			;;
	esac
	return 1
}

describe() {
	local dev="$1" b parent
	b=$(basename "$1")

	case "$b" in
		sd[a-z][0-9]*|mmcblk[0-9]*p[0-9]*|nvme[0-9]*n[0-9]*p[0-9]*|vd[a-z][0-9]*)
			parent=$(basename "$(parent_dev "$dev")")
			;;
		*)
			parent="$b"
			;;
	esac

	local vendor=$(cat /sys/block/$parent/device/vendor 2>/dev/null | tr -d '\n')
	local model=$(cat /sys/block/$parent/device/model  2>/dev/null | tr -d '\n')
	local blocks=$(cat /sys/block/$parent/size 2>/dev/null)
	local size=$(awk -v x="$blocks" 'BEGIN{printf "%.1fG", x*512/1024/1024/1024}')
	local name=$(echo "${vendor} ${model}" | tr -s ' ')
	echo "$dev $size $name"
}

get_router_ip() {
	local ip
	ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
	if [ -n "$ip" ]; then echo "$ip"; return; fi
	ip=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
	if [ -n "$ip" ]; then echo "$ip"; return; fi
	ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
	if [ -n "$ip" ]; then echo "$ip"; return; fi
	echo "<ip-роутера>"
}

shout_fatal() {
	local rip=$(get_router_ip)
	local share_present=0
	uci -q get ksmbd.overlaybackup >/dev/null 2>&1 && share_present=1

	echo -e "${CLR_ORANGE}------------------------------------------------------------${CLR_RESET}"
	echo -e "${CLR_ORANGE} Этап: ${FATAL_STAGE:-<неизвестен>}${CLR_RESET}"
	echo
	echo -e "${CLR_YELLOW} Бэкап overlay (если создан):${CLR_RESET}"
	echo "    ${BACKUP_DIR:-/tmp/.usb-extroot-x7k2m9q4p1w8}/"
	echo "    (в ОЗУ — исчезнет при ребуте, скопируй сейчас, если нужен)"
	echo

	if [ "$share_present" = "1" ]; then
		echo -e "  Доступ к бэкапу по локальной сети: "
		echo -e "  ${CLR_YELLOW}\\\\\\\\$(get_router_ip)\\overlaybackup${CLR_RESET}"
		echo -e "  user: 12345   password: 12345"
		echo
	fi

	echo -e "${CLR_YELLOW} НЕ ПЕРЕЗАГРУЖАЙ РОУТЕР, пока не убедишься, что:${CLR_RESET}"
	echo "    - /overlay смонтирован и доступен"
	echo "    - fstab.extroot не указывает на USB"
	echo "    - из бэкапа можно вернуть данные"
	echo -e "${CLR_ORANGE}------------------------------------------------------------${CLR_RESET}"
	echo
}

pkg_repair_start() {
	have uci || return 1

	PKG_REPAIR_OLD_DNS=""
	PKG_REPAIR_Z_STAT=""
	PKG_REPAIR_Z2_STAT=""
	PKG_REPAIR_Y_STAT=""
	PKG_REPAIR_DNS_CHANGED=0
	PKG_REPAIR_SVC_STOPPED=0

	if [ -x /etc/init.d/zapret ]; then
		PKG_REPAIR_Z_STAT=$(/etc/init.d/zapret status 2>/dev/null)
	fi
	if [ -x /etc/init.d/zapret2 ]; then
		PKG_REPAIR_Z2_STAT=$(/etc/init.d/zapret2 status 2>/dev/null)
	fi
	if [ -x /etc/init.d/youtubeUnblock ]; then
		PKG_REPAIR_Y_STAT=$(/etc/init.d/youtubeUnblock status 2>/dev/null)
	fi

	if [ "$PKG_REPAIR_Z_STAT" = "running" ]; then
		echo "        останавливаю zapret"
		/etc/init.d/zapret stop >/dev/null 2>&1
		PKG_REPAIR_SVC_STOPPED=1
	fi
	if [ "$PKG_REPAIR_Z2_STAT" = "running" ]; then
		echo "        останавливаю zapret2"
		/etc/init.d/zapret2 stop >/dev/null 2>&1
		PKG_REPAIR_SVC_STOPPED=1
	fi
	if [ "$PKG_REPAIR_Y_STAT" = "running" ]; then
		echo "        останавливаю youtubeUnblock"
		/etc/init.d/youtubeUnblock stop >/dev/null 2>&1
		PKG_REPAIR_SVC_STOPPED=1
	fi

	PKG_REPAIR_OLD_DNS=$(uci -q get dhcp.@dnsmasq[0].server)
	uci set dhcp.@dnsmasq[0].noresolv='1'
	uci -q del dhcp.@dnsmasq[0].server
	uci add_list dhcp.@dnsmasq[0].server='9.9.9.11'
	if uci commit dhcp 2>/dev/null; then
		PKG_REPAIR_DNS_CHANGED=1
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
	fi

	local DOMAINS="openwrt.org downloads.openwrt.org packages.routerich.ru routerich.ru github.com raw.githubusercontent.com"
	if have nslookup; then
		for d in $DOMAINS; do
			nslookup "$d" >/dev/null 2>&1
		done
	fi
	sleep 3

	local pm
	pm=$(detect_pm)
	case "$pm" in
		apk)
			echo "        apk update"
			apk update >/dev/null 2>&1
			;;
		opkg)
			echo "        opkg update"
			opkg update >/dev/null 2>&1
			;;
		*)
			echo "        нет apk/opkg — индексы не обновляю"
			;;
	esac

	PKG_REPAIR_ACTIVE=1

	if [ "$PKG_REPAIR_DNS_CHANGED" = "1" ] || [ "$PKG_REPAIR_SVC_STOPPED" = "1" ]; then
		return 0
	fi
	return 1
}

fix_uboot_env() {
	return
	if have fw_printenv && have fw_setenv; then
		if fw_printenv 2>/dev/null | grep -q '^owrt_country='; then
			a=a
		else
			fw_setenv owrt_country RU
		fi
		if fw_printenv 2>/dev/null | grep -q '^owrt_ssid='; then
			fw_setenv owrt_ssid
		else
			a=a
		fi
		if fw_printenv 2>/dev/null | grep -q '^owrt_wifi_key='; then
			fw_setenv owrt_wifi_key
		else
			a=a
		fi
	else
		a=a
	fi
}

get_current_overlay() {
	local mp
	mp=$(awk '$2=="/overlay" {print $2; exit}' /proc/mounts)
	if [ -z "$mp" ]; then
		if [ -d /rom/overlay/upper ]; then
			mp=/rom/overlay
		else
			mp=/overlay
		fi
	fi
	echo "$mp"
}

storage_quick_check() {
	for d in /dev/sd? /dev/mmcblk?; do
		[ -b "$d" ] || continue
		is_removable_storage "$d" || continue
		return 0
	done
	return 1
}

pkg_ensure() {
	local missing="" p
	for p in $WANT_PKGS; do
		pkg_present "$p" || missing="$missing $p"
	done
	missing=$(echo "$missing" | sed 's/^ *//; s/ *$//')
	if [ -z "$missing" ]; then
		echo "      все зависимости на месте"
		return 0
	fi
	echo "      доустанавливаю: $missing"
	$opkg_cmd $pkg_update_cmd >/dev/null 2>&1 || true
	if ! $opkg_cmd $pkg_install_cmd $missing >/dev/null 2>&1; then
		echo -e "${CLR_ORANGE}      установка не удалась${CLR_RESET}"
		return 1
	fi
	echo -e "${CLR_GREEN}      установлено${CLR_RESET}"
	return 0
}

stage0_deps() {
	local mode="${1:-install}"

	echo
	STAGE0="[0/9] зависимости"
	echo "$STAGE0 ..."
	echo "      менеджер пакетов: $opkg_cmd"

	if ! pkg_ensure; then
		if [ "$mode" = "check" ]; then
			echo -e "${CLR_ORANGE}      часть зависимостей недоступна — продолжаю${CLR_RESET}"
			return 0
		fi
		die "$STAGE0" "Зависимости отсутствуют.

	Проверь вручную:
	  $opkg_cmd $pkg_update_cmd
	  $opkg_cmd $pkg_install_cmd $WANT_PKGS"
	fi
	echo -e "${CLR_GREEN}      tar: $(tar --version 2>&1 | head -1)${CLR_RESET}"
	echo -e "${CLR_GREEN}      зависимости на месте${CLR_RESET}"
}

stage1_overlay() {
	echo
	STAGE1="[1/9] текущий overlay"
	echo "$STAGE1 ..."

	echo "      overlay: $CUR_OVERLAY_MP"

	if [ -z "$CUR_OVERLAY_DEV" ]; then
		die "$STAGE1" "Не нашёл устройство $CUR_OVERLAY_MP.

	Проверь вручную:
	  mount | grep overlay
	  cat /proc/mounts | grep overlay"
	fi
	echo "      устройство: $CUR_OVERLAY_DEV"

	ORIG_DEV="$CUR_OVERLAY_DEV"

	if is_internal_dev "$CUR_OVERLAY_DEV"; then
		echo "      ок, внутренний: $ORIG_DEV"
	else
		echo -e "${CLR_ORANGE}      /overlay УЖЕ на внешнем носителе: $CUR_OVERLAY_DEV${CLR_RESET}"
		echo -e "${CLR_ORANGE}      Это повторный перенос на другой накопитель.${CLR_RESET}"
	fi
}

stage2_find_usb() {
	echo
	STAGE2="[2/9] поиск внешнего накопителя"
	echo "$STAGE2 ..."

	local skip_parent=$(parent_dev "$CUR_OVERLAY_DEV")

	ALL=""
	for d in /dev/sd? /dev/mmcblk?; do
		[ -b "$d" ] && ALL="$ALL $d"
	done
	CAND=""
	for d in $ALL; do
		[ "$(parent_dev "$d")" = "$skip_parent" ] && continue

		b=$(basename "$d")
		case "$b" in
			mmcblk[0-9]*) [ "$(cat /sys/block/$b/removable 2>/dev/null)" = "0" ] && continue ;;
		esac

		CAND="$CAND $d"
	done

	USB_PRESENT=0
	TARGET=""
	PART=""
	FS=""
	DESC=""

	if [ -z "$CAND" ]; then
		return 1
	fi

	DISKS=""
	for d in $CAND; do
		case "$(basename $d)" in
			sd[a-z]|mmcblk[0-9]*) DISKS="$DISKS $d";;
		esac
	done

	if [ -z "$DISKS" ]; then
		return 1
	fi

	USB_PRESENT=1
	set -- $DISKS

	echo "Найдены внешние накопители:"
	n=0
	for d in $DISKS; do
		n=$((n + 100))
		echo -e "  ${CLR_YELLOW}$n -> ${CLR_GREEN}$(describe $d)  ${CLR_RESET}"
	done
	echo

	if [ "$BATCH" = "1" ]; then
		ok=0
		for d in $DISKS; do
			if [ "$d" = "$BATCH_DEVICE" ] || [ "$(parent_dev "$BATCH_DEVICE")" = "$d" ]; then
				TARGET="$d"
				ok=1
				break
			fi
		done
		if [ "$ok" != "1" ]; then
			echo -e "${CLR_ORANGE}      batch: устройство '$BATCH_DEVICE' не найдено среди целей${CLR_RESET}"
			echo "      доступно: $DISKS"
			exit 2
		fi
		echo -e "      batch: выбрано $TARGET (раздел: $BATCH_DEVICE)"
	else
		printf "${CLR_RESET}Укажите целевой накопитель (введите число слева, 0 — отмена): "
		read CHOSEN

		case "$CHOSEN" in
			0|"")
				echo "Отменено."
				exit 0
				;;
		esac

		ok=0
		n=0
		for d in $DISKS; do
			n=$((n + 100))
			if [ "$n" = "$CHOSEN" ]; then
				TARGET="$d"
				ok=1
				break
			fi
		done

		if [ "$ok" != "1" ]; then
			die "$STAGE2" "Выбран несуществующий номер: $CHOSEN"
		fi
	fi

	DESC=$(describe "$TARGET")
	echo -e "      найден: ${CLR_YELLOW}$DESC${CLR_RESET}"

	PARTS=""
	for p in ${TARGET}*; do
		[ -b "$p" ] || continue
		case "$(basename $p)" in
			sd[a-z][0-9]*|mmcblk[0-9]*p[0-9]*) ;;
			*) continue;;
		esac
		PARTS="$PARTS $p"
	done
	[ -z "$PARTS" ] && PARTS="$TARGET"

	if [ "$BATCH" = "1" ] && [ -b "$BATCH_DEVICE" ]; then
		PART="$BATCH_DEVICE"
	else
		PART=$(echo $PARTS | awk '{print $1}')
	fi

	block info "$PART" >/dev/null 2>&1
	FS=$(block info "$PART" 2>/dev/null | grep -o 'TYPE="[^"]*"' | cut -d'"' -f2)

	if [ "$MODE" = "noformat" ]; then
		if [ "$FS" != "ext4" ]; then
			die "$STAGE2" "Нужна существующая ФС ext4 на $PART.
	Текущая: FS=${FS:--}."
		fi
	fi

	echo -e "      ЦЕЛЬ:${CLR_YELLOW}   $DESC${CLR_RESET}"
	for p in $PARTS; do
		f=$(block info "$p" 2>/dev/null | grep -o 'TYPE="[^"]*"' | cut -d'"' -f2)
		m=$(block info "$p" 2>/dev/null | grep -o 'MOUNT="[^"]*"' | cut -d'"' -f2)
		echo "      $p FS=${f:--} ${m:+смонтирован $m}"
	done

	return 0
}

quick_overlay_dev() {
	local mp
	mp=$(get_current_overlay)
	awk -v m="$mp" '$2==m {print $1; exit}' /proc/mounts
}

extroot_active() {
	local qdev
	qdev=$(quick_overlay_dev)
	[ -n "$qdev" ] || return 1
	is_internal_dev "$qdev" && return 1
	return 0
}

# ============================================================
#  BATCH: обработчики --action.
# ============================================================
if [ "$BATCH" = "1" ] && [ -n "$BATCH_ACTION" ]; then
	case "$BATCH_ACTION" in
		status)
			if awk '$2=="/rom/overlay" {f=1; exit} END{exit !f}' /proc/mounts; then
				echo "fallback=yes"
			else
				echo "fallback=no"
			fi
			qdev=$(quick_overlay_dev)
			if [ -n "$qdev" ] && ! is_internal_dev "$qdev"; then
				echo "extroot=yes"
				echo "extroot_dev=$qdev"
				echo "extroot_desc=$(describe "$qdev")"
			else
				echo "extroot=no"
			fi
			exit 0
			;;

		devices)
			for d in /dev/sd? /dev/mmcblk? /dev/nvme?n? /dev/vd?; do
				[ -b "$d" ] || continue

				if ! is_usb "/dev/$(basename $d)" && [ "$(cat /sys/block/$(basename $d)/removable 2>/dev/null)" != "1" ]; then
					case "$(basename $d)" in
						mmcblk[0-9]*) [ "$(cat /sys/block/$(basename $d)/removable 2>/dev/null)" = "0" ] && continue ;;
					esac
				fi

				for p in ${d}*; do
					[ -b "$p" ] || continue
					case "$(basename "$p")" in
						sd[a-z][0-9]*|mmcblk[0-9]*p[0-9]*|nvme[0-9]*n[0-9]*p[0-9]*|vd[a-z][0-9]*) ;;
						*) continue ;;
					esac

					fs=$(timeout 2 block info "$p" 2>/dev/null | grep -o 'TYPE="[^"]*"' | cut -d'"' -f2)

					if [ -z "$fs" ]; then
						fs=$(awk -v dev="$p" '$1==dev {print $3; exit}' /proc/mounts)
					fi

					if [ -z "$fs" ] && command -v blkid >/dev/null 2>&1; then
						fs=$(blkid -o value -s TYPE "$p" 2>/dev/null)
					fi

					if [ -n "$fs" ] && [ "$fs" != "squashfs" ] && [ "$fs" != "ubifs" ]; then
						echo "$p|${fs}|$(describe "$p")"
						break
					fi
				done
			done
			exit 0
			;;

		archive-info)
			latest=$(ls -t /tmp/.usb-extroot-*/overlay_backup_*.tar.gz 2>/dev/null | head -1)
			if [ -n "$latest" ] && [ -f "$latest" ]; then
				echo "exists=yes"
				echo "size=$(wc -c < "$latest" 2>/dev/null || echo 0)"
			else
				echo "exists=no"
			fi
			exit 0
			;;
		archive-list)
			seen=""
			for f in /tmp/*.tar.gz; do
				[ -f "$f" ] || continue
				size=$(wc -c < "$f" 2>/dev/null || echo 0)
				echo "tmp/$(basename "$f")|$size"
			done
			for mnt in $(awk '$3=="ext4" || $3=="f2fs" || $3=="btrfs" {print $2}' /proc/mounts); do
				dir="$mnt/usb-extroot-backups"
				[ -d "$dir" ] || continue
				case " $seen " in *" $dir "*) continue ;; esac
				seen="$seen $dir"
				for f in "$dir"/*.tar.gz; do
					[ -f "$f" ] || continue
					size=$(wc -c < "$f" 2>/dev/null || echo 0)
					echo "$(basename "$f")|$size"
				done
				if [ -d "$dir/manual" ]; then
					for f in "$dir/manual"/*.tar.gz; do
						[ -f "$f" ] || continue
						size=$(wc -c < "$f" 2>/dev/null || echo 0)
						echo "manual/$(basename "$f")|$size"
					done
				fi
			done
			exit 0
			;;
		*)
			echo "ERROR: unknown action '$BATCH_ACTION'" >&2
			exit 2
			;;
	esac
fi

EXTROOT_ACTIVE=0
EXTROOT_DEV=""
if extroot_active; then
	EXTROOT_ACTIVE=1
	EXTROOT_DEV=$(quick_overlay_dev)
fi

FALLBACK_ACTIVE=0
if awk '$2=="/rom/overlay" {found=1; exit} END{exit !found}' /proc/mounts; then
	FALLBACK_ACTIVE=1
fi

# ============================================================
#  Подтягивание модулей
# ============================================================
SRC_BASE="https://raw.githubusercontent.com/kkkkCampbell/USB-extroot/refs/heads/main"

_dep_looks_valid() {
	local f="$1" marker="$2"
	[ -f "$f" ] && [ -s "$f" ] || return 1
	head -n 5 "$f" | grep -qi '<html\|<!doctype' && return 1
	grep -q "$marker" "$f" || return 1
	return 0
}

_dep_fetch() {
	local url="$1" dst="$2" tmp
	tmp="${dst}.part"
	rm -f "$tmp"

	if have wget; then
		wget --timeout=3 -qO "$tmp" "$url" 2>/dev/null || { rm -f "$tmp"; return 1; }
	elif have curl; then
		curl -fsSL --connect-timeout 3 "$url" -o "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
	else
		return 1
	fi

	[ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
	mv "$tmp" "$dst"
	return 0
}

_dep_try_download() {
	local name="$1" marker="$2" out="$3"
	local url attempt
	url="$SRC_BASE/$name"
	attempt=0
	rm -f "$out"
	while [ "$attempt" -lt 3 ]; do
		if _dep_fetch "$url" "$out" && _dep_looks_valid "$out" "$marker"; then
			return 0
		fi
		attempt=$((attempt + 1))
		sleep 1
	done
	rm -f "$out"
	return 1
}

_dep_find_local() {
	local name="$1" marker="$2" src
	for src in "/root/$name" "/$name" "/opt/usb-extroot/$name" "/tmp/$name"; do
		if _dep_looks_valid "$src" "$marker"; then
			echo "$src"
			return 0
		fi
	done
	return 1
}

DEPS_LOADED=0
ensure_dependencies() {
	[ "$DEPS_LOADED" = "1" ] && return 0
	load_dependencies
	DEPS_LOADED=1
	return 0
}

load_dependencies() {

	local new_clone="/tmp/clone-overlay.sh.new"
	local new_switch="/tmp/switch-overlay.sh.new"
	local ok_clone=0 ok_switch=0
	local local_clone local_switch
	clear
	echo
	echo "Скачиваю модули с github"
	sleep 1
	echo "      проверяю модули..."

	if [ "$TEST_MODE" != "1" ]; then
		_dep_try_download "clone-overlay.sh"  "clone_overlay_interactive" "$new_clone"  && ok_clone=1
		_dep_try_download "switch-overlay.sh" "second_drive_menu"          "$new_switch" && ok_switch=1

		if [ "$ok_clone" = "1" ] && [ "$ok_switch" = "1" ]; then
			echo -e "${CLR_GREEN}      оба модуля получены с GitHub${CLR_RESET}"

			mv -f "$new_clone"  "/tmp/clone-overlay.sh"
			mv -f "$new_switch" "/tmp/switch-overlay.sh"

			if [ -w "$(dirname "$path")" ] || [ -w "$path" ]; then
				mkdir -p "$path" 2>/dev/null
				cp -f /tmp/clone-overlay.sh  "$path/clone-overlay.sh"  2>/dev/null
				cp -f /tmp/switch-overlay.sh "$path/switch-overlay.sh" 2>/dev/null
				echo "      сохранены в $path"
			fi

			. /tmp/clone-overlay.sh
			. /tmp/switch-overlay.sh
			sleep 2
			return 0
		fi

		rm -f "$new_clone" "$new_switch"
		echo -e "${CLR_ORANGE}      не оба модуля доступны с GitHub, использую локальные${CLR_RESET}"
	else
		echo -e "${CLR_YELLOW}      TEST_MODE=1 — GitHub не опрашиваю${CLR_RESET}"
	fi

	local_clone=$(_dep_find_local "clone-overlay.sh"  "clone_overlay_interactive")
	local_switch=$(_dep_find_local "switch-overlay.sh" "second_drive_menu")

	if [ -n "$local_clone" ]; then
		. "$local_clone"
		echo "      clone-overlay:  $local_clone"
	else
		echo -e "      clone-overlay:  ${CLR_ORANGE}не найден${CLR_RESET}"
	fi

	if [ -n "$local_switch" ]; then
		. "$local_switch"
		echo "      switch-overlay: $local_switch"
	else
		echo -e "      switch-overlay: ${CLR_ORANGE}не найден${CLR_RESET}"
	fi

	if [ -z "$local_clone" ] || [ -z "$local_switch" ]; then
		echo
		echo -e "${CLR_ORANGE}Модули недоступны частично или полностью.${CLR_RESET}"
		echo "  Пункт 4 меню может не работать."
	fi
	return 0
}

# ============================================================
#  Безусловное монтирование съёмных накопителей.
# ============================================================
mount_removable_all() {
	local d p base mnt fs any found listed parts_found w usb_ms _u

	any=0
	found=0
	flash=""

	if have modprobe; then
		modprobe usb-storage 2>/dev/null || modprobe usb_storage 2>/dev/null || true
		modprobe uas 2>/dev/null || true
		modprobe ext4 2>/dev/null || true
		modprobe vfat 2>/dev/null || true
		modprobe exfat 2>/dev/null || true
	fi

	usb_ms=0
	for _u in /sys/bus/usb/devices/*:*/bInterfaceClass; do
		[ -f "$_u" ] || continue
		[ "$(cat "$_u" 2>/dev/null)" = "08" ] && { usb_ms=1; break; }
	done
	if [ "$usb_ms" = "1" ]; then
		w=0
		while [ "$w" -lt 10 ]; do
			ls /dev/sd? >/dev/null 2>&1 && break
			sleep 1
			w=$((w + 1))
		done
	fi

	for d in /dev/sd? /dev/mmcblk?; do
		[ -b "$d" ] || continue
		is_removable_storage "$d" || continue
		found=$((found + 1))

		parts_found=0
		for p in ${d}*; do
			[ -b "$p" ] || continue
			case "$(basename "$p")" in
				sd[a-z][0-9]*|mmcblk[0-9]*p[0-9]*) parts_found=1 ;;
				*) continue ;;
			esac

			awk -v dev="$p" '$1==dev {f=1; exit} END{exit !f}' /proc/mounts && continue

			base=$(basename "$p")
			mnt="/mnt/$base"
			mkdir -p "$mnt" 2>/dev/null || continue

			if mount "$p" "$mnt" 2>/dev/null; then
				fs=$(awk -v m="$mnt" '$2==m {print $3; exit}' /proc/mounts)
				echo "      $p -> $mnt (${fs:-?})"
				any=1
			fi
		done

		if [ "$parts_found" = "0" ]; then
			awk -v dev="$d" '$1==dev {f=1; exit} END{exit !f}' /proc/mounts && continue
			base=$(basename "$d")
			mnt="/mnt/$base"
			mkdir -p "$mnt" 2>/dev/null || continue
			if mount "$d" "$mnt" 2>/dev/null; then
				fs=$(awk -v m="$mnt" '$2==m {print $3; exit}' /proc/mounts)
				echo "      $d -> $mnt (${fs:-?}, whole-disk)"
				any=1
			fi
		fi
	done

	if [ "$found" = "0" ]; then
		flash="no"
		echo "      (съёмных накопителей не обнаружено)"
		echo "        /dev:"
		listed=0
		for d in /dev/sd? /dev/mmcblk?; do
			[ -b "$d" ] || continue
			b=$(basename "$d")
			rem=$(cat /sys/block/$b/removable 2>/dev/null)
			real=$(readlink -f /sys/block/$b 2>/dev/null)
			echo "          $d removable=${rem:-?} path=${real:-<no sysfs>}"
			listed=1
		done
		[ "$listed" = "0" ] && echo "          пусто (нет /dev/sd*, /dev/mmcblk*)"

		echo "        lsmod:"
		lsmod 2>/dev/null | grep -E 'usb_storage|uas|usbcore|xhci|ehci|ohci' || echo "          (модули USB не загружены)"

		echo "        /sys/bus/usb/devices:"
		ls /sys/bus/usb/devices/ 2>/dev/null || echo "          (нет)"

		echo "        dmesg | tail -15:"
		dmesg 2>/dev/null | tail -15
	else
		flash="yes"
		[ "$any" = "0" ] && echo "      (найдено $found, все уже смонтированы, или не содержат распознанной ФС)"
	fi
	return 0
}

echo

if [ "$BATCH" = "1" ] && { [ -n "$BATCH_ACTION" ] || [ "$BATCH_MODE" = "reset_keep_extroot" ] || [ "$BATCH_MODE" = "restore" ] || [ "$BATCH_MODE" = "fallback-fix" ] || [ "$BATCH_MODE" = "restore_archive" ] || [ "$BATCH_MODE" = "backup" ] || [ "$BATCH_MODE" = "backup_manual" ]; }; then
	echo "      (режим $BATCH_ACTION $BATCH_MODE: пропускаю сканирование USB)"
else
	echo
	echo "Монтирую съёмные накопители..."
	mount_removable_all
fi

# ============================================================
#  BATCH: валидация аргументов перед стартом операции.
# ============================================================
if [ "$BATCH" = "1" ]; then
	if [ -z "$BATCH_MODE" ]; then
		echo "ERROR: --mode не указан" >&2
		exit 2
	fi
	case "$BATCH_MODE" in
		format|noformat|restore|fallback-fix|fallback_fix|restore_archive|backup|backup-manual|backup_manual|reset_keep_extroot) ;;
		*)
			echo "ERROR: неизвестный --mode='$BATCH_MODE'" >&2
			exit 2
			;;
	esac
	case "$BATCH_MODE" in
		format|noformat)
			if [ -z "$BATCH_DEVICE" ]; then
				echo "ERROR: --device не указан для mode=$BATCH_MODE" >&2
				exit 2
			fi
			;;
		restore_archive)
			if [ -z "$BATCH_DEVICE" ]; then
				echo "ERROR: --device не указан для mode=$BATCH_MODE" >&2
				exit 2
			fi
			if [ -z "$BATCH_ARCHIVE" ]; then
				echo "ERROR: --archive не указан для mode=$BATCH_MODE" >&2
				exit 2
			fi
			;;
		backup|backup-manual|backup_manual)
			;;
	esac
	if [ "$BATCH_CONFIRM" != "yes" ]; then
		echo "ERROR: --confirm=yes обязателен" >&2
		exit 2
	fi
	MODE=$(echo "$BATCH_MODE" | tr '-' '_')
	case "$MODE" in
		format)          CHOICE_TEXT="форматировать и перенести" ;;
		noformat)        CHOICE_TEXT="перенести без форматирования" ;;
		restore)         CHOICE_TEXT="восстановить загрузку с внутренней памяти" ;;
		fallback_fix)    CHOICE_TEXT="исправить аварийный режим" ;;
		restore_archive) CHOICE_TEXT="восстановление из архива" ;;
		backup)          CHOICE_TEXT="автобэкап" ;;
		backup_manual)   CHOICE_TEXT="ручной бэкап" ;;
		reset_keep_extroot) CHOICE_TEXT="сброс к заводским с сохранением загрузки с флэшки" ;;
	esac
	echo
	echo "============================================================"
	echo "  BATCH: mode=$MODE"
	[ -n "$BATCH_DEVICE" ] && echo "  device=$BATCH_DEVICE"
	[ -n "$BATCH_ARCHIVE" ] && echo "  archive=$BATCH_ARCHIVE"
	echo "============================================================"
fi

# ============================================================
#  ВЕТКА backup / backup_manual — снять снапшот /overlay/upper.
# ============================================================
if [ "$MODE" = "backup" ] || [ "$MODE" = "backup_manual" ]; then
	if [ "$MODE" = "backup_manual" ]; then
		BK_TYPE="manual"
		BK_PREFIX="USER_MANUAL_ARCHIVE"
		BK_ROTATE=50
		BK_SUBDIR="manual"
	else
		BK_TYPE="auto"
		BK_PREFIX="autobackup"
		BK_ROTATE=30
		BK_SUBDIR=""
	fi

	if [ "$BK_TYPE" = "auto" ] && [ -f /tmp/usb-extroot-autobackup.done ]; then
		echo "backup: уже выполнялся в эту загрузку, пропуск"
		exit 0
	fi

	if [ "$BK_TYPE" = "manual" ]; then
		have tar || die "$CHOICE_TEXT" "tar не найден."
		have uci || die "$CHOICE_TEXT" "uci не найден."
	fi

	BK_OVERLAY_DEV=$(quick_overlay_dev)
	if [ -z "$BK_OVERLAY_DEV" ]; then
		if [ "$BK_TYPE" = "manual" ]; then
			die "$CHOICE_TEXT" "Не нашёл устройство /overlay."
		fi
		echo "backup: /overlay не смонтирован, пропуск"
		exit 0
	fi

	if is_internal_dev "$BK_OVERLAY_DEV"; then
		if [ "$BK_TYPE" = "manual" ]; then
			die "$CHOICE_TEXT" "Overlay на внутреннем носителе ($BK_OVERLAY_DEV).
Manual backup доступен только когда /overlay на съёмной флешке."
		fi
		echo "backup: overlay на внутреннем носителе ($BK_OVERLAY_DEV), пропуск"
		exit 0
	fi

	BK_MNT=$(awk -v p="$BK_OVERLAY_DEV" '$1==p {print $2; exit}' /proc/mounts)
	if [ -z "$BK_MNT" ] || [ ! -d "$BK_MNT" ]; then
		if [ "$BK_TYPE" = "manual" ]; then
			die "$CHOICE_TEXT" "Не нашёл точку монтирования $BK_OVERLAY_DEV."
		fi
		echo "backup: нет точки монтирования для $BK_OVERLAY_DEV, пропуск"
		exit 0
	fi

	if [ ! -d "$BK_MNT/upper" ]; then
		if [ "$BK_TYPE" = "manual" ]; then
			die "$CHOICE_TEXT" "Нет $BK_MNT/upper."
		fi
		echo "backup: $BK_MNT/upper отсутствует, пропуск"
		exit 0
	fi

	BK_DIR="$BK_MNT/usb-extroot-backups"
	[ -n "$BK_SUBDIR" ] && BK_DIR="$BK_DIR/$BK_SUBDIR"

	if ! mkdir -p "$BK_DIR" 2>/dev/null; then
		if [ "$BK_TYPE" = "manual" ]; then
			die "$CHOICE_TEXT" "Не смог создать $BK_DIR."
		fi
		echo "backup: не смог создать $BK_DIR, пропуск"
		exit 0
	fi

	BK_UPPER_KB=$(du -sk "$BK_MNT/upper" 2>/dev/null | awk '{print $1}')
	BK_AVAIL_KB=$(df -k "$BK_MNT" 2>/dev/null | awk 'NR==2 {print $4}')

	if [ -z "$BK_UPPER_KB" ] || [ -z "$BK_AVAIL_KB" ]; then
		if [ "$BK_TYPE" = "manual" ]; then
			die "$CHOICE_TEXT" "Не смог определить размер upper или свободное место."
		fi
		echo "backup: не смог определить размеры, пропуск"
		exit 0
	fi

	if [ "$BK_AVAIL_KB" -lt $((BK_UPPER_KB * 2)) ]; then
		if [ "$BK_TYPE" = "manual" ]; then
			die "$CHOICE_TEXT" "Мало места: upper=${BK_UPPER_KB}K, свободно=${BK_AVAIL_KB}K.
Нужно минимум $((BK_UPPER_KB * 2))K."
		fi
		echo "backup: мало места (upper=${BK_UPPER_KB}K avail=${BK_AVAIL_KB}K), пропуск"
		exit 0
	fi

	[ -d "$BK_MNT/usb-extroot-backups" ] && \
		find "$BK_MNT/usb-extroot-backups" -name '*.part' -mtime +1 -delete 2>/dev/null || true

	BK_TS=$(date +%Y-%m-%d_%H-%M-%S)
	BK_FILE="$BK_DIR/${BK_PREFIX}_${BK_TS}.tar.gz"
	BK_PART_FILE="${BK_FILE}.part"

	echo "      тип: $BK_TYPE"
	echo "      overlay: $BK_OVERLAY_DEV -> $BK_MNT"
	echo "      upper: ${BK_UPPER_KB}K, свободно: ${BK_AVAIL_KB}K"
	echo "      создаю $BK_FILE ..."

	if ! tar -C / -czf "$BK_PART_FILE" --exclude=overlay/upper/tmp overlay/upper 2>/tmp/usb-extroot-bk.err; then
		echo "      tar errors:"
		head -20 /tmp/usb-extroot-bk.err
		rm -f "$BK_PART_FILE"
		if [ "$BK_TYPE" = "manual" ]; then
			die "$CHOICE_TEXT" "Не удалось создать архив."
		fi
		echo "backup: tar failed, exit"
		exit 1
	fi

	if ! tar -tzf "$BK_PART_FILE" >/dev/null 2>&1; then
		rm -f "$BK_PART_FILE"
		if [ "$BK_TYPE" = "manual" ]; then
			die "$CHOICE_TEXT" "Архив повреждён."
		fi
		echo "backup: verify failed, exit"
		exit 1
	fi

	mv "$BK_PART_FILE" "$BK_FILE"
	sync

	BK_SIZE_KB=$(du -k "$BK_FILE" 2>/dev/null | awk '{print $1}')
	echo -e "${CLR_GREEN}      архив: $BK_FILE (${BK_SIZE_KB}K)${CLR_RESET}"

	TOTAL=$(ls -1 "$BK_DIR"/*.tar.gz 2>/dev/null | wc -l)
	if [ "$TOTAL" -gt "$BK_ROTATE" ]; then
		REMOVE=$((TOTAL - BK_ROTATE))
		echo "      ротация: удаляю $REMOVE старых"
		ls -1t "$BK_DIR"/*.tar.gz 2>/dev/null | tail -n "$REMOVE" | while read -r old; do
			rm -f "$old"
			echo "        удалён $(basename "$old")"
		done
	fi

	if [ "$BK_TYPE" = "auto" ]; then
		touch /tmp/usb-extroot-autobackup.done
	fi

	if [ "$BK_TYPE" = "manual" ]; then
		echo "MANUAL_ARCHIVE_READY=$BK_FILE"
	fi

	exit 0
fi

# ============================================================
#  ВЕТКА restore_archive — развернуть архив на указанную флешку.
# ============================================================
if [ "$MODE" = "restore_archive" ]; then
	stage0_deps check

	ARCHIVE_PATH=""
	if [ "${BATCH_ARCHIVE#tmp/}" != "$BATCH_ARCHIVE" ]; then
		ARCHIVE_PATH="/tmp/${BATCH_ARCHIVE#tmp/}"
	fi
	if [ -z "$ARCHIVE_PATH" ]; then
		for mnt in $(awk '$3=="ext4" || $3=="f2fs" || $3=="btrfs" {print $2}' /proc/mounts); do
			candidate="$mnt/usb-extroot-backups/$BATCH_ARCHIVE"
			if [ -f "$candidate" ]; then
				ARCHIVE_PATH="$candidate"
				break
			fi
		done
	fi

	if [ -z "$ARCHIVE_PATH" ]; then
		die "$CHOICE_TEXT" "Архив не найден: $BATCH_ARCHIVE
	Проверь: find /mnt -name '$BATCH_ARCHIVE' 2>/dev/null"
	fi
	echo "      архив: $ARCHIVE_PATH"

	if [ -z "$BATCH_DEVICE" ] || [ ! -b "$BATCH_DEVICE" ]; then
		die "$CHOICE_TEXT" "Целевое устройство не задано или не существует: $BATCH_DEVICE"
	fi
	RESTORE_PART="$BATCH_DEVICE"
	RESTORE_TARGET=$(awk -v p="$RESTORE_PART" '$1==p {print $2; exit}' /proc/mounts)
	if [ -z "$RESTORE_TARGET" ] || [ ! -d "$RESTORE_TARGET" ]; then
		die "$CHOICE_TEXT" "Целевое устройство $RESTORE_PART не примонтировано."
	fi
	echo "      цель: $RESTORE_PART -> $RESTORE_TARGET"

	if ! tar -tzf "$ARCHIVE_PATH" 2>/dev/null | grep -q '^overlay/upper/etc/config/'; then
		die "$CHOICE_TEXT" "Это не бэкап overlay. В архиве нет пути overlay/upper/etc/config/.
	Скорее всего, это архив конфигурации (LuCI/Sysupgrade).
	Используйте штатное восстановление или выберите архив, созданный кнопкой «Создать бэкап»."
	fi

	# 2.6 Проверка безопасности архива ДО сноса upper.
	# Отклоняем: absolute paths, '..' в путях, device/fifo, suid/sgid.
	# Симлинки разрешены — это норма overlay (etc/ksmbd/ksmbd.conf -> /var/...,
	# etc/rc.d/S* -> ../init.d/*), их цель — внутри merged-view, не за пределами upper.
	echo "      проверяю архив на небезопасное содержимое..."

	TAR_LIST=$(tar -tzf "$ARCHIVE_PATH" 2>/dev/null) || die "$CHOICE_TEXT" "Не читается tar."
	if echo "$TAR_LIST" | grep -qE '^/'; then
		die "$CHOICE_TEXT" "Архив содержит абсолютные пути — отклонён."
	fi
	if echo "$TAR_LIST" | grep -qE '(^|/)\.\.(/|$)'; then
		die "$CHOICE_TEXT" "Архив содержит '..' в путях — отклонён."
	fi

	UNSAFE=$(tar -tvzf "$ARCHIVE_PATH" 2>/dev/null | awk '
		{
			perm = $1
			if (perm ~ /^[cbp]/) { print "device/fifo: " $0; next }
			if (perm ~ /[sS]/)   { print "suid/sgid: " $0;  next }
		}
	')
	if [ -n "$UNSAFE" ]; then
		echo "      опасное содержимое (первые строки):"
		echo "$UNSAFE" | head -5
		#die "$CHOICE_TEXT" "Архив содержит потенциально небезопасные файлы (device/fifo/suid/sgid). Восстановление отменено, текущий upper не тронут."
	fi

	echo -e "${CLR_GREEN}      архив безопасен${CLR_RESET}"

	rm -rf "$RESTORE_TARGET/upper"
	mkdir -p "$RESTORE_TARGET/work"

	echo "      распаковываю архив в $RESTORE_TARGET ..."
	if ! tar -xzf "$ARCHIVE_PATH" -C "$RESTORE_TARGET" 2>/tmp/tar_restore.err; then
		echo "      tar errors:"
		head -20 /tmp/tar_restore.err
		die "$CHOICE_TEXT" "Не удалось распаковать архив.
	Цель: $RESTORE_PART ($RESTORE_TARGET)
	архив: $ARCHIVE_PATH"
	fi

	if [ ! -d "$RESTORE_TARGET/overlay/upper" ]; then
		die "$CHOICE_TEXT" "В архиве нет overlay/upper.
	Проверь: tar -tzf '$ARCHIVE_PATH' | head -20"
	fi
	echo "      переношу overlay/upper -> upper"
	rm -rf "$RESTORE_TARGET/upper"
	if ! mv "$RESTORE_TARGET/overlay/upper" "$RESTORE_TARGET/upper" 2>/dev/null; then
		die "$CHOICE_TEXT" "Не смог переместить $RESTORE_TARGET/overlay/upper -> $RESTORE_TARGET/upper."
	fi
	rm -rf "$RESTORE_TARGET/overlay"

	if [ ! -d "$RESTORE_TARGET/upper/etc/config" ]; then
		die "$CHOICE_TEXT" "После распаковки в $RESTORE_TARGET/upper нет etc/config."
	fi

	RESTORE_UUID=$(block info "$RESTORE_PART" 2>/dev/null | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)
	if [ -z "$RESTORE_UUID" ]; then
		sleep 1
		RESTORE_UUID=$(block info "$RESTORE_PART" 2>/dev/null | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)
	fi
	if [ -z "$RESTORE_UUID" ]; then
		die "$CHOICE_TEXT" "Не получил UUID для $RESTORE_PART."
	fi

	RESTORE_CFG="$RESTORE_TARGET/upper/etc/config"
	echo "      заменяю $RESTORE_CFG/fstab (без extroot)"
	cat > "$RESTORE_CFG/fstab" <<FSTAB_EOF
config global
	option anon_swap '0'
	option anon_mount '0'
	option auto_swap '1'
	option auto_mount '1'
	option delay_root '5'
	option check_fs '0'
FSTAB_EOF

	uci -q delete fstab.extroot
	uci -q delete fstab.rwm
	uci commit fstab

	echo "      настраиваю extroot во внутренней памяти (UBI)..."
	UBI_DEV=$(find_internal_overlay_dev)
	if [ -n "$UBI_DEV" ]; then
		UBI_MNT=/tmp/ubi_restore
		mkdir -p "$UBI_MNT"
		if mount -t ubifs "$UBI_DEV" "$UBI_MNT" 2>/dev/null || mount "$UBI_DEV" "$UBI_MNT" 2>/dev/null; then
			UBI_CFG="$UBI_MNT/upper/etc/config"
			if [ -d "$UBI_CFG" ]; then
				uci -c "$UBI_CFG" -q delete fstab.extroot
				uci -c "$UBI_CFG" set fstab.extroot=mount
				uci -c "$UBI_CFG" set fstab.extroot.uuid="$RESTORE_UUID"
				uci -c "$UBI_CFG" set fstab.extroot.target="/overlay"
				uci -c "$UBI_CFG" set fstab.extroot.enabled="1"
				uci -c "$UBI_CFG" -q delete fstab.rwm
				uci -c "$UBI_CFG" commit fstab
				echo "      extroot: UUID=$RESTORE_UUID -> /overlay (сохранено в UBI)"
			fi
			umount "$UBI_MNT" 2>/dev/null || true
			rmdir "$UBI_MNT" 2>/dev/null || true
		else
			echo -e "${CLR_ORANGE}      ВНИМАНИЕ: не смог смонтировать UBI для записи extroot!${CLR_RESET}"
		fi
	fi

	echo -e "      extroot: UUID=${CLR_YELLOW}$RESTORE_UUID${CLR_RESET} ($RESTORE_PART) -> /overlay"

	REBOOT_HELPER="$RESTORE_TARGET/upper/root/reboot_after.sh"
	mkdir -p "$RESTORE_TARGET/upper/root"
	cat > "$REBOOT_HELPER" <<-'EOF'
	#!/bin/sh
	# RESTORE-ARCHIVE
	WAIT_BEFORE_REBOOT=20
	rm -f /root/reboot_after.sh
	uci -q delete ksmbd.overlaybackup
	uci -q commit ksmbd
	if command -v ksmbd.useradmin >/dev/null 2>&1; then
		ksmbd.useradmin -d 12345 >/dev/null 2>&1
	fi
	sed -i '/^12345:/d' /etc/passwd
	[ -f /etc/shadow ] && sed -i '/^12345:/d' /etc/shadow
	sed -i '/^\/root\/reboot_after\.sh$/d' /etc/rc.local 2>/dev/null || true
	mkdir -p /overlay
	sleep 1
	sync
	sleep "$WAIT_BEFORE_REBOOT"
	if ! mount | grep -q ' /rom/overlay ' && mount | grep -q ' /overlay '; then
		rm -f /flagfile
		/etc/init.d/ac_recovery.sh stop
		exit 0
	fi
	sync
	delay="40"
	setsid sh -c "
		trap '' TERM
		sleep $delay
		echo b > /proc/sysrq-trigger
		sleep 1
		reboot -f
	" &
	sleep 1
	reboot
EOF
	chmod +x "$REBOOT_HELPER"

	if [ ! -f "$RESTORE_TARGET/upper/etc/rc.local" ]; then
		printf '#!/bin/sh\n# Put your custom commands here that should be executed once\n# the system init finished. By default this file does nothing.\n\nexit 0\n' > "$RESTORE_TARGET/upper/etc/rc.local"
	fi
	if ! grep -q '^/root/reboot_after.sh$' "$RESTORE_TARGET/upper/etc/rc.local"; then
		sed -i '/^exit 0/i /root/reboot_after.sh' "$RESTORE_TARGET/upper/etc/rc.local"
	fi
	chmod +x "$RESTORE_TARGET/upper/etc/rc.local"

	sync
	sleep 2

	echo
	echo -e "${CLR_GREEN}================================================================${CLR_RESET}"
	echo -e "${CLR_GREEN} Готово. Архив развёрнут на $RESTORE_PART.${CLR_RESET}"
	echo -e "${CLR_GREEN} Роутер будет перезагружен и загрузится с $RESTORE_PART.${CLR_RESET}"
	echo -e "${CLR_GREEN}================================================================${CLR_RESET}"

	confirm_reboot_or_die 0
	exit 0
fi

# ============================================================
#  МЕНЮ (interactive)
# ============================================================
if [ "$BATCH" != "1" ]; then
	while :; do
		clear
		if [ "$flash" = "no" ]; then
			echo -e "${CLR_ORANGE}НАКОПИТЕЛИ НЕ ОБНАРУЖЕНЫ!${CLR_RESET}"
			echo -e "${CLR_ORANGE}ПОДКЛЮЧИТЕ ФЛЭШКУ И ПЕРЕЗАПУСТИТЕ СКРИПТ${CLR_RESET}"
		fi
		echo "============================================================"
		echo "usb-extroot.sh  ${ver}"
cat <<-'BANNER'
	Перенос overlay OpenWrt на USB-накопитель (extroot)
	------------------------------------------------------------
	 До ввода YES — только чтение.
	 После YES — необратимо; при ошибке — стоп и инструкции.
	 Лог: /tmp/usb-extroot.log
	============================================================
	BANNER
		accessible=""
		if [ "$EXTROOT_ACTIVE" = "1" ]; then
			echo
			echo -e "${CLR_ORANGE} /overlay уже размещён на внешнем носителе: ${CLR_GREEN}$(describe "$EXTROOT_DEV")${CLR_RESET}"
			echo " Пункты 1 и 2 недоступны."
			accessible="(недоступно)"
		fi

		if [ "$FALLBACK_ACTIVE" = "1" ]; then
			echo
			echo -e "${CLR_ORANGE}!!! ОБНАРУЖЕНА ПРОБЛЕМА С OVERLAY !!!${CLR_RESET}"
			echo -e "${CLR_ORANGE} overlay работает в аварийном режиме (фоллбэк).${CLR_RESET}"
		fi

		echo
		echo -e "${CLR_YELLOW}Действие:${CLR_RESET}"
		echo -e "  1) Роутер → USB-накопитель с форматированием накопителя  ${CLR_ORANGE}${accessible}${CLR_RESET}"
		echo -e "  2) Роутер → USB-накопитель без форматирования накопителя ${CLR_ORANGE}${accessible}${CLR_RESET}"
		echo -e "  3) Восстановить загрузку с внутренней памяти роутера"
		echo -e "  4) Выбор загрузочного устройства, клонирование накопителя"
		if [ "$EXTROOT_ACTIVE" = "1" ] || [ "$FALLBACK_ACTIVE" = "1" ]; then
			echo -e "  6) Восстановить состояние из архива на флешку"
		fi
		if [ "$FALLBACK_ACTIVE" = "1" ]; then
			echo -e "  ${CLR_ORANGE}5) Исправить аварийный режим overlay (рекомендуется)${CLR_RESET}"
		fi
		echo -e "  0) Выход"
		printf "${CLR_YELLOW}Выбор: ${CLR_RESET}"
		read CHOICE

		case "$CHOICE" in
			1) MODE=format;   CHOICE_TEXT="форматировать и перенести overlay на USB-носитель" ;;
			2) MODE=noformat; CHOICE_TEXT="перенести без форматирования" ;;
			3) MODE=restore;  CHOICE_TEXT="восстановить загрузку с внутренней памяти роутера" ;;
			4)
				ensure_dependencies
				if command -v second_drive_menu >/dev/null 2>&1; then
					second_drive_menu
				else
					echo
					echo "Модуль не подключён."
					sleep 2
				fi
				continue
				;;
			5)
				if [ "$FALLBACK_ACTIVE" != "1" ]; then
					echo
					echo "Пункт 5 доступен только при обнаружении фоллбэка."
					sleep 2
					continue
				fi
				MODE=fallback_fix
				CHOICE_TEXT="исправить аварийный режим overlay"
				;;
			6)
				if [ "$EXTROOT_ACTIVE" != "1" ] && [ "$FALLBACK_ACTIVE" != "1" ]; then
					echo
					echo "Пункт 6 доступен только при extroot или fallback."
					sleep 2
					continue
				fi
				echo
				echo "Доступные архивы:"
				n=0
				ARCHIVES=""
				for mnt in $(awk '$3=="ext4" || $3=="f2fs" || $3=="btrfs" {print $2}' /proc/mounts); do
					for f in "$mnt/usb-extroot-backups"/*.tar.gz; do
						[ -f "$f" ] || continue
						n=$((n + 1))
						ARCHIVES="$ARCHIVES $f"
						echo "  $n) $(basename "$f")"
					done
					if [ -d "$mnt/usb-extroot-backups/manual" ]; then
						for f in "$mnt/usb-extroot-backups/manual"/*.tar.gz; do
							[ -f "$f" ] || continue
							n=$((n + 1))
							ARCHIVES="$ARCHIVES $f"
							echo "  $n) manual/$(basename "$f")"
						done
					fi
				done
				if [ "$n" = "0" ]; then
					echo "  (нет архивов)"
					sleep 2
					continue
				fi
				printf "Выберите номер (0 - отмена): "
				read ACH
				case "$ACH" in
					0|"") continue ;;
				esac
				ok=0
				n=0
				for f in $ARCHIVES; do
					n=$((n + 1))
					if [ "$n" = "$ACH" ]; then
						BATCH_ARCHIVE=$(basename "$f")
						case "$f" in
							*/manual/*) BATCH_ARCHIVE="manual/$BATCH_ARCHIVE" ;;
						esac
						ok=1
						break
					fi
				done
				if [ "$ok" != "1" ]; then
					echo "Неверный выбор."
					sleep 2
					continue
				fi
				MODE=restore_archive
				CHOICE_TEXT="восстановление из архива $BATCH_ARCHIVE"
				;;
			0) echo "Выход."; exit 0 ;;
			*)
				echo
				echo "Неизвестный выбор: '$CHOICE'"
				sleep 2
				continue
				;;
		esac

		if [ "$EXTROOT_ACTIVE" = "1" ] && [ "$MODE" != "restore" ] && [ "$MODE" != "fallback_fix" ] && [ "$MODE" != "restore_archive" ]; then
			echo
			echo -e "${CLR_ORANGE}Невозможно: overlay уже на $EXTROOT_DEV.${CLR_RESET}"
			echo "  Перенос c USB на тот же USB не имеет практического смысла."
			echo "  Вам доступны только пункты 3, 4, 5, 6, 0"
			echo
			printf "  Нажмите Enter для продолжения (авто через 10с): "
			read -t 10 _
			echo
			continue
		fi

		break
	done
fi

# ============================================================
#  ВЕТКА 5 — автоисправление фоллбэка overlay.
# ============================================================
if [ "$MODE" = "fallback_fix" ]; then
	stage0_deps check

	echo
	echo "      очищаю fstab.extroot/rwm..."
	uci -q delete fstab.extroot
	uci -q delete fstab.rwm
	uci commit fstab
	echo "      fstab очищен."

	echo "      создаю /overlay..."
	if ! mkdir -p /overlay 2>/tmp/mkdir.err; then
		echo -e "${CLR_ORANGE}      mkdir /overlay не удался:${CLR_RESET}"
		cat /tmp/mkdir.err 2>/dev/null
		die "$CHOICE_TEXT" "Не смог создать /overlay.

	Проверь:
	  ls -la /overlay
	  mount | grep overlay
	  touch /overlay/test 2>&1
	  df -h /overlay"
	fi

	sync
	echo -e "${CLR_GREEN}      /overlay создан${CLR_RESET}"

	echo
	echo -e "${CLR_GREEN}Готово. Ребут для применения.${CLR_RESET}"

	confirm_reboot_or_die 0
	exit 0
fi

# ============================================================
#  ВЕТКА reset_keep_extroot — сброс с сохранением загрузки с флешки.
# ============================================================
# Сброс = «отодвинуть upper в upper.old + жёсткий reboot».
# При следующем буте firstboot/uci-defaults отработают на пустом upper
# и создадут корректное окружение (init.d/*, certs, board.json и т.д.).
if [ "$MODE" = "reset_keep_extroot" ]; then
	QDEV=$(quick_overlay_dev)
	if [ -z "$QDEV" ] || is_internal_dev "$QDEV"; then
		die "$CHOICE_TEXT" "Сброс с сохранением extroot доступен только при загрузке с внешней флешки."
	fi
	QMP=$(awk -v d="$QDEV" '$1==d {print $2; exit}' /proc/mounts)
	[ -n "$QMP" ] || die "$CHOICE_TEXT" "Не получил точку монтирования для $QDEV."

	rm -rf "$QMP/upper.old" 2>/dev/null
	mv "$QMP/upper" "$QMP/upper.old" || die "$CHOICE_TEXT" "Не смог переместить $QMP/upper -> $QMP/upper.old."
	sync
	sleep 2
	reboot -f
fi


# ============================================================
#  ВЕТКА 3 — восстановление загрузки с внутренней памяти
# ============================================================
if [ "$MODE" = "restore" ]; then

	QDEV=$(quick_overlay_dev)

	if [ -n "$QDEV" ] && is_internal_dev "$QDEV"; then
		if ! uci -q get fstab.extroot >/dev/null 2>&1; then
			die "$CHOICE_TEXT" "extroot не найден в fstab.
	Восстанавливать нечего."
		fi
	fi

	fix_uboot_env
	stage0_deps check

	share_down

	UBI_DEV=$(find_internal_overlay_dev)
	UBI_RC=$?

	case "$UBI_RC" in
		0)
			echo "      устройство с overlay: $UBI_DEV"
			;;
		1)
			die "$CHOICE_TEXT" "Не нашёл ни одного устройства с внутренним overlay."
			;;
		2)
			die "$CHOICE_TEXT" "Найдено несколько устройств с overlay:
	$UBI_DEV

	Автовыбор невозможен."
			;;
	esac

	UBI_MNT=/tmp/ubi_restore
	mkdir -p "$UBI_MNT"

	mount_ok=0
	if mount -t ubifs "$UBI_DEV" "$UBI_MNT" 2>/dev/null \
	   || mount "$UBI_DEV" "$UBI_MNT" 2>/dev/null; then
		mount_ok=1
	fi

	if [ "$mount_ok" != "1" ]; then
		rmdir "$UBI_MNT" 2>/dev/null || true
		die "$CHOICE_TEXT" "Не смог смонтировать $UBI_DEV в $UBI_MNT."
	fi

	if [ ! -d "$UBI_MNT/upper" ] \
	   || [ ! -d "$UBI_MNT/work" ] \
	   || [ ! -d "$UBI_MNT/upper/etc/config" ]; then
		umount "$UBI_MNT" 2>/dev/null || true
		rmdir "$UBI_MNT" 2>/dev/null || true
		die "$CHOICE_TEXT" "$UBI_DEV не похож на overlay OpenWrt."
	fi
	echo -e "${CLR_GREEN}      маркеры overlay подтверждены${CLR_RESET}"

	if [ -d "$UBI_MNT/upper/etc/config" ]; then
		uci -c "$UBI_MNT/upper/etc/config" -q delete fstab.extroot
		uci -c "$UBI_MNT/upper/etc/config" -q delete fstab.rwm
		uci -c "$UBI_MNT/upper/etc/config" commit fstab
		echo "      fstab внутри $UBI_DEV очищен."
	fi

	uci -q delete fstab.extroot
	uci -q delete fstab.rwm
	uci commit fstab
	echo "      fstab в живой системе очищен."

	mkdir -p "$UBI_MNT/upper/root"

	cat > "$UBI_MNT/upper/root/reboot_after.sh" <<-'EOF'
	#!/bin/sh
	# RESTORE
	WAIT_BEFORE_REBOOT=20
	rm -f /root/reboot_after.sh
	uci -q delete ksmbd.overlaybackup
	uci -q commit ksmbd
	if command -v ksmbd.useradmin >/dev/null 2>&1; then
		ksmbd.useradmin -d 12345 >/dev/null 2>&1
	fi
	sed -i '/^12345:/d' /etc/passwd
	[ -f /etc/shadow ] && sed -i '/^12345:/d' /etc/shadow
	sed -i '/^\/root\/reboot_after\.sh$/d' /etc/rc.local 2>/dev/null || true
	mkdir -p /overlay
	sleep 1
	sync
	sleep "$WAIT_BEFORE_REBOOT"
	if ! mount | grep -q ' /rom/overlay ' && mount | grep -q ' /overlay '; then
		rm -f /flagfile
		/etc/init.d/ac_recovery.sh stop
		exit 0
	fi

	sync
	delay="40"

	setsid sh -c "
		trap '' TERM
		sleep $delay
		echo b > /proc/sysrq-trigger
		sleep 1
		reboot -f
	" &

	sleep 1
	reboot

EOF
	chmod +x "$UBI_MNT/upper/root/reboot_after.sh"

	mkdir -p "$UBI_MNT/upper/etc"
	if [ ! -f "$UBI_MNT/upper/etc/rc.local" ]; then
		printf '#!/bin/sh\n# Put your custom commands here that should be executed once\n# the system init finished. By default this file does nothing.\n\nexit 0\n' > "$UBI_MNT/upper/etc/rc.local"
	fi
	if ! grep -q '^/root/reboot_after.sh$' "$UBI_MNT/upper/etc/rc.local"; then
		sed -i '/^exit 0/i /root/reboot_after.sh' "$UBI_MNT/upper/etc/rc.local"
	fi
	chmod +x "$UBI_MNT/upper/etc/rc.local"
	sync
	sleep 3

	cp /tmp/usb-extroot.log "$UBI_MNT/upper/root/usb-extroot.log" 2>/dev/null || true
	mkdir -p "$UBI_MNT/overlay"
	[ -e "$UBI_MNT/upper/overlay" ] && [ ! -d "$UBI_MNT/upper/overlay" ] && rm -f "$UBI_MNT/upper/overlay"
	mkdir -p "$UBI_MNT/upper/overlay"
	sync
	sleep 3

	umount "$UBI_MNT" 2>/dev/null || true
	echo "      reboot_after.sh + rc.local в $UBI_DEV подготовлены."
	rmdir "$UBI_MNT" 2>/dev/null || true

	echo
	echo -e "${CLR_GREEN}Готово. Роутер перезагружается.${CLR_RESET}"

	confirm_reboot_or_die 0
	exit 0
fi

# ============================================================
#  ВЕТКИ 1 и 2 — перенос
# ============================================================

if ! storage_quick_check; then
	echo
	echo "      диагностика /dev:"
	diag_found=0
	for d in /dev/sd? /dev/mmcblk?; do
		[ -b "$d" ] || continue
		b=$(basename "$d")
		rem=$(cat /sys/block/$b/removable 2>/dev/null)
		echo "        $d removable=${rem:-?}"
		diag_found=1
	done
	[ "$diag_found" = "0" ] && echo "        /dev/sd* и /dev/mmcblk* отсутствуют — не установлен kmod-usb-storage?"
	die "$CHOICE_TEXT" "Внешних съёмных накопителей не найдено.
	Подключите флешку/SD-карту и запустите скрипт заново."
fi

CUR_OVERLAY_MP=$(get_current_overlay)
CUR_OVERLAY_DEV=$(awk -v m="$CUR_OVERLAY_MP" '$2==m {print $1; exit}' /proc/mounts)

if [ -z "$CUR_OVERLAY_DEV" ]; then
	die "$CHOICE_TEXT" "Не нашёл устройство $CUR_OVERLAY_MP.
	Проверь: mount | grep overlay"
fi

SKIP_PARENT=$(parent_dev "$CUR_OVERLAY_DEV")

USB_TARGET=""
for d in /dev/sd? /dev/mmcblk?; do
	[ -b "$d" ] || continue
	is_removable_storage "$d" || continue
	[ "$(parent_dev "$d")" = "$SKIP_PARENT" ] && continue
	USB_TARGET="$d"
	break
done

if [ -z "$USB_TARGET" ]; then
	die "$CHOICE_TEXT" "Внешних накопителей для переноса не найдено.

	Текущий overlay уже на $CUR_OVERLAY_DEV ($SKIP_PARENT).
	Подключи другой накопитель, либо вернись на внутренний overlay (режим 3)."
fi

fix_uboot_env
stage0_deps check
stage1_overlay

if [ "$MODE" = "restore" ] || [ "$MODE" = "fallback_fix" ]; then
	:
elif ! stage2_find_usb; then
	die "$CHOICE_TEXT" "Внешний накопитель найден, но не определён как диск (sd*/mmcblk*)."
fi

# ============================================================
#  ШАГ 3. Проверки
# ============================================================
echo
STAGE3="[3/9] проверки безопасности"
echo "$STAGE3 ..."

SRC_SIZE_KB=$(du -sk "$CUR_OVERLAY_MP" 2>/dev/null | awk '{print $1}')
TMP_AVAIL_KB=$(df -k /tmp 2>/dev/null | awk 'NR==2 {print $4}')

echo "      overlay: ${SRC_SIZE_KB}K, /tmp свободно: ${TMP_AVAIL_KB}K"

if [ -z "$SRC_SIZE_KB" ] || [ -z "$TMP_AVAIL_KB" ]; then
	die "$STAGE3" "Не смог определить размер overlay или /tmp."
fi

NEED_TMP_KB=$(( SRC_SIZE_KB * 2 + SRC_SIZE_KB / 10 ))
if [ "$TMP_AVAIL_KB" -lt "$NEED_TMP_KB" ]; then
	die "$STAGE3" "Мало места в /tmp для staging + архив.
	Нужно: ${NEED_TMP_KB}K, свободно: ${TMP_AVAIL_KB}K."
fi
echo -e "${CLR_GREEN}      ок, в /tmp места хватает${CLR_RESET}"

if [ ! -d "$CUR_OVERLAY_MP/upper/etc/config" ]; then
	die "$STAGE3" "В overlay нет upper/etc/config."
fi
echo -e "${CLR_GREEN}      структура overlay корректна${CLR_RESET}"

echo "      физ.диски: overlay=$SKIP_PARENT usb=$(parent_dev "$PART")"
echo

if [ "$BATCH" = "1" ]; then
	echo -e "${CLR_GREEN}      batch: подтверждение уже получено через --confirm=yes${CLR_RESET}"
else
	CONFIRM_CODE=$(tr -dc '0-9' < /dev/urandom 2>/dev/null | head -c 4)

	echo
	echo -e "      ${CLR_ORANGE}############################################${CLR_RESET}"
	echo -e "      ${CLR_ORANGE}#      ВНИМАНИЕ: НЕОБРАТИМАЯ ОПЕРАЦИЯ!     #${CLR_RESET}"
	echo -e "      ${CLR_ORANGE}############################################${CLR_RESET}"
	echo
	if [ "$MODE" = format ]; then
		echo -e "${CLR_ORANGE}Все данные на $DESC будут уничтожены!${CLR_RESET}"
	else
		echo -e "${CLR_YELLOW}На $PART будет удалена только overlay-структура.${CLR_RESET}"
	fi

	echo
	echo "Сейчас будет уничтожен накопитель:"
	echo -e "    ${CLR_YELLOW}$DESC${CLR_RESET}"
	echo -e "    раздел: ${CLR_YELLOW}$PART${CLR_RESET}"
	echo
	if [ "$MODE" = format ]; then
		echo -e "Действие: ${CLR_ORANGE}ФОРМАТИРОВАНИЕ${CLR_RESET} mkfs.ext4 -F $PART"
	else
		echo -e "Действие: ${CLR_ORANGE}удаление overlay-структуры на $PART${CLR_RESET}"
	fi
	echo
	printf "Для подтверждения введите число:"
	printf " ${CLR_YELLOW}${CONFIRM_CODE}${CLR_RESET}"
	echo
	printf "Число (Enter — отмена): "
	read A

	if [ "$A" != "$CONFIRM_CODE" ]; then
		echo
		echo "Отменено."
		exit 0
	fi
fi

echo -e "Подтверждено: ${CLR_YELLOW}$TARGET ($MODE)${CLR_RESET}."

echo
STAGE5="[5/9] пакеты"
echo "$STAGE5 ..."
echo -e "${CLR_GREEN}      все пакеты установлены ранее${CLR_RESET}"

echo
STAGE6="[6/9] staging overlay"
STAGE_DIR=/tmp/overlay_stage
echo "$STAGE6 в $STAGE_DIR ..."

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/overlay/upper"

echo "      копирую upper/ из $CUR_OVERLAY_MP (без work/, .fs_state) ..."
if ! cp -a "$CUR_OVERLAY_MP/upper/." "$STAGE_DIR/overlay/upper/" 2>/tmp/cp.err; then
	echo "      cp errors:"
	head -20 /tmp/cp.err
	die "$STAGE6" "Не смог скопировать upper/ в staging."
fi

rm -rf "$STAGE_DIR/overlay/upper/work" 2>/dev/null || true
rm -f "$STAGE_DIR/overlay/upper/.fs_state" 2>/dev/null || true

STAGE_SIZE_KB=$(du -sk "$STAGE_DIR" 2>/dev/null | awk '{print $1}')
echo "      staging размер: ${STAGE_SIZE_KB}K"

if [ ! -d "$STAGE_DIR/overlay/upper/etc/config" ]; then
	die "$STAGE6" "Staging неполный — нет overlay/upper/etc/config."
fi
echo -e "${CLR_GREEN}      staging корректный${CLR_RESET}"

echo
STAGE7="[7/9] подготовка $PART"
MNT=/mnt/extroot_tmp
mkdir -p "$MNT"

echo "$STAGE7 ..."

sync
if [ -x /etc/init.d/fstab ]; then
	/etc/init.d/fstab stop >/dev/null 2>&1 || true
fi

if have fuser; then
	fuser -k -m "$MNT" "$PART" 2>/dev/null || true
fi

for target_mpt in "$MNT" "$PART" "$TARGET"; do
	umount "$target_mpt" 2>/dev/null || true
	umount -l "$target_mpt" 2>/dev/null || true
	umount -f "$target_mpt" 2>/dev/null || true
done

sleep 2

if [ "$MODE" = format ]; then
	echo "      освобождаю $PART..."

	if have block; then
		block umount "$PART" 2>/dev/null || true
	fi
	if have fuser; then
		fuser -k -m "$PART" 2>/dev/null || true
	fi
	for m in $(awk -v p="$PART" '$1==p {print $2}' /proc/mounts); do
		umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
	done
	umount "$PART" 2>/dev/null || umount -l "$PART" 2>/dev/null || true
	sync
	sleep 2

	if mount | grep -q "$PART "; then
		echo "      держатели $PART:"
		mount | grep "$PART "
		fatal "$STAGE7" "Раздел $PART всё ещё занят, mkfs невозможен.
	Staging цел: $STAGE_DIR"
	fi
	echo -e "${CLR_GREEN}      $PART свободен${CLR_RESET}"
fi

if [ "$MODE" = format ]; then
	echo "      форматирование $PART в ext4..."

	sync
	sleep 1

	b=$(basename "$TARGET")
	VENDOR=$(cat /sys/block/$b/device/vendor 2>/dev/null | tr -d '\n ' | sed 's/^ *//;s/ *$//')
	MODEL=$(cat /sys/block/$b/device/model 2>/dev/null | tr -d '\n ' | sed 's/^ *//;s/ *$//')
	REAL=$(readlink -f /sys/block/$b/device 2>/dev/null)
	USB_PORT=$(echo "$REAL" | sed -n 's|.*/usb[0-9]*/\([0-9]*-[0-9.]*\)/.*|\1|p')

	echo "      USB-порт: '${USB_PORT:-<не найден>}'"
	echo "      vendor='$VENDOR' model='$MODEL'"

	if [ -n "$USB_PORT" ] && [ -d /sys/bus/usb/devices/$USB_PORT ]; then
		echo "      пересоздаю USB-порт $USB_PORT..."

		umount "$PART" 2>/dev/null || umount -l "$PART" 2>/dev/null || true
		block umount "$PART" 2>/dev/null || true
		sync
		sleep 1

		echo 0 > /sys/bus/usb/devices/$USB_PORT/authorized
		sleep 3
		echo 1 > /sys/bus/usb/devices/$USB_PORT/authorized

		i=0
		FOUND=""
		while [ $i -lt 20 ]; do
			sleep 1
			for d in /dev/sd?; do
				[ -b "$d" ] || continue
				db=$(basename "$d")
				v=$(cat /sys/block/$db/device/vendor 2>/dev/null | tr -d '\n ' | sed 's/^ *//;s/ *$//')
				m=$(cat /sys/block/$db/device/model 2>/dev/null | tr -d '\n ' | sed 's/^ *//;s/ *$//')
				if [ "$v" = "$VENDOR" ] && [ "$m" = "$MODEL" ]; then
					FOUND="$d"
					break
				fi
			done
			[ -n "$FOUND" ] && break
			i=$((i + 1))
		done

		if [ -z "$FOUND" ]; then
			fatal "$STAGE7" "USB-диск не переподключился за 20 сек."
		fi

		echo "      диск найден заново: $FOUND"

		TARGET="$FOUND"
		PART=""
		for p in ${TARGET}*; do
			[ -b "$p" ] || continue
			case "$(basename $p)" in
				sd[a-z][0-9]*|mmcblk[0-9]*p[0-9]*) ;;
				*) continue ;;
			esac
			PART="$p"
			break
		done
		[ -z "$PART" ] && PART="$TARGET"
		echo "      раздел: $PART"

		sleep 1
		if [ ! -b "$PART" ]; then
			fatal "$STAGE7" "Раздел $PART не появился после пересоздания."
		fi

		umount "$PART" 2>/dev/null || umount -l "$PART" 2>/dev/null || true
		block umount "$PART" 2>/dev/null || true
		sync
		sleep 1

		echo "      освобождаю $PART перед mkfs..."
		i=0
		while [ $i -lt 5 ]; do
			MNT_TMP=$(awk -v p="$PART" '$1==p {print $2; exit}' /proc/mounts)
			[ -z "$MNT_TMP" ] && break
			umount "$MNT_TMP" 2>/dev/null || umount -l "$MNT_TMP" 2>/dev/null || true
			sleep 1
			i=$((i + 1))
		done

		if mount | grep -q "$PART "; then
			fatal "$STAGE7" "Раздел $PART не удаётся освободить перед mkfs."
		fi
		echo -e "${CLR_GREEN}      $PART свободен после пересоздания${CLR_RESET}"
		echo -e "${CLR_ORANGE}Форматирую накопитель...${CLR_RESET}"
	fi

	mkfs_success=0

	i=1
	while [ $i -le 3 ]; do
		if mkfs.ext4 -F -L extroot "$PART" >/dev/null 2>&1; then
			mkfs_success=1
			break
		fi
		sleep 2
		i=$((i + 1))
	done

	if [ "$mkfs_success" != "1" ]; then
		mkfs.ext4 -F -L extroot "$PART"
		fatal "$STAGE7" "mkfs.ext4 на $PART упал."
	fi

	echo -e "${CLR_GREEN}      отформатировано: $PART (ext4, label=extroot)${CLR_RESET}"
fi

MNT_TMP=$(awk -v p="$PART" '$1==p {print $2; exit}' /proc/mounts)
if [ -n "$MNT_TMP" ]; then
	MNT="$MNT_TMP"
	echo "      $PART уже примонтирован в $MNT"
else
	MNT=/mnt/extroot_tmp
	mkdir -p "$MNT"
	echo "      монтирую $PART -> $MNT"
	if ! mount "$PART" "$MNT" 2>/dev/null; then
		fatal "$STAGE7" "Не смог смонтировать $PART в $MNT."
	fi
fi

if [ "$MODE" = noformat ]; then
	echo
	echo "      удаляю только overlay-структуру (данные не тронуты) ..."

	for entry in "$MNT/upper" "$MNT/work" "$MNT/.fs_state" "$MNT/.fs_state.bak"; do
		[ -e "$entry" ] || continue
		echo "        rm -rf $entry"
		if ! rm -rf "$entry"; then
			umount "$MNT" 2>/dev/null || true
			fatal "$STAGE7" "Не смог удалить $entry."
		fi
	done
	sync
	echo "      overlay-структура очищена, остальные данные на месте"
fi

echo "      копирую staging на USB..."
AVAIL_DST_KB=$(df -k "$MNT" 2>/dev/null | awk 'NR==2 {print $4}')
echo "      свободно: ${AVAIL_DST_KB}K, нужно ~${STAGE_SIZE_KB}K"

if [ -z "$AVAIL_DST_KB" ]; then
	umount "$MNT" 2>/dev/null || true
	fatal "$STAGE7" "Не смог определить свободное место на $PART."
fi
if [ "$AVAIL_DST_KB" -lt $((STAGE_SIZE_KB + STAGE_SIZE_KB / 10)) ]; then
	umount "$MNT" 2>/dev/null || true
	fatal "$STAGE7" "Мало места на $PART (${AVAIL_DST_KB}K < ${STAGE_SIZE_KB}K)."
fi

mkdir -p "$MNT/upper"
if ! cp -a "$STAGE_DIR/overlay/upper/." "$MNT/upper/" 2>/tmp/cp2.err; then
	echo "      cp errors:"
	head -20 /tmp/cp2.err
	umount "$MNT" 2>/dev/null || true
	fatal "$STAGE7" "Не смог скопировать upper/ на USB."
fi

mkdir -p "$MNT/work"
sync

USB_SIZE_KB=$(du -sk "$MNT" 2>/dev/null | awk '{print $1}')
echo "      на USB: ${USB_SIZE_KB}K"

CFG="$MNT/upper/etc/config"
if [ ! -d "$CFG" ]; then
	umount "$MNT" 2>/dev/null || true
	fatal "$STAGE7" "На USB нет upper/etc/config."
fi
echo -e "${CLR_GREEN}      копирование на USB завершено${CLR_RESET}"

echo
STAGE8="[8/9] архив"
BACKUP_DIR=/tmp/.usb-extroot-x7k2m9q4p1w8
echo "$STAGE8 в $BACKUP_DIR ..."

mkdir -p "$BACKUP_DIR"
TS=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_ARCHIVE="$BACKUP_DIR/overlay_backup_${TS}.tar.gz"

echo "      удаляю whiteouts из staging..."
find "$STAGE_DIR/overlay/upper" -name '.wh.*' -delete 2>/dev/null || true
find "$STAGE_DIR/overlay/upper" -type c -delete 2>/dev/null || true
find "$STAGE_DIR/overlay/upper" -type d -empty -delete 2>/dev/null || true

echo "      создаю архив $BACKUP_ARCHIVE ..."
if ! tar -C "$STAGE_DIR" -czf "$BACKUP_ARCHIVE" overlay 2>/tmp/tar_read.err; then
	echo "      tar errors:"
	head -20 /tmp/tar_read.err
	umount "$MNT" 2>/dev/null || true
	fatal "$STAGE8" "Не смог создать архив."
fi

if ! tar -tzf "$BACKUP_ARCHIVE" >/dev/null 2>&1; then
	umount "$MNT" 2>/dev/null || true
	fatal "$STAGE8" "Архив повреждён: $BACKUP_ARCHIVE"
fi

ARCHIVE_SIZE_KB=$(du -k "$BACKUP_ARCHIVE" 2>/dev/null | awk '{print $1}')
echo "      архив: ${ARCHIVE_SIZE_KB}K"
echo -e "${CLR_GREEN}      архив создан${CLR_RESET}"

echo "      копирую архив на USB (ротация: 30 последних)..."
mkdir -p "$MNT/usb-extroot-backups"
if cp "$BACKUP_ARCHIVE" "$MNT/usb-extroot-backups/" 2>/dev/null; then
    ARCH_NAME=$(basename "$BACKUP_ARCHIVE")
    echo -e "${CLR_GREEN}      архив сохранён на USB: /usb-extroot-backups/$ARCH_NAME${CLR_RESET}"

    TOTAL=$(ls -1 "$MNT/usb-extroot-backups"/overlay_backup_*.tar.gz "$MNT/usb-extroot-backups"/autobackup_*.tar.gz 2>/dev/null | wc -l)
    if [ "$TOTAL" -gt 30 ]; then
        REMOVE_COUNT=$((TOTAL - 30))
        ls -1t "$MNT/usb-extroot-backups"/overlay_backup_*.tar.gz "$MNT/usb-extroot-backups"/autobackup_*.tar.gz 2>/dev/null | tail -n "$REMOVE_COUNT" | while read -r old; do
            rm -f "$old"
            echo "      ротация: удалён старый архив $(basename "$old")"
        done
        TOTAL_AFTER=$(ls -1 "$MNT/usb-extroot-backups"/overlay_backup_*.tar.gz "$MNT/usb-extroot-backups"/autobackup_*.tar.gz 2>/dev/null | wc -l)
        echo -e "${CLR_GREEN}      на USB сейчас архивов: $TOTAL_AFTER${CLR_RESET}"
    else
        echo -e "${CLR_GREEN}      на USB сейчас архивов: $TOTAL${CLR_RESET}"
    fi
else
    echo -e "${CLR_ORANGE}      не смог скопировать архив на USB${CLR_RESET}"
fi
sync

if [ "$BATCH" != "1" ]; then
	echo "      поднимаю шару для доступа к бэкапу..."
	share_up
	echo -e "      ${CLR_GREEN}Доступ к бэкапу по локальной сети: "
	echo -e "      ${CLR_YELLOW}\\\\\\\\$(get_router_ip)\\overlaybackup"
	echo -e "      user: 12345   password: 12345${CLR_RESET}"
	echo
else
	echo "      архив готов для скачивания через веб-интерфейс"
fi

echo
STAGE9="[9/9] fstab"
echo "$STAGE9 ..."

UUID=$(block info "$PART" | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)
if [ -z "$UUID" ]; then
	sleep 1
	mkdir -p "$MNT/upper/root"
	sleep 1; sync
	cp /tmp/usb-extroot.log "$MNT/upper/root/usb-extroot.log" 2>/dev/null || true
	umount "$MNT" 2>/dev/null || true
	fatal "$STAGE9" "Не получил UUID для $PART."
fi

uci -q delete fstab.extroot
uci set fstab.extroot=mount
uci set fstab.extroot.uuid="$UUID"
uci set fstab.extroot.target="/overlay"
uci set fstab.extroot.enabled="1"
uci -q delete fstab.rwm
uci commit fstab

uci -c "$CFG" -q delete fstab.extroot
uci -c "$CFG" set fstab.extroot=mount
uci -c "$CFG" set fstab.extroot.uuid="$UUID"
uci -c "$CFG" set fstab.extroot.target="/overlay"
uci -c "$CFG" set fstab.extroot.enabled="1"
uci -c "$CFG" -q delete fstab.rwm
uci -c "$CFG" commit fstab

echo -e "      extroot: UUID=${CLR_YELLOW}$UUID${CLR_RESET} -> /overlay"
echo "Проверка живого fstab:"
uci show fstab 2>/dev/null | grep -E 'extroot' || echo "      (extroot не найден!)"

echo "Проверка fstab на USB:"
grep -E 'extroot' "$CFG/fstab" || echo "      (extroot не найден!)"

REBOOT_HELPER="$MNT/upper/root/reboot_after.sh"
mkdir -p "$MNT/upper/root"

sleep 1; sync
cp /tmp/usb-extroot.log "$MNT/upper/root/usb-extroot.log" 2>/dev/null || true

cat > "$REBOOT_HELPER" <<-'EOF'
	#!/bin/sh
	# MAIN
	WAIT_BEFORE_REBOOT=20

	rm -f /root/reboot_after.sh
	uci -q delete ksmbd.overlaybackup
	uci -q commit ksmbd
	if command -v ksmbd.useradmin >/dev/null 2>&1; then
		ksmbd.useradmin -d 12345 >/dev/null 2>&1
	fi
	sed -i '/^12345:/d' /etc/passwd
	[ -f /etc/shadow ] && sed -i '/^12345:/d' /etc/shadow
	sed -i '/^\/root\/reboot_after\.sh$/d' /etc/rc.local 2>/dev/null || true

	mkdir -p /overlay
	sleep 1
	sync

	sleep "$WAIT_BEFORE_REBOOT"

	if ! mount | grep -q ' /rom/overlay ' && mount | grep -q ' /overlay '; then
		rm -f /flagfile
		/etc/init.d/ac_recovery.sh stop
		exit 0
	fi

	sync
	delay="40"
	setsid sh -c "
		trap '' TERM
		sleep $delay
		echo b > /proc/sysrq-trigger
		sleep 1
		reboot -f
	" &
	sleep 1
	reboot

EOF
chmod +x "$REBOOT_HELPER"
if [ ! -f "$MNT/upper/etc/rc.local" ]; then
	printf '#!/bin/sh\n# Put your custom commands here that should be executed once\n# the system init finished. By default this file does nothing.\n\nexit 0\n' > "$MNT/upper/etc/rc.local"
fi
if ! grep -q '^/root/reboot_after.sh$' "$MNT/upper/etc/rc.local"; then
	sed -i '/^exit 0/i /root/reboot_after.sh' "$MNT/upper/etc/rc.local"
fi
chmod +x "$MNT/upper/etc/rc.local"

sync
sleep 3

if [ "$BATCH" = "1" ]; then
	echo -e "ОЖИДАНИЕ СКАЧИВАНИЯ АРХИВА (ожидание подтверждения пользователя)..."
	sleep 37173 &
	SLEEP_PID=$!
	wait $SLEEP_PID 2>/dev/null || true
fi


echo -e "${CLR_GREEN}================================================================${CLR_RESET}"
echo

if [ "$BATCH" != "1" ]; then
    echo -e "${CLR_GREEN} Готово. 
 Бэкап (ОЗУ):   $BACKUP_ARCHIVE
 Бэкап (USB):   /usb-extroot-backups/$(basename "$BACKUP_ARCHIVE")${CLR_RESET}"
	echo
	echo -e "${CLR_YELLOW}    Доступ к бэкапу по локальной сети: \\\\\\\\$(get_router_ip)\\overlaybackup${CLR_RESET}"
	echo -e "${CLR_YELLOW}    user: 12345   password: 12345${CLR_RESET}"
	echo
fi



echo -e "${CLR_ORANGE}    При перезагрузке  возможно зависание роутера!${CLR_RESET}"
echo -e "${CLR_ORANGE}    Перезапустите роутер отключив и подав питание.${CLR_RESET}"
echo
echo -e "${CLR_GREEN}================================================================${CLR_RESET}"

sync
sleep 3
umount "$MNT" 2>/dev/null || true
rm -rf "$STAGE_DIR" 2>/dev/null || true

confirm_reboot_or_die 1
