# ============================================================
#  switch-overlay.sh — смена загрузочного накопителя
#                     и точка входа для работы со вторым.
#
#  Подключается из основного:
#      . /root/clone-overlay.sh
#      . /root/switch-overlay.sh
#
#  Точка входа:
#      second_drive_menu
# ============================================================

SWITCH_DST_DEV=""

# ------------------------------------------------------------
#  Есть ли на устройстве валидный overlay?
#  Если оно уже примонтировано — проверяем в его точке.
#  Если нет — монтируем ro во временную и смотрим.
# ------------------------------------------------------------
switch_overlay_check_ovl_on_dev() {
    local dev="$1" mp tmp
    mp=$(awk -v d="$dev" '$1==d {print $2; exit}' /proc/mounts)
    if [ -n "$mp" ]; then
        [ -d "$mp/upper/etc/config" ] && return 0 || return 1
    fi

    tmp="/tmp/.scan-mnt.$$"
    mkdir -p "$tmp" || return 1
    if mount -o ro "$dev" "$tmp" 2>/dev/null; then
        if [ -d "$tmp/upper/etc/config" ]; then
            umount "$tmp" 2>/dev/null || true
            rmdir "$tmp" 2>/dev/null || true
            return 0
        fi
        umount "$tmp" 2>/dev/null || true
    fi
    rmdir "$tmp" 2>/dev/null || true
    return 1
}

# ------------------------------------------------------------
#  Список съёмных, кроме источника, с валидным оверлеем.
#  Возвращает путь к временному файлу (dev|desc) или пусто.
# ------------------------------------------------------------
switch_overlay_scan_targets() {
    local d part desc out
    out="/tmp/.switch-targets.$$"
    : > "$out"

    # Первым — внутренний overlay (UBI rootfs_data), если он есть
    # и если мы сейчас НЕ на нём (иначе переключение бессмысленно).
    if clone_overlay_find_source; then
        if find_internal_overlay_dev >/dev/null 2>&1; then
            printf '%s|%s\n' "__internal__" "(Переключиться на роутер)" >> "$out"
        fi
    fi

    for d in /dev/sd? /dev/mmcblk?; do
        [ -b "$d" ] || continue
        is_removable_storage "$d" || continue
        if [ -n "$CLONE_SRC_PARENT" ] && [ "$(parent_dev "$d")" = "$CLONE_SRC_PARENT" ]; then
            continue
        fi

        part=""
        for p in ${d}*; do
            [ -b "$p" ] || continue
            case "$(basename "$p")" in
                sd[a-z][0-9]*|mmcblk[0-9]*p[0-9]*) ;;
                *) continue ;;
            esac
            part="$p"
            break
        done
        [ -n "$part" ] || part="$d"

        if switch_overlay_check_ovl_on_dev "$part"; then
            desc=$(describe "$part")
            printf '%s|%s\n' "$part" "$desc" >> "$out"
        fi
    done

    if [ ! -s "$out" ]; then
        rm -f "$out"
        return 1
    fi
    echo "$out"
    return 0
}


# ------------------------------------------------------------
#  Выбор цели. Заполняет SWITCH_DST_DEV.
# ------------------------------------------------------------
switch_overlay_choose_target() {
    local list n i dev desc

    list=$(switch_overlay_scan_targets) || list=""
    if [ -z "$list" ] || [ ! -f "$list" ]; then
        echo
        echo -e "${CLR_ORANGE}Не найдено накопителей с оверлеем, кроме текущего.${CLR_RESET}"
        echo
        return 1
    fi

    echo
    echo -e "${CLR_YELLOW}Накопители с оверлеем:${CLR_RESET}"
    n=0
    while IFS='|' read -r dev desc; do
        n=$((n + 1))
        echo -e "${CLR_GREEN}  $n) $desc${CLR_RESET}"
    done < "$list"
	echo
    printf "Выберите (1-%d, 0 — отмена): " "$n"
    read i

    case "$i" in
        0|"") rm -f "$list"; return 1 ;;
        *[!0-9]*) rm -f "$list"; echo "Некорректный ввод."; return 1 ;;
    esac
    if [ "$i" -lt 1 ] || [ "$i" -gt "$n" ]; then
        rm -f "$list"
        echo "Вне диапазона."
        return 1
    fi

    n=0
    while IFS='|' read -r dev desc; do
        n=$((n + 1))
        if [ "$n" = "$i" ]; then
            SWITCH_DST_DEV="$dev"
            break
        fi
    done < "$list"

    rm -f "$list"
    [ -n "$SWITCH_DST_DEV" ] || return 1
    return 0
}

# ------------------------------------------------------------
#  Записать новый UUID в fstab UBI rootfs_data и в fstab цели.
# ------------------------------------------------------------
switch_overlay_apply() {
    local uuid ubi_dev ubi_rc ubi_mnt dst_mp dst_was_mounted

    # Спец-случай: возврат на внутренний NAND.
    # Это не смена UUID, а удаление extroot из fstab UBI.
    if [ "$SWITCH_DST_DEV" = "__internal__" ]; then
        ubi_dev=$(find_internal_overlay_dev)
        ubi_rc=$?
        case "$ubi_rc" in
            0) ;;
            1) echo -e "${CLR_ORANGE}Том rootfs_data не найден.${CLR_RESET}"; return 1 ;;
            2) echo -e "${CLR_ORANGE}Найдено несколько rootfs_data, автовыбор невозможен.${CLR_RESET}"; return 1 ;;
        esac

        ubi_mnt=/mnt/ubi_switch
        mkdir -p "$ubi_mnt" || return 1
        if ! mount -t ubifs "$ubi_dev" "$ubi_mnt" 2>/dev/null; then
            rmdir "$ubi_mnt" 2>/dev/null || true
            echo -e "${CLR_ORANGE}Не смог примонтировать $ubi_dev.${CLR_RESET}"
            return 1
        fi

        if [ ! -d "$ubi_mnt/upper/etc/config" ]; then
            umount "$ubi_mnt" 2>/dev/null || true
            rmdir "$ubi_mnt" 2>/dev/null || true
            echo -e "${CLR_ORANGE}В $ubi_dev нет upper/etc/config.${CLR_RESET}"
            return 1
        fi

        uci -c "$ubi_mnt/upper/etc/config" -q delete fstab.extroot
        uci -c "$ubi_mnt/upper/etc/config" -q delete fstab.rwm
        uci -c "$ubi_mnt/upper/etc/config" commit fstab 2>/dev/null || true
        sync
        umount "$ubi_mnt" 2>/dev/null || true
        rmdir "$ubi_mnt" 2>/dev/null || true

        return 0
    fi

    uuid=$(block info "$SWITCH_DST_DEV" 2>/dev/null \
           | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)
    if [ -z "$uuid" ]; then
        echo -e "${CLR_ORANGE}Не получил UUID для $SWITCH_DST_DEV.${CLR_RESET}"
        return 1
    fi

    # --- 1. UBI rootfs_data ---
    ubi_dev=$(find_internal_overlay_dev)
    ubi_rc=$?
    case "$ubi_rc" in
        0) ;;
        1) echo -e "${CLR_ORANGE}Том rootfs_data не найден.${CLR_RESET}"; return 1 ;;
        2) echo -e "${CLR_ORANGE}Найдено несколько rootfs_data, автовыбор невозможен.${CLR_RESET}"; return 1 ;;
    esac

    ubi_mnt=/mnt/ubi_switch
    mkdir -p "$ubi_mnt" || return 1
    if ! mount -t ubifs "$ubi_dev" "$ubi_mnt" 2>/dev/null; then
        rmdir "$ubi_mnt" 2>/dev/null || true
        echo -e "${CLR_ORANGE}Не смог примонтировать $ubi_dev.${CLR_RESET}"
        return 1
    fi

    if [ ! -d "$ubi_mnt/upper/etc/config" ]; then
        umount "$ubi_mnt" 2>/dev/null || true
        rmdir "$ubi_mnt" 2>/dev/null || true
        echo -e "${CLR_ORANGE}В $ubi_dev нет upper/etc/config.${CLR_RESET}"
        return 1
    fi

    uci -c "$ubi_mnt/upper/etc/config" -q set fstab.extroot.uuid="$uuid"
	uci -c "$ubi_mnt/upper/etc/config" -q delete fstab.extroot
    uci -c "$ubi_mnt/upper/etc/config" set fstab.extroot=mount
    uci -c "$ubi_mnt/upper/etc/config" set fstab.extroot.uuid="$uuid"
    uci -c "$ubi_mnt/upper/etc/config" set fstab.extroot.target="/overlay"
    uci -c "$ubi_mnt/upper/etc/config" set fstab.extroot.enabled="1"
    uci -c "$ubi_mnt/upper/etc/config" -q delete fstab.rwm
    uci -c "$ubi_mnt/upper/etc/config" commit fstab 2>/dev/null || true
    sync
	sleep 2
    umount "$ubi_mnt" 2>/dev/null || true
    rmdir "$ubi_mnt" 2>/dev/null || true

    # --- 2. fstab на самом целевом носителе ---
    dst_mp=$(awk -v d="$SWITCH_DST_DEV" '$1==d {print $2; exit}' /proc/mounts)
    dst_was_mounted=0
    if [ -n "$dst_mp" ]; then
        dst_was_mounted=1
    else
        dst_mp=/mnt/switch_dst
        mkdir -p "$dst_mp" || return 1
        if ! mount "$SWITCH_DST_DEV" "$dst_mp" 2>/dev/null; then
            echo -e "${CLR_ORANGE}Не смог примонтировать цель.${CLR_RESET}"
            rmdir "$dst_mp" 2>/dev/null || true
            return 1
        fi
    fi

    if [ -d "$dst_mp/upper/etc/config" ]; then
        uci -c "$dst_mp/upper/etc/config" -q delete fstab.extroot
        uci -c "$dst_mp/upper/etc/config" set fstab.extroot=mount
        uci -c "$dst_mp/upper/etc/config" set fstab.extroot.uuid="$uuid"
        uci -c "$dst_mp/upper/etc/config" set fstab.extroot.target="/overlay"
        uci -c "$dst_mp/upper/etc/config" set fstab.extroot.enabled="1"
        uci -c "$dst_mp/upper/etc/config" -q delete fstab.rwm
        uci -c "$dst_mp/upper/etc/config" commit fstab 2>/dev/null || true
        sync
    fi

    if [ "$dst_was_mounted" = "0" ]; then
        umount "$dst_mp" 2>/dev/null || true
        rmdir "$dst_mp" 2>/dev/null || true
    fi

    return 0
}


# ------------------------------------------------------------
#  Применить смену + предложить ребут.
#  SWITCH_DST_DEV должен быть установлен снаружи.
# ------------------------------------------------------------
switch_overlay_after_clone() {
    if [ -z "$SWITCH_DST_DEV" ]; then
        echo -e "${CLR_ORANGE}switch_overlay_after_clone: цель не задана.${CLR_RESET}"
        return 1
    fi

    echo
    echo "      применяю fstab..."
    echo "      цель: $SWITCH_DST_DEV"

    if ! switch_overlay_apply; then
        echo
        echo -e "${CLR_ORANGE}Ошибка при переключении.${CLR_RESET}"
        echo "  Подробности — см. выше."
        echo "  Загрузка останется с текущего накопителя."
        printf "Нажмите Enter для возврата: "
        read _
        return 1
    fi

    echo
    echo -e "${CLR_GREEN}Готово.${CLR_RESET}"
    echo "  После перезагрузки система поднимется с $SWITCH_DST_DEV."
    echo
    printf "Перезагрузить сейчас? (y/N): "
    read a
    case "$a" in
        y|Y|yes|YES)
            sync
            sleep 2
            reboot
            ;;
        *)
            echo "Ок, перезагрузи вручную."
            ;;
    esac
    return 0
}


# ------------------------------------------------------------
#  Интерактив: сменить загрузочный накопитель.
# ------------------------------------------------------------

switch_overlay_interactive() {
    echo
    echo "============================================================"
    echo "  Смена загрузочного накопителя"
    echo "============================================================"
    echo

    if ! switch_overlay_choose_target; then
        printf "Нажмите Enter для возврата: "
        read _
        return 1
    fi

    echo
    if [ "$SWITCH_DST_DEV" = "__internal__" ]; then
        new_desc="(внутренний overlay / NAND)"
    else
        new_desc="$SWITCH_DST_DEV"
    fi

    if clone_overlay_find_source; then
        echo "      новый загрузочный: $new_desc"
        echo "      текущий:           $CLONE_SRC_DEV"
    else
        echo "      новый загрузочный: $new_desc"
        echo "      текущий:           (внутренний носитель)"
    fi

    echo
    printf "Переназначить? (y/N): "
    read a
    case "$a" in
        y|Y|yes|YES) ;;
        *) echo "Отменено."; return 1 ;;
    esac

    switch_overlay_after_clone
    return $?
}

# ------------------------------------------------------------
#  Подменю «Второй накопитель».
#  Если целей с оверлеем нет — сразу копирование.
# ------------------------------------------------------------
second_drive_menu() {
    local cur_desc
    if clone_overlay_find_source; then
        cur_desc=$(describe "$CLONE_SRC_DEV")
    else
        cur_desc="(Роутер / NAND)"
    fi

    while :; do
        clear
        echo "============================================================"
        echo "  Операции со вторым накопителем"
        echo "============================================================"
        echo
        echo -e "${CLR_YELLOW}Текущий загрузочный:${CLR_RESET}"
        echo -e "    ${CLR_GREEN}$cur_desc${CLR_RESET}"
        echo
        echo -e "${CLR_YELLOW}Действие:${CLR_RESET}"
        echo "  1) Назначить загрузочным другой накопитель"
        echo "     (нужен накопитель с валидным оверлеем)"
        echo
        echo "  2) Клонировать текущий на другой накопитель"
        echo "     и назначить его загрузочным"
        echo
        echo "  3) Клонировать текущий на другой накопитель"
        echo
        echo "  0) Возврат в предыдущее меню"
        printf "${CLR_YELLOW}Выбор: ${CLR_RESET}"
        read CHOICE

        case "$CHOICE" in
            1) switch_overlay_interactive; return ;;
            2) clone_overlay_interactive 1; return ;;
            3) clone_overlay_interactive 0; return ;;
            0|"") return ;;
            *) sleep 1; continue ;;
        esac
    done
}
