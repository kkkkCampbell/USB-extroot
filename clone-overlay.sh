# ============================================================
#  clone-overlay.sh  — копирование extroot-структуры
#                     с текущего носителя на другой.
#
#  Не самостоятельный скрипт. Подключается из основного:
#      . /root/clone-overlay.sh
#  Использует общие функции основного:
#      have, is_removable_storage, is_internal_dev, parent_dev,
#      describe, get_current_overlay, die, fatal,
#      CLR_RESET, CLR_GREEN, CLR_ORANGE, CLR_YELLOW, LOG.
#
#  Единственная точка входа для пользователя:
#      clone_overlay_interactive
# ============================================================

CLONE_SRC_DEV=""
CLONE_SRC_MP=""
CLONE_SRC_PARENT=""
CLONE_DST_DEV=""
CLONE_DST_FS=""
CLONE_MNT=/mnt/clone_target

# ------------------------------------------------------------
#  Источник = текущий extroot, если мы загружены с внешнего.
# ------------------------------------------------------------
clone_overlay_find_source() {
    local mp dev
    mp=$(get_current_overlay)
    [ -n "$mp" ] || return 1

    dev=$(awk -v m="$mp" '$2==m {print $1; exit}' /proc/mounts)
    [ -n "$dev" ] || return 1
    is_internal_dev "$dev" && return 1

    CLONE_SRC_MP="$mp"
    CLONE_SRC_DEV="$dev"
    CLONE_SRC_PARENT=$(parent_dev "$dev")
    return 0
}

# ------------------------------------------------------------
#  Список кандидатов-целей.
#  Возвращает путь к временному файлу (формат: dev|fs|desc),
#  либо пусто и код 1, если целей нет.
# ------------------------------------------------------------
clone_overlay_list_targets() {
    local d part fs desc
    local out="/tmp/.clone-targets.$$"

    : > "$out"

    for d in /dev/sd? /dev/mmcblk?; do
        [ -b "$d" ] || continue
        is_removable_storage "$d" || continue
        [ "$(parent_dev "$d")" = "$CLONE_SRC_PARENT" ] && continue

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

        fs=$(block info "$part" 2>/dev/null \
             | grep -o 'TYPE="[^"]*"' | cut -d'"' -f2)
        desc=$(describe "$part")

        printf '%s|%s|%s\n' "$part" "${fs:-}" "$desc" >> "$out"
    done

    if [ ! -s "$out" ]; then
        rm -f "$out"
        return 1
    fi

    echo "$out"
    return 0
}

# ------------------------------------------------------------
#  Выбор цели. Заполняет CLONE_DST_DEV и CLONE_DST_FS.
# ------------------------------------------------------------
clone_overlay_choose_target() {
    local list n i dev fs desc mark

    list=$(clone_overlay_list_targets) || list=""
    if [ -z "$list" ] || [ ! -f "$list" ]; then
        echo
        echo -e "${CLR_ORANGE}Не найдено ни одного внешнего накопителя, кроме источника.${CLR_RESET}"
        echo "  Подключите вторую флэшку и повторите."
        echo
        printf "Нажмите Enter для возврата: "
        read _
        return 1
    fi

    echo
    echo -e "${CLR_YELLOW}Источник (сейчас загружены отсюда):${CLR_RESET}"
    echo -e "       ${CLR_GREEN}$(describe "$CLONE_SRC_DEV")${CLR_RESET}"
    echo
    echo -e "${CLR_YELLOW}Доступные цели:${CLR_RESET}"

    n=0
    while IFS='|' read -r dev fs desc; do
        n=$((n + 1))
        case "$fs" in
            ext2|ext3|ext4)
                mark="${CLR_GREEN}FS=$fs — можно без форматирования${CLR_RESET}"
                ;;
            "")
                mark="${CLR_ORANGE}FS=— — потребуется форматирование${CLR_RESET}"
                ;;
            *)
                mark="${CLR_ORANGE}FS=$fs — потребуется форматирование${CLR_RESET}"
                ;;
        esac
        echo -e "    $n) $desc"
        echo -e "       $mark"
    done < "$list"

    if [ "$n" = "0" ]; then
        rm -f "$list"
        return 1
    fi

    printf "Выберите цель (1-%d, 0 — отмена): " "$n"
    read i

    case "$i" in
        0|"")
            rm -f "$list"
            return 1
            ;;
        *[!0-9]*)
            rm -f "$list"
            echo "Некорректный ввод."
            return 1
            ;;
    esac

    if [ "$i" -lt 1 ] || [ "$i" -gt "$n" ]; then
        rm -f "$list"
        echo "Вне диапазона."
        return 1
    fi

    n=0
    while IFS='|' read -r dev fs desc; do
        n=$((n + 1))
        if [ "$n" = "$i" ]; then
            CLONE_DST_DEV="$dev"
            CLONE_DST_FS="$fs"
            break
        fi
    done < "$list"

    rm -f "$list"

    [ -n "$CLONE_DST_DEV" ] || return 1
    return 0
}

# ------------------------------------------------------------
#  Подготовка цели: если ФС не из {ext2,ext3,ext4} — спросить
#  и, при согласии, отформатировать.
# ------------------------------------------------------------
clone_overlay_prepare_target() {
    case "$CLONE_DST_FS" in
        ext2|ext3|ext4)
            echo "      цель уже $CLONE_DST_FS, форматирование не нужно"
            return 0
            ;;
    esac

    echo -e "${CLR_ORANGE}Цель не отформатирована в ext2/ext3/ext4 (текущая ФС: ${CLONE_DST_FS:-нет}).${CLR_RESET}"
    echo "  Все данные на $CLONE_DST_DEV будут уничтожены."
    echo
    printf "Отформатировать в ext4? (y/N): "
    read a
    case "$a" in
        y|Y|yes|YES) ;;
        *) echo "Отменено."; return 1 ;;
    esac

    if have fuser; then
        fuser -k -m "$CLONE_DST_DEV" 2>/dev/null || true
    fi
    for m in $(awk -v p="$CLONE_DST_DEV" '$1==p {print $2}' /proc/mounts); do
        umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
    done
    umount "$CLONE_DST_DEV" 2>/dev/null || umount -l "$CLONE_DST_DEV" 2>/dev/null || true
    sync
    sleep 1

    echo "      mkfs.ext4 $CLONE_DST_DEV ..."
    if ! mkfs.ext4 -F -L extroot "$CLONE_DST_DEV" >/dev/null 2>&1; then
        mkfs.ext4 -F -L extroot "$CLONE_DST_DEV"
        echo
        echo -e "${CLR_ORANGE}mkfs.ext4 не удался.${CLR_RESET}"
        return 1
    fi
    CLONE_DST_FS=ext4
    echo -e "${CLR_GREEN}      отформатировано${CLR_RESET}"
    return 0
}

# ------------------------------------------------------------
#  Проверка места и монтирование цели в CLONE_MNT.
#  При успехе цель ОСТАЁТСЯ примонтированной.
# ------------------------------------------------------------
clone_overlay_check_space() {
    local src_kb dst_kb need_kb

    src_kb=$(du -sk "$CLONE_SRC_MP" 2>/dev/null | awk '{print $1}')
    if [ -z "$src_kb" ]; then
        echo -e "${CLR_ORANGE}Не смог определить размер источника $CLONE_SRC_MP.${CLR_RESET}"
        return 1
    fi

    mkdir -p "$CLONE_MNT" || return 1
    if ! mount "$CLONE_DST_DEV" "$CLONE_MNT" 2>/dev/null; then
        echo -e "${CLR_ORANGE}Не смог смонтировать $CLONE_DST_DEV в $CLONE_MNT.${CLR_RESET}"
        rmdir "$CLONE_MNT" 2>/dev/null || true
        return 1
    fi

    dst_kb=$(df -k "$CLONE_MNT" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$dst_kb" ]; then
        umount "$CLONE_MNT" 2>/dev/null || true
        rmdir "$CLONE_MNT" 2>/dev/null || true
        echo -e "${CLR_ORANGE}Не смог определить свободное место на цели.${CLR_RESET}"
        return 1
    fi

    need_kb=$(( src_kb + src_kb / 10 ))
    echo "      источник: ${src_kb}K, цель свободна: ${dst_kb}K, нужно ~${need_kb}K"

    if [ "$dst_kb" -lt "$need_kb" ]; then
        umount "$CLONE_MNT" 2>/dev/null || true
        rmdir "$CLONE_MNT" 2>/dev/null || true
        echo -e "${CLR_ORANGE}Мало места на цели.${CLR_RESET}"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------
#  Копирование. Цель уже примонтирована в CLONE_MNT.
# ------------------------------------------------------------
clone_overlay_copy() {
    local ok=0 tgt

    echo "      копирую upper/ ..."
    mkdir -p "$CLONE_MNT/upper"
    if ! cp -a "$CLONE_SRC_MP/upper/." "$CLONE_MNT/upper/" 2>/tmp/clone_cp.err; then
        echo "      cp errors:"
        head -20 /tmp/clone_cp.err
        ok=1
    fi

    echo "      создаю work/ ..."
    mkdir -p "$CLONE_MNT/work"

    echo "      копирую .fs_state ..."
    if [ -L "$CLONE_SRC_MP/.fs_state" ]; then
        tgt=$(readlink "$CLONE_SRC_MP/.fs_state")
        [ -n "$tgt" ] && ln -sfn "$tgt" "$CLONE_MNT/.fs_state"
    elif [ -e "$CLONE_SRC_MP/.fs_state" ]; then
        cp -a "$CLONE_SRC_MP/.fs_state" "$CLONE_MNT/.fs_state" 2>/dev/null || true
    fi

    if [ ! -d "$CLONE_MNT/upper/etc/config" ]; then
        echo -e "${CLR_ORANGE}      цель не содержит upper/etc/config — копия некорректна${CLR_RESET}"
        ok=1
    fi

    sync
    return $ok
}

# ------------------------------------------------------------
#  Точка входа.
# ------------------------------------------------------------
clone_overlay_interactive() {
    local offer_switch=1
    if [ "$#" -gt 0 ]; then
        offer_switch="$1"
    fi

    echo
    echo "============================================================"
    echo "  Копирование extroot на второй накопитель"
    echo "============================================================"
    echo

    if ! clone_overlay_find_source; then
        echo -e "${CLR_ORANGE}Система загружена не с внешнего носителя.${CLR_RESET}"
        echo "  Копировать нечего: текущий overlay не на флэшке."
        echo
        printf "Нажмите Enter для возврата: "
        read _
        return 1
    fi

    if ! clone_overlay_choose_target; then
        return 1
    fi

    echo
    echo "      источник: $CLONE_SRC_DEV ($CLONE_SRC_MP)"
    echo "      цель:     $CLONE_DST_DEV"
    echo

    if ! clone_overlay_prepare_target; then
        return 1
    fi

    if ! clone_overlay_check_space; then
        return 1
    fi

    echo
    echo -e "${CLR_YELLOW}Внимание:${CLR_RESET} в корне цели будут перезаписаны"
    echo "  upper/, work/, .fs_state. Остальные файлы на цели не тронуты."
    echo
    printf "Начать копирование? (y/N): "
    read a
    case "$a" in
        y|Y|yes|YES) ;;
        *)
            umount "$CLONE_MNT" 2>/dev/null || true
            rmdir "$CLONE_MNT" 2>/dev/null || true
            echo "Отменено."
            return 1
            ;;
    esac

    local rc=0
    clone_overlay_copy || rc=1

    # Цель размонтируем всегда — её либо заберут, либо переключат
    umount "$CLONE_MNT" 2>/dev/null || umount -l "$CLONE_MNT" 2>/dev/null || true
    rmdir "$CLONE_MNT" 2>/dev/null || true

    if [ "$rc" != "0" ]; then
        echo
        echo -e "${CLR_ORANGE}Копирование завершилось с ошибками.${CLR_RESET}"
        echo "  Источник не тронут, можно повторить."
        echo
        printf "Нажмите Enter для возврата: "
        read _
        return 1
    fi

    echo
    echo -e "${CLR_GREEN}Готово. Копия overlay лежит на $CLONE_DST_DEV.${CLR_RESET}"
    echo "  Источник ($CLONE_SRC_DEV) не тронут."

    if [ "$offer_switch" != "1" ]; then
        echo "  Флэшку можно забирать."
        echo
        printf "Нажмите Enter для возврата: "
        read _
        return 0
    fi

    echo
    echo -e "${CLR_YELLOW}Сделать эту флэшку основной загрузочной?${CLR_RESET}"
    echo "  текущая: $CLONE_SRC_DEV"
    echo "  станет:  $CLONE_DST_DEV"
    echo "  после согласия — перезагрузка."
    echo
    printf "Назначить основной? (y/N): "
    read a
    case "$a" in
        y|Y|yes|YES)
            if ! command -v switch_overlay_after_clone >/dev/null 2>&1; then
                echo
                echo -e "${CLR_ORANGE}Модуль switch-overlay.sh не подключён.${CLR_RESET}"
                echo "  Копия создана, но переключение невозможно."
                printf "Нажмите Enter для возврата: "
                read _
                return 1
            fi
            SWITCH_DST_DEV="$CLONE_DST_DEV"
            switch_overlay_after_clone
            return $?
            ;;
        *)
            echo "Ок, флэшка остаётся копией."
            echo
            printf "Нажмите Enter для возврата: "
            read _
            return 0
            ;;
    esac
}