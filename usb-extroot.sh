#!/bin/sh
# ============================================================
#  usb-extroot.sh  v0.1.15
#  Перенос overlay OpenWrt на USB-накопитель (extroot)
#  Лог: /tmp/usb-extroot.log (сброс в overlay в конце)
#  Бэкап: /tmp/.usb-extroot-x7k2m9q4p1w8/ (tmpfs, RAM)
# ============================================================
# ------------------------------------------------------------
#  Самопереезд в RAM.
#
#  Скрипт обычно лежит в /root (overlay). Когда overlay
#  в процессе работы размонтируется и пересобирается,
#  ядро теряет доступ к overlayfs-superblock, и построчное
#  чтение скрипта начинает возвращать чужой или устаревший
#  контент. Копируем себя в /tmp (tmpfs) и перезапускаемся
#  оттуда — с этого момента overlay нам больше не важен.
#
#  Проверка [ -f "$0" ] — только регулярный файл.
#  При запуске через sh <(wget ...) $0 это /dev/fd/NN,
#  симлинк на пайп. cp такого «файла» отдаёт не весь
#  скрипт, а только непрочитанный остаток пайпа — то
#  есть кусок с середины. Поэтому в этом режиме
#  самопереезд не делаем: sh и так читает из того же
#  пайпа, что и раньше.
# ------------------------------------------------------------
path="/opt/usb-extroot"
TEST_MODE=0

case "$0" in
    /tmp/*|/dev/shm/*|/run/*) ;;
    *)
        if [ -f "$0" ] && [ -w /tmp ]; then
            SELF_RAM=/tmp/.usb-extroot-run.sh
            if cp "$0" "$SELF_RAM" 2>/dev/null; then
                chmod +x "$SELF_RAM" 2>/dev/null
                exec /bin/sh "$SELF_RAM" "$@"
            fi
        fi
        ;;
esac

ver="v0.1.15"

CLR_RESET="\033[0m"
CLR_GREEN="\033[32m"
CLR_ORANGE="\033[38;5;208m"
CLR_YELLOW="\033[33m"

LOG=/tmp/usb-extroot.log
if [ -z "$_LOGGED" ]; then
    export _LOGGED=1
    FIFO=/tmp/usb-extroot.fifo
    rm -f "$FIFO"
    mkfifo "$FIFO"
    tee -a "$LOG" < "$FIFO" &
    exec > "$FIFO" 2>&1
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

# ============================================================
#  Поиск устройства внутреннего overlay.
#  Единственный критерий — имя UBI-тома "rootfs_data".
#
#  Возвращает:
#    0 — ровно один том, устройство в stdout
#    1 — ни одного тома
#    2 — больше одного тома, список устройств в stdout
# ============================================================
find_internal_overlay_dev() {
    local nf d found count

    found=""
    count=0
    for nf in /sys/class/ubi/ubi*_*/name; do
        [ -f "$nf" ] || continue
        [ "$(cat "$nf" 2>/dev/null)" = "rootfs_data" ] || continue
        d=$(basename "$(dirname "$nf")")
        [ -c "/dev/$d" ] || continue
        found="$found /dev/$d"
        count=$((count + 1))
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

        /etc/init.d/ksmbd restart >/dev/null 2>&1
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

# ============================================================
#  Перехват INT/TERM/HUP: восстановить сеть и убрать шару,
#  если скрипт оборван посередине (Ctrl+C, kill, SIGHUP).
#  EXIT не трогаем — иначе конфликт с обычными exit 0/1.
# ============================================================
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

# ============================================================
#  Мягкий ребут с fallback на жёсткий.
#
#  Логика:
#    1. Запускаем сторож в отдельной сессии (setsid).
#       Сторож игнорирует SIGTERM и спит $delay секунд.
#    2. В основном процессе делаем мягкий `reboot`:
#       - если он сработает — система уходит, сторож умирает вместе с ней;
#       - если залипнет после SIGTERM и до SIGKILL — сторож выживет,
#         доспит и дёрнет `reboot -f`.
#    3. Через $delay секунд сторож делает `reboot -f`.
#
#  $1 — таймаут в секундах (по умолчанию 40).
# ============================================================
soft_reboot_with_fallback() {
    local delay="${1:-40}"

    setsid sh -c "
        trap '' TERM
        sleep $delay
        echo b > /proc/sysrq-trigger
		#reboot -f
    " &

    sleep 1
    reboot
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

# ============================================================
#  Родительское устройство для sd*/mmcblk*
# ============================================================
parent_dev() {
    local d="$1"
    case "$d" in
        /dev/mmcblk*p[0-9]*) echo "${d%p[0-9]*}" ;;
        /dev/sd[a-z][0-9]*)  echo "${d%[0-9]*}" ;;
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
    case "$(grep -h DRIVER /sys/block/$b/device/uevent 2>/dev/null)" in
        *uas*|*usb-storage*) return 0;;
    esac
    return 1
}

# ============================================================
#  Внутреннее (впаянное) устройство:
#    ubi*, mtdblock*, root       — NAND/NOR
#    mmcblk* с removable=0       — eMMC
# ============================================================
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

# ============================================================
#  Съёмное внешнее хранилище?
#    sd*     -> is_usb
#    mmcblk* -> removable=1 (SD-карта), removable=0 (eMMC) отсеивается
# ============================================================
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
        sd[a-z][0-9]*|mmcblk[0-9]*p[0-9]*)
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
    local name=$(echo "${vendor} ${model}" | sed 's/  *//g; s/^ //; s/ $//')
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

# ============================================================
#  Быстрая проверка: есть ли вообще внешнее съёмное хранилище
# ============================================================
storage_quick_check() {
    for d in /dev/sd? /dev/mmcblk?; do
        [ -b "$d" ] || continue
        is_removable_storage "$d" || continue
        return 0
    done
    return 1
}

# ============================================================
#  Система зависимостей.
#
#  DEP_<набор>_CMDS  — команды вида "cmd:pkg"
#  DEP_<набор>_FS    — файловые системы вида "fs:kmod"
#
#  Наборы:
#    base  — то, что нужно скрипту в любой операции
#    ext4  — то, что нужно только для операций с ext4 (запись)
#
#  Спец-проверки:
#    GNU tar (для base) — find_gnu_tar
#    Сеть (для base)    — есть wget или curl
# ============================================================

DEP_BASE_CMDS="
awk:busybox
sed:busybox
grep:busybox
cat:busybox
head:busybox
cut:busybox
tr:busybox
cp:busybox
mv:busybox
rm:busybox
mkdir:busybox
rmdir:busybox
chmod:busybox
ln:busybox
sleep:busybox
sync:busybox
printf:busybox
find:busybox
tee:busybox
mkfifo:busybox
mount:busybox
umount:busybox
df:busybox
du:busybox
basename:busybox
dirname:busybox
readlink:busybox
block:block-mount
uci:uci
"

DEP_BASE_FS="
ubifs:kmod-fs-ubifs
"

DEP_EXT4_CMDS="
mkfs.ext4:e2fsprogs
"

DEP_EXT4_FS="
ext4:kmod-fs-ext4
"

DEP_NET="wget:wget-ssl curl:curl"

# ------------------------------------------------------------
#  Поиск GNU tar. Возвращает путь через stdout.
# ------------------------------------------------------------
find_gnu_tar() {
    local cand
    for cand in tar /usr/bin/tar /usr/libexec/tar-gnu /bin/tar; do
        if [ -x "$cand" ] || have "$cand"; then
            if $cand --version 2>&1 | grep -qi 'GNU tar'; then
                echo "$cand"
                return 0
            fi
        fi
    done
    return 1
}

# ------------------------------------------------------------
#  Батч-установка (один вызов pm, а не по пакету)
# ------------------------------------------------------------
install_pkgs() {
    local pm="$1" pkgs="$2"
    [ -n "$pkgs" ] || return 0
    case "$pm" in
        apk)  apk add $pkgs ;;
        opkg) opkg update >/dev/null 2>&1
              opkg install $pkgs ;;
        *)    return 1 ;;
    esac
}

# ------------------------------------------------------------
#  Проверить и, при необходимости, доустановить зависимости.
#  $1 — набор: base | ext4
# ------------------------------------------------------------
deps_ensure() {
    local set="$1"
    local cmds fs_list missing still entry cmd pkg fs found_net

    case "$set" in
        base)
            cmds="$DEP_BASE_CMDS"
            fs_list="$DEP_BASE_FS"
            ;;
        ext4)
            cmds="$DEP_EXT4_CMDS"
            fs_list="$DEP_EXT4_FS"
            ;;
        *)
            echo "deps_ensure: неизвестный набор '$set'"
            return 1
            ;;
    esac

    missing=""

    for entry in $cmds; do
        cmd="${entry%%:*}"
        pkg="${entry#*:}"
        if ! have "$cmd"; then
            case " $missing " in
                *" $pkg "*) ;;
                *) missing="$missing $pkg" ;;
            esac
        fi
    done

    for entry in $fs_list; do
        fs="${entry%%:*}"
        pkg="${entry#*:}"
        if ! grep -qw "$fs" /proc/filesystems 2>/dev/null; then
            case " $missing " in
                *" $pkg "*) ;;
                *) missing="$missing $pkg" ;;
            esac
        fi
    done

    # Спец-проверки только для base
    if [ "$set" = "base" ]; then
        if ! find_gnu_tar >/dev/null 2>&1; then
            case " $missing " in
                *" tar "*) ;;
                *) missing="$missing tar" ;;
            esac
        fi

        found_net=0
        for entry in $DEP_NET; do
            cmd="${entry%%:*}"
            if have "$cmd"; then found_net=1; break; fi
        done
        [ "$found_net" = "0" ] && missing="$missing wget-ssl"
    fi

    missing=$(echo "$missing" | sed 's/^ *//; s/ *$//')

    if [ -z "$missing" ]; then
        return 0
    fi

    echo -e "      ${CLR_ORANGE}отсутствуют: $missing${CLR_RESET}"

    if [ "$PM" = "none" ]; then
        echo -e "${CLR_ORANGE}Нет ни apk, ни opkg — установить нельзя.${CLR_RESET}"
        return 1
    fi

    echo "      подготовка сети (DNS, блокировщики)..."
    pkg_repair_start || echo "      сеть не тронута (нечего чинить)"

    echo "      устанавливаю..."
    if ! install_pkgs "$PM" "$missing"; then
        pkg_repair_finish
        echo -e "${CLR_ORANGE}Установка не удалась: $missing${CLR_RESET}"
        return 1
    fi

    echo "      восстанавливаю сеть..."
    pkg_repair_finish

    # Повторная проверка — то, что реально встало
    still=""
    for entry in $cmds; do
        cmd="${entry%%:*}"
        have "$cmd" || still="$still $cmd"
    done
    for entry in $fs_list; do
        fs="${entry%%:*}"
        grep -qw "$fs" /proc/filesystems 2>/dev/null || still="$still $fs"
    done

    if [ -n "$still" ]; then
        echo -e "${CLR_ORANGE}После установки всё ещё нет:$still${CLR_RESET}"
        return 1
    fi

    return 0
}

stage0_deps() {
    echo
    STAGE0="[0/9] зависимости"
    echo "$STAGE0 ..."
    PM=$(detect_pm)
    echo "      менеджер пакетов: $PM"

    if ! deps_ensure base; then
        die "$STAGE0" "Базовые зависимости не установлены.

Проверь вручную:
  $PM update
  $PM add <пакеты из сообщения выше>

Если что-то недоступно в фиде — поставь вручную и запусти скрипт заново."
    fi

    TARBIN=$(find_gnu_tar)
    if [ -z "$TARBIN" ]; then
        die "$STAGE0" "GNU tar не найден.

  command -v tar  -> $(command -v tar 2>/dev/null || echo 'нет')
  tar --version    -> $(tar --version 2>&1 | head -1)

Поставь GNU tar и запусти скрипт заново."
    fi

    echo -e "${CLR_GREEN}      базовые зависимости на месте${CLR_RESET}"
    echo -e "${CLR_GREEN}      GNU tar: ${TARBIN}${CLR_RESET}"
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
        is_removable_storage "$d" || continue
        [ "$(parent_dev "$d")" = "$skip_parent" ] && continue
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

    if [ $# -eq 1 ]; then
        TARGET="$1"
    else
        echo "Найдено несколько внешних накопителей:"
        n=0
        for d in $DISKS; do
            n=$((n + 100))
            echo -e "  ${CLR_YELLOW}$n -> ${CLR_GREEN}$(describe $d)  ${CLR_RESET}"
        done
        echo
        printf "${CLR_RESET}Укажите целевой (введите число слева): "
        read CHOSEN

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
    PART=$(echo $PARTS | awk '{print $1}')

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

# ============================================================
#  extroot уже активен?
#    overlay смонтирован И его устройство — внешнее.
# ============================================================
extroot_active() {
    local qdev
    qdev=$(quick_overlay_dev)
    [ -n "$qdev" ] || return 1
    is_internal_dev "$qdev" && return 1
    return 0
}

EXTROOT_ACTIVE=0
EXTROOT_DEV=""
if extroot_active; then
    EXTROOT_ACTIVE=1
    EXTROOT_DEV=$(quick_overlay_dev)
fi

# ============================================================
#  Подтягивание модулей (clone-overlay.sh, switch-overlay.sh).
#
#  Логика:
#    1) пробуем скачать ОБА свежих с GitHub во временные .new
#       (3 попытки на файл, пауза 1с между)
#    2) если ОБА скачались и валидны:
#         - заменяем ими рабочие копии в /tmp
#         - подключаем
#    3) если хотя бы один не скачался:
#         - .new удаляем, ничего не заменяем
#         - ищем доступные "старые" в /root, /, /tmp
#         - подключаем то, что нашли (может быть частично)
#
#  Консистентность пары: либо оба новые, либо оба старые.
# ============================================================
SRC_BASE="https://raw.githubusercontent.com/kkkkCampbell/USB-extroot/refs/heads/main"

_dep_looks_valid() {
    local f="$1" marker="$2"
    [ -s "$f" ] || return 1
    head -n 5 "$f" | grep -qi '<html\|<!doctype' && return 1
    grep -q "$marker" "$f" || return 1
    return 0
}

_dep_fetch() {
    local url="$1" dst="$2" tmp
    tmp="${dst}.part"
    rm -f "$tmp"

    if have wget; then
        wget -qO "$tmp" "$url" 2>/dev/null || { rm -f "$tmp"; return 1; }
    elif have curl; then
        curl -fsSL "$url" -o "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
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
    for src in "/root/$name" "/$name" "/opt/usb-extroot" "/tmp/$name"; do
        if _dep_looks_valid "$src" "$marker"; then
            echo "$src"
            return 0
        fi
    done
    return 1
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

            # Использовать сейчас — из /tmp
            mv -f "$new_clone"  "/tmp/clone-overlay.sh"
            mv -f "$new_switch" "/tmp/switch-overlay.sh"

            # Сохранить на будущее — в $path
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

load_dependencies

# ============================================================
#  МЕНЮ (цикл: возврат при недопустимом выборе)
# ============================================================
while :; do
    clear

    echo "============================================================"
    echo "usb-extroot.sh  ${ver}"
    cat <<'BANNER'
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

    echo
    echo -e "${CLR_YELLOW}Действие:${CLR_RESET}"
    echo -e "  1) Роутер → USB-накопитель с форматированием накопителя  ${CLR_ORANGE}${accessible}${CLR_RESET}"
    echo -e "  2) Роутер → USB-накопитель без форматирования накопителя ${CLR_ORANGE}${accessible}${CLR_RESET}"
    echo -e "  3) Восстановить загрузку с внутренней памяти роутера"
	echo -e "  4) Выбор загрузочного устройства, клонирование накопителя"
    echo -e "  0) Выход"
    printf "Выбор: "
    read CHOICE

    case "$CHOICE" in
        1) MODE=format;   CHOICE_TEXT="форматировать и перенести overlay на USB-носитель" ;;
        2) MODE=noformat; CHOICE_TEXT="перенести без форматирования" ;;
        3) MODE=restore;  CHOICE_TEXT="восстановить загрузку с внутренней памяти роутера" ;;
        4)
            if command -v second_drive_menu >/dev/null 2>&1; then
                second_drive_menu
            else
                echo
                echo "Модуль не подключён."
                sleep 2
            fi
            continue
            ;;
        0|"") echo "Выход."; exit 0 ;;
        *)
            echo
            echo "Неизвестный выбор: '$CHOICE'"
            sleep 2
            continue
            ;;
    esac

    if [ "$EXTROOT_ACTIVE" = "1" ] && [ "$MODE" != "restore" ]; then
        echo
        echo -e "${CLR_ORANGE}Невозможно: overlay уже на $EXTROOT_DEV.${CLR_RESET}"
        echo "  Перенос c USB на тот же USB не имеет практического смысла."
        echo "  Вам доступны только пункты 3, 4, 0"
        echo
        printf "  Нажмите Enter для продолжения (авто через 10с): "
        read -t 10 _
        echo
        continue
    fi

    break
done

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
    stage0_deps

    share_down

    UBI_DEV=$(find_internal_overlay_dev)
    UBI_RC=$?

    case "$UBI_RC" in
        0)
            echo "      том rootfs_data: $UBI_DEV"
            ;;
        1)
            die "$CHOICE_TEXT" "Не нашёл ни одного тома rootfs_data в /sys/class/ubi/.

Это не NAND-OpenWrt с overlay на UBI, либо UBI ещё не инициализирован.

Проверь:
  ls /sys/class/ubi/
  for f in /sys/class/ubi/*/name; do echo \"\$f = \$(cat \$f)\"; done
  cat /proc/filesystems | grep ubifs

Ничего не тронуто, extroot не снят."
            ;;
        2)
            die "$CHOICE_TEXT" "Найдено несколько томов rootfs_data:
$UBI_DEV

Автовыбор невозможен (dual-boot?).

Смонтируй нужный том вручную и заверши restore сам:
  mount -t ubifs /dev/ubiN_M /mnt/ubi_restore
  uci -c /mnt/ubi_restore/upper/etc/config -q delete fstab.extroot
  uci -c /mnt/ubi_restore/upper/etc/config -q delete fstab.rwm
  uci -c /mnt/ubi_restore/upper/etc/config commit fstab
  umount /mnt/ubi_restore

Ничего не тронуто, extroot не снят."
            ;;
    esac

    UBI_MNT=/mnt/ubi_restore
    mkdir -p "$UBI_MNT"

    mount_ok=0
    if mount -t ubifs "$UBI_DEV" "$UBI_MNT" 2>/dev/null; then
        mount_ok=1
    fi

    if [ "$mount_ok" != "1" ]; then
        rmdir "$UBI_MNT" 2>/dev/null || true
        die "$CHOICE_TEXT" "Не смог смонтировать $UBI_DEV в $UBI_MNT.

Проверь:
  mount | grep ubifs
  dmesg | tail -20
  cat /proc/filesystems | grep ubifs

Ничего не тронуто, extroot не снят."
    fi

    if [ ! -L "$UBI_MNT/.fs_state" ] \
       || [ ! -d "$UBI_MNT/upper" ] \
       || [ ! -d "$UBI_MNT/work" ] \
       || [ ! -d "$UBI_MNT/upper/etc/config" ]; then
        umount "$UBI_MNT" 2>/dev/null || true
        rmdir "$UBI_MNT" 2>/dev/null || true
        die "$CHOICE_TEXT" "$UBI_DEV не похож на overlay OpenWrt.

Нет одного из маркеров: .fs_state, upper/, work/, upper/etc/config.
Это может быть чужой ubifs (калибровки, логи, вендорский раздел).

Ничего не тронуто, extroot не снят."
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

    cat > "$UBI_MNT/upper/root/reboot_after.sh" <<'EOF'
#!/bin/sh
# RESTORE
WAIT_BEFORE_REBOOT=100

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
sleep 1
delay="40"

setsid sh -c "
	trap '' TERM
	sleep $delay
	echo b > /proc/sysrq-trigger
	#reboot -f
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
	sleep 1
	cp /tmp/usb-extroot.log "$UBI_MNT/upper/root/usb-extroot.log" 2>/dev/null || true
    umount "$UBI_MNT" 2>/dev/null || true
    echo "      reboot_after.sh + rc.local в $UBI_DEV подготовлены."
    rmdir "$UBI_MNT" 2>/dev/null || true

    echo
    echo -e "${CLR_GREEN}Готово. Ребут для применения.${CLR_RESET}"
    printf "Перезагрузить сейчас? (y/N): "
    read R
    case "$R" in
        y|Y|yes|YES)
            echo "Перезагружаюсь..."
            sync
			sleep 2
            soft_reboot_with_fallback 40
            ;;
        *)
            echo "Ок, перезагрузи вручную."
            exit 0
            ;;
    esac
    exit 0
fi

# ============================================================
#  ВЕТКИ 1 и 2 — перенос
# ============================================================

if ! storage_quick_check; then
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

# ============================================================
#  Ранняя проверка: есть ли вообще куда переносить.
#  Накопитель, на котором уже overlay, отсеивается по родителю.
#  Если после отсева кандидатов нет — дальше идти некуда.
#  Это read-only проверка, до любых изменений системы.
# ============================================================
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
Этот накопитель пропускается: перенос на него бессмыслен.

Подключи другой накопитель, либо вернись на внутренний overlay (режим 3)."
fi

# ============================================================
#  Только теперь — изменяющие операции.
#  Проверка ФС для режима noformat — в stage2_find_usb,
#  после финального выбора $PART.
# ============================================================
fix_uboot_env
stage0_deps
stage1_overlay

if ! stage2_find_usb; then
    die "$CHOICE_TEXT" "Внешний накопитель найден, но не определён как диск (sd*/mmcblk*).
Проверь: ls /dev/sd* /dev/mmcblk* и dmesg | tail -20"
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
    die "$STAGE3" "Не смог определить размер overlay или /tmp.
overlay: ${SRC_SIZE_KB:-?}K
/tmp:    ${TMP_AVAIL_KB:-?}K"
fi

NEED_TMP_KB=$(( SRC_SIZE_KB * 2 + SRC_SIZE_KB / 10 ))
if [ "$TMP_AVAIL_KB" -lt "$NEED_TMP_KB" ]; then
    die "$STAGE3" "Мало места в /tmp для staging + архив.
Нужно: ${NEED_TMP_KB}K, свободно: ${TMP_AVAIL_KB}K."
fi
echo -e "${CLR_GREEN}      ок, в /tmp места хватает${CLR_RESET}"

if [ ! -d "$CUR_OVERLAY_MP/upper/etc/config" ]; then
    die "$STAGE3" "В overlay нет upper/etc/config.
Overlay неполный или нестандартный."
fi
echo -e "${CLR_GREEN}      структура overlay корректна${CLR_RESET}"

echo "      физ.диски: overlay=$SKIP_PARENT usb=$(parent_dev "$PART")"

echo
if [ "$MODE" = format ]; then
    echo -e "${CLR_ORANGE}Все данные на $DESC будут уничтожены (mkfs.ext4 $PART).${CLR_RESET}"
else
    echo -e "${CLR_YELLOW}На $PART будет удалена только overlay-структура (upper/, work/, .fs_state),${CLR_RESET}"
    echo -e "${CLR_YELLOW}остальные данные не тронуты. Затем будет развёрнут overlay.${CLR_RESET}"
fi

printf "Для подтверждения введите YES: "
read A
if [ "$A" != "YES" ]; then
    echo "Отменено."
    exit 0
fi
echo -e "Подтверждено: ${CLR_YELLOW}$TARGET ($MODE)${CLR_RESET}."

# ============================================================
#  ШАГ 5. Пакеты
# ============================================================
echo
STAGE5="[5/9] пакеты"
echo "$STAGE5 ..."

if ! deps_ensure ext4; then
    die "$STAGE5" "Не удалось подготовить пакеты для работы с ext4.

Проверь вручную:
  $PM update
  $PM add kmod-fs-ext4 e2fsprogs"
fi

echo -e "${CLR_GREEN}      пакеты для ext4 на месте${CLR_RESET}"

# ============================================================
#  ШАГ 6. Staging
# ============================================================
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
    die "$STAGE6" "Не смог скопировать upper/ в staging.
Ничего не тронуто, overlay цел."
fi

rm -rf "$STAGE_DIR/overlay/upper/work" 2>/dev/null || true
rm -f "$STAGE_DIR/overlay/upper/.fs_state" 2>/dev/null || true

STAGE_SIZE_KB=$(du -sk "$STAGE_DIR" 2>/dev/null | awk '{print $1}')
echo "      staging размер: ${STAGE_SIZE_KB}K"

if [ ! -d "$STAGE_DIR/overlay/upper/etc/config" ]; then
    die "$STAGE6" "Staging неполный — нет overlay/upper/etc/config.
Ничего не тронуто, overlay цел."
fi
echo -e "${CLR_GREEN}      staging корректный${CLR_RESET}"

# ============================================================
#  ШАГ 7. Формат / очистка + копирование staging на USB
#
#  Overlay-источник не трогаем: upper/ уже в /tmp,
#  система работает с текущего overlay. fuser/umount
#  касаются только целевых точек ($MNT, $PART, $TARGET).
# ============================================================
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
            fatal "$STAGE7" "USB-диск не переподключился за 20 сек.
Staging цел: $STAGE_DIR"
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
            fatal "$STAGE7" "Раздел $PART не появился после пересоздания.
Staging цел: $STAGE_DIR"
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
            fatal "$STAGE7" "Раздел $PART не удаётся освободить перед mkfs.
Staging цел: $STAGE_DIR"
        fi
        echo -e "${CLR_GREEN}      $PART свободен после пересоздания${CLR_RESET}"
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
        fatal "$STAGE7" "mkfs.ext4 на $PART упал.
Staging цел: $STAGE_DIR"
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
        fatal "$STAGE7" "Не смог смонтировать $PART в $MNT.
Staging цел: $STAGE_DIR"
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
            fatal "$STAGE7" "Не смог удалить $entry.
Staging цел: $STAGE_DIR"
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
    fatal "$STAGE7" "Не смог определить свободное место на $PART.
Staging цел: $STAGE_DIR"
fi
if [ "$AVAIL_DST_KB" -lt $((STAGE_SIZE_KB + STAGE_SIZE_KB / 10)) ]; then
    umount "$MNT" 2>/dev/null || true
    fatal "$STAGE7" "Мало места на $PART (${AVAIL_DST_KB}K < ${STAGE_SIZE_KB}K).
Staging цел: $STAGE_DIR"
fi

mkdir -p "$MNT/upper"
if ! cp -a "$STAGE_DIR/overlay/upper/." "$MNT/upper/" 2>/tmp/cp2.err; then
    echo "      cp errors:"
    head -20 /tmp/cp2.err
    umount "$MNT" 2>/dev/null || true
    fatal "$STAGE7" "Не смог скопировать upper/ на USB.
Staging цел: $STAGE_DIR"
fi

mkdir -p "$MNT/work"
sync

USB_SIZE_KB=$(du -sk "$MNT" 2>/dev/null | awk '{print $1}')
echo "      на USB: ${USB_SIZE_KB}K"

CFG="$MNT/upper/etc/config"
if [ ! -d "$CFG" ]; then
    umount "$MNT" 2>/dev/null || true
    fatal "$STAGE7" "На USB нет upper/etc/config.
Staging цел: $STAGE_DIR"
fi
echo -e "${CLR_GREEN}      копирование на USB завершено${CLR_RESET}"

# ============================================================
#  ШАГ 8. Архив
# ============================================================
echo
STAGE8="[8/9] архив"
BACKUP_DIR=/tmp/.usb-extroot-x7k2m9q4p1w8
echo "$STAGE8 в $BACKUP_DIR ..."

mkdir -p "$BACKUP_DIR"
TS=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_ARCHIVE="$BACKUP_DIR/overlay_backup_${TS}.tar.gz"

echo "      поднимаю шару для доступа к бэкапу..."
share_up
echo -e "      ${CLR_GREEN}Доступ к бэкапу по локальной сети: "
echo -e "      ${CLR_YELLOW}\\\\\\\\$(get_router_ip)\\overlaybackup"
echo -e "      user: 12345   password: 12345${CLR_RESET}"
echo

echo "      удаляю whiteouts из staging..."
find "$STAGE_DIR/overlay/upper" -name '.wh.*' -delete 2>/dev/null || true
find "$STAGE_DIR/overlay/upper" -type d -empty -delete 2>/dev/null || true

echo "      создаю архив $BACKUP_ARCHIVE ..."
if ! $TARBIN -C "$STAGE_DIR" -czf "$BACKUP_ARCHIVE" overlay 2>/tmp/tar_read.err; then
    echo "      tar errors:"
    head -20 /tmp/tar_read.err
    umount "$MNT" 2>/dev/null || true
    fatal "$STAGE8" "Не смог создать архив.
Staging цел: $STAGE_DIR"
fi

if ! $TARBIN -tzf "$BACKUP_ARCHIVE" >/dev/null 2>&1; then
    umount "$MNT" 2>/dev/null || true
    fatal "$STAGE8" "Архив повреждён: $BACKUP_ARCHIVE"
fi

ARCHIVE_SIZE_KB=$(du -k "$BACKUP_ARCHIVE" 2>/dev/null | awk '{print $1}')
echo "      архив: ${ARCHIVE_SIZE_KB}K"
echo -e "${CLR_GREEN}      архив создан${CLR_RESET}"

# ============================================================
#  ШАГ 9. fstab
# ============================================================
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
    fatal "$STAGE9" "Не получил UUID для $PART.
Staging цел: $STAGE_DIR
Бэкап цел: $BACKUP_ARCHIVE"
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

# ============================================================
#  ПОДГОТОВКА ДВОЙНОГО РЕБУТА
# ============================================================
REBOOT_HELPER="$MNT/upper/root/reboot_after.sh"

mkdir -p "$MNT/upper/root"

sleep 1; sync
cp /tmp/usb-extroot.log "$MNT/upper/root/usb-extroot.log" 2>/dev/null || true

cat > "$REBOOT_HELPER" <<'EOF'
#!/bin/sh
# MAIN
WAIT_BEFORE_REBOOT=100

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
	#reboot -f
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

umount "$MNT" 2>/dev/null || true
rm -rf "$STAGE_DIR" 2>/dev/null || true

echo
echo -e "${CLR_GREEN}================================================================${CLR_RESET}"
echo -e "${CLR_GREEN} Готово. Бэкап: $BACKUP_ARCHIVE${CLR_RESET}"
echo -e "${CLR_YELLOW}    Доступ к бэкапу по локальной сети: \\\\\\\\$(get_router_ip)\\overlaybackup${CLR_RESET}"
echo -e "${CLR_YELLOW}    user: 12345   password: 12345${CLR_RESET}"
echo
echo "    1) перезагрузить сейчас"
echo "    2) выйти без перезагрузки"
echo -e "${CLR_GREEN}================================================================${CLR_RESET}"
printf "Выбор: "
read R
case "$R" in
    1)
        echo
        echo -e "${CLR_ORANGE}!!! ПЕРЕЗАГРУЗКА ЧЕРЕЗ 10 СЕКУНД !!!${CLR_RESET}"
        echo "    Ctrl+C — отмена."
        i=10
        while [ $i -gt 0 ]; do
            printf "\r    осталось: %2d " "$i"
            sleep 1
            i=$((i-1))
        done
        printf "\r    осталось:  0 \n"
        echo "Перезагружаюсь..."
        share_down
        sync
		sleep 2
        soft_reboot_with_fallback 40
        ;;
    *) echo "Ок, не перезагружаю." ;;
esac
