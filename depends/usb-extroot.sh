#!/bin/sh
# ============================================================
#  usb-extroot.sh  v0.1.45.00-draft-ref**tored
#  Перенос overlay OpenWrt на USB-накопитель (extroot)
#  Лог: /tmp/usb-extroot.log
#  Бэкап: /tmp/.usb-extroot-x7k2m9q4p1w8/
#  Запуск: sh /opt/usb-extroot/usb-extroot.sh
# 
#  Установка:
#  sh <( wget -qO- https://raw.githubusercontent.com/kkkkCampbell/USB-extroot/refs/heads/draft-ref---tored/install.sh )
#  
# ============================================================
ver="v0.1.45.00-draft-ref**tored"
SRC_BASE="https://raw.githubusercontent.com/kkkkCampbell/USB-extroot/refs/heads/draft"
TEST_MODE=0
EST_UBIFS_PCT=120
EST_OTHER_PCT=110

if [ -f /opt/usb-extroot/lib/paths.sh ]; then
    . /opt/usb-extroot/lib/paths.sh
else
    UE_RT="${UE_RT:-/tmp/usb-extroot}"
    LOG="$UE_RT/usb-extroot.log"
    PID_FILE="$UE_RT/usb-extroot.pid"
    REBOOT_NOW="$UE_RT/reboot-now"
    REBOOT_CANCEL="$UE_RT/reboot-cancel"
    STAGE_DIR="$UE_RT/stage"
    MNT_DIR="$UE_RT/mnt"
    ERR_DIR="$UE_RT/err"
    PKG_DIR="$UE_RT/pkg"
    BACKUPS_DIR="$UE_RT/backups"
    BACKUPS_MANUAL="$BACKUPS_DIR/manual"
    BACKUPS_AUTO="$BACKUPS_DIR/auto"
    BACKUPS_EMERGENCY="$BACKUPS_DIR/emergency_backup"
fi

# ============================================================
#  L1 — УТИЛИТЫ
# ============================================================
have() { command -v "$1" >/dev/null 2>&1; }

run_tar() {
	if tar cf /dev/null /dev/null 2>/dev/null; then
		tar "$@"
	elif [ -x /rom/bin/tar ]; then
		/rom/bin/tar "$@"
	else
		return 127
	fi
}

parent_dev() {
	local d="$1"
	case "$d" in
		/dev/mmcblk*p[0-9]*) echo "${d%p[0-9]*}" ;;
		/dev/sd[a-z][0-9]*)  echo "${d%[0-9]*}" ;;
		/dev/nvme*n*p[0-9]*) echo "${d%p[0-9]*}" ;;
		/dev/vd[a-z][0-9]*)  echo "${d%p[0-9]*}" ;;
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
	local dev="$1" b parent size_str
	b=$(basename "$1")
	if is_internal_dev "$dev"; then
		local mp=$(awk -v d="$dev" '$1==d {print $2; exit}' /proc/mounts)
		if [ -n "$mp" ]; then
			local size_mb=$(df -m "$mp" 2>/dev/null | awk 'NR==2 {print $2}')
			if [ -n "$size_mb" ] && [ "$size_mb" -gt 1024 ]; then
				size_str=$(awk "BEGIN {printf \"%.1fG\", $size_mb/1024}")
			else
				size_str="${size_mb:-?}M"
			fi
			echo "$dev $size_str Внутренняя память"
		else
			echo "$dev Внутренняя память"
		fi
		return
	fi
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

get_backup_name() {
	local ts=$(date +%Y-%m-%d_%H.%M)
	local hostname=$(cat /proc/sys/kernel/hostname 2>/dev/null | tr -d '\r\n')
	[ -z "$hostname" ] && hostname=$(uname -n)
	hostname=$(echo "$hostname" | tr -c 'a-zA-Z0-9_.-' '_' | tr 'A-Z' 'a-z' | sed 's/_$//')
	local os_id="OpenWrt"
	local os_rel=""
	local os_rev=""
	if [ -f /etc/openwrt_release ]; then
		. /etc/openwrt_release
		os_id="${DISTRIB_ID:-$os_id}"
		os_rel="${DISTRIB_RELEASE:-}"
		os_rev="${DISTRIB_REVISION:-}"
	fi
	[ -z "$os_rel" ] && os_rel="$(uname -r)"
	os_rev="${os_rev%%-*}"
	os_id=$(echo "$os_id" | tr -c 'a-zA-Z0-9_.-' '_' | sed 's/_$//')
	os_rel=$(echo "$os_rel" | tr -c 'a-zA-Z0-9_.-' '_' | sed 's/_$//')
	os_rev=$(echo "$os_rev" | tr -c 'a-zA-Z0-9_.-' '_' | sed 's/_$//')
	local distro_part="${os_id}"
	[ -n "$os_rel" ] && distro_part="${distro_part}-${os_rel}"
	[ -n "$os_rev" ] && distro_part="${distro_part}-${os_rev}"
	echo "${hostname}_${distro_part}_${ts}.tar.gz"
}

get_partition_uuid() {
	local part="$1"
	local uuid
	uuid=$(block info "$part" 2>/dev/null | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)
	if [ -z "$uuid" ]; then
		sleep 1
		uuid=$(block info "$part" 2>/dev/null | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)
	fi
	echo "$uuid"
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

quick_overlay_dev() {
	local mp
	mp=$(get_current_overlay)
	awk -v m="$mp" '$2==m {print $1; exit}' /proc/mounts
}

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
			tmpmnt="$UE_RT/mnt/ovl.$$"
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

tar_is_full() {
	local t
	t=$(command -v tar 2>/dev/null) || return 1
	case "$(readlink -f "$t" 2>/dev/null)" in
		*/busybox|*/busybox.*) return 1 ;;
	esac
	tar --version 2>/dev/null | grep -qE 'GNU tar|bsdtar' && return 0
	return 1
}

fs_in_kernel() {
	local fs="$1"
	grep -qw "$fs" /proc/filesystems 2>/dev/null && return 0
	find "/lib/modules/$(uname -r)" -name "${fs}.ko*" 2>/dev/null | grep -q . && return 0
	return 1
}

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

detect_pm() {
	if command -v apk  >/dev/null 2>&1; then echo apk
	elif command -v opkg >/dev/null 2>&1; then echo opkg
	else echo none
	fi
}

rotate_backups() {
	local bk_dir="$1"
	local bk_rotate="$2"
	local pattern="${3:-*.tar.gz}"
	local total
	total=$(ls -1 "$bk_dir"/$pattern 2>/dev/null | wc -l)
	if [ "$total" -gt "$bk_rotate" ]; then
		local remove_count=$((total - bk_rotate))
		ls -1t "$bk_dir"/$pattern 2>/dev/null | tail -n "$remove_count" | while read -r old; do
			rm -f "$old"
			echo "      ротация: удалён старый архив $(basename "$old")"
		done
	fi
}

remove_whiteouts() {
	local local_stage_dir="$1"
	local up="$local_stage_dir/overlay/upper"

	[ -d "$up" ] || return 0

	if [ "$whiteouts_removed" != "1" ]; then
		echo "      удаляю whiteouts из staging..."
		find "$up" -name '.wh.*' 2>/dev/null | while IFS= read -r _f; do rm -f "$_f"; done
		find "$up" -type c 2>/dev/null | while IFS= read -r _f; do rm -f "$_f"; done
		find "$up" -depth -type d 2>/dev/null | while IFS= read -r _d; do
			[ "$_d" = "$up" ] && continue
			rmdir "$_d" 2>/dev/null
		done
		whiteouts_removed=1
	else
		echo "      whiteouts удалены ранее"
	fi
}


storage_quick_check() {
	for d in /dev/sd? /dev/mmcblk?; do
		[ -b "$d" ] || continue
		is_removable_storage "$d" || continue
		return 0
	done
	return 1
}

# ============================================================
#  L1 — ПЕРЕМЕННЫЕ
# ============================================================
opkg_cmd="opkg"
pkg_install_cmd="install"
pkg_update_cmd="update"
if have apk; then
	opkg_cmd="apk"
	pkg_install_cmd="add"
fi
WANT_PKGS="block-mount uci tar e2fsprogs kmod-usb-storage kmod-usb-storage-uas kmod-fs-vfat kmod-fs-exfat kmod-fs-ext4"

# ============================================================
#  L2 — СОСТОЯНИЕ REPAIR
# ============================================================
PKG_REPAIR_ACTIVE=0
PKG_REPAIR_OLD_DNS=""
PKG_REPAIR_Z_STAT=""
PKG_REPAIR_Z2_STAT=""
PKG_REPAIR_Y_STAT=""
PKG_REPAIR_DNS_CHANGED=0
PKG_REPAIR_SVC_STOPPED=0

# ============================================================
#  L2 — DIE / FATAL / SHOUT
# ============================================================
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

shout_fatal() {
	local rip=$(get_router_ip)
	local share_present=0
	uci -q get ksmbd.overlaybackup >/dev/null 2>&1 && share_present=1
	echo -e "${CLR_ORANGE}------------------------------------------------------------${CLR_RESET}"
	echo -e "${CLR_ORANGE} Этап: ${FATAL_STAGE:-<неизвестен>}${CLR_RESET}"
	echo
	echo -e "${CLR_YELLOW} Бэкап overlay (если создан):${CLR_RESET}"
	echo "    ${BACKUP_DIR:-$UE_RT/backups}/"
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
	cp "$LOG" "${BACKUP_DIR:-$BACKUPS_DIR}/" 2>/dev/null || true
	shout_fatal
	exit 1
}

# ============================================================
#  L2 — PKG REPAIR
# ============================================================
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
		apk)  echo "        apk update";  apk update >/dev/null 2>&1 ;;
		opkg) echo "        opkg update"; opkg update >/dev/null 2>&1 ;;
		*)    echo "        нет apk/opkg — индексы не обновляю" ;;
	esac
	PKG_REPAIR_ACTIVE=1
	if [ "$PKG_REPAIR_DNS_CHANGED" = "1" ] || [ "$PKG_REPAIR_SVC_STOPPED" = "1" ]; then
		return 0
	fi
	return 1
}

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

# ============================================================
#  L2 — PKG ENSURE
# ============================================================
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

# ============================================================
#  L2 — SHARE (SMB)
# ============================================================
cleanup_smb_user() {
	if command -v ksmbd.useradmin >/dev/null 2>&1; then
		ksmbd.useradmin -d 12345 >/dev/null 2>&1
	fi
	sed -i '/^12345:/d' /etc/passwd 2>/dev/null
	[ -f /etc/shadow ] && sed -i '/^12345:/d' /etc/shadow 2>/dev/null
}

share_up() {
	local share_path="${1:-${BACKUP_DIR:-$UE_RT/backups}}"
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
		uci -q set ksmbd.overlaybackup.path="$share_path"
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
		rm -rf "$UE_RT/backups"
		/etc/init.d/ksmbd restart; 
	fi
	cleanup_smb_user
}


# ============================================================
#  L2 — chmod_777
#  Рекурсивно 777 на всё в $UE_RT/stage и $UE_RT/backups.
#  ksmbd из OpenWrt не всегда корректно прокидывает права в Windows-
#  клиент, приходится ровнять ФС-права руками.
# ============================================================
chmod_777() {
    [ -d "$UE_RT/stage" ]   && chmod -R 777 "$UE_RT/stage"   2>/dev/null || true
    [ -d "$UE_RT/backups" ] && chmod -R 777 "$UE_RT/backups" 2>/dev/null || true
    return 0
}


DESTRUCTIVE_PHASE=0

_handle_stop() {
    if [ "$DESTRUCTIVE_PHASE" = "1" ]; then
		echo
        echo "STOP во время деструктивной фазы — игнорирую. Операция продолжится до безопасной точки."
        return 0
    fi
    echo "Прервано. Восстанавливаю состояние..."
    pkg_repair_finish
    exit 130
}

# Базовый trap INT/TERM/HUP — срабатывает при Ctrl+C в любом режиме.
# В batch-секции ниже переопределяется с _cleanup_pid_and_lock.
trap '_handle_stop' INT TERM HUP

# ============================================================
#  L2 — FSTAB
# ============================================================
clear_fstab_extroot() {
	local cfg_dir="${1:-}"
	if [ -n "$cfg_dir" ]; then
		uci -c "$cfg_dir" -q delete fstab.extroot
		uci -c "$cfg_dir" -q delete fstab.rwm
		uci -c "$cfg_dir" commit fstab 2>/dev/null
	else
		uci -q delete fstab.extroot
		uci -q delete fstab.rwm
		uci commit fstab 2>/dev/null
	fi
}

apply_fstab_extroot() {
	local uuid="$1"
	local cfg_dir="${2:-}"
	clear_fstab_extroot "$cfg_dir"
	if [ -n "$cfg_dir" ]; then
		uci -c "$cfg_dir" set fstab.extroot=mount
		uci -c "$cfg_dir" set fstab.extroot.uuid="$uuid"
		uci -c "$cfg_dir" set fstab.extroot.target="/overlay"
		uci -c "$cfg_dir" set fstab.extroot.enabled="1"
		uci -c "$cfg_dir" commit fstab 2>/dev/null
	else
		uci set fstab.extroot=mount
		uci set fstab.extroot.uuid="$uuid"
		uci set fstab.extroot.target="/overlay"
		uci set fstab.extroot.enabled="1"
		uci commit fstab
	fi
}

# ============================================================
#  L2 — REBOOT HELPER
# ============================================================
create_reboot_helper() {
	local target_root="$1"
	local helper_type="${2:-MAIN}"
	local reboot_helper="$target_root/root/reboot_after.sh"
	mkdir -p "$target_root/root"
	cat > "$reboot_helper" <<-EOF
	#!/bin/sh
	# $helper_type
	WAIT_BEFORE_REBOOT=20

	rm -f /root/reboot_after.sh
	uci -q delete ksmbd.overlaybackup
	uci -q commit ksmbd
	command -v ksmbd.useradmin >/dev/null 2>&1 && ksmbd.useradmin -d 12345 >/dev/null 2>&1
	sed -i '/^12345:/d' /etc/passwd
	[ -f /etc/shadow ] && sed -i '/^12345:/d' /etc/shadow
	sed -i '/^\/root\/reboot_after\.sh$/d' /etc/rc.local 2>/dev/null || true

	mkdir -p /overlay
	sleep 1
	sync

	sleep "\$WAIT_BEFORE_REBOOT"

	if ! mount | grep -q ' /rom/overlay ' && mount | grep -q ' /overlay '; then
		rm -f /flagfile
		/etc/init.d/ac_recovery.sh stop
		exit 0
	fi

	sync
	delay="40"
	setsid sh -c "
		trap '' TERM
		sleep \$delay
		echo b > /proc/sysrq-trigger
		sleep 1
		reboot -f
	" &
	sleep 1
	reboot
	EOF
	chmod +x "$reboot_helper"
	mkdir -p "$target_root/etc"
	if [ ! -f "$target_root/etc/rc.local" ]; then
		printf '#!/bin/sh\n# Put your custom commands here that should be executed once\n# the system init finished. By default this file does nothing.\n\nexit 0\n' > "$target_root/etc/rc.local"
	fi
	if ! grep -q '^/root/reboot_after.sh$' "$target_root/etc/rc.local"; then
		sed -i '/^exit 0/i /root/reboot_after.sh' "$target_root/etc/rc.local"
	fi
	chmod +x "$target_root/etc/rc.local"
}

# ============================================================
#  L2 — SOFT REBOOT
# ============================================================
soft_reboot_with_fallback() {
	local delay="${1:-40}"
	sync
	sleep 3
	if [ "$BATCH" = "1" ] && [ "$BATCH_BACKUP" = "yes" ] && [ -n "$ARCHIVE_WAIT" ] && [ "$ARCHIVE_WAIT" -gt 0 ]; then
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
		echo "Перезагружаюсь..."
		sleep 5
		echo b > /proc/sysrq-trigger
		sleep 1
		reboot -f
	" &
	sleep 2
	if [ "$MODE" = "noformat" ] || [ "$MODE" = "revert_extroot" ]; then
		echo "Перезагружаюсь..."
		sleep 5
		reboot -f
	fi
	echo "Перезагружаюсь..."
	sleep 5
	reboot
}


# ============================================================
#  L2 — WAIT FOR REBOOT ACTION
#  Ждёт, пока UI не создаст $REBOOT_NOW или $REBOOT_CANCEL.
#  Каждые 60 сек пишет в лог.
# ============================================================
_wait_for_reboot_action() {
    DESTRUCTIVE_PHASE=0
    echo -e " \033[38;2;17;17;17mEXTROOT_READY_CODE_777888\033[0m\n"
    echo -e "${CLR_GREEN}================================================================${CLR_RESET}"
    echo " ${CLR_GREEN}ОЖИДАНИЕ ДЕЙСТВИЯ ПОЛЬЗОВАТЕЛЯ...${CLR_RESET}"
    echo -e "${CLR_GREEN}================================================================${CLR_RESET}"
    echo
    local _waited=0
    while true; do
        if [ -f "$REBOOT_NOW" ]; then
            rm -f "$REBOOT_NOW"
            break
        fi
        if [ -f "$REBOOT_CANCEL" ]; then
            rm -f "$REBOOT_CANCEL"
            echo "Пользователь отменил перезагрузку. Завершаю работу."
            exit 0
        fi
        sleep 1
        _waited=$((_waited + 1))
        if [ $((_waited % 60)) -eq 0 ]; then
            echo "      жду действия пользователя, прошло $((_waited / 60)) мин..."
        fi
    done
}


# ============================================================
#  L2 — CONFIRM REBOOT
# ============================================================
confirm_reboot_or_die() {
	DESTRUCTIVE_PHASE=0
	local cancel=0 i
	local has_backup=0
	[ -n "$PRE_OP_BACKUP_ARCHIVE" ] && has_backup=1

	if [ "$BATCH" = "1" ]; then
		soft_reboot_with_fallback 40
		return
	fi

	echo
	echo -e "${CLR_GREEN}================================================================${CLR_RESET}"
	echo
	[ -n "    $PRE_REBOOT_MSG" ] && echo -e "${CLR_GREEN} $PRE_REBOOT_MSG${CLR_RESET}"
	if [ "$has_backup" = "1" ]; then
		echo " Бэкап (ОЗУ): $PRE_OP_BACKUP_ARCHIVE"
		[ -n "$PRE_OP_BACKUP_FLASH" ] && echo " Бэкап (флэшка): $PRE_OP_BACKUP_FLASH"
		echo
		echo -e "${CLR_YELLOW}    Доступ к бэкапу по локальной сети: \\\\\\\\$(get_router_ip)\\overlaybackup${CLR_RESET}"
		echo -e "${CLR_YELLOW}    user: 12345   password: 12345${CLR_RESET}"
	fi
	echo
	echo -e "${CLR_ORANGE}    При перезагрузке  возможно зависание роутера!${CLR_RESET}"
	echo -e "${CLR_ORANGE}    Перезапустите роутер отключив и подав питание.${CLR_RESET}"
	echo
	echo -e "${CLR_GREEN}================================================================${CLR_RESET}"
	echo

	if [ "$has_backup" = "1" ]; then
		echo -e "${CLR_ORANGE}!!! ПЕРЕЗАГРУЗКА ЧЕРЕЗ ${ARCHIVE_WAIT} СЕКУНД !!!${CLR_RESET}"
		echo "    Любая клавиша — отмена."
		i=20
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
			echo "Бэкап доступен по сети:"
			echo "  SMB: \\\\$(get_router_ip)\\overlaybackup"
			echo "  user: 12345   password: 12345"
			echo
			echo "НИЧЕГО НЕ ТРОГАЙ и не запускай скрипт повторно,"
			echo "пока не перезагрузишь роутер командой:"
			echo
			echo -e "    ${CLR_YELLOW}reboot${CLR_RESET}"
			echo
			exit 1
		fi
	fi

	share_down
	echo "    Перезагружаюсь..."
	sync
	sleep 2
	soft_reboot_with_fallback 40
}


# ============================================================
#  L2 — DEPS LOADING (switch_overlay)
# ============================================================
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
#  L2 — MOUNT REMOVABLE
# ============================================================
mount_removable_all() {
	local d p base mnt fs any found listed parts_found w usb_ms _u retry=0
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
	while [ "$retry" -lt 3 ]; do
		for d in /dev/sd? /dev/mmcblk?; do
			[ -b "$d" ] && { found=1; break; }
		done
		[ "$found" = "1" ] && break
		sleep 1
		retry=$((retry + 1))
	done
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


# ============================================================
#  L2 — STAGE0/1/2
# ============================================================
stage0_deps() {
	local mode="${1:-install}"
	echo
	STAGE0="[0/9] зависимости"
	echo "$STAGE0 ..."
	echo "      менеджер пакетов: $opkg_cmd"
	if ! tar cf /dev/null /dev/null 2>/dev/null && [ ! -x /rom/bin/tar ]; then
		die "$STAGE0" "tar не работает: ни в PATH, ни /rom/bin/tar.

	Восстановление и бэкап без tar невозможны.
	Проверьте вручную:
	  which tar
	  ls -la /bin/tar /usr/bin/tar /rom/bin/tar
	  readlink -f \$(which tar)
	  tar --version
	  /rom/bin/tar --version

	Если /bin/tar — висячий симлинк на битый /usr/libexec/tar-gnu:
	  rm -f /bin/tar /usr/bin/tar
	После этого /rom/bin/tar снова станет доступен через PATH,
	либо fallback в run_tar сработает прямо сейчас."
	fi
	if ! pkg_ensure; then
		if [ "$mode" = "check" ]; then
			echo -e "${CLR_ORANGE}      часть зависимостей недоступна — продолжаю${CLR_RESET}"
		else
			die "$STAGE0" "Зависимости отсутствуют.

	Проверь вручную:
	  $opkg_cmd $pkg_update_cmd
	  $opkg_cmd $pkg_install_cmd $WANT_PKGS"
		fi
	fi
	if ! tar cf /dev/null /dev/null 2>/dev/null && [ ! -x /rom/bin/tar ]; then
		die "$STAGE0" "tar не работает после установки зависимостей: ни в PATH, ни /rom/bin/tar.

	Проверьте вручную:
	  ls -la /bin/tar /usr/bin/tar /rom/bin/tar
	  readlink -f \$(which tar)
	  tar --version
	  /rom/bin/tar --version"
	fi
	if tar cf /dev/null /dev/null 2>/dev/null; then
		echo -e "${CLR_GREEN}      tar (PATH): доступен${CLR_RESET}"
	elif [ -x /rom/bin/tar ]; then
		echo -e "${CLR_ORANGE}      tar в PATH не работает, использую /rom/bin/tar (busybox)${CLR_RESET}"
	fi
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
	echo "      Найдены внешние накопители:"
	n=0
	for d in $DISKS; do
		n=$((n + 100))
		echo -e "        ${CLR_YELLOW}$n -> ${CLR_GREEN}$(describe $d)  ${CLR_RESET}"
	done
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
			_src_parent=$(parent_dev "$CUR_OVERLAY_DEV")
			_req_parent=$(parent_dev "$BATCH_DEVICE")
			if [ "$_req_parent" = "$_src_parent" ]; then
				echo -e "${CLR_ORANGE}      batch: '$BATCH_DEVICE' — это текущий загрузочный носитель${CLR_RESET}"
				echo "      Форматировать диск, с которого работаем, нельзя."
				echo "      Доступные цели: $DISKS"
			else
				echo -e "${CLR_ORANGE}      batch: устройство '$BATCH_DEVICE' не найдено среди целей${CLR_RESET}"
				echo "      доступно: $DISKS"
			fi
			exit 2
		fi
		echo -e "      batch: выбрано $TARGET (раздел: $BATCH_DEVICE)"
	else
		printf "${CLR_RESET}\nУкажите целевой накопитель (введите число слева, 0 — отмена): "
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
	echo -e "      цель: ${CLR_YELLOW}  $DESC${CLR_RESET}"
	for p in $PARTS; do
		f=$(block info "$p" 2>/dev/null | grep -o 'TYPE="[^"]*"' | cut -d'"' -f2)
		m=$(block info "$p" 2>/dev/null | grep -o 'MOUNT="[^"]*"' | cut -d'"' -f2)
		echo "      $p FS=${f:--} ${m:+смонтирован $m}"
	done
	return 0
}

# ============================================================
#  L2 — PRE_OP_BACKUP
#  ENABLED (yes|no), SOURCE_UPPER, EXCLUDE_MNT (не класть на этот mount)
#  Устанавливает PRE_OP_BACKUP_ARCHIVE (путь в /tmp) и PRE_OP_BACKUP_FLASH (путь на флэшке или пусто)
# ============================================================
PRE_OP_BACKUP_ARCHIVE=""
PRE_OP_BACKUP_FLASH=""
PRE_REBOOT_MSG=""

pre_op_backup() {
	local enabled="${1:-no}"
	local source_upper="$2"
	local op_type="${3:-before_upper_delete}"
	PRE_OP_BACKUP_ARCHIVE=""
	PRE_OP_BACKUP_FLASH=""

	[ "$enabled" = "yes" ] || return 0

	local bk_prefix
	case "$op_type" in
		before_format)       bk_prefix="BF_" ;;
		before_upper_delete) bk_prefix="BUD_" ;;
		*)
			echo "      (pre_op_backup: неизвестный тип '$op_type', использую before_upper_delete)"
			bk_prefix="BUD_"
			;;
	esac

	if [ -z "$source_upper" ] || [ ! -d "$source_upper" ]; then
		echo "      (pre_op_backup: нечего бэкапить, $source_upper отсутствует)"
		return 0
	fi

	local bk_dir_tmp="$UE_RT/backups/emergency_backup"
	mkdir -p "$bk_dir_tmp" || {
		echo "      ВНИМАНИЕ: не смог создать $bk_dir_tmp, пропускаю бэкап"
		return 0
	}

	local bk_name="${bk_prefix}$(get_backup_name)"
	local bk_tmp="$bk_dir_tmp/$bk_name"
	local bk_part="${bk_tmp}.part"

	echo
	echo "      создаю pre-op бэкап: $bk_tmp ..."
	echo "      source: $source_upper"

	local src_parent=$(dirname "$source_upper")
	local src_name=$(basename "$source_upper")

	if ! tar -C "$src_parent" --transform="s|^${src_name}|overlay/upper|" -czf "$bk_part" --exclude="${src_name}/tmp" "$src_name" 2>$UE_RT/err/preop.err; then
		echo "      tar errors:"
		head -20 $UE_RT/err/preop.err 2>/dev/null
		rm -f "$bk_part"
		die "pre_op_backup" "Не удалось создать pre-op бэкап."
	fi

	if ! tar -tzf "$bk_part" >/dev/null 2>&1; then
		rm -f "$bk_part"
		die "pre_op_backup" "Pre-op бэкап повреждён."
	fi

	mv "$bk_part" "$bk_tmp"
	PRE_OP_BACKUP_ARCHIVE="$bk_tmp"
	chmod_777
	local size_kb=$(du -k "$bk_tmp" 2>/dev/null | awk '{print $1}')
	echo "      архив (ОЗУ): $bk_tmp (${size_kb}K)"
	echo "EMERGENCY_ARCHIVE_READY=$bk_tmp"
	echo "      (копия на цель будет создана после завершения разрушительной операции)"

	if [ "$BATCH" = "1" ]; then
		echo "      (batch: ожидание не нужно)"
		return 0
	fi
	if [ ! -t 0 ]; then
		echo "      (no tty: ожидание не нужно)"
		return 0
	fi

	echo "      поднимаю шару..."
	share_up "$bk_dir_tmp"
	echo
	echo "============================================================"
	echo -e " Pre-op бэкап готов:\n $bk_name"
	echo
	echo " Скачайте по локальной сети:"
	echo "   SMB:  \\\\$(get_router_ip)\\overlaybackup"
	echo "   user: 12345   password: 12345"
	echo "============================================================"
	echo
	printf " Нажмите Enter, когда скачаете (авто-продолжение через 10 мин): "
	read -t 600 _ || true
	echo
	return 0
}

# ============================================================
#  L3 — emergency_copy_to_target TARGET_MNT
#  Копирует $PRE_OP_BACKUP_ARCHIVE в <TARGET_MNT>/usb-extroot-backups/emergency_backup/.
#  Ничего не делает если архива нет, если target не смонтирован, если target на ubifs.
# ============================================================
emergency_copy_to_target() {
	local target_mnt="$1"
	[ -n "$PRE_OP_BACKUP_ARCHIVE" ] || return 0
	[ -f "$PRE_OP_BACKUP_ARCHIVE" ] || return 0
	[ -z "$target_mnt" ] && return 0
	[ -d "$target_mnt" ] || return 0

	local _fs=$(awk -v m="$target_mnt" '$2==m {print $3; exit}' /proc/mounts)
	case "$_fs" in
		ubifs) return 0 ;;
	esac

	local dst_dir="$target_mnt/usb-extroot-backups/emergency_backup"
	if ! mkdir -p "$dst_dir" 2>/dev/null; then
		echo "      ВНИМАНИЕ: не смог создать $dst_dir"
		return 0
	fi

	local bk_name=$(basename "$PRE_OP_BACKUP_ARCHIVE")
	if cp "$PRE_OP_BACKUP_ARCHIVE" "$dst_dir/$bk_name" 2>/dev/null; then
		PRE_OP_BACKUP_FLASH="$dst_dir/$bk_name"
		echo "      emergency-бэкап скопирован на цель: $PRE_OP_BACKUP_FLASH"
		echo "EMERGENCY_ARCHIVE_READY=$PRE_OP_BACKUP_FLASH"
	else
		echo "      ВНИМАНИЕ: не смог скопировать $bk_name на $target_mnt"
	fi
	return 0
}
# ============================================================
#  L3 — do_backup TYPE (manual|auto)
# ============================================================
do_backup() {
	local bk_type="${1:-}"
	case "$bk_type" in
		manual|auto) ;;
		*) die "do_backup" "Неизвестный тип: '$bk_type'" ;;
	esac

	if [ "$bk_type" = "manual" ]; then
		BK_TYPE="manual"
		BK_PREFIX="manual-backup-full_"
		BK_ROTATE=$(uci -q get usb-extroot.main.manual_rotate 2>/dev/null)
		[ -z "$BK_ROTATE" ] && BK_ROTATE=50
		case "$BK_ROTATE" in ''|*[!0-9]*) BK_ROTATE=50 ;; esac
		[ "$BK_ROTATE" -lt 5 ]  && BK_ROTATE=5
		[ "$BK_ROTATE" -gt 50 ] && BK_ROTATE=50
		BK_SUBDIR="manual"
		if ! tar_is_full; then
			echo "      устанавливаю GNU tar..."
			$opkg_cmd $pkg_update_cmd >/dev/null 2>&1 || true
			$opkg_cmd $pkg_install_cmd tar >/dev/null 2>&1 || true
		fi
	else
		BK_TYPE="auto"
		BK_PREFIX="auto-backup-full-"
		BK_ROTATE=$(uci -q get usb-extroot.main.auto_rotate 2>/dev/null)
		[ -z "$BK_ROTATE" ] && BK_ROTATE=30
		case "$BK_ROTATE" in ''|*[!0-9]*) BK_ROTATE=30 ;; esac
		[ "$BK_ROTATE" -lt 3 ]  && BK_ROTATE=3
		[ "$BK_ROTATE" -gt 20 ] && BK_ROTATE=20
		BK_SUBDIR=""
	fi

	if [ "$BK_TYPE" = "auto" ]; then
		AUTO_ENABLED=$(uci -q get usb-extroot.main.autobackup_enabled 2>/dev/null)
		if [ "$AUTO_ENABLED" = "0" ]; then
			echo "backup: автобэкап отключён в настройках, пропуск"
			return 0
		fi
		if [ -f $UE_RT/autobackup.done ]; then
			echo "backup: уже выполнялся в эту загрузку, пропуск"
			return 0
		fi
	fi

	if [ "$BK_TYPE" = "manual" ]; then
		have tar || die "$CHOICE_TEXT" "tar не найден."
		have uci || die "$CHOICE_TEXT" "uci не найден."
	fi

	if [ -n "$BATCH_DEVICE" ]; then
		if [ "$BATCH_DEVICE" = "active" ]; then
			BK_OVERLAY_DEV=$(quick_overlay_dev)
		elif [ "$BATCH_DEVICE" = "internal" ]; then
			BK_OVERLAY_DEV=$(find_internal_overlay_dev)
			if [ $? -ne 0 ]; then
				die "$CHOICE_TEXT" "Внутренний overlay не найден."
			fi
		else
			BK_OVERLAY_DEV="$BATCH_DEVICE"
		fi
	else
		BK_OVERLAY_DEV=$(quick_overlay_dev)
	fi

	if [ -z "$BK_OVERLAY_DEV" ]; then
		if [ "$BK_TYPE" = "manual" ]; then
			die "$CHOICE_TEXT" "Не нашёл устройство /overlay."
		fi
		echo "backup: /overlay не смонтирован, пропуск"
		return 0
	fi

	BK_IS_INTERNAL=0
	if is_internal_dev "$BK_OVERLAY_DEV"; then
		if [ "$BK_TYPE" = "manual" ]; then
			BK_IS_INTERNAL=1
		else
			echo "backup: overlay на внутреннем носителе ($BK_OVERLAY_DEV), пропуск"
			return 0
		fi
	fi

	BK_MNT=$(awk -v p="$BK_OVERLAY_DEV" '$1==p {print $2; exit}' /proc/mounts)
	BK_NEED_UMOUNT=0

	if [ -z "$BK_MNT" ] || [ ! -d "$BK_MNT" ]; then
		if [ "$BK_TYPE" != "manual" ]; then
			echo "backup: нет точки монтирования для $BK_OVERLAY_DEV, пропуск"
			return 0
		fi
		BK_MNT="$UE_RT/mnt/bk.$$"
		mkdir -p "$BK_MNT" || die "$CHOICE_TEXT" "Не смог создать $BK_MNT"
		if is_internal_dev "$BK_OVERLAY_DEV"; then
			if ! mount -t ubifs "$BK_OVERLAY_DEV" "$BK_MNT" 2>/dev/null && \
			   ! mount "$BK_OVERLAY_DEV" "$BK_MNT" 2>/dev/null; then
				rmdir "$BK_MNT" 2>/dev/null || true
				die "$CHOICE_TEXT" "Не смог смонтировать внутренний overlay $BK_OVERLAY_DEV."
			fi
		else
			if ! mount "$BK_OVERLAY_DEV" "$BK_MNT" 2>/dev/null; then
				rmdir "$BK_MNT" 2>/dev/null || true
				die "$CHOICE_TEXT" "Не смог смонтировать $BK_OVERLAY_DEV."
			fi
		fi
		BK_NEED_UMOUNT=1
		echo "      временно смонтирован $BK_OVERLAY_DEV -> $BK_MNT"
	fi

	if [ ! -d "$BK_MNT/upper" ]; then
		[ "$BK_NEED_UMOUNT" = "1" ] && umount "$BK_MNT" 2>/dev/null
		[ "$BK_NEED_UMOUNT" = "1" ] && rmdir "$BK_MNT" 2>/dev/null || true
		if [ "$BK_TYPE" = "manual" ]; then
			die "$CHOICE_TEXT" "Нет $BK_MNT/upper."
		fi
		echo "backup: $BK_MNT/upper отсутствует, пропуск"
		return 0
	fi

	CUR_ACTIVE_DEV=$(quick_overlay_dev)
	if [ "$BK_IS_INTERNAL" = "1" ] || [ "$BK_NEED_UMOUNT" = "1" ] || [ "$BK_OVERLAY_DEV" != "$CUR_ACTIVE_DEV" ]; then
		BK_DIR="$UE_RT/backups"
		[ -n "$BK_SUBDIR" ] && BK_DIR="$BK_DIR/$BK_SUBDIR"
		BK_DST_FS="/tmp"
	else
		BK_DIR="$BK_MNT/usb-extroot-backups"
		[ -n "$BK_SUBDIR" ] && BK_DIR="$BK_DIR/$BK_SUBDIR"
		BK_DST_FS="$BK_MNT"
	fi

	if ! mkdir -p "$BK_DIR" 2>/dev/null; then
		[ "$BK_NEED_UMOUNT" = "1" ] && umount "$BK_MNT" 2>/dev/null
		[ "$BK_NEED_UMOUNT" = "1" ] && rmdir "$BK_MNT" 2>/dev/null || true
		if [ "$BK_TYPE" = "manual" ]; then
			die "$CHOICE_TEXT" "Не смог создать $BK_DIR."
		fi
		echo "backup: не смог создать $BK_DIR, пропуск"
		return 0
	fi

	BK_UPPER_KB=$(du -sk "$BK_MNT/upper" 2>/dev/null | awk '{print $1}')
	BK_AVAIL_KB=$(df -k "$BK_DST_FS" 2>/dev/null | awk 'NR==2 {print $4}')

	if [ -z "$BK_UPPER_KB" ] || [ -z "$BK_AVAIL_KB" ]; then
		[ "$BK_NEED_UMOUNT" = "1" ] && umount "$BK_MNT" 2>/dev/null
		[ "$BK_NEED_UMOUNT" = "1" ] && rmdir "$BK_MNT" 2>/dev/null || true
		if [ "$BK_TYPE" = "manual" ]; then
			die "$CHOICE_TEXT" "Не смог определить размер upper или свободное место."
		fi
		echo "backup: не смог определить размеры, пропуск"
		return 0
	fi

	if [ "$BK_DST_FS" != "/tmp" ] && [ "$BK_AVAIL_KB" -lt $((BK_UPPER_KB * 2)) ]; then
		[ "$BK_NEED_UMOUNT" = "1" ] && umount "$BK_MNT" 2>/dev/null
		[ "$BK_NEED_UMOUNT" = "1" ] && rmdir "$BK_MNT" 2>/dev/null || true
		if [ "$BK_TYPE" = "manual" ]; then
			die "$CHOICE_TEXT" "Мало места: upper=${BK_UPPER_KB}K, свободно=${BK_AVAIL_KB}K.
Нужно минимум $((BK_UPPER_KB * 2))K."
		fi
		echo "backup: мало места (upper=${BK_UPPER_KB}K avail=${BK_AVAIL_KB}K), пропуск"
		return 0
	fi

	[ -d "$BK_DIR" ] && \
		find "$BK_DIR" -name '*.part' -mtime +1 -delete 2>/dev/null || true

	BK_FILE="$BK_DIR/${BK_PREFIX}$(get_backup_name)"
	BK_PART_FILE="${BK_FILE}.part"

	echo "      тип: $BK_TYPE"
	echo "      overlay: $BK_OVERLAY_DEV -> $BK_MNT"
	echo "      upper: ${BK_UPPER_KB}K, свободно: ${BK_AVAIL_KB}K"
	echo "      создаю $BK_FILE ..."

	TAR_OK=0
	if [ "$BK_OVERLAY_DEV" = "$CUR_ACTIVE_DEV" ] && [ "$BK_MNT" = "$(get_current_overlay)" ]; then
		if tar -C / -czf "$BK_PART_FILE" --exclude=overlay/upper/tmp overlay/upper 2>/tmp/usb-extroot-bk.err; then
			TAR_OK=1
		fi
	else
		if tar -C "$BK_MNT" --transform='s|^upper|overlay/upper|' -czf "$BK_PART_FILE" --exclude='upper/tmp' upper 2>/tmp/usb-extroot-bk.err; then
			TAR_OK=1
		else
			STAGE_TMP=$(mktemp -d $UE_RT/mnt/bkstage.XXXXXX 2>/dev/null) || STAGE_TMP=""
			if [ -n "$STAGE_TMP" ]; then
				mkdir -p "$STAGE_TMP/overlay"
				if ln -s "$BK_MNT/upper" "$STAGE_TMP/overlay/upper" 2>/dev/null && \
				   tar -C "$STAGE_TMP" -czhf "$BK_PART_FILE" --exclude='overlay/upper/tmp' overlay 2>/tmp/usb-extroot-bk.err; then
					TAR_OK=1
				fi
				rm -rf "$STAGE_TMP"
			fi
		fi
	fi

	if [ "$TAR_OK" != "1" ]; then
		rc=$?
		echo "      tar errors (exit code: $rc):"
		if [ -s /tmp/usb-extroot-bk.err ]; then
			head -20 /tmp/usb-extroot-bk.err
		else
			if [ "$rc" -eq 137 ] || [ "$rc" -eq 143 ]; then
				echo "        [OOM] Процесс убит OOM-killer'ом из-за нехватки ОЗУ."
			else
				echo "        [ENOSPC/ERR] stderr пуст. Вероятно, закончилось место в /tmp."
			fi
		fi
		rm -f "$BK_PART_FILE"
		[ "$BK_NEED_UMOUNT" = "1" ] && umount "$BK_MNT" 2>/dev/null
		[ "$BK_NEED_UMOUNT" = "1" ] && rmdir "$BK_MNT" 2>/dev/null || true
		if [ "$BK_TYPE" = "manual" ]; then
			die "$CHOICE_TEXT" "Не удалось создать архив."
		fi
		echo "backup: tar failed, exit"
		return 1
	fi

	if ! tar -tzf "$BK_PART_FILE" >/dev/null 2>&1; then
		rm -f "$BK_PART_FILE"
		[ "$BK_NEED_UMOUNT" = "1" ] && umount "$BK_MNT" 2>/dev/null
		[ "$BK_NEED_UMOUNT" = "1" ] && rmdir "$BK_MNT" 2>/dev/null || true
		if [ "$BK_TYPE" = "manual" ]; then
			die "$CHOICE_TEXT" "Архив повреждён."
		fi
		echo "backup: verify failed, exit"
		return 1
	fi

	mv "$BK_PART_FILE" "$BK_FILE"
	chmod_777
	sync

	if [ "$BK_NEED_UMOUNT" = "1" ]; then
		umount "$BK_MNT" 2>/dev/null || umount -l "$BK_MNT" 2>/dev/null || true
		rmdir "$BK_MNT" 2>/dev/null || true
		echo "      временный mount снят"
	fi

	BK_SIZE_KB=$(du -k "$BK_FILE" 2>/dev/null | awk '{print $1}')
	echo -e "${CLR_GREEN}      архив: $BK_FILE (${BK_SIZE_KB}K)${CLR_RESET}"

	rotate_backups "$BK_DIR" "$BK_ROTATE"

	if [ "$BK_TYPE" = "auto" ]; then
		touch $UE_RT/autobackup.done
	fi

	if [ "$BK_TYPE" = "manual" ]; then
		echo
		echo "MANUAL_ARCHIVE_READY=$BK_FILE"
		echo "Архивация завершена."
	fi

	return 0
}


# ============================================================
#  L3 — do_transfer FORMAT (1=format, 0=noformat)
# ============================================================
do_transfer() {
	local do_format="${1:-0}"
	local MODE_local
	if [ "$do_format" = "1" ]; then
		MODE="format"
		CHOICE_TEXT="форматировать и перенести"
	else
		MODE="noformat"
		CHOICE_TEXT="перенести без форматирования"
	fi

	CUR_OVERLAY_MP=$(get_current_overlay)
	CUR_OVERLAY_DEV=$(awk -v m="$CUR_OVERLAY_MP" '$2==m {print $1; exit}' /proc/mounts)
	if [ -z "$CUR_OVERLAY_DEV" ]; then
		die "$CHOICE_TEXT" "Не нашёл устройство $CUR_OVERLAY_MP."
	fi
	SKIP_PARENT=$(parent_dev "$CUR_OVERLAY_DEV")

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
		[ "$diag_found" = "0" ] && echo "        /dev/sd* и /dev/mmcblk* отсутствуют"
		die "$CHOICE_TEXT" "Внешних съёмных накопителей не найдено."
	fi

	USB_TARGET=""
	for d in /dev/sd? /dev/mmcblk?; do
		[ -b "$d" ] || continue
		is_removable_storage "$d" || continue
		[ "$(parent_dev "$d")" = "$SKIP_PARENT" ] && continue
		USB_TARGET="$d"
		break
	done
	if [ -z "$USB_TARGET" ]; then
		die "$CHOICE_TEXT" "Внешних накопителей для переноса не найдено."
	fi

	stage0_deps check
	stage1_overlay
	if ! stage2_find_usb; then
		die "$CHOICE_TEXT" "Внешний накопитель найден, но не определён как диск."
	fi

	echo
	STAGE3="[3/9] проверки безопасности"
	echo "$STAGE3 ..."
	SRC_SIZE_KB=$(du -sk "$CUR_OVERLAY_MP/upper" 2>/dev/null | awk '{print $1}')
	rm -rf "$UE_RT/stage"
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
		if [ "$do_format" = "1" ]; then
			echo -e "${CLR_ORANGE}Все данные на $DESC будут уничтожены!${CLR_RESET}"
		else
			echo -e "${CLR_YELLOW}На $PART будет удалена только overlay-структура.${CLR_RESET}"
		fi
		echo
		echo "Сейчас будет уничтожены данные на накопителе:"
		echo -e "    ${CLR_YELLOW}$DESC${CLR_RESET}"
		echo -e "    раздел: ${CLR_YELLOW}$PART${CLR_RESET}"
		echo
		if [ "$do_format" = "1" ]; then
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
	echo -e "      Подтверждено: ${CLR_YELLOW}$TARGET ($MODE)${CLR_RESET}."

	echo
	STAGE6="[6/9] staging overlay"
	STAGE_DIR=$UE_RT/stage
	echo "$STAGE6 в $STAGE_DIR ..."
	rm -rf "$STAGE_DIR"
	mkdir -p "$STAGE_DIR/overlay/upper"
	chmod_777
	echo "      копирую upper/ из $CUR_OVERLAY_MP ..."
	if ! cp -a "$CUR_OVERLAY_MP/upper/." "$STAGE_DIR/overlay/upper/" 2>$UE_RT/err/cp.err; then
		echo "      cp errors:"
		head -20 $UE_RT/err/cp.err
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
	whiteouts_removed=0
   remove_whiteouts "$STAGE_DIR"
   
	# ===== pre_op_backup =====
	# Бэкапим ЦЕЛЕВОЙ upper (старый на флешке), если он есть — то, что уничтожит format/noformat

	# ===== do_transfer: pre_op_backup (бэкап ЦЕЛИ) =====
	if [ "$BATCH_BACKUP" = "yes" ]; then
		BAK_MNT=$(awk -v p="$PART" '$1==p {print $2; exit}' /proc/mounts)
		BAK_OWN=0
		if [ -z "$BAK_MNT" ]; then
			BAK_MNT="$UE_RT/mnt/pre.$$"
			mkdir -p "$BAK_MNT"
			if ! mount "$PART" "$BAK_MNT" 2>/dev/null; then
				rmdir "$BAK_MNT" 2>/dev/null
				fatal "$STAGE6" "Не смог смонтировать $PART для проверки upper. Форматирование отменено — без бэкапа нельзя."
			fi
			BAK_OWN=1
		fi
		if [ -d "$BAK_MNT/upper" ]; then
			if [ "$do_format" = "1" ]; then
				pre_op_backup yes "$BAK_MNT/upper" before_format
			else
				pre_op_backup yes "$BAK_MNT/upper" before_upper_delete
			fi
			if [ -z "$PRE_OP_BACKUP_ARCHIVE" ] && [ "$BATCH_BACKUP" = "yes" ]; then
				fatal "$STAGE6" "Не удалось создать pre-op бэкап."
			fi
		else
			echo "      Каталог upper на цели не обнаружен, пропускаю архивацию"
		fi
		if [ "$BAK_OWN" = "1" ]; then
			umount "$BAK_MNT" 2>/dev/null || umount -l "$BAK_MNT" 2>/dev/null || true
			rmdir "$BAK_MNT" 2>/dev/null || true
		fi
	else
		echo "      (backup=no: pre_op бэкап пропущен)"
	fi








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
	if [ "$do_format" = "1" ]; then
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
	
	
	
	
	
	
	
	
	
	
	if [ "$do_format" = "1" ]; then
		echo -e "${CLR_ORANGE}> Форматирую накопитель...${CLR_RESET}"
		DESTRUCTIVE_PHASE=1
		
		# временно отключаем hotplug auto-mount: иначе block-mount
		# перемонтирует раздел между umount и mkfs.ext4
		_hp_disabled=""
		for _hp in /etc/hotplug.d/block/*; do
			[ -x "$_hp" ] || continue
			chmod -x "$_hp" 2>/dev/null && _hp_disabled="$_hp_disabled $_hp"
		done
		[ -n "$_hp_disabled" ] && echo "      отключены hotplug на время mkfs:$_hp_disabled"

		mkfs_success=0
		i=1
		while [ $i -le 5 ]; do
			umount "$PART" 2>/dev/null
			umount -l "$PART" 2>/dev/null
			if have block; then
				block umount "$PART" 2>/dev/null
			fi
			for m in $(awk -v p="$PART" '$1==p {print $2}' /proc/mounts); do
				umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
			done
			sync
			sleep 1

			_still=$(awk -v p="$PART" '$1==p {print $2; exit}' /proc/mounts)
			[ -n "$_still" ] && echo "      (диагностика: $PART снова смонтирован в $_still, попытка $i)"

			if mkfs.ext4 -F -F "$PART" >/dev/null 2>&1; then
				mkfs_success=1
				break
			fi
			sleep 2
			i=$((i + 1))
		done

		for _hp in $_hp_disabled; do
			chmod +x "$_hp" 2>/dev/null
		done

		if [ "$mkfs_success" != "1" ]; then
			mkfs.ext4 -F -F "$PART"
			fatal "$STAGE7" "mkfs.ext4 на $PART упал."
		fi
		echo -e "${CLR_GREEN}      отформатировано: $PART (ext4)${CLR_RESET}"
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
	if [ "$do_format" = "0" ]; then
		echo
		echo "      удаляю только overlay-структуру (данные не тронуты) ..."
		DESTRUCTIVE_PHASE=1
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

	# emergency-бэкап на цель — после деструктивных операций,
	# до копирования staging (чтобы сбой staging не уничтожил бэкап)
	if [ -n "$PRE_OP_BACKUP_ARCHIVE" ]; then
		emergency_copy_to_target "$MNT"
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
	if ! cp -a "$STAGE_DIR/overlay/upper/." "$MNT/upper/" 2>$UE_RT/err/cp2.err; then
		echo "      cp errors:"
		head -20 $UE_RT/err/cp2.err
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
	STAGE9="[9/9] fstab"
	echo "$STAGE9 ..."
	UUID=$(get_partition_uuid "$PART")
	if [ -z "$UUID" ]; then
		sleep 1
		mkdir -p "$MNT/upper/root"
		sleep 1; sync
		cp "$LOG" "$MNT/upper/root/usb-extroot.log" 2>/dev/null || true
		umount "$MNT" 2>/dev/null || true
		fatal "$STAGE9" "Не получил UUID для $PART."
	fi
	apply_fstab_extroot "$UUID"
	apply_fstab_extroot "$UUID" "$CFG"
	echo -e "      extroot: UUID=${CLR_YELLOW}$UUID${CLR_RESET} -> /overlay"
	echo "Проверка живого fstab:"
	uci show fstab 2>/dev/null | grep -E 'extroot' || echo "      (extroot не найден!)"
	echo "Проверка fstab на USB:"
	grep -E 'extroot' "$CFG/fstab" || echo "      (extroot не найден!)"
	create_reboot_helper "$MNT/upper" "MAIN"
	sync
	sleep 3

	if [ "$BATCH" = "1" ] && [ "$BATCH_BACKUP" = "yes" ] && [ -n "$PRE_OP_BACKUP_ARCHIVE" ]; then
		_wait_for_reboot_action
	fi

	PRE_REBOOT_MSG="Перенос завершён."
	sync
	sleep 3
	umount "$MNT" 2>/dev/null || true
	rm -rf "$STAGE_DIR" 2>/dev/null || true
	DESTRUCTIVE_PHASE=0
	confirm_reboot_or_die 0
	return 0
}

# fix_uboot_env is a no-op stub; leaving for compatibility
fix_uboot_env() { return; }

# ==================================================================
#  L3 — do_revert_extroot (extroot → internal БЕЗ АРХИВА, режим 3)
# ==================================================================
do_revert_extroot() {
	MODE="revert_extroot"
	CHOICE_TEXT="отменить extroot, грузиться с внутренней памяти"
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
		0) echo "      устройство с overlay: $UBI_DEV" ;;
		1) die "$CHOICE_TEXT" "Не нашёл ни одного устройства с внутренним overlay." ;;
		2) die "$CHOICE_TEXT" "Найдено несколько устройств с overlay:
	$UBI_DEV

	Автовыбор невозможен." ;;
	esac
	UBI_MNT=$UE_RT/mnt/ubi-restore
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
		clear_fstab_extroot "$UBI_MNT/upper/etc/config"
		echo "      fstab внутри $UBI_DEV очищен."
	fi
	DESTRUCTIVE_PHASE=1
	clear_fstab_extroot
	echo "      fstab в живой системе очищен."
	create_reboot_helper "$UBI_MNT/upper" "RESTORE"
	cp "$LOG" "$UBI_MNT/upper/root/usb-extroot.log" 2>/dev/null || true
	mkdir -p "$UBI_MNT/overlay"
	[ -e "$UBI_MNT/upper/overlay" ] && [ ! -d "$UBI_MNT/upper/overlay" ] && rm -f "$UBI_MNT/upper/overlay"
	mkdir -p "$UBI_MNT/upper/overlay"
	sync
	sleep 3
	umount "$UBI_MNT" 2>/dev/null || true
	echo "      reboot_after.sh + rc.local в $UBI_DEV подготовлены."
	rmdir "$UBI_MNT" 2>/dev/null || true
	echo
	PRE_REBOOT_MSG="Загрузка переключена на внутреннюю память."
    DESTRUCTIVE_PHASE=0
	confirm_reboot_or_die 0
	return 0
}


# ============================================================
#  L3 — do_restore_archive
# ============================================================
do_restore_archive() {
	MODE="restore_archive"
	CHOICE_TEXT="восстановление из архива"
	RESTORE_IS_ACTIVE=0
	stage0_deps check

	ARCHIVE_PATH=""
	if [ "${BATCH_ARCHIVE#tmp/}" != "$BATCH_ARCHIVE" ]; then
		ARCHIVE_PATH="/tmp/${BATCH_ARCHIVE#tmp/}"
	elif [ -f "/overlay/usb-extroot-backups/$BATCH_ARCHIVE" ]; then
		ARCHIVE_PATH="/overlay/usb-extroot-backups/$BATCH_ARCHIVE"
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

	if [ "$BATCH_DEVICE" = "internal" ]; then
		if is_internal_dev "$(quick_overlay_dev)"; then
			RESTORE_PART="internal"
			RESTORE_TARGET="/overlay"
			echo "      цель: внутренняя память (АКТИВНА)"
		else
			RESTORE_PART=$(find_internal_overlay_dev)
			if [ -z "$RESTORE_PART" ]; then
				die "$CHOICE_TEXT" "Не нашёл внутренний overlay (UBI)."
			fi
			RESTORE_TARGET="$UE_RT/mnt/ubi-restore-archive"
			mkdir -p "$RESTORE_TARGET"
			umount "$RESTORE_TARGET" 2>/dev/null || true
			if ! mount -t ubifs "$RESTORE_PART" "$RESTORE_TARGET" 2>/dev/null; then
				die "$CHOICE_TEXT" "Не смог смонтировать $RESTORE_PART в $RESTORE_TARGET."
			fi
			echo "      цель: внутренняя память (неактивна, $RESTORE_PART)"
		fi
	else

		RESTORE_PART="$BATCH_DEVICE"
		if [ ! -b "$RESTORE_PART" ]; then
			die "$CHOICE_TEXT" "Устройство не существует: $RESTORE_PART"
		fi
		CUR_ACTIVE_DEV=$(quick_overlay_dev)
		if [ "$RESTORE_PART" = "$CUR_ACTIVE_DEV" ]; then
			RESTORE_IS_ACTIVE=1
			RESTORE_TARGET=$(get_current_overlay)
			echo "      цель: $RESTORE_PART (АКТИВНА, самоперезапись)"
		else
			RESTORE_IS_ACTIVE=0
			RESTORE_TARGET="$UE_RT/mnt/ext-restore-target"
			mkdir -p "$RESTORE_TARGET"
			umount "$RESTORE_TARGET" 2>/dev/null || true
			if ! mount "$RESTORE_PART" "$RESTORE_TARGET" 2>/dev/null; then
				die "$CHOICE_TEXT" "Не смог смонтировать $RESTORE_PART в $RESTORE_TARGET."
			fi
			echo "      цель: $RESTORE_PART (внешний накопитель)"
		fi
	fi

	ARCHIVE_KB=$(du -k "$ARCHIVE_PATH" 2>/dev/null | awk '{print $1}')
	[ -z "$ARCHIVE_KB" ] && ARCHIVE_KB=0
	NEED_PRE_KB=$(( ARCHIVE_KB * EST_UBIFS_PCT / 100 ))
	AVAIL_KB=$(df -k "$RESTORE_TARGET" 2>/dev/null | awk 'NR==2 {print $4}')
	TARGET_UPPER_KB=0
	if [ -d "$RESTORE_TARGET/upper" ]; then
		TARGET_UPPER_KB=$(du -sk "$RESTORE_TARGET/upper" 2>/dev/null | awk '{print $1}')
	fi
	TOTAL_AVAIL_KB=$(( AVAIL_KB + TARGET_UPPER_KB ))
	echo "      грубая оценка: архив ${ARCHIVE_KB}K, порог для отсева ${NEED_PRE_KB}K, доступно (свободно+upper): ${TOTAL_AVAIL_KB}K"
	if [ "$TOTAL_AVAIL_KB" -lt "$NEED_PRE_KB" ]; then
		umount "$RESTORE_TARGET" 2>/dev/null || true
		die "$CHOICE_TEXT" "Заведомо недостаточно места на Цели (по размеру архива).
	Доступно (свободно + upper): ${TOTAL_AVAIL_KB}K
	Грубая оценка (архив * ${EST_UBIFS_PCT}%): ${NEED_PRE_KB}K"
	fi
	echo -e "${CLR_GREEN}      грубая оценка пройдена${CLR_RESET}"

	if ! tar cf /dev/null /dev/null 2>/dev/null && [ ! -x /rom/bin/tar ]; then
		umount "$RESTORE_TARGET" 2>/dev/null || true
		die "$CHOICE_TEXT" "tar не работает: ни в PATH, ни /rom/bin/tar."
	fi
	if ! run_tar -tzf "$ARCHIVE_PATH" 2>/dev/null | grep -q '^overlay/upper/etc/config/'; then
		umount "$RESTORE_TARGET" 2>/dev/null || true
		die "$CHOICE_TEXT" "Это не бэкап overlay. В архиве нет пути overlay/upper/etc/config/.
	Проверьте вручную:
	  tar -tzf $ARCHIVE_PATH | head -20"
	fi
	TAR_LIST=$(run_tar -tzf "$ARCHIVE_PATH" 2>/dev/null) || { umount "$RESTORE_TARGET" 2>/dev/null; die "$CHOICE_TEXT" "Не читается tar."; }
	if echo "$TAR_LIST" | grep -qE '^/'; then umount "$RESTORE_TARGET" 2>/dev/null; die "$CHOICE_TEXT" "Архив содержит абсолютные пути."; fi
	if echo "$TAR_LIST" | grep -qE '(^|/)\.\.(/|$)'; then umount "$RESTORE_TARGET" 2>/dev/null; die "$CHOICE_TEXT" "Архив содержит '..' в путях."; fi





	# ===== pre_op_backup для do_restore_archive =====
	# Бэкапим ЦЕЛЕВОЙ upper (то, что будет стёрто восстановлением)
	# ===== do_restore_archive: pre_op_backup (бэкап ЦЕЛИ) =====
	if [ "$BATCH_BACKUP" = "yes" ]; then
		if [ -d "$RESTORE_TARGET/upper" ]; then
			pre_op_backup yes "$RESTORE_TARGET/upper" before_upper_delete
			if [ -z "$PRE_OP_BACKUP_ARCHIVE" ]; then
				fatal "$CHOICE_TEXT" "Не удалось создать pre-op бэкап."
			fi
		else
			echo "      $RESTORE_TARGET/upper отсутствует — бэкапить нечего, пропускаю"
		fi
	else
		echo "      (backup=no: pre_op бэкап пропущен)"
	fi
	




	if [ "$BATCH_DEVICE" = "internal" ] && [ "$RESTORE_TARGET" = "/overlay" ] && is_internal_dev "$(quick_overlay_dev)"; then
		echo
		echo "      ---> освобождаю место в /overlay: удаляю пакеты > 1 MiB ---"
		_upc_rom_db="/rom/lib/apk/db/installed"
		_upc_cur_db="/lib/apk/db/installed"
		_upc_limit=$((1024 * 1024))
		if [ ! -f "$_upc_rom_db" ]; then
			echo "        [skip] нет $_upc_rom_db"
		elif [ ! -f "$_upc_cur_db" ]; then
			echo "        [skip] нет $_upc_cur_db"
		elif ! have apk; then
			echo "        [skip] apk не найден"
		else
			awk '/^P:/ { p = substr($0, 3); if (p != "") print p }' "$_upc_rom_db" | sort -u > $UE_RT/pkg/rom.pkgs
			awk '/^P:/ { p = substr($0, 3); if (p != "") print p }' "$_upc_cur_db" | sort -u > $UE_RT/pkg/cur.pkgs
			grep -vxFf $UE_RT/pkg/rom.pkgs $UE_RT/pkg/cur.pkgs > $UE_RT/pkg/user.pkgs || :
			: > $UE_RT/pkg/to-remove.pkgs
			awk -v limit="$_upc_limit" -v out="$UE_RT/pkg/to-remove.pkgs" '
				FNR == NR { user[$0] = 1; next }
				/^P:/ { pkg = substr($0, 3); cur = (pkg in user); next }
				cur && /^I:/ { sz = substr($0, 3) + 0; pkgs[pkg] = sz; cur = 0; next }
				cur && /^$/ { cur = 0 }
				END {
					n = 0; for (p in pkgs) keys[++n] = p
					for (i = 1; i <= n; i++)
						for (j = i + 1; j <= n; j++)
							if (pkgs[keys[j]] > pkgs[keys[i]]) {
								t = keys[i]; keys[i] = keys[j]; keys[j] = t
							}
					for (i = 1; i <= n; i++) {
						p = keys[i]; s = pkgs[p]
						if      (s < 1024)    ss = sprintf("%d B", s)
						else if (s < 1048576) ss = sprintf("%.1f KiB", s / 1024)
						else                  ss = sprintf("%.2f MiB", s / 1048576)
						mark = (s > limit) ? "  >1MiB" : ""
						printf "        %-42s %10s%s\n", p, ss, mark
						if (s > limit) print p > out
					}
					close(out)
				}
			' $UE_RT/pkg/user.pkgs "$_upc_cur_db"
			if [ -s $UE_RT/pkg/to-remove.pkgs ]; then
				_upc_n=$(wc -l < $UE_RT/pkg/to-remove.pkgs)
				echo "        кандидатов на удаление: $_upc_n"
				if apk del --simulate $(cat $UE_RT/pkg/to-remove.pkgs) >/dev/null 2>&1; then
					if apk del $(cat $UE_RT/pkg/to-remove.pkgs) >/dev/null 2>&1; then
						echo "        [OK] удалено $_upc_n пакет(ов)"
					else
						echo "        [WARN] apk del завершился с ошибкой, продолжаю"
					fi
				else
					echo "        [WARN] apk del --simulate отказал (зависимости?), пропускаю удаление"
				fi
			else
				echo "        пакетов > 1 MiB нет, удалять нечего"
			fi
			rm -f $UE_RT/pkg/rom.pkgs $UE_RT/pkg/cur.pkgs $UE_RT/pkg/user.pkgs $UE_RT/pkg/to-remove.pkgs
		fi
		sync
		sleep 2
	fi

	if [ "$RESTORE_TARGET" = "/overlay" ] && [ -x /usr/local/sbin/user-pkgs-clean.sh ]; then
		echo
		echo "      ---> освобождаю место в /overlay: удаляю большие пакеты > 1 MiB ---"
		if /usr/local/sbin/user-pkgs-clean.sh --force > $UE_RT/err/pkg-clean.$$ 2>&1; then
			sed 's/^/        /' $UE_RT/err/pkg-clean.$$
		else
			_pkg_rc=$?
			echo "      ---> удаление пакетов не удалось (код $_pkg_rc), продолжаю без освобождения" >&2
			sed 's/^/        /' $UE_RT/err/pkg-clean.$$
		fi
		rm -f $UE_RT/err/pkg-clean.$$
		sync
		sleep 2
	fi

	
	STAGING="$UE_RT/stage"
	echo "      распаковываю архив в ОЗУ ($STAGING)..."
	rm -rf "$STAGING"
	mkdir -p "$STAGING/overlay/upper"
	chmod_777
	if ! run_tar -xzf "$ARCHIVE_PATH" -C "$STAGING" 2>$UE_RT/err/tar-restore.err; then
		umount "$RESTORE_TARGET" 2>/dev/null || true
		rm -rf "$STAGING"
		die "$CHOICE_TEXT" "Не удалось распаковать архив."
	fi
	if [ ! -d "$STAGING/overlay/upper" ]; then
		umount "$RESTORE_TARGET" 2>/dev/null || true
		rm -rf "$STAGING"
		die "$CHOICE_TEXT" "В архиве нет overlay/upper."
	fi
	STAGING_SIZE_KB=$(du -sk "$STAGING/overlay/upper" 2>/dev/null | awk '{print $1}')
	ARCHIVE_KB=$(du -k "$ARCHIVE_PATH" 2>/dev/null | awk '{print $1}')
	AVAIL_KB=$(df -k "$RESTORE_TARGET" 2>/dev/null | awk 'NR==2 {print $4}')
	TARGET_UPPER_KB=$(du -sk "$RESTORE_TARGET/upper" 2>/dev/null | awk '{print $1}')
	[ -z "$TARGET_UPPER_KB" ] && TARGET_UPPER_KB=0
	NEED_ON_TARGET_KB=0
	if [ "$BATCH_DEVICE" = "internal" ]; then
		NEED_ON_TARGET_KB=$(( ARCHIVE_KB * EST_UBIFS_PCT / 100 ))
		echo "      ФС цели: ubifs (внутренний UBI), оценка размера upper: ${NEED_ON_TARGET_KB}K"
	else
		NEED_ON_TARGET_KB=$(( STAGING_SIZE_KB * EST_OTHER_PCT / 100 ))
		echo "      ФС цели: не ubifs (внешний), оценка размера upper: ${NEED_ON_TARGET_KB}K"
	fi
	AFTER_RM_AVAIL_KB=$(( AVAIL_KB + TARGET_UPPER_KB ))
	echo "      архив: ${ARCHIVE_KB}K, staging: ${STAGING_SIZE_KB}K"
	echo "      свободно на Цели: ${AVAIL_KB}K, upper старый: ${TARGET_UPPER_KB}K"
	echo "      после rm upper будет свободно: ${AFTER_RM_AVAIL_KB}K"

	if [ "$BATCH_DEVICE" = "internal" ] && [ "$RESTORE_TARGET" = "/overlay" ]; then
		UBI_ROOT_DATA_PATH=""
		for _nf in /sys/class/ubi/ubi*_*/name; do
			[ -f "$_nf" ] || continue
			[ "$(cat "$_nf" 2>/dev/null)" = "rootfs_data" ] || continue
			UBI_ROOT_DATA_PATH=$(dirname "$_nf")
			break
		done
		if [ -n "$UBI_ROOT_DATA_PATH" ]; then
			UBI_VOL_NAME=$(basename "$UBI_ROOT_DATA_PATH")
			UBI_DEV_NAME="${UBI_VOL_NAME%_*}"
			UBI_AVAIL_LEB=$(ubinfo "/dev/$UBI_DEV_NAME" 2>/dev/null \
				| awk -F: '/Amount of available logical eraseblocks:/ {
					gsub(/^ +/, "", $2);
					split($2, _a, " ");
					print _a[1];
					exit
				}')
			case "$UBI_AVAIL_LEB" in
				''|*[!0-9]*)
					echo "      (avail_eraseblocks не определён, проверка пропущена)"
					;;
				0)
					if [ "$AVAIL_KB" -lt "$NEED_ON_TARGET_KB" ]; then
						umount "$RESTORE_TARGET" 2>/dev/null || true
						rm -rf "$STAGING"
						die "$CHOICE_TEXT" "Ubifs-том ${UBI_VOL_NAME} на ${UBI_DEV_NAME} переполнен, GC заблокирован.

	avail_eraseblocks = 0 → obsolete блоки не могут быть освобождены.
	Свободно сейчас:          ${AVAIL_KB}K
	Нужно для нового upper:   ${NEED_ON_TARGET_KB}K

	Удаление старого upper не поможет: физически оно не освобождает
	место, а GC не может переработать obsolete LEB'ы.

	Восстановление на active internal невозможно без полного сброса тома.
	Варианты:
	  0. Освободить место вручную (удалить пакеты), перезагрузить, повторить восстановление.
	  1. Сброс роутера, затем восстановление из архива на чистый internal.
	  2. Перепрошивка роутера, затем восстановление из архива на чистый internal.
	  3. Восстановление на внешний носитель (extroot)."
					fi
					;;
				*)
					echo "      UBI: avail_eraseblocks = ${UBI_AVAIL_LEB} на /dev/${UBI_DEV_NAME}, GC работает"
					;;
			esac
		fi
	fi















	if [ "$AVAIL_KB" -ge "$NEED_ON_TARGET_KB" ]; then
		echo "      ---> БЕЗОПАСНЫЙ МЕТОД (upper.new)"
		rm -rf "$RESTORE_TARGET/upper.new"
		mkdir -p "$RESTORE_TARGET/upper.new"
		echo "      ---> Копирую staging в upper.new (через tar)..."
		if ! (run_tar -C "$STAGING/overlay/upper" -czf - . | run_tar -C "$RESTORE_TARGET/upper.new" -xzf -) 2>/dev/null; then
			umount "$RESTORE_TARGET" 2>/dev/null || true
			rm -rf "$STAGING"
			rm -rf "$RESTORE_TARGET/upper.new"
			die "$CHOICE_TEXT" "Не смог скопировать upper в upper.new."
		fi

		echo "      ---> Экспресс-проверка upper.new..."
		_EXPRESS_OK=1
		for _chk in etc/config/system etc/config/network etc/passwd etc/shadow; do
			if [ ! -f "$RESTORE_TARGET/upper.new/$_chk" ]; then
				echo "        отсутствует: $_chk"
				_EXPRESS_OK=0
			fi
		done
		if [ "$_EXPRESS_OK" != "1" ]; then
			umount "$RESTORE_TARGET" 2>/dev/null || true
			rm -rf "$STAGING"
			die "$CHOICE_TEXT" "Экспресс-проверка upper.new не пройдена.
	Старый upper не тронут. Staging сохранён в $STAGING."
		fi
		echo -e "${CLR_GREEN}      upper.new проверен${CLR_RESET}"

		if [ "$BATCH" = "1" ]; then
			echo "      ---> batch: подтверждение уже получено через --confirm=yes"
		else
			

			echo
			echo
			echo "  Сейчас старый upper на $RESTORE_PART будет УДАЛЁН"
			echo "  и заменён на upper.new из архива."
			echo
			echo "  Заберите бэкап, после введите yes."
			echo "  Бэкап: $PRE_OP_BACKUP_ARCHIVE"
			[ -n "$PRE_OP_BACKUP_FLASH" ] && echo "  Копия: $PRE_OP_BACKUP_FLASH"
			echo "  Шара активна до ребута:"
			printf "  ${CLR_GREEN}SMB: ${CLR_YELLOW}\\\\\\\\$(get_router_ip)\\overlaybackup\n"
			echo -e "  user: 12345  password: 12345${CLR_RESET}"
			echo
			printf "Продолжить? (введите yes для подтверждения, Enter — отмена): "
			read _final
			if [ "$_final" != "yes" ]; then
				umount "$RESTORE_TARGET" 2>/dev/null || true
				rm -rf "$STAGING"
				echo "Отменено."
				exit 1
			fi
		fi

		echo "      ---> УДАЛЯЮ старый upper..."
		DESTRUCTIVE_PHASE=1
		rm -rf "$RESTORE_TARGET/upper"
		if ! mv "$RESTORE_TARGET/upper.new" "$RESTORE_TARGET/upper" 2>/dev/null; then
			umount "$RESTORE_TARGET" 2>/dev/null || true
			rm -rf "$STAGING"
			die "$CHOICE_TEXT" "Не смог переименовать upper.new."
		fi
	elif [ "$AFTER_RM_AVAIL_KB" -ge "$NEED_ON_TARGET_KB" ]; then
		if [ "$RESTORE_IS_ACTIVE" = "1" ]; then
			umount "$RESTORE_TARGET" 2>/dev/null || true
			rm -rf "$STAGING"
			die "$CHOICE_TEXT" "Не хватает места для самоперезаписи через upper.new.
	Свободно:               ${AVAIL_KB}K
	Нужно для upper.new:    ${NEED_ON_TARGET_KB}K

	Прямой метод (rm upper → верхний копир) для активного носителя запрещён:
	система потеряет upper без возможности восстановления при ошибке копирования.

	Варианты:
	  1. Освободить место на $RESTORE_PART, перезагрузиться, повторить.
	  2. Восстановить на другой накопитель.
	  3. Восстановить на внутреннюю память (пункт 5 → цель internal)."
		fi
		
		
		
		
	elif [ "$AFTER_RM_AVAIL_KB" -ge "$NEED_ON_TARGET_KB" ]; then
	
		echo "      ---> ПРЯМОЙ МЕТОД (без upper.new)"
		DESTRUCTIVE_PHASE=1
		rm -rf "$RESTORE_TARGET/upper"
		sync
		sleep 5
		mkdir -p "$RESTORE_TARGET/upper"
		: > $UE_RT/err/cp-direct.err
		CP_OK=0
		if (run_tar -C "$STAGING/overlay/upper" -czf - . | run_tar -C "$RESTORE_TARGET/upper" -xzf -) 2>>$UE_RT/err/cp-direct.err; then
			CP_OK=1
		else
			sync
			sleep 15
			if (run_tar -C "$STAGING/overlay/upper" -czf - . | run_tar -C "$RESTORE_TARGET/upper" -xzf -) 2>>$UE_RT/err/cp-direct.err; then
				CP_OK=1
			fi
		fi
		if [ "$CP_OK" != "1" ]; then
			head -30 $UE_RT/err/cp-direct.err
			umount "$RESTORE_TARGET" 2>/dev/null || true
			die "$CHOICE_TEXT" "Не смог скопировать upper на цель. Staging сохранён в $STAGING."
		fi
		if [ ! -d "$RESTORE_TARGET/upper/etc/config" ]; then
			umount "$RESTORE_TARGET" 2>/dev/null || true
			die "$CHOICE_TEXT" "Скопированный upper не содержит etc/config. Staging сохранён в $STAGING."
		fi
		sync
		sleep 2
		rm -rf "$STAGING"
	else
		umount "$RESTORE_TARGET" 2>/dev/null || true
		rm -rf "$STAGING"
		die "$CHOICE_TEXT" "Недостаточно места на Цели.
	Нужно на upper.new (свободно сейчас):        ${NEED_ON_TARGET_KB}K
	Нужно на прямой метод (после rm upper):       ${NEED_ON_TARGET_KB}K
	Свободно сейчас:                              ${AVAIL_KB}K
	Свободно после rm upper:                      ${AFTER_RM_AVAIL_KB}K"
	fi


	# emergency-бэкап на цель — после деструктивных операций
	if [ -n "$PRE_OP_BACKUP_ARCHIVE" ]; then
		emergency_copy_to_target "$RESTORE_TARGET"
	fi

	mkdir -p "$RESTORE_TARGET/work"
	rm -rf "$STAGING"


	if [ "$BATCH_DEVICE" = "internal" ]; then
		clear_fstab_extroot "$RESTORE_TARGET/upper/etc/config"
		echo "      fstab в internal очищен (extroot не нужен)."
		create_reboot_helper "$RESTORE_TARGET/upper" "RESTORE-ARCHIVE"
	else
		RESTORE_UUID=$(get_partition_uuid "$RESTORE_PART")
		if [ -z "$RESTORE_UUID" ]; then
			umount "$RESTORE_TARGET" 2>/dev/null || true
			die "$CHOICE_TEXT" "Не получил UUID для $RESTORE_PART."
		fi
		RESTORE_CFG="$RESTORE_TARGET/upper/etc/config"
		cat > "$RESTORE_CFG/fstab" <<FSTAB_EOF
config global
	option anon_swap '0'
	option anon_mount '0'
	option auto_swap '1'
	option auto_mount '1'
	option delay_root '5'
	option check_fs '0'
FSTAB_EOF
		clear_fstab_extroot
		UBI_DEV=$(find_internal_overlay_dev)
		if [ -n "$UBI_DEV" ]; then
			UBI_MNT=$UE_RT/mnt/ubi-fstab
			mkdir -p "$UBI_MNT"
			if mount -t ubifs "$UBI_DEV" "$UBI_MNT" 2>/dev/null || mount "$UBI_DEV" "$UBI_MNT" 2>/dev/null; then
				UBI_CFG="$UBI_MNT/upper/etc/config"
				if [ -d "$UBI_CFG" ]; then
					apply_fstab_extroot "$RESTORE_UUID" "$UBI_CFG"
				fi
				umount "$UBI_MNT" 2>/dev/null || true
				rmdir "$UBI_MNT" 2>/dev/null || true
			fi
		fi
		create_reboot_helper "$RESTORE_TARGET/upper" "RESTORE-ARCHIVE"
	fi
	sync
	sleep 2
	umount "$RESTORE_TARGET" 2>/dev/null || true

	if [ "$RESTORE_IS_ACTIVE" = "1" ]; then
		PRE_REBOOT_MSG="Архив развёрнут самоперезаписью на $RESTORE_PART."
	else
		PRE_REBOOT_MSG="Архив развёрнут на $RESTORE_PART."
	fi
	
	if [ "$BATCH" = "1" ] && [ "$BATCH_BACKUP" = "yes" ]; then
		_wait_for_reboot_action
	fi
	confirm_reboot_or_die 0
	return 0
}

# ============================================================
#  L3 — do_fallback_fix
# ============================================================
do_fallback_fix() {
	MODE="fallback_fix"
	CHOICE_TEXT="исправить аварийный режим"
	stage0_deps check
	echo
	echo "      очищаю fstab.extroot/rwm..."
	DESTRUCTIVE_PHASE=1
	clear_fstab_extroot
	echo "      fstab очищен."
	echo "      создаю /overlay..."
	if ! mkdir -p /overlay 2>$UE_RT/err/mkdir.err; then
		echo -e "${CLR_ORANGE}      mkdir /overlay не удался:${CLR_RESET}"
		cat $UE_RT/err/mkdir.err 2>/dev/null
		die "$CHOICE_TEXT" "Не смог создать /overlay."
	fi
	sync
	echo -e "${CLR_GREEN}      /overlay создан${CLR_RESET}"
	echo
	PRE_REBOOT_MSG="Аварийный режим overlay исправлен."
	DESTRUCTIVE_PHASE=0
	confirm_reboot_or_die 0
	return 0
}

# ============================================================
#  L3 — do_reset_keep_extroot
# ============================================================
do_reset_keep_extroot() {
	MODE="reset_keep_extroot"
	CHOICE_TEXT="сброс к заводским с сохранением загрузки с флэшки"
	QDEV=$(quick_overlay_dev)
	if [ -z "$QDEV" ] || is_internal_dev "$QDEV"; then
		die "$CHOICE_TEXT" "Сброс с сохранением extroot доступен только при загрузке с внешней флешки."
	fi
	QMP=$(awk -v d="$QDEV" '$1==d {print $2; exit}' /proc/mounts)
	[ -n "$QMP" ] || die "$CHOICE_TEXT" "Не получил точку монтирования для $QDEV."
	rm -rf "$QMP/upper.old" 2>/dev/null
	DESTRUCTIVE_PHASE=1
	mv "$QMP/upper" "$QMP/upper.old" || die "$CHOICE_TEXT" "Не смог переместить $QMP/upper -> $QMP/upper.old."
	echo
	echo "      Сброс до настроек по умолчанию завершён.
      Загрузка будет произведена с внешнего накопителя.

      Роутер перезагружается"
	sleep 10
	sync
	sleep 5
	reboot -f
}

# ============================================================
#  L3 — do_switch_overlay
# ============================================================
do_switch_overlay() {
	MODE="switch_overlay"
	CHOICE_TEXT="смена загрузочного накопителя"
	ensure_dependencies
	if [ -z "$BATCH_DEVICE" ]; then
		die "$CHOICE_TEXT" "Целевое устройство для переключения не задано."
	fi
	SWITCH_DST_DEV="$BATCH_DEVICE"
	echo "      переключение загрузочного накопителя на: $SWITCH_DST_DEV"
	DESTRUCTIVE_PHASE=1
	if ! switch_overlay_apply; then
		die "$CHOICE_TEXT" "Ошибка при применении переключения оверлея."
	fi
	PRE_REBOOT_MSG="Загрузочный накопитель изменён."
	DESTRUCTIVE_PHASE=0
	confirm_reboot_or_die 0
	return 0
}

# ============================================================
#  L3 — do_menu_backup_interactive
#  Спрашивает про бэкап, делает backup_manual, показывает путь/SMB.
#  Возвращает: BATCH_BACKUP=no (бэкап уже сделан, в do_X он не нужен)
# ============================================================
do_menu_backup_interactive() {
	printf "\n${CLR_GREEN}Создать архив ДАННЫХ ЦЕЛИ ${CLR_ORANGE}(того, что будет стёрто)? ${CLR_RESET}[${CLR_GREEN}Y${CLR_RESET}/n]: "
	read -r BACKUP_ANSWER
	case "${BACKUP_ANSWER:-y}" in
		[Yy]*) BATCH_BACKUP="yes" ;;
		*)     BATCH_BACKUP="no" ;;
	esac
	return 0
}

# ============================================================
#  L0 — ПАРСИНГ АРГУМЕНТОВ
# ============================================================
BATCH=0
BATCH_MODE=""
BATCH_DEVICE=""
BATCH_TARGET=""
BATCH_CONFIRM=""
BATCH_ACTION=""
BATCH_ARCHIVE=""
BATCH_BACKUP="yes"
ARCHIVE_WAIT=120

for _a in "$@"; do
echo $_a >> /tmp/a.txt
	case "$_a" in
		--version)          echo "$ver"; exit 0 ;;
		--batch)            BATCH=1 ;;
		--mode=*)           BATCH_MODE="${_a#*=}" ;;
		--device=*)         BATCH_DEVICE="${_a#*=}" ;;
		--target=*)         BATCH_TARGET="${_a#*=}" ;;
		--confirm=*)        BATCH_CONFIRM="${_a#*=}" ;;
		--action=*)         BATCH_ACTION="${_a#*=}" ;;
		--archive=*)        BATCH_ARCHIVE="${_a#*=}" ;;
		--backup=*)         BATCH_BACKUP="${_a#*=}" ;;
		--archive-wait=*)   ARCHIVE_WAIT="${_a#*=}" ;;
	esac
done

if [ "$BATCH" = "1" ]; then
	export BATCH BATCH_MODE BATCH_DEVICE BATCH_TARGET BATCH_CONFIRM BATCH_ACTION BATCH_ARCHIVE ARCHIVE_WAIT BATCH_BACKUP
fi

# ============================================================
#  L0 — PID / LOG
# ============================================================
mkdir -p "$UE_RT" \
         "$BACKUPS_MANUAL" \
         "$BACKUPS_AUTO" \
         "$BACKUPS_EMERGENCY" \
         "$STAGE_DIR" \
         "$MNT_DIR" \
         "$ERR_DIR" \
         "$PKG_DIR" 2>/dev/null || true

PID_FILE="${USB_EXTROOT_PID_FILE:-$PID_FILE}"
LOG="${USB_EXTROOT_LOG:-$LOG}"
LOCK_DIR="${USB_EXTROOT_LOCK_DIR:-}"

# Стираем stale-маркеры прошлых прогонов, ТОЛЬКО если это не --action=*
if [ -z "$BATCH_ACTION" ]; then
	rm -f "$REBOOT_NOW" "$REBOOT_CANCEL" 2>/dev/null || true
fi

_cleanup_pid_and_lock() {
	sleep 6
	rm -f "$PID_FILE"
	if [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then
		rm -rf "$LOCK_DIR"
	fi
}

if [ -z "$BATCH_ACTION" ]; then
	rm -f "$REBOOT_NOW" "$REBOOT_CANCEL" 2>/dev/null || true
fi

if [ "$BATCH" = "1" ] && [ -z "$BATCH_ACTION" ]; then
	if [ "$BATCH_MODE" = "backup" ] && [ -f "$PID_FILE" ]; then
		# чистим stale-маркеры от предыдущих прерванных прогонов
		rm -f "$REBOOT_NOW" "$REBOOT_CANCEL"
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
	trap '_cleanup_pid_and_lock; _handle_stop' INT TERM HUP
	trap '_cleanup_pid_and_lock' EXIT
	echo "=== $(date '+%F %T') argv: $* ===" >> "$LOG"
	exec >> "$LOG" 2>&1
fi

# ============================================================
#  L0 — SELF-EXEC TO RAM
# ============================================================
path="/opt/usb-extroot"
TEST_MODE="${TEST_MODE:-0}"
if [ ! -d "/opt/usb-extroot" ]; then mkdir -p "/opt/usb-extroot"; fi

case "$0" in
	/tmp/*|/dev/shm/*|/run/*) ;;
	*)
		if [ -z "$BATCH_ACTION" ] && [ "$BATCH" != "1" ] && [ -f "$0" ] && [ -w /tmp ]; then
			SELF_RAM=$UE_RT/run.sh
			if cp "$0" "$SELF_RAM" 2>/dev/null; then
				chmod +x "$SELF_RAM" 2>/dev/null
				exec /bin/sh "$SELF_RAM" "$@"
			fi
		fi
		;;
esac

# ============================================================
#  L0 — ЦВЕТА
# ============================================================
if [ "$BATCH" = "1" ]; then
	CLR_RESET=""; CLR_GREEN=""; CLR_ORANGE=""; CLR_YELLOW=""
else
	CLR_RESET="\033[0m"; CLR_GREEN="\033[32m"; CLR_ORANGE="\033[38;5;208m"; CLR_YELLOW="\033[33m"
fi

TEST_MODE="${TEST_MODE:-0}"

# ============================================================
#  L0 — BATCH_ACTION (до монтирования USB)
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
			# 1. Сканируем внешние накопители
			for d in /dev/sd? /dev/mmcblk? /dev/nvme?n? /dev/vd?; do
				[ -b "$d" ] || continue
				if ! is_usb "/dev/$(basename $d)" && [ "$(cat /sys/block/$(basename $d)/removable 2>/dev/null)" != "1" ]; then
					case "$(basename $d)" in
						mmcblk[0-9]*) [ "$(cat /sys/block/$(basename $d)/removable 2>/dev/null)" = "0" ] && continue ;;
					esac
				fi
				has_parts=0
				for p in ${d}*; do
					[ -b "$p" ] || continue
					case "$(basename "$p")" in
						sd[a-z][0-9]*|mmcblk[0-9]*p[0-9]*|nvme[0-9]*n[0-9]*p[0-9]*|vd[a-z][0-9]*)
							has_parts=1
							fs=$(timeout 2 block info "$p" 2>/dev/null | grep -o 'TYPE="[^"]*"' | cut -d'"' -f2)
							[ -z "$fs" ] && fs=$(awk -v dev="$p" '$1==dev {print $3; exit}' /proc/mounts)
							case "$fs" in
								squashfs) continue ;;
							esac
							echo "$p|${fs:-raw}|$(describe "$p")"
							;;
					esac
				done
				if [ "$has_parts" = "0" ]; then
					echo "$d|raw|$(describe "$d")"
				fi
			done

			# # 2. Сканируем внутреннюю память (UBI / rootfs_data), как основной источник
			# for nf in /sys/class/ubi/ubi*_*/name; do
				# [ -f "$nf" ] || continue
				# [ "$(cat "$nf" 2>/dev/null)" = "rootfs_data" ] || continue
				# d=$(basename "$(dirname "$nf")")
				# [ -c "/dev/$d" ] || continue
				# echo "/dev/$d|ubifs|$(describe "/dev/$d")"
			# done
			exit 0
			;;
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
		switch-targets)
			ensure_dependencies
			if command -v switch_overlay_scan_targets >/dev/null 2>&1; then
				list=$(switch_overlay_scan_targets 2>/dev/null)
				if [ -n "$list" ] && [ -f "$list" ]; then
					cat "$list"
					rm -f "$list"
				fi
			fi
			exit 0
			;;
		backup-sources)
			qdev=$(quick_overlay_dev)
			if [ -n "$qdev" ]; then
				echo "active|Текущий активный носитель ($(describe "$qdev"))"
			fi
			if [ -n "$qdev" ] && ! is_internal_dev "$qdev"; then
				int_dev=$(find_internal_overlay_dev)
				if [ -n "$int_dev" ]; then
					echo "internal|Внутренняя память роутера"
				fi
			fi
			for mnt in $(awk '$3=="ext4" || $3=="f2fs" || $3=="btrfs" {print $2}' /proc/mounts); do
				dev=$(awk -v m="$mnt" '$2==m {print $1; exit}' /proc/mounts)
				[ -z "$dev" ] && continue
				[ "$dev" = "$qdev" ] && continue
				if [ -d "$mnt/upper/etc/config" ] || [ -d "$mnt/etc/config" ]; then
					size_mb=$(df -m "$mnt" 2>/dev/null | awk 'NR==2 {print $2}')
					if [ -n "$size_mb" ] && [ "$size_mb" -gt 1024 ]; then
						size_gb=$(awk "BEGIN {printf \"%.1f\", $size_mb/1024}")
						size_str="${size_gb} ГБ"
					else
						size_str="${size_mb:-?} МБ"
					fi
					parent_name=$(basename "$(parent_dev "$dev")")
					desc="Раздел $dev ($size_str, диск $parent_name)"
					echo "$dev|$desc"
				fi
			done
			exit 0
			;;
		archive-info)
			latest=$(ls -t "$BACKUPS_DIR"/*.tar.gz \
			              "$BACKUPS_MANUAL"/*.tar.gz \
			              "$BACKUPS_AUTO"/*.tar.gz \
			              "$BACKUPS_EMERGENCY"/*.tar.gz \
			              /mnt/*/usb-extroot-backups/manual/*.tar.gz \
			              /mnt/*/usb-extroot-backups/auto/*.tar.gz \
			              /mnt/*/usb-extroot-backups/emergency_backup/*.tar.gz \
			              2>/dev/null | head -1)
			if [ -n "$latest" ] && [ -f "$latest" ]; then
				echo "exists=yes"
				echo "size=$(wc -c < "$latest" 2>/dev/null || echo 0)"
			else
				echo "exists=no"
			fi
			exit 0
			;;
		archive-list)
			for f in $(ls -t "$UE_RT/backups"/*.tar.gz 2>/dev/null); do
				[ -f "$f" ] || continue
				size=$(ls -l "$f" 2>/dev/null | awk '{print $5}')
				size=${size:-0}
				echo "tmp/$(basename "$f")|$size"
			done
			FOUND_ARCHIVES=$(find "$UE_RT/backups" /overlay/usb-extroot-backups /mnt/*/usb-extroot-backups -type f -name "*.tar.gz" 2>/dev/null)
			if [ -n "$FOUND_ARCHIVES" ]; then
				for f in $(ls -t $FOUND_ARCHIVES 2>/dev/null); do
					[ -f "$f" ] || continue
					size=$(ls -l "$f" 2>/dev/null | awk '{print $5}')
					size=${size:-0}
					case "$f" in
						*/manual/*)             echo "manual/$(basename "$f")|$size" ;;
						*/auto/*)               echo "auto/$(basename "$f")|$size" ;;
						*/emergency_backup/*)   echo "emergency_backup/$(basename "$f")|$size" ;;
						*)                      echo "$(basename "$f")|$size" ;;
					esac
				done
			fi
			exit 0
			;;
	esac
fi

# ============================================================
#  L0 — ОПРЕДЕЛЕНИЕ ОКРУЖЕНИЯ
# ============================================================
EXTROOT_ACTIVE=0
EXTROOT_DEV=""

# inline:
qdev=$(quick_overlay_dev)
if [ -n "$qdev" ] && ! is_internal_dev "$qdev"; then
	EXTROOT_ACTIVE=1
	EXTROOT_DEV="$qdev"
fi
FALLBACK_ACTIVE=0
if awk '$2=="/rom/overlay" {found=1; exit} END{exit !found}' /proc/mounts; then
	FALLBACK_ACTIVE=1
fi

# ============================================================
#  L0 — МОНТИРОВАНИЕ USB (или пропуск для action/mode)
# ============================================================
echo
if [ "$BATCH" = "1" ] && { [ -n "$BATCH_ACTION" ] || [ "$BATCH_MODE" = "reset_keep_extroot" ] || [ "$BATCH_MODE" = "restore" ] || [ "$BATCH_MODE" = "fallback-fix" ] || [ "$BATCH_MODE" = "restore_archive" ] || [ "$BATCH_MODE" = "backup" ] || [ "$BATCH_MODE" = "backup_manual" ] || [ "$BATCH_MODE" = "switch_overlay" ]; }; then
	echo "      (режим $BATCH_ACTION $BATCH_MODE: пропускаю сканирование USB)"
else
	echo
	echo "Монтирую съёмные накопители..."
	mount_removable_all
fi

# ============================================================
#  L0 — BATCH VALIDATION
# ============================================================
if [ "$BATCH" = "1" ]; then
	if [ -z "$BATCH_MODE" ]; then
		echo "ERROR: --mode не указан" >&2
		exit 2
	fi
	case "$BATCH_MODE" in
		format|noformat|restore|revert_extroot|fallback-fix|fallback_fix|restore_archive|backup|backup-manual|backup_manual|reset_keep_extroot|switch_overlay) ;;
		*) echo "ERROR: неизвестный --mode='$BATCH_MODE'" >&2; exit 2 ;;
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
		switch_overlay)
			if [ -z "$BATCH_DEVICE" ]; then
				echo "ERROR: --device не указан для mode=$BATCH_MODE" >&2
				exit 2
			fi
			;;
	esac
	if [ "$BATCH_CONFIRM" != "yes" ]; then
		echo "ERROR: --confirm=yes обязателен" >&2
		exit 2
	fi
	MODE=$(echo "$BATCH_MODE" | tr '-' '_')
	[ "$MODE" = "restore" ] && MODE="revert_extroot"
	case "$MODE" in
		format)             CHOICE_TEXT="форматировать и перенести" ;;
		noformat)           CHOICE_TEXT="перенести без форматирования" ;;
		revert_extroot)     CHOICE_TEXT="отменить extroot, грузиться с внутренней памяти" ;;
		fallback_fix)       CHOICE_TEXT="исправить аварийный режим" ;;
		restore_archive)    CHOICE_TEXT="восстановление из архива" ;;
		backup)             CHOICE_TEXT="автобэкап" ;;
		backup_manual)      CHOICE_TEXT="ручной бэкап" ;;
		reset_keep_extroot) CHOICE_TEXT="сброс к заводским с сохранением загрузки с флэшки" ;;
		switch_overlay)     CHOICE_TEXT="смена загрузочного накопителя" ;;
	esac
	echo
	echo "============================================================"
	echo "  BATCH: mode=$MODE"
	[ -n "$BATCH_DEVICE" ] && echo "  device=$BATCH_DEVICE"
	[ -n "$BATCH_ARCHIVE" ] && echo "  archive=$BATCH_ARCHIVE"
	echo "============================================================"
fi

# ============================================================
#  L0 — ДИСПЕТЧЕР (BATCH)
# ============================================================
if [ "$BATCH" = "1" ]; then
	case "$MODE" in
		format)             do_transfer 1; exit $? ;;
		noformat)           do_transfer 0; exit $? ;;
		restore)            do_revert_extroot; exit $? ;;   # back-compat
		revert_extroot)     do_revert_extroot; exit $? ;;
		restore_archive)    do_restore_archive; exit $? ;;
		backup)             do_backup auto; exit $? ;;
		backup_manual)      do_backup manual; exit $? ;;
		fallback_fix)       do_fallback_fix; exit $? ;;
		reset_keep_extroot) do_reset_keep_extroot ;;
		switch_overlay)     do_switch_overlay; exit $? ;;
	esac
	exit 0
fi

# ============================================================
#  L0 — INTERACTIVE MENU
# ============================================================
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
	 До ввода КОДА подтверждения — только чтение.
	 После ввода КОДА подтверждения — необратимо; при ошибке — стоп и инструкции.
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
	echo -e "  3) Отменить extroot, вернуться к загрузке с внутренней памяти"
	echo -e "  4) Выбор загрузочного устройства, клонирование накопителя"
	echo -e "  5) Восстановить состояние из архива на флешку"



	if [ "$FALLBACK_ACTIVE" = "1" ]; then
			echo -e "  ${CLR_ORANGE}9) Исправить аварийный режим overlay (рекомендуется)${CLR_RESET}"
	fi
	echo -e "  0) Выход"
	printf "${CLR_YELLOW}Выбор: ${CLR_RESET}"
	read CHOICE

	MENU_MODE=""
	MENU_DEVICE=""
	MENU_ARCHIVE=""
	MENU_DONE=0

	case "$CHOICE" in
		1) MENU_MODE="format";   MENU_DONE=1 ;;
		2) MENU_MODE="noformat"; MENU_DONE=1 ;;
		3) MENU_MODE="revert_extroot";  MENU_DONE=1 ;;
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
		9)
			if [ "$FALLBACK_ACTIVE" != "1" ]; then
				echo
				echo "Пункт 9 доступен только при обнаружении фоллбэка."
				sleep 2
				continue
			fi
			MENU_MODE="fallback_fix"
			MENU_DONE=1
			;;
		5)
			echo
			echo "Доступные архивы:"
			echo
			n=0
			ARCHIVES=""
			for mnt in $(awk '$3=="ext4" || $3=="f2fs" || $3=="btrfs" {print $2}' /proc/mounts); do
				for f in "$mnt/usb-extroot-backups"/*.tar.gz; do
					[ -f "$f" ] || continue
					n=$((n + 1))
					ARCHIVES="$ARCHIVES $f"
					echo "  $n) $(basename "$f")"
				done
				for _sub in manual auto emergency_backup; do
					[ -d "$mnt/usb-extroot-backups/$_sub" ] || continue
					for f in "$mnt/usb-extroot-backups/$_sub"/*.tar.gz; do
						[ -f "$f" ] || continue
						n=$((n + 1))
						ARCHIVES="$ARCHIVES $f"
						echo "  $n) $_sub/$(basename "$f")"
					done
				done
			done
			
			
			
			
			
			
			if [ "$n" = "0" ]; then
				echo "  (нет архивов)"
				sleep 2
				continue
			fi
			printf "\nВыберите номер архива (0 - отмена): "
			read ACH
			case "$ACH" in
				0|"") continue ;;
			esac
			ok=0
			n=0
			ARCHIVE_SELECTED=""
			for f in $ARCHIVES; do
				n=$((n + 1))
				if [ "$n" = "$ACH" ]; then
					ARCHIVE_SELECTED="$f"
					ok=1
					break
				fi
			done
			if [ "$ok" != "1" ]; then
				echo "Неверный выбор."
				sleep 2
				continue
			fi

			echo
			echo "цель восстановления:"
			echo
			echo "  0) internal — внутренняя память (/overlay)"
			
			
			
			
			
			
			n=0
			TGT_LIST=""
			CUR_ACTIVE_DEV=$(quick_overlay_dev)
			for d in /dev/sd? /dev/mmcblk?; do
				[ -b "$d" ] || continue
				is_removable_storage "$d" || continue
				for p in ${d}*; do
					[ -b "$p" ] || continue
					case "$(basename "$p")" in
						sd[a-z][0-9]*|mmcblk[0-9]*p[0-9]*) ;;
						*) continue ;;
					esac
					n=$((n + 1))
					TGT_LIST="$TGT_LIST $p"
					_mark=""
					if [ "$p" = "$CUR_ACTIVE_DEV" ]; then
						_mark=" ${CLR_ORANGE}[АКТИВНА — самоперезапись]${CLR_RESET}"
					fi
					echo -e "  $n) $p ($(describe "$p"))${_mark}"
				done
			done
			
			
			
			
			
			
			
			printf "\nВыберите цель (0 - internal, Enter - отмена): "
			read TGT
			case "$TGT" in
				"") continue ;;
				0) MENU_DEVICE="internal" ;;
				*)
					ok=0
					n=0
					MENU_DEVICE=""
					for p in $TGT_LIST; do
						n=$((n + 1))
						if [ "$n" = "$TGT" ]; then
							MENU_DEVICE="$p"
							ok=1
							break
						fi
					done
					if [ "$ok" != "1" ]; then
						echo "Неверный выбор."
						sleep 2
						continue
					fi
					;;
			esac

			case "$ARCHIVE_SELECTED" in
				*/manual/*)             MENU_ARCHIVE="manual/$(basename "$ARCHIVE_SELECTED")" ;;
				*/auto/*)               MENU_ARCHIVE="auto/$(basename "$ARCHIVE_SELECTED")" ;;
				*/emergency_backup/*)   MENU_ARCHIVE="emergency_backup/$(basename "$ARCHIVE_SELECTED")" ;;
				*)                      MENU_ARCHIVE=$(basename "$ARCHIVE_SELECTED") ;;
			esac
			
			MENU_MODE="restore_archive"
			MENU_DONE=1
			;;
		0) echo "Выход."; exit 0 ;;
		*)
			echo
			echo "Неизвестный выбор: '$CHOICE'"
			sleep 2
			continue
			;;
	esac

	if [ "$EXTROOT_ACTIVE" = "1" ] && [ "$MENU_MODE" != "revert_extroot" ] && [ "$MENU_MODE" != "fallback_fix" ] && [ "$MENU_MODE" != "restore_archive" ]; then
		echo
		echo -e "${CLR_ORANGE}Невозможно: overlay уже на $EXTROOT_DEV.${CLR_RESET}"
		echo "  Перенос c USB на тот же USB не имеет практического смысла."
		echo "  Пункты 1 и 2 недоступны — они меняют текущий extroot."
		echo "  Используйте другие пункты меню."
		echo
		printf "  Нажмите Enter для продолжения (авто через 10с): "
		read -t 10 _
		echo
		continue
	fi

	MODE="$MENU_MODE"
	BATCH_DEVICE="$MENU_DEVICE"
	BATCH_ARCHIVE="$MENU_ARCHIVE"

	case "$MODE" in
		format|noformat|restore_archive)
			do_menu_backup_interactive
			;;
	esac

	break
done

# ============================================================
#  L0 — ДИСПЕТЧЕР (INTERACTIVE)
# ============================================================
case "$MODE" in
	format)             do_transfer 1; exit $? ;;
	noformat)           do_transfer 0; exit $? ;;
	revert_extroot)     do_revert_extroot; exit $? ;;
	restore)            do_revert_extroot; exit $? ;;   # back-compat
	restore_archive)    do_restore_archive; exit $? ;;
	backup)             do_backup auto; exit $? ;;
	backup_manual)      do_backup manual; exit $? ;;
	fallback_fix)       do_fallback_fix; exit $? ;;
	reset_keep_extroot) do_reset_keep_extroot ;;
	switch_overlay)     do_switch_overlay; exit $? ;;
esac 
