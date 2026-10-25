#!/bin/sh
# ============================================================
#  usb-extroot-install.sh  — установщик usb-extroot + веб-морда
#  sh <( wget -qO- https://raw.githubusercontent.com/kkkkCampbell/USB-extroot/refs/heads/draft/usb-extroot-install.sh )
# ============================================================
TEST_MODE=0
BASE_DIR="/opt/usb-extroot"

die() { echo "ОШИБКА: $1" >&2; exit 1; }
need_dir()  { [ -d "$1" ] || die "каталог $1 не создан"; }
need_file() { [ -s "$1" ] || die "файл $1 не создан или пуст"; }
need_exec() { need_file "$1"; [ -x "$1" ] || die "файл $1 не исполняемый"; }
need_sh()   { need_file "$1"; sh -n "$1" 2>/dev/null || die "синтаксическая ошибка в $1"; }
need_link() { [ -L "$1" ] || die "симлинк $1 не создан"; [ -e "$1" ] || die "симлинк $1 висит"; }

# safe_ln TARGET LINK — идемпотентный симлинк.
# Если LINK уже указывает на TARGET — ничего не делает (без "File exists").
# Иначе (нет LINK, ведёт в другое место, обычный файл) — rm -f + ln -s.
safe_ln() {
	local target="$1" link="$2"
	mkdir -p "$(dirname "$link")" || die "mkdir $(dirname "$link")"
	if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
		return 0
	fi
	rm -f "$link" || die "rm -f $link"
	ln -s "$target" "$link" || die "ln $link -> $target"
}

mkdir -p "$BASE_DIR" || die "не смог создать $BASE_DIR"
need_dir "$BASE_DIR"

# service_running NAME — спрашивает init-систему.
service_running() {
	local svc="$1"
	[ -x /etc/init.d/"$svc" ] || return 1
	/etc/init.d/"$svc" status >/dev/null 2>&1
}

# wait_for_service NAME TIMEOUT_SEC — только целые секунды
wait_for_service() {
	local svc="$1" timeout=40 i=0
	while [ "$i" -lt "$timeout" ]; do
		if service_running "$svc"; then
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	return 1
}

if [ "$(id -u)" != "0" ]; then
    echo "Запустите от root" >&2
    exit 1
fi

if [ "$TEST_MODE" != "1" ]; then
	SRC="https://raw.githubusercontent.com/kkkkCampbell/USB-extroot/refs/heads/draft"
	echo "==> Скачиваю usb-extroot.sh..."
	if ! wget -qO "$BASE_DIR/usb-extroot.sh" "$SRC/usb-extroot.sh"; then
		if ! curl -fsSL "$SRC/usb-extroot.sh" -o "$BASE_DIR/usb-extroot.sh"; then
			echo "Не смог скачать usb-extroot.sh" >&2
			exit 1
		fi
	fi
	echo "    OK"
else
    echo "==> TEST_MODE=1: пропускаю скачивание usb-extroot.sh"
    if [ ! -x "$BASE_DIR/usb-extroot.sh" ]; then
        echo "    ВНИМАНИЕ: $BASE_DIR/usb-extroot.sh не найден или не исполняемый!"
    fi
fi

chmod +x "$BASE_DIR/usb-extroot.sh" || die "chmod +x usb-extroot.sh"
if [ "$TEST_MODE" != "1" ]; then
	need_exec "$BASE_DIR/usb-extroot.sh"
fi

# ---- UCI config: два токена ----
gen_token() {
	head -c 16 /dev/urandom 2>/dev/null | hexdump -e '16/1 "%02x"' 2>/dev/null
}

if [ ! -f /etc/config/usb-extroot ]; then
	echo "==> Создаю /etc/config/usb-extroot..."
	NEW_READ=$(gen_token)
	[ -n "$NEW_READ" ] || NEW_READ="fixme${RANDOM}${RANDOM}${RANDOM}"
	NEW_WRITE=$(gen_token)
	[ -n "$NEW_WRITE" ] || NEW_WRITE="fixme${RANDOM}${RANDOM}${RANDOM}"
	cat > /etc/config/usb-extroot <<UCI_EOF
config usb-extroot 'main'
	option autobackup_delay '300'
	option read_token '$NEW_READ'
	option write_token '$NEW_WRITE'
UCI_EOF
	need_file /etc/config/usb-extroot
else
	OLD_TOKEN=$(uci -q get usb-extroot.main.api_token 2>/dev/null)
	if [ -n "$OLD_TOKEN" ]; then
		echo "==> Миграция api_token -> read_token/write_token..."
		uci set usb-extroot.main.read_token="$OLD_TOKEN" || die "uci set read_token"
		NEW_WRITE=$(gen_token)
		[ -n "$NEW_WRITE" ] || NEW_WRITE="fixme${RANDOM}${RANDOM}${RANDOM}"
		uci set usb-extroot.main.write_token="$NEW_WRITE" || die "uci set write_token"
		uci -q delete usb-extroot.main.api_token
		uci commit usb-extroot || die "uci commit usb-extroot"
	fi
	EX_READ=$(uci -q get usb-extroot.main.read_token 2>/dev/null)
	if [ -z "$EX_READ" ]; then
		echo "==> Дописываю read_token..."
		NEW_READ=$(gen_token)
		[ -n "$NEW_READ" ] || NEW_READ="fixme${RANDOM}${RANDOM}${RANDOM}"
		uci set usb-extroot.main.read_token="$NEW_READ" || die "uci set read_token"
		uci commit usb-extroot || die "uci commit usb-extroot"
	fi
	EX_WRITE=$(uci -q get usb-extroot.main.write_token 2>/dev/null)
	if [ -z "$EX_WRITE" ]; then
		echo "==> Дописываю write_token..."
		NEW_WRITE=$(gen_token)
		[ -n "$NEW_WRITE" ] || NEW_WRITE="fixme${RANDOM}${RANDOM}${RANDOM}"
		uci set usb-extroot.main.write_token="$NEW_WRITE" || die "uci set write_token"
		uci commit usb-extroot || die "uci commit usb-extroot"
	fi
fi

echo "==> Устанавливаю rpcd-плагин..."
cat > "$BASE_DIR/luci.usb-extroot" <<'RPCD_EOF'
#!/bin/sh
SCRIPT=/opt/usb-extroot/usb-extroot.sh
LOG=/tmp/usb-extroot.log
PID_FILE=/tmp/usb-extroot.pid
LOCK_DIR=/var/lock/usb-extroot-run.lock

esc_json() {
    awk 'BEGIN{printf "\""} {gsub(/\\/,"\\\\");gsub(/"/,"\\\"");gsub(/\t/,"\\t");if(NR>1)printf "\\n";printf "%s",$0} END{printf "\""}'
}

is_running() {
    [ -f "$PID_FILE" ] || return 1
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null && return 0
    rm -f "$PID_FILE"
    return 1
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
    local b
    b=$(basename "$1")
    case "$b" in
        sd[a-z][0-9]*|mmcblk[0-9]*p[0-9]*) b=$(basename "$(parent_dev "/dev/$b")") ;;
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

is_removable_storage() {
    local parent
    parent=$(basename "$(parent_dev "$1")")
    case "$parent" in
        sd[a-z]) is_usb "/dev/$parent"; return $? ;;
        mmcblk[0-9]*) [ "$(cat /sys/block/$parent/removable 2>/dev/null)" = "1" ]; return $? ;;
    esac
    return 1
}

run_script_action() {
    local action="$1"
    local out rc p tmp i state
    if [ ! -x "$SCRIPT" ]; then echo "NOT_FOUND"; return 1; fi

    if command -v timeout >/dev/null 2>&1; then
        out=$(timeout -s KILL 30 "$SCRIPT" --batch --action="$action" 2>&1)
        rc=$?
        if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then echo "TIMEOUT"; return 124; fi
    else
        tmp="/tmp/usb-extroot.act.$$"
        rm -f "$tmp"
        "$SCRIPT" --batch --action="$action" >"$tmp" 2>&1 &
        p=$!
        i=0
        while [ "$i" -lt 35 ]; do
            if [ ! -r "/proc/$p/stat" ]; then
                break
            fi
            state=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
            if [ "$state" = "Z" ] || [ -z "$state" ]; then
                break
            fi
            sleep 1
            i=$((i + 1))
        done
        if [ "$i" -ge 10 ]; then
            state=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
            if [ -n "$state" ] && [ "$state" != "Z" ]; then
                kill -9 "$p" 2>/dev/null
                wait "$p" 2>/dev/null
                rm -f "$tmp"
                echo "TIMEOUT"
                return 124
            fi
        fi
        wait "$p" 2>/dev/null
        rc=$?
        out=$(cat "$tmp" 2>/dev/null)
        rm -f "$tmp"
    fi

    if [ $rc -ne 0 ]; then echo "SCRIPT_ERROR: $out"; return $rc; fi
    echo "$out"
    return 0
}

method_version() {
    local v="" tmp="/tmp/usb-extroot.ver.$$" p i state
    if [ -x "$SCRIPT" ]; then
        if command -v timeout >/dev/null 2>&1; then
            timeout -s KILL 30 "$SCRIPT" --version >"$tmp" 2>/dev/null
        else
            "$SCRIPT" --version >"$tmp" 2>/dev/null &
            p=$!
            i=0
            while [ "$i" -lt 35 ]; do
                if [ ! -r "/proc/$p/stat" ]; then
                    break
                fi
                state=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
                if [ "$state" = "Z" ] || [ -z "$state" ]; then
                    break
                fi
                sleep 1
                i=$((i + 1))
            done
            if [ "$i" -ge 10 ]; then
                state=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
                if [ -n "$state" ] && [ "$state" != "Z" ]; then
                    kill -9 "$p" 2>/dev/null
                    wait "$p" 2>/dev/null
                fi
            fi
            wait "$p" 2>/dev/null
        fi
        [ -s "$tmp" ] && v=$(head -n1 "$tmp")
        rm -f "$tmp"
    fi
    printf '{ "result": { "version": '; printf '%s' "$v" | esc_json; printf ' } }\n'
}

method_api_read_token() {
    local tok=""
    tok=$(uci -q get usb-extroot.main.read_token 2>/dev/null)
    printf '{ "result": { "read_token": '; printf '%s' "$tok" | esc_json; printf ' } }\n'
}

method_api_write_token() {
    local tok=""
    tok=$(uci -q get usb-extroot.main.write_token 2>/dev/null)
    printf '{ "result": { "write_token": '; printf '%s' "$tok" | esc_json; printf ' } }\n'
}

method_abort_sleep() {
    killall sleep 37173 2>/dev/null || true
    echo '{ "result": { "status": "aborted" } }'
}

method_status() {
    local out running="false" kv
    is_running && running="true"
    out=$(run_script_action status)
    if [ "$out" = "TIMEOUT" ]; then echo '{ "error": "script timeout" }'; return
    elif [ "$out" = "NOT_FOUND" ]; then echo '{ "error": "usb-extroot.sh not found" }'; return
    elif [ "${out#SCRIPT_ERROR}" != "$out" ]; then
        printf '{ "error": %s }\n' "$(printf '%s' "$out" | esc_json)"; return
    fi
    kv=$(printf '%s' "$out" | awk -F= '
        NF>=2 { if (cnt++) printf ","; k=$1; $1=""; v=substr($0,2);
                gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v);
                printf "\"%s\":\"%s\"", k, v }
    ')
    printf '{ "result": {'
    if [ -n "$kv" ]; then printf '%s, ' "$kv"; fi
    printf '"running": %s } }\n' "$running"
}

method_devices() {
    local out
    out=$(run_script_action devices)
    if [ "$out" = "TIMEOUT" ]; then echo '{ "error": "script timeout" }'; return
    elif [ "$out" = "NOT_FOUND" ]; then echo '{ "error": "usb-extroot.sh not found" }'; return
    elif [ "${out#SCRIPT_ERROR}" != "$out" ]; then
        printf '{ "error": %s }\n' "$(printf '%s' "$out" | esc_json)"; return
    fi
    printf '{ "result": ['
    printf '%s\n' "$out" | awk -F'|' '
        NF>=3 { if (cnt++) printf ",";
                dev=$1; fs=$2; desc=$3;
                gsub(/\\/, "\\\\", dev); gsub(/"/, "\\\"", dev);
                gsub(/\\/, "\\\\", fs); gsub(/"/, "\\\"", fs);
                gsub(/\\/, "\\\\", desc); gsub(/"/, "\\\"", desc);
                printf "{\"dev\":\"%s\",\"fs\":\"%s\",\"desc\":\"%s\"}", dev, fs, desc }
    '
    printf '] }\n'
}

method_switch_targets() {
    local first=1 dev mp desc devices_out=""
    local status_out is_extroot="" cur_dev=""
    
    status_out=$(run_script_action status)
    is_extroot=$(printf '%s' "$status_out" | awk -F= '$1=="extroot" {print $2}')
    cur_dev=$(printf '%s' "$status_out" | awk -F= '$1=="extroot_dev" {print $2}')
    
    # Получаем человекочитаемые имена (с вендором и моделью) через тот же метод
    devices_out=$(run_script_action devices)

    printf '{ "result": ['
    
    if [ "$is_extroot" = "yes" ]; then
        printf '{"dev":"internal","desc":"Внутренняя память роутера"}'
        first=0
    fi

    for dev in $(awk '$3=="ext4" || $3=="f2fs" || $3=="btrfs" {print $1}' /proc/mounts 2>/dev/null | awk '!seen[$0]++'); do
        case "$dev" in
            /dev/ubi*|/dev/mtdblock*|/dev/root) continue ;;
        esac
        
        [ "$dev" = "$cur_dev" ] && continue
        
        mp=$(awk -v d="$dev" '$1==d {print $2; exit}' /proc/mounts 2>/dev/null)
        [ -n "$mp" ] || continue
        
        if [ -d "$mp/upper/etc/config" ] || [ -d "$mp/etc/config" ]; then
            # Берем красивое имя из results action=devices
            desc=$(printf '%s\n' "$devices_out" | awk -F'|' -v d="$dev" '$1==d {print $3; exit}')
            
            # Если вдруг не нашли (fallback)
            if [ -z "$desc" ]; then
                size_mb=$(df -m "$mp" 2>/dev/null | awk 'NR==2 {print $2}')
                parent_name=$(basename "$(parent_dev "$dev")")
                if [ -n "$size_mb" ] && [ "$size_mb" -gt 1024 ]; then
                    size_gb=$(awk "BEGIN {printf \"%.1f\", $size_mb/1024}")
                    size_str="${size_gb} ГБ"
                else
                    size_str="${size_mb:-?} МБ"
                fi
                desc="Раздел $dev ($size_str, диск $parent_name)"
            fi
            
            if [ "$first" = "1" ]; then
                first=0
            else
                printf ","
            fi
            
            dev_esc=$(printf '%s' "$dev" | sed 's/\\/\\\\/g; s/"/\\"/g')
            desc_esc=$(printf '%s' "$desc" | sed 's/\\/\\\\/g; s/"/\\"/g')
            printf '{"dev":"%s","desc":"%s"}' "$dev_esc" "$desc_esc"
        fi
    done
    
    printf '] }\n'
}


method_log() {
    local chunk=""
    [ -f "$LOG" ] && chunk=$(cat "$LOG" 2>/dev/null)
    printf '{ "result": { "chunk": '; printf '%s' "$chunk" | esc_json; printf ' } }\n'
}

method_backup_sources() {
    local out
    out=$(run_script_action backup-sources)
    if [ "$out" = "TIMEOUT" ]; then echo '{ "error": "script timeout" }'; return
    elif [ "$out" = "NOT_FOUND" ]; then echo '{ "error": "usb-extroot.sh not found" }'; return
    elif [ "${out#SCRIPT_ERROR}" != "$out" ]; then
        printf '{ "error": %s }\n' "$(printf '%s' "$out" | esc_json)"; return
    fi
    printf '{ "result": ['
    printf '%s\n' "$out" | awk -F'|' '
        NF>=2 { if (cnt++) printf ",";
                dev=$1; desc=$2;
                gsub(/\\/, "\\\\", dev); gsub(/"/, "\\\"", dev);
                gsub(/\\/, "\\\\", desc); gsub(/"/, "\\\"", desc);
                printf "{\"dev\":\"%s\",\"desc\":\"%s\"}", dev, desc }
    '
    printf '] }\n'
}

method_archive_info() {
    local out
    out=$(run_script_action archive-info)
    if [ "$out" = "TIMEOUT" ]; then echo '{ "error": "script timeout" }'; return
    elif [ "$out" = "NOT_FOUND" ]; then echo '{ "error": "usb-extroot.sh not found" }'; return
    elif [ "${out#SCRIPT_ERROR}" != "$out" ]; then
        printf '{ "error": %s }\n' "$(printf '%s' "$out" | esc_json)"; return
    fi
    printf '{ "result": {'
    printf '%s' "$out" | awk -F= '
        NF>=2 { if (cnt++) printf ","; k=$1; $1=""; v=substr($0,2);
                gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v);
                if (v ~ /^[0-9]+$/) printf "\"%s\":%s", k, v;
                else printf "\"%s\":\"%s\"", k, v }
    '
    printf '} }\n'
}

method_archive_list() {
    local out
    out=$(run_script_action archive-list)
    if [ "$out" = "TIMEOUT" ]; then echo '{ "error": "script timeout" }'; return
    elif [ "$out" = "NOT_FOUND" ]; then echo '{ "error": "usb-extroot.sh not found" }'; return
    elif [ "${out#SCRIPT_ERROR}" != "$out" ]; then
        printf '{ "error": %s }\n' "$(printf '%s' "$out" | esc_json)"; return
    fi



    printf '{ "result": ['
    printf '%s\n' "$out" | awk -F'|' '
        NF>=2 { if (seen[$1]++) next;
                if (cnt++) printf ","; name=$1; size=$2;
                gsub(/\\/, "\\\\", name); gsub(/"/, "\\\"", name);
                printf "{\"name\":\"%s\",\"size\":%s}", name, size }
    '
    printf '] }\n'


}

method_run() {
    local params mode device confirm archive pid lock_pid running_pid
    params=$(cat)

    if [ ! -x "$SCRIPT" ]; then
        echo "ERROR: usb-extroot.sh not found" >> "$LOG"
        echo '{ "error": "usb-extroot.sh not found" }'
        return
    fi

    if is_running; then
        running_pid=$(cat "$PID_FILE" 2>/dev/null)
        echo "ERROR: already running (pid $running_pid)" >> "$LOG"
        printf '{ "error": "already running", "pid": %d }\n' "${running_pid:-0}"
        return
    fi

    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "ERROR: already running (lock pid $lock_pid)" >> "$LOG"
            printf '{ "error": "already running", "pid": %d }\n' "$lock_pid"
            return
        fi
        rm -rf "$LOCK_DIR"
        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
            echo "ERROR: lock race" >> "$LOG"
            echo '{ "error": "lock race" }'
            return
        fi
    fi
    echo $$ > "$LOCK_DIR/pid"

    : > "$LOG"

    mode=$(echo "$params" | jsonfilter -e '@.mode' 2>/dev/null)
    device=$(echo "$params" | jsonfilter -e '@.device' 2>/dev/null)
    confirm=$(echo "$params" | jsonfilter -e '@.confirm' 2>/dev/null)
    archive=$(echo "$params" | jsonfilter -e '@.archive' 2>/dev/null)

    _fail() {
        rm -rf "$LOCK_DIR"
        echo "ERROR: $1" >> "$LOG"
        printf '{ "error": %s }\n' "$(printf '%s' "$1" | esc_json)"
    }

    if [ "$confirm" != "yes" ]; then _fail "confirm required"; return; fi

    case "$mode" in
        format|noformat|restore|fallback_fix|restore_archive|backup|backup_manual|reset_keep_extroot|switch_overlay) ;;
        *) _fail "invalid mode '$mode'"; return ;;
    esac















    case "$mode" in
        format|noformat|restore_archive|switch_overlay)
            if [ -z "$device" ]; then
                _fail "device required for $mode"; return
            fi
            if [ "$mode" = "restore_archive" ] && [ "$device" = "internal" ]; then
                :  # internal разрешён только для restore_archive
            elif [ "$mode" != "switch_overlay" ] && [ "${device#/dev/}" = "$device" ]; then
                _fail "invalid device '$device'"; return
            elif [ "$mode" != "switch_overlay" ] && [ "$device" != "internal" ] && ! is_removable_storage "$device"; then
                _fail "device '$device' is not removable (only USB/SD allowed)"; return
            fi
            ;;
        backup_manual)
            if [ -n "$device" ] && [ "$device" != "active" ] && [ "$device" != "internal" ] && [ "${device#/dev/}" = "$device" ]; then
                _fail "invalid device '$device'"; return
            fi
            ;;
    esac













    case "$mode" in
        format|noformat|switch_overlay)
            if [ -z "$device" ]; then _fail "device required for $mode"; return; fi
            archive=""
            ;;
        restore_archive)
            if [ -z "$archive" ]; then _fail "archive required for restore_archive"; return; fi
            ;;
        *)
            device=""; archive=""
            ;;
    esac

    if [ -n "$device" ]; then
        USB_EXTROOT_PID_FILE="$PID_FILE" USB_EXTROOT_LOCK_DIR="$LOCK_DIR" \
            setsid sh "$SCRIPT" --batch --mode="$mode" --device="$device" --archive="$archive" --confirm=yes >>"$LOG" 2>&1 &
    else
        USB_EXTROOT_PID_FILE="$PID_FILE" USB_EXTROOT_LOCK_DIR="$LOCK_DIR" \
            setsid sh "$SCRIPT" --batch --mode="$mode" --confirm=yes >>"$LOG" 2>&1 &
    fi

    local i=0
    pid=""
    while [ $i -lt 10 ]; do
        if [ -f "$PID_FILE" ]; then
            pid=$(cat "$PID_FILE" 2>/dev/null)
            [ -n "$pid" ] && break
        fi
        sleep 1
        i=$((i + 1))
    done

    if [ -z "$pid" ]; then
        echo "WARN: PID_FILE not created in 10s" >> "$LOG"
        printf '{ "result": { "pid": 0, "started": true, "note": "pid-pending" } }\n'
        return
    fi
    printf '{ "result": { "pid": %d, "started": true } }\n' "$pid"
}

case "$1" in
    list)
        echo '{ "status": {}, "devices": {}, "switch_targets": {}, "log": { "offset": 0 }, "archive_info": {}, "archive_list": {}, "backup_sources": {}, "version": {}, "api_read_token": {}, "api_write_token": {}, "abort_sleep": {}, "run": { "params": {} } }'
        ;;
    call)
        method="$2"
        case "$method" in
            status)          method_status ;;
            devices)         method_devices ;;
            switch_targets)  method_switch_targets ;;
            log)             method_log ;;
            archive_info)    method_archive_info ;;
            archive_list)    method_archive_list ;;
            backup_sources)  method_backup_sources ;;
            version)         method_version ;;
            api_read_token)  method_api_read_token ;;
            api_write_token) method_api_write_token ;;
            abort_sleep)     method_abort_sleep ;;
            run)             method_run ;;
            *) echo '{ "error": "unknown method" }' ;;
        esac
        ;;
esac
RPCD_EOF
need_sh "$BASE_DIR/luci.usb-extroot"
chmod +x "$BASE_DIR/luci.usb-extroot" || die "chmod +x luci.usb-extroot"
need_exec "$BASE_DIR/luci.usb-extroot"

echo "==> Создаю симлинки для rpcd..."
safe_ln "$BASE_DIR/luci.usb-extroot" /usr/libexec/rpcd/luci.usb-extroot
need_link /usr/libexec/rpcd/luci.usb-extroot

echo "==> Устанавливаю ACL..."
cat > "$BASE_DIR/acl.json" <<'ACL_EOF'
{
    "luci-app-usb-extroot": {
        "description": "USB extroot management",
        "read": {
            "ubus": {
                "luci.usb-extroot": [
                    "status", "devices", "switch_targets", "log", "archive_info", "archive_list", "backup_sources",
                    "version", "api_read_token"
                ]
            }
        },
        "write": {
            "ubus": {
                "luci.usb-extroot": [ "run", "api_write_token", "abort_sleep" ]
            }
        }
    }
}
ACL_EOF
need_file "$BASE_DIR/acl.json"
safe_ln "$BASE_DIR/acl.json" /usr/share/rpcd/acl.d/luci-app-usb-extroot.json
need_link /usr/share/rpcd/acl.d/luci-app-usb-extroot.json

echo "==> Устанавливаю меню..."
cat > "$BASE_DIR/menu.json" <<'MENU_EOF'
{
    "admin/services/usb-extroot": {
        "title": "USB extroot",
        "order": 30,
        "action": { "type": "view", "path": "usb-extroot/main" },
        "depends": { "acl": [ "luci-app-usb-extroot" ] }
    }
}
MENU_EOF
need_file "$BASE_DIR/menu.json"
safe_ln "$BASE_DIR/menu.json" /usr/share/luci/menu.d/luci-app-usb-extroot.json
need_link /usr/share/luci/menu.d/luci-app-usb-extroot.json

echo "==> Устанавливаю view..."
cat > "$BASE_DIR/main.js" <<'VIEW_EOF'
'use strict';
'require view';
'require ui';
'require rpc';
'require dom';


var callStatus = rpc.declare({ object: 'luci.usb-extroot', method: 'status' });
var callDevices = rpc.declare({ object: 'luci.usb-extroot', method: 'devices' });
var callSwitchTargets = rpc.declare({ object: 'luci.usb-extroot', method: 'switch_targets' });
var callLog = rpc.declare({ object: 'luci.usb-extroot', method: 'log' });
var callArchiveInfo = rpc.declare({ object: 'luci.usb-extroot', method: 'archive_info' });


var callArchiveList = rpc.declare({ object: 'luci.usb-extroot', method: 'archive_list' });
var callBackupSources = rpc.declare({ object: 'luci.usb-extroot', method: 'backup_sources' });
var callVersion = rpc.declare({ object: 'luci.usb-extroot', method: 'version' });




var callApiReadToken = rpc.declare({ object: 'luci.usb-extroot', method: 'api_read_token' });
var callApiWriteToken = rpc.declare({ object: 'luci.usb-extroot', method: 'api_write_token' });
var callAbortSleep = rpc.declare({ object: 'luci.usb-extroot', method: 'abort_sleep' });
var callRun = rpc.declare({ object: 'luci.usb-extroot', method: 'run', params: [ 'mode', 'device', 'archive', 'confirm' ] });

var pollTimer = null;
var readToken = '';
var writeToken = '';

function unwrap(res) { if (res && typeof res === 'object' && 'result' in res) return res.result; return res; }
function cleanLog(str) { return str.replace(/\r/g, '').replace(/[\u001b\u009b][[()#;?]*(?:[0-9]{1,4}(?:;[0-9]{1,4})*)?[0-9A-ORZcf-nqry=><]/g, ''); }
function genConfirmCode() { var n = ''; for (var i = 0; i < 4; i++) n += Math.floor(Math.random() * 10); return n; }

function buildManualDownloadLink(relPath) {
    var url = '/cgi-bin/usb-extroot-archive';
    if (relPath) url += '?file=' + encodeURIComponent(relPath);
    if (readToken) url += (url.indexOf('?') === -1 ? '?' : '&') + 'token=' + encodeURIComponent(readToken);
    return E('a', { 'href': url, 'class': 'cbi-button cbi-button-apply', 'style': 'margin-left:8px;' }, 'Скачать вручную');
}

return view.extend({
    load: function() {
        return Promise.all([
            callVersion().catch(function() { return null; }),
            callApiReadToken().catch(function() { return null; }),
            callApiWriteToken().catch(function() { return null; })
        ]);
    },

    render: function(results) {
        var self = this;
        var verRes = results ? results[0] : null;
        var readRes = results ? results[1] : null;
        var writeRes = results ? results[2] : null;
        var ver = (unwrap(verRes) || {}).version || '';
        readToken = (unwrap(readRes) || {}).read_token || '';
        writeToken = (unwrap(writeRes) || {}).write_token || '';
        var canWrite = !!writeToken;

        var logPre = E('pre', {
            'id': 'usb-extroot-log',
            'style': 'background:#111;color:#ccc;padding:10px;height:400px;overflow:auto;font-family:monospace;font-size:12px;white-space:pre-wrap;border:1px solid #444;margin-top:10px;'
        }, '');

        var deviceSelect = E('select', { 'id': 'usb-extroot-device', 'style': 'width:100%;padding:4px;', 'disabled': true }, [
            E('option', { 'value': '' }, '— нажмите "Получить состояние" —')
        ]);
        var modeSelect = E('select', { 'id': 'usb-extroot-mode', 'style': 'width:100%;padding:4px;', 'disabled': true }, [
            E('option', { 'value': '' }, '— ВЫБЕРИТЕ ВАРИАНТ ПЕРЕНОСА ДАННЫХ —'),
            E('option', { 'value': 'format' }, 'С форматированием (mkfs.ext4) ПОЛНОЕ УНИЧТОЖЕНИЕ ДАННЫХ'),
            E('option', { 'value': 'noformat' }, 'Без форматирования (только overlay-структура)')
        ]);



        var switchDeviceSelect = E('select', { 'id': 'usb-extroot-switch-device', 'style': 'width:100%;padding:4px;', 'disabled': true,
            'change': function() {
                var btnSwitchEl = document.getElementById('btn-switch-overlay');
                if (btnSwitchEl) {
                    btnSwitchEl.disabled = !canWrite || !switchDeviceSelect.value;
                }
            }
        }, [
            E('option', { 'value': '' }, '— нажмите "Получить состояние" —')
        ]);
		
		

        var statusText = E('div', { 'style': 'margin-bottom:2px;color:#aaa; font-weight:bold;' }, 'Статус не проверен.');
        var subStatusText = E('div', { 'style': 'margin-bottom:6px; font-size:13px; font-weight:bold; display:none;' }, '');
        var hintText = E('div', { 'id': 'usb-extroot-hint', 'style': 'margin-bottom:10px; color:#ffaa00; font-size:12px; display:none;' }, '');

        var btnFallback = E('button', {
            'class': 'cbi-button cbi-button-negative', 'style': 'margin-right:8px; display:none;', 'id': 'btn-fallback_fix', 'disabled': true,
            'click': function() { self.runOp('fallback_fix', null, null, logPre); }
        }, 'Исправить аварийный режим overlay');

        var btnTransfer = E('button', {
            'class': 'cbi-button', 'style': 'margin-right:8px;', 'id': 'btn-transfer', 'disabled': true,
            'click': function() { self.runOp(modeSelect.value, deviceSelect.value, null, logPre); }
        }, 'Выполнить перенос');

        var btnSwitchOverlay = E('button', {
            'class': 'cbi-button cbi-button-apply', 'style': 'margin-right:8px;', 'id': 'btn-switch-overlay', 'disabled': true,
            'click': function() {
                var dev = switchDeviceSelect.value;
                if (!dev) { ui.addNotification(null, E('p', {}, 'Выберите накопитель для переключения.'), 'danger'); return; }
                if (dev === 'internal') {
                    self.runOp('restore', null, null, logPre);
                } else {
                    self.runOp('switch_overlay', dev, null, logPre);
                }
            }
        }, 'Сменить загрузочный накопитель');

        var btnRestoreArchive = E('button', {
            'class': 'cbi-button', 'style': 'margin-right:8px;', 'id': 'btn-restore-archive', 'disabled': true,
            'click': function() { self.showArchiveList(logPre); }
        }, 'Восстановить из архива на флешке');








        var btnBackup = E('button', {
            'class': 'cbi-button', 'style': 'margin-right:32px;', 'id': 'btn-backup-manual', 'disabled': true,
            'click': function() { self.showBackupSourceDialog(logPre); }
        }, 'Создать бэкап сейчас');









        var btnUpload = E('button', {
            'class': 'cbi-button', 'style': 'margin-right:8px;', 'id': 'btn-upload-archive', 'disabled': true,
            'click': function() { self.showUploadDialog(logPre); }
        }, 'Загрузить архив с ПК');

        var btnFactoryReset = E('button', {
            'class': 'cbi-button cbi-button-negative', 'style': 'margin-top:20px; display:none;', 'id': 'btn-factory-reset', 'disabled': true,
            'click': function() { self.runOp('reset_keep_extroot', null, null, logPre); }
        }, 'Сбросить настройки (оставить загрузку с флешки)');

        var updateUI = function(status, devices, switchTargets) {
            var isExtroot = (status.extroot === 'yes');
            var isFallback = (status.fallback === 'yes');
            var curDev = status.extroot_dev || '';

            deviceSelect.innerHTML = '';
            var availCount = 0;
            if (devices && Array.isArray(devices)) {
                devices.forEach(function(d) {
                    if (isExtroot && d.dev === curDev) return;
                    deviceSelect.appendChild(E('option', { 'value': d.dev }, d.desc));
                    availCount++;
                });
            }
            if (availCount === 0) {
                deviceSelect.appendChild(E('option', { 'value': '' }, '— нет доступных накопителей —'));
            }

            switchDeviceSelect.innerHTML = '';
            var switchAvailCount = 0;
            if (switchTargets && Array.isArray(switchTargets)) {
                switchTargets.forEach(function(t) {
                    switchDeviceSelect.appendChild(E('option', { 'value': t.dev }, t.desc));
                    switchAvailCount++;
                });
            }
            if (switchAvailCount > 0) {
                switchDeviceSelect.insertBefore(E('option', { 'value': '' }, '— выберите накопитель —'), switchDeviceSelect.firstChild);
                switchDeviceSelect.value = ''; // Сбрасываем выбор на "Не выбрано" при обновлении
            } else {
                switchDeviceSelect.appendChild(E('option', { 'value': '' }, '— нет накопителей с валидным оверлеем —'));
            }

            var btnTransferEl = document.getElementById('btn-transfer');
            var modeSelectEl = document.getElementById('usb-extroot-mode');
            var btnSwitchEl = document.getElementById('btn-switch-overlay');
            var btnRestoreEl = document.getElementById('btn-restore');
            var btnRestoreArchiveEl = document.getElementById('btn-restore-archive');
            var btnBackupEl = document.getElementById('btn-backup-manual');
            var btnUploadEl = document.getElementById('btn-upload-archive');
            var hintEl = document.getElementById('usb-extroot-hint');

            var extrootStr = isExtroot
                ? 'Используется накопитель ' + (status.extroot_desc || curDev)
                : 'Используется внутренний накопитель роутера';
            var errStr = isFallback ? 'ДА (ТРЕБУЕТСЯ ИСПРАВЛЕНИЕ)' : 'НЕТ';
            statusText.textContent = extrootStr + ' | Ошибки: ' + errStr;

            var subStatusEl = document.getElementById('usb-extroot-substatus');
            if (subStatusEl) {
                if (isExtroot) {
                    subStatusEl.textContent = 'Вы загружены с внешнего накопителя';
                    subStatusEl.style.color = '#ffaa00';
                    subStatusEl.style.display = 'block';
                } else {
                    subStatusEl.style.display = 'none';
                }
            }
            if (isFallback) statusText.style.color = '#ff5555';
            else if (isExtroot) statusText.style.color = '#32cd32';
            else statusText.style.color = '#aaa';

            if (isFallback) {
                if (btnTransferEl) btnTransferEl.disabled = true;
                if (modeSelectEl) modeSelectEl.disabled = true;
                deviceSelect.disabled = true;
                if (btnSwitchEl) btnSwitchEl.disabled = true;
                switchDeviceSelect.disabled = true;
                if (btnRestoreArchiveEl) btnRestoreArchiveEl.disabled = true;
                if (btnBackupEl) btnBackupEl.disabled = true;
                if (btnUploadEl) btnUploadEl.disabled = true;
                if (hintEl) {
                    hintEl.textContent = 'ВНИМАНИЕ: Обнаружен аварийный режим overlay (фоллбэк). Сначала нажмите «Исправить аварийный режим overlay».';
                    hintEl.style.display = 'block'; hintEl.style.color = '#ff5555';
                }
            } else if (!isExtroot) {
                // Внутренняя память: разрешаем бэкап, восстановление из архива и загрузку с ПК
                if (btnTransferEl) btnTransferEl.disabled = !canWrite || availCount === 0;
                if (modeSelectEl) modeSelectEl.disabled = !canWrite || availCount === 0;
                deviceSelect.disabled = !canWrite || availCount === 0;
                if (btnSwitchEl) btnSwitchEl.disabled = !canWrite || switchAvailCount === 0 || switchDeviceSelect.value === '';
                switchDeviceSelect.disabled = !canWrite || switchAvailCount === 0;

                if (btnBackupEl) btnBackupEl.disabled = !canWrite;
                if (btnRestoreArchiveEl) btnRestoreArchiveEl.disabled = !canWrite;
                if (btnUploadEl) btnUploadEl.disabled = !canWrite;

                if (hintEl) hintEl.style.display = 'none';
            } else {
                // Клон-режим (Флешка А -> Флешка Б)
                if (btnTransferEl) btnTransferEl.disabled = !canWrite || availCount === 0;
                if (modeSelectEl) modeSelectEl.disabled = !canWrite || availCount === 0;
                deviceSelect.disabled = !canWrite || availCount === 0;
                if (btnSwitchEl) btnSwitchEl.disabled = !canWrite || switchAvailCount === 0 || switchDeviceSelect.value === '';
                switchDeviceSelect.disabled = !canWrite || switchAvailCount === 0;
                
                if (btnRestoreArchiveEl) btnRestoreArchiveEl.disabled = !canWrite;
                if (btnBackupEl) btnBackupEl.disabled = !canWrite;
                if (btnUploadEl) btnUploadEl.disabled = !canWrite;
                if (hintEl) {
                    if (!canWrite) {
                        hintEl.textContent = 'У вас только чтение (нет write-ACL). Действия записи недоступны.';
                        hintEl.style.display = 'block'; hintEl.style.color = '#ff5555';
                    } else hintEl.style.display = 'none';
                }
            }

            var fbBtn = document.getElementById('btn-fallback_fix');
            if (fbBtn) fbBtn.style.display = (isFallback && canWrite) ? 'inline-block' : 'none';
            if (fbBtn) fbBtn.disabled = !canWrite;
            
            var getStateBtn = document.getElementById('btn-get-state');
            if (getStateBtn) getStateBtn.disabled = false;
            
            var resetBtnEl = document.getElementById('btn-factory-reset');
            if (resetBtnEl) {
                resetBtnEl.style.display = (isExtroot && canWrite) ? 'block' : 'none';
                resetBtnEl.disabled = !canWrite;
            }
        };

        self._updateUI = updateUI;

        self._lockUI = function(disabled) {
            ['btn-transfer', 'btn-switch-overlay', 'btn-fallback_fix', 'btn-restore-archive',
             'btn-backup-manual', 'btn-upload-archive', 'btn-get-state', 'btn-factory-reset'].forEach(function(id) {
                var el = document.getElementById(id);
                if (el) el.disabled = disabled;
            });
            var modeSelectEl = document.getElementById('usb-extroot-mode');
            if (modeSelectEl) modeSelectEl.disabled = disabled;
            var deviceSelectEl = document.getElementById('usb-extroot-device');
            if (deviceSelectEl) deviceSelectEl.disabled = disabled;
            var switchDeviceSelectEl = document.getElementById('usb-extroot-switch-device');
            if (switchDeviceSelectEl) switchDeviceSelectEl.disabled = disabled;
        };

        var btnGetState = E('button', {
            'class': 'cbi-button cbi-button-action', 'style': 'margin-right:8px;', 'id': 'btn-get-state',
            'click': function(ev) {
                var btn = ev.currentTarget;
                btn.disabled = true; btn.textContent = 'Получение...';
                var resetBtn = function() { btn.disabled = false; btn.textContent = 'Получить состояние'; };
                Promise.all([
                    callStatus().catch(function(err) { return { __error: err }; }),
                    callDevices().catch(function(err) { return { __error: err }; }),
                    callSwitchTargets().catch(function(err) { return { __error: err }; })
                ]).then(function(arr) {
                    var sRes = arr[0], dRes = arr[1], stRes = arr[2];
                    if (sRes && sRes.__error) {
                        var msg = (sRes.__error.message) ? sRes.__error.message : String(sRes.__error);
                        ui.addNotification(null, E('p', {}, 'Статус: ' + msg), 'danger');
                    }
                    if (dRes && dRes.__error) {
                        var msg2 = (dRes.__error.message) ? dRes.__error.message : String(dRes.__error);
                        ui.addNotification(null, E('p', {}, 'Устройства: ' + msg2), 'danger');
                    }
                    if (stRes && stRes.__error) {
                        var msg3 = (stRes.__error.message) ? stRes.__error.message : String(stRes.__error);
                        ui.addNotification(null, E('p', {}, 'Цели переключения: ' + msg3), 'danger');
                    }
                    updateUI(unwrap(sRes) || {}, unwrap(dRes) || [], unwrap(stRes) || []);
                    resetBtn();
                });
            }
        }, 'Получить состояние');

        var controls = E('div', { 'style': 'margin:10px 0;padding:10px;background:rgba(0,0,0,0.05);border:1px solid rgba(255,255,255,0.1);' }, [
            E('div', { 'style': 'margin-bottom:8px;' }, [ btnGetState ]),
            statusText, 
            E('div', { 'id': 'usb-extroot-substatus' }, [ subStatusText ]), 
            hintText,
            E('hr', { 'style': 'border:0;border-top:1px solid rgba(255,255,255,0.1);margin:10px 0;' }),
            E('div', { 'style': 'margin-bottom:8px;display:flex;gap:10px;align-items:center;' }, [
                E('label', { 'style': 'font-weight:bold;white-space:nowrap;' }, 'Режим переноса:'), modeSelect
            ]),
            E('div', { 'style': 'margin-bottom:12px;display:flex;gap:10px;align-items:center;' }, [
                E('label', { 'style': 'font-weight:bold;white-space:nowrap;' }, 'Накопитель для переноса:'), deviceSelect
            ]),
            E('div', { 'style': 'display:flex; flex-wrap:wrap; gap:8px; justify-content:flex-end; margin-top:15px; margin-bottom:15px;' }, [
                btnTransfer, btnFallback
            ]),
            E('hr', { 'style': 'border:0;border-top:1px dashed rgba(255,255,255,0.2);margin:10px 0;' }),
            E('div', { 'style': 'margin-bottom:12px;display:flex;gap:10px;align-items:center;' }, [
                E('label', { 'style': 'font-weight:bold;white-space:nowrap;' }, 'Выбор загрузочного диска:'), switchDeviceSelect
            ]),
            E('div', { 'style': 'display:flex; flex-wrap:wrap; gap:8px; justify-content:flex-end; margin-top:15px; margin-bottom:15px;' }, [
                btnSwitchOverlay
            ]),

            E('div', { 'style': 'border-top:1px dashed rgba(255,255,255,0.2); margin-bottom:15px;' }),
            E('div', { 'style': 'display:flex; flex-wrap:wrap; gap:8px;' }, [
                btnBackup, btnRestoreArchive, btnUpload
            ])
        ]);

        return E([], [
            E('h2', {}, ['USB extroot',
                ver ? E('span', { 'style': 'margin-left:12px;font-size:14px;font-weight:normal;color:#888;' }, ver) : ''
            ]),
            E('p', {}, 'Перенос overlay OpenWrt на USB-накопитель и управление загрузкой.'),
            controls,
            E('h3', {}, 'Журнал выполнения'),
            logPre,
            btnFactoryReset
        ]);
    },












    showBackupSourceDialog: function(logPre) {
        var self = this;
        if (!writeToken) { ui.addNotification(null, E('p', {}, 'Нет прав на запись (нет write-ACL).'), 'danger'); return; }
        callBackupSources().then(function(res) {
            var sources = unwrap(res);
            if (!Array.isArray(sources) || sources.length === 0) {
                ui.addNotification(null, E('p', {}, 'Нет доступных источников для бэкапа.'), 'danger');
                return;
            }
            var sourceSelect = E('select', { 'style': 'width:100%;padding:4px;margin-bottom:10px;' }, []);
            sources.forEach(function(s) {
                sourceSelect.appendChild(E('option', { 'value': s.dev }, s.desc));
            });

            var body = E('div', {}, [
                E('p', { 'style': 'font-weight:bold;' }, 'Выберите источник для создания архива:'),
                sourceSelect
            ]);

            var footer = E('div', { 'style': 'display:flex;gap:8px;justify-content:flex-end;' }, [
                E('button', { 'class': 'cbi-button cbi-button-reset', 'click': function() { ui.hideModal(); } }, 'Отмена'),
                E('button', {
                    'class': 'cbi-button cbi-button-apply',
                    'click': function() {
                        var dev = sourceSelect.value;
                        ui.hideModal();
                        self.doBackupManual(dev, logPre);
                    }
                }, 'Создать бэкап')
            ]);
            ui.showModal('Создание бэкапа', [ body, footer ]);
        }).catch(function(err) {
            ui.addNotification(null, E('p', {}, 'Ошибка получения источников: ' + err), 'danger');
        });
    },

    doBackupManual: function(device, logPre) {
        var self = this;
        logPre.textContent = ''; self._lockUI(true);
        callRun('backup_manual', device, '', 'yes').then(function(res) {
            if (res && res.error) { ui.addNotification(null, E('p', {}, 'Ошибка: ' + res.error), 'danger'); self._lockUI(false); return; }
            self.startPolling(logPre, 'backup_manual');
        }).catch(function(err) { ui.addNotification(null, E('p', {}, 'Ошибка запуска: ' + err), 'danger'); self._lockUI(false); });
    },












    showUploadDialog: function(logPre) {
        var self = this;
        if (!writeToken) { ui.addNotification(null, E('p', {}, 'Загрузка архивов требует права записи (write-ACL).'), 'danger'); return; }
        
        var fileInput = E('input', { 'type': 'file', 'accept': '.tar.gz', 'style': 'margin-bottom:10px; width:100%;' });
        var copyCheckbox = E('input', { 'type': 'checkbox', 'id': 'upload-copy-to-usb', 'style': 'margin-right:8px;' });
        var copyLabel = E('label', { 'for': 'upload-copy-to-usb', 'style': 'cursor:pointer;' }, 'Скопировать архив на накопитель');
        var copyWrapper = E('div', { 'style': 'margin-top:10px; margin-bottom:10px; display:flex; align-items:center;' }, [ copyCheckbox, copyLabel ]);

        var statusText = E('p', { 'style': 'margin-top:10px; font-weight:bold;' }, '');
        var progressBar = E('div', { 'style': 'width:100%; height:10px; background:#333; margin-top:10px; display:none;' }, [
            E('div', { 'style': 'width:0%; height:100%; background:#32cd32; transition:width 0.2s;' })
        ]);

        var body = E('div', {}, [
            E('p', {}, 'Выберите файл .tar.gz (архив overlay/upper) для загрузки и немедленного восстановления:'),
            fileInput, copyWrapper, statusText, progressBar
        ]);

        var footer = E('div', { 'style': 'display:flex;gap:8px;justify-content:flex-end;' }, [
            E('button', { 'class': 'cbi-button cbi-button-reset', 'click': function() { ui.hideModal(); } }, 'Закрыть'),
            E('button', {
                'class': 'cbi-button cbi-button-apply',
                'click': function() {
                    var file = fileInput.files[0];
                    if (!file || !file.name.endsWith('.tar.gz')) {
                        ui.addNotification(null, E('p', {}, 'Выберите .tar.gz файл.'), 'danger'); return;
                    }
                    var shouldCopy = copyCheckbox.checked;
                    statusText.textContent = 'Загрузка... (' + Math.round(file.size / 1024) + ' KB)';
                    progressBar.style.display = 'block';
                    
                    var xhr = new XMLHttpRequest();
                    var uploadUrl = '/cgi-bin/usb-extroot-upload?file=' + encodeURIComponent(file.name);
                    if (writeToken) {
                        uploadUrl += '&token=' + encodeURIComponent(writeToken);
                    }
                    xhr.open('POST', uploadUrl, true);
                    xhr.setRequestHeader('Content-Type', 'application/octet-stream');
                    xhr.setRequestHeader('X-Extroot-Token', writeToken);
                    
                    xhr.upload.onprogress = function(e) {
                        if (e.lengthComputable) {
                            var percent = Math.round((e.loaded / e.total) * 100);
                            progressBar.firstChild.style.width = percent + '%';
                            statusText.textContent = 'Загрузка: ' + percent + '%';
                        }
                    };
                    
                    xhr.onload = function() {
                        
							
						                        if (xhr.status >= 200 && xhr.status < 300) {
                            ui.hideModal();
                            ui.addNotification(null, E('p', {}, 'Архив загружен. Выберите цель восстановления.'), 'info');

                            var archiveParam = 'tmp/' + file.name;
                            if (shouldCopy) {
                                archiveParam = 'save_tmp/' + file.name;
                            }

                            Promise.all([ callDevices(), callStatus() ]).then(function(results) {
                                var devices = unwrap(results[0]);
                                if (!Array.isArray(devices)) devices = [];
                                var st = unwrap(results[1]) || {};

                                var targetSelect = E('select', { 'style': 'width:100%;padding:4px;margin-bottom:10px;' }, [
                                    E('option', { 'value': 'internal' }, 'Внутренняя память роутера (/overlay)')
                                ]);
                                devices.forEach(function(d) {
                                    targetSelect.appendChild(E('option', { 'value': d.dev }, d.desc));
                                });

                                // По умолчанию — текущая загрузка: extroot → текущий диск, иначе internal
                                if (st.extroot_dev) {
                                    targetSelect.value = st.extroot_dev;
                                } else {
                                    targetSelect.value = 'internal';
                                }

                                var body = E('div', {}, [
                                    E('p', { 'style': 'font-weight:bold;' }, 'Архив: ' + file.name),
                                    E('p', {}, 'Цель восстановления:'),
                                    targetSelect,
                                    E('p', { 'style': 'font-size:12px; color:#888; margin-top:10px;' },
                                        'По умолчанию — текущая загрузка. Если выбрать внешний накопитель, система после ребута загрузится с него (extroot).')
                                ]);

                                var footer = E('div', { 'style': 'display:flex;gap:8px;justify-content:flex-end;' }, [
                                    E('button', { 'class': 'cbi-button cbi-button-reset',
                                        'click': function() { ui.hideModal(); } }, 'Отмена'),
                                    E('button', {
                                        'class': 'cbi-button cbi-button-apply',
                                        'click': function() {
                                            var target = targetSelect.value;
                                            if (!target) { ui.addNotification(null, E('p', {}, 'Выберите цель.'), 'danger'); return; }
                                            ui.hideModal();
                                            self.runOp('restore_archive', target, archiveParam, logPre);
                                        }
                                    }, 'Восстановить')
                                ]);
                                ui.showModal('Выбор цели восстановления', [ body, footer ]);
                            });	
							
                        } else {
                            statusText.textContent = 'Ошибка сервера: ' + xhr.responseText;
                            statusText.style.color = '#ff5555';
                            progressBar.firstChild.style.background = '#ff5555';
                        }
                    };
                    xhr.onerror = function() {
                        statusText.textContent = 'Ошибка сети.';
                        statusText.style.color = '#ff5555';
                    };
                    xhr.send(file);
                }
            }, 'Загрузить и восстановить')
        ]);
        ui.showModal('Загрузка и восстановление из архива', [ body, footer ]);
    },

    downloadArchive: function(relPath) {
        if (!readToken) return Promise.resolve(false);
        var url = '/cgi-bin/usb-extroot-archive';
        if (relPath) url += '?file=' + encodeURIComponent(relPath);
        if (readToken) url += (url.indexOf('?') === -1 ? '?' : '&') + 'token=' + encodeURIComponent(readToken);
        
        return fetch(url).then(function(r) {
            if (!r.ok) throw new Error('HTTP ' + r.status);
            
            var filename = relPath ? relPath.split('/').pop() : 'overlay_backup.tar.gz';
            var disposition = r.headers.get('content-disposition');
            if (disposition && disposition.indexOf('filename=') !== -1) {
                var matches = disposition.match(/filename[^;=\n]*=((['"]).*?\2|[^;\n]*)/);
                if (matches && matches[1]) {
                    filename = matches[1].replace(/['"]/g, '');
                }
            }
            
            return r.blob().then(function(blob) {
                return { blob: blob, filename: filename };
            });
        }).then(function(data) {
            var a = document.createElement('a');
            var objUrl = URL.createObjectURL(data.blob);
            a.href = objUrl;
            a.download = data.filename;
            document.body.appendChild(a); a.click(); document.body.removeChild(a);
            setTimeout(function() { URL.revokeObjectURL(objUrl); }, 2000);
            return true;
        }).catch(function() { return false; });
    },

    showArchiveList: function(logPre) {
        var self = this;
        if (!writeToken) { ui.addNotification(null, E('p', {}, 'Восстановление из архива требует write-ACL.'), 'danger'); return; }
        Promise.all([ callArchiveList(), callDevices() ]).then(function(results) {
            var list = unwrap(results[0]);
            var devices = unwrap(results[1]);
            if (!Array.isArray(devices)) devices = [];
            
            if (!Array.isArray(list) || list.length === 0) { 
                ui.addNotification(null, E('p', {}, 'На примонтированных разделах нет архивов.'), 'warning'); 
                return; 
            }

            var archiveSelect = E('select', { 'style': 'width:100%;padding:4px;margin-bottom:10px;' }, [
                E('option', { 'value': '' }, '— выберите архив —')
            ]);


            list.forEach(function(a) {
                var sizeKb = Math.round(a.size / 1024);
                archiveSelect.appendChild(E('option', { 'value': a.name }, a.name + ' (' + sizeKb + ' KB)'));
            });



            var deviceSelect2 = E('select', { 'style': 'width:100%;padding:4px;margin-bottom:10px;' }, [
                E('option', { 'value': '' }, '— выберите цель —')
            ]);
            // Всегда доступна внутренняя память (восстановление на /overlay)
            deviceSelect2.appendChild(E('option', { 'value': 'internal' }, 'Внутренняя память роутера (/overlay)'));
            devices.forEach(function(d) {
                deviceSelect2.appendChild(E('option', { 'value': d.dev }, d.desc));
            });

            var body = E('div', {}, [
                E('p', { 'style': 'color:#ff5555;font-weight:bold;' }, 'ВНИМАНИЕ: архив будет развёрнут на выбранную цель (внешний накопитель или внутренняя память /overlay).'),
                E('p', {}, 'Архив (новые вверху):'), archiveSelect,
                E('p', {}, 'Целевое устройство:'), deviceSelect2
            ]);

            var footer = E('div', { 'style': 'display:flex;gap:8px;justify-content:flex-end;' }, [
                E('button', { 'class': 'cbi-button cbi-button-reset', 'click': function() { ui.hideModal(); } }, 'Отмена'),
                E('button', {
                    'class': 'cbi-button cbi-button-apply',
                    'click': function() {
                        var arc = archiveSelect.value;
                        var dev = deviceSelect2.value;
                        if (!arc || !dev) { ui.addNotification(null, E('p', {}, 'Выберите архив и цель.'), 'danger'); return; }
                        ui.hideModal();
                        self.runOp('restore_archive', dev, arc, logPre);
                    }
                }, 'Развернуть')
            ]);
            ui.showModal('Восстановление из архива', [ body, footer ]);
        }).catch(function(err) { ui.addNotification(null, E('p', {}, 'Ошибка получения списков: ' + err), 'danger'); });
    },

    runOp: function(mode, device, archive, logPre) {
        var self = this;
        if (!writeToken) { ui.addNotification(null, E('p', {}, 'Это действие требует write-ACL.'), 'danger'); return; }
        if (!mode) { ui.addNotification(null, E('p', {}, 'Выберите действие.'), 'warning'); return; }
        if ((mode === 'format' || mode === 'noformat') && !device) { ui.addNotification(null, E('p', {}, 'Выберите накопитель.'), 'danger'); return; }
        if (mode === 'switch_overlay' && !device) { ui.addNotification(null, E('p', {}, 'Выберите целевой накопитель.'), 'danger'); return; }

        if (mode === 'restore_archive' && device === 'internal') {
            self.showBackupPrompt(archive, logPre);
            return;
        }

        self.showConfirmDialog(mode, device, archive, logPre);
    },

    showBackupPrompt: function(archive, logPre) {
        var self = this;
        var body = E('div', {}, [
            E('p', { 'style': 'font-weight:bold; color:#ffaa00;' },
                'Восстановление на внутреннюю память роутера (/overlay).'),
            E('p', {},
                'Текущий overlay будет уничтожен в процессе восстановления. Рекомендуем сначала сохранить его в архив и скачать на компьютер — на случай, если после восстановления что-то пойдёт не так.'),
            E('p', {}, 'Выберите действие:')
        ]);
        var footer = E('div', { 'style': 'display:flex;gap:8px;justify-content:flex-end;flex-wrap:wrap;' }, [
            E('button', {
                'class': 'cbi-button cbi-button-reset',
                'click': function() { ui.hideModal(); }
            }, 'Отмена'),
            E('button', {
                'class': 'cbi-button cbi-button-negative',
                'click': function() {
                    ui.hideModal();
                    self.showConfirmDialog('restore_archive', 'internal', archive, logPre);
                }
            }, 'Восстановить без бэкапа'),
            E('button', {
                'class': 'cbi-button cbi-button-apply',
                'click': function() {
                    ui.hideModal();
                    self.doBackupThenRestore(archive, logPre);
                }
            }, 'Сначала бэкап, потом восстановить')
        ]);
        ui.showModal('Сохранить текущее состояние?', [ body, footer ]);
    },

    doBackupThenRestore: function(archive, logPre) {
        var self = this;
        logPre.textContent = '';
        self._lockUI(true);

        callRun('backup_manual', '', '', 'yes').then(function(res) {
            if (res && res.error) {
                ui.addNotification(null, E('p', {}, 'Ошибка запуска бэкапа: ' + res.error), 'danger');
                self._lockUI(false);
                return;
            }
            self._pollBackupThenRestore(archive, logPre);
        }).catch(function(err) {
            ui.addNotification(null, E('p', {}, 'Ошибка запуска бэкапа: ' + err), 'danger');
            self._lockUI(false);
        });
    },

    _pollBackupThenRestore: function(archive, logPre) {
        var self = this;
        var downloaded = false;
        var completed = false;
        var ticks = 0;
        var MAX_TICKS = 180;
        var downloadPromise = null;

        var timer = setInterval(function() {
            ticks++;
            if (ticks > MAX_TICKS) {
                clearInterval(timer);
                ui.addNotification(null, E('p', {}, 'Таймаут создания бэкапа. Восстановление отменено.'), 'danger');
                self._lockUI(false);
                return;
            }
            callLog().then(function(res) {
                var r = unwrap(res);
                if (r && r.chunk) {
                    logPre.textContent = cleanLog(r.chunk);
                    logPre.scrollTop = logPre.scrollHeight;

                    if (!downloaded) {
                        var m = r.chunk.match(/MANUAL_ARCHIVE_READY=(\S+)/);
                        if (m) {
                            downloaded = true;
                            var rel = m[1].trim().split('/').pop();
                            if (m[1].indexOf('/manual/') !== -1) rel = 'manual/' + rel;
                            downloadPromise = self.downloadArchive(rel).then(function(ok) {
                                if (ok) ui.addNotification(null, E('p', {}, 'Бэкап скачан на компьютер.'), 'info');
                                else ui.addNotification(null, E('p', {}, 'Не удалось скачать бэкап автоматически. ', buildManualDownloadLink(rel)), 'warning');
                            }).catch(function() {});
                        }
                    }

                    if (!completed && r.chunk.indexOf('Архивация завершена.') !== -1) {
                        completed = true;
                        clearInterval(timer);
                        var proceed = function() {
                            ui.addNotification(null, E('p', {},
                                'Бэкап готов. Переходим к восстановлению архива на внутреннюю память.'), 'info');
                            self.showConfirmDialog('restore_archive', 'internal', archive, logPre);
                        };
                        if (downloadPromise) {
                            downloadPromise.then(function() { setTimeout(proceed, 1000); })
                                           .catch(function() { setTimeout(proceed, 1000); });
                        } else {
                            setTimeout(proceed, 2000);
                        }
                    }
                }
            }).catch(function() {});
        }, 1000);
    },

    showConfirmDialog: function(mode, device, archive, logPre) {
        var self = this;
        var devDesc = device || '';
        if (device) {
            var sel = document.getElementById('usb-extroot-device');
            var switchSel = document.getElementById('usb-extroot-switch-device');
            if (sel && sel.selectedIndex >= 0 && mode !== 'switch_overlay') devDesc = sel.options[sel.selectedIndex].text;
            if (switchSel && switchSel.selectedIndex >= 0 && mode === 'switch_overlay') devDesc = switchSel.options[switchSel.selectedIndex].text;
        }
        var descEl, pStyle = { 'style': 'font-size:16px; color:#ff5555; font-weight:bold; margin-bottom:15px;' };
        if (mode === 'format') descEl = E('p', pStyle, 'ВСЕ ДАННЫЕ на устройстве ' + devDesc + ' БУДУТ УНИЧТОЖЕНЫ.');
        else if (mode === 'noformat') descEl = E('p', pStyle, 'На устройстве ' + devDesc + ' будет удалена структура overlay.');
        else if (mode === 'switch_overlay') descEl = E('p', { 'style': 'font-size:16px; color:#32cd32; font-weight:bold; margin-bottom:15px;' }, 'Загрузочный накопитель будет изменен на: ' + devDesc);
        else if (mode === 'restore') descEl = E('p', pStyle, 'Загрузка будет переключена на внутреннюю память.');
        else if (mode === 'fallback_fix') descEl = E('p', pStyle, 'Будет очищен fstab.extroot и создан /overlay.');
        else if (mode === 'restore_archive') {
            var targetLabel = (device === 'internal') ? 'ВНУТРЕННЮЮ ПАМЯТЬ (/overlay)' : devDesc;
            descEl = E('p', pStyle,
                'Восстановление из архива ' + archive + ' на ' + targetLabel +
                '. Текущий overlay будет заменён. Откат: внешний архив + загрузка с флешки.'
            );
        }
        else if (mode === 'reset_keep_extroot') descEl = E('p', pStyle, 'ВНИМАНИЕ: Все настройки будут сброшены. Система продолжит загружаться с текущей флешки, но конфигурация станет заводской. Бэкапы на флешке сохранятся.');
        var code = genConfirmCode();
        var codeInput = E('input', { 'type': 'text', 'maxlength': '4', 'style': 'font-size:16px;width:60px;text-align:center;padding:4px;' });

        var body = E('div', {}, [
            descEl, E('hr'),
            E('p', {}, [ 'Код: ', E('span', { 'style': 'font-size:16px;color:#777;font-family:monospace;' }, code) ]),
            E('p', {}, [ E('label', {}, 'Ввод: '), codeInput ])
        ]);
        var footer = E('div', { 'style': 'display:flex;gap:8px;justify-content:flex-end;' }, [
            E('button', { 'class': 'cbi-button cbi-button-reset',
                'click': function() { ui.hideModal(); self._lockUI(false); } }, 'Отмена'),
            E('button', {
                'class': 'cbi-button cbi-button-apply',
                'click': function() {
                    if (codeInput.value !== code) { ui.addNotification(null, E('p', {}, 'Неверный код.'), 'danger'); return; }
                    ui.hideModal(); self.executeRun(mode, device, archive, logPre);
                }
            }, 'Действуй')
        ]);
        ui.showModal('Подтверждение', [ body, footer ]);
        setTimeout(function() { codeInput.focus(); }, 100);
    },

    executeRun: function(mode, device, archive, logPre) {
        var self = this;
        logPre.textContent = ''; self._lockUI(true);
        callRun(mode, device || '', archive || '', 'yes').then(function(res) {
            if (res && res.error) { ui.addNotification(null, E('p', {}, 'Ошибка: ' + res.error), 'danger'); self._lockUI(false); return; }
            var pid = (res && res.result && res.result.pid) || 0;
            var note = (res && res.result && res.result.note) || '';
            if (pid === 0 || note === 'pid-pending') {
                ui.addNotification(null, E('p', {},
                    'Операция запущена, но PID-файл ещё не появился. Ждём до 30 секунд. ' +
                    'Если лог не обновится — проверьте состояние кнопкой «Получить состояние».'
                ), 'warning');
            }
            self.startPolling(logPre, mode);
        }).catch(function(err) { ui.addNotification(null, E('p', {}, 'Ошибка запуска: ' + err), 'danger'); self._lockUI(false); });
    },

    startPolling: function(logPre, mode) {
        if (pollTimer) clearInterval(pollTimer);
        var archiveDownloaded = false;
        var runningNotified = false;
        var manualDownloaded = false;
        var watchArchiveInfo = (mode !== 'backup_manual');
        var watchManualReady = (mode === 'backup_manual');
        var self = this;
        var pollTicks = 0;
        var GRACE_TICKS = 15;

        var showDownloadModal = function() {
            if (document.getElementById('usb-extroot-download-modal')) return;

            var btnDownload = E('button', {
                'class': 'cbi-button cbi-button-apply',
                'style': 'font-size:14px; padding:8px 16px; margin-right:10px;',
                'click': function() {
                    self.downloadArchive('').then(function(ok) {
                        if (ok) {
                            ui.addNotification(null, E('p', {}, 'Архив успешно скачан.'), 'info');
                        } else {
                            ui.addNotification(null, E('p', {}, 'Не удалось скачать автоматически. Воспользуйтесь ссылкой: ', buildManualDownloadLink('')), 'warning');
                        }
                    });
                }
            }, '📥 Скачать архив бэкапа');

            var btnReboot = E('button', {
                'class': 'cbi-button cbi-button-negative',
                'style': 'font-size:14px; padding:8px 16px;',
                'click': function() {
                    callAbortSleep().then(function() {
                        ui.hideModal();
                        ui.addNotification(null, E('p', {}, 'Сигнал перезагрузки отправлен, роутер перезагружается. Страница обновится автоматически, когда связь восстановится.'), 'info');
                        // Никаких window.location.reload() — ждем, пока роутер сам не оборвет связь
                    }).catch(function(err) {
                        ui.addNotification(null, E('p', {}, 'Ошибка отправки команды ребута: ' + err), 'danger');
                    });
                }
            }, '🔄 Перезагрузить роутер сейчас');
			
            var body = E('div', { 'id': 'usb-extroot-download-modal', 'style': 'padding: 10px;' }, [
                E('p', { 'style': 'font-size:16px; font-weight:bold; color:#ffaa00;' }, '⚠️ Операция успешно завершена!'),
                E('p', {}, 'Перед тем как роутер уйдет в перезагрузку, убедитесь, что все данные сохранены.'),
                E('div', { 'style': 'margin-top:20px; display:flex; gap:10px; align-items:center;' }, [
                    btnDownload, btnReboot
                ])
            ]);

            ui.showModal('Требуется подтверждение перезагрузки', [ body ]);
        };

        pollTimer = setInterval(function() {
            pollTicks++;
            callLog().then(function(res) {
                var r = unwrap(res);
                if (r && r.chunk) {
                    logPre.textContent = cleanLog(r.chunk);
                    logPre.scrollTop = logPre.scrollHeight;
                    if (watchManualReady && !manualDownloaded) {
                        var m = r.chunk.match(/MANUAL_ARCHIVE_READY=(\S+)/);
                        if (m) {
                            manualDownloaded = true;
                            var rel = m[1].trim().split('/').pop();
                            if (m[1].indexOf('/manual/') !== -1) rel = 'manual/' + rel;
                            
                            setTimeout(function() {
                                self.downloadArchive(rel).then(function(ok) {
                                    if (ok) ui.addNotification(null, E('p', {}, 'Бэкап создан, скачиваем...'), 'info');
                                    else ui.addNotification(null, E('p', {}, 'Не удалось скачать бэкап автоматически. ', buildManualDownloadLink(rel)), 'warning');
                                });
                            }, 3000);
                        }
                    }
                }
            }).catch(function() {});

            if (watchArchiveInfo && !archiveDownloaded && mode !== 'switch_overlay') {
                callArchiveInfo().then(function(res) {
                    var r = unwrap(res);
                    if (r && r.exists === 'yes' && !archiveDownloaded) {
                        archiveDownloaded = true;
                        showDownloadModal();
                    }
                }).catch(function() {});
            }

            if (!runningNotified && pollTicks >= GRACE_TICKS) {
                callStatus().then(function(res) {
                    var r = unwrap(res);
                    if (r && r.running === false) {
                        runningNotified = true;
                        clearInterval(pollTimer);
                        Promise.all([
                            callStatus().catch(function() { return {}; }),
                            callDevices().catch(function() { return []; }),
                            callSwitchTargets().catch(function() { return []; })
                        ]).then(function(arr) {
                            self._updateUI(unwrap(arr[0]) || {}, unwrap(arr[1]) || [], unwrap(arr[2]) || []);
                        }).catch(function() { self._lockUI(false); });
                    }
                }).catch(function() {});
            }
        }, 1000);
    }
});
VIEW_EOF
need_file "$BASE_DIR/main.js"
safe_ln "$BASE_DIR/main.js" /www/luci-static/resources/view/usb-extroot/main.js
need_link /www/luci-static/resources/view/usb-extroot/main.js

echo "==> Устанавливаю CGI для отдачи архива (read_token)..."
cat > "$BASE_DIR/archive.cgi" <<'CGI_EOF'
#!/bin/sh
REMOTE="${REMOTE_ADDR:-}"
case "$REMOTE" in
    127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;;
    *) echo "Status: 403 Forbidden"; echo; echo "Forbidden."; exit 0 ;;
esac

EXPECTED_READ=$(uci -q get usb-extroot.main.read_token 2>/dev/null)
EXPECTED_WRITE=$(uci -q get usb-extroot.main.write_token 2>/dev/null)
if [ -z "$EXPECTED_READ" ]; then
    echo "Status: 503 Service Unavailable"; echo; echo "no read_token configured"
    exit 0
fi

FILE=""
REQ_TOKEN=""
[ -n "$QUERY_STRING" ] && for pair in $(echo "$QUERY_STRING" | tr '&' ' '); do
    case "$pair" in
        file=*)  FILE="${pair#file=}" ;;
        token=*) REQ_TOKEN="${pair#token=}" ;;
    esac
done
[ -n "$HTTP_X_EXTROOT_TOKEN" ] && REQ_TOKEN="$HTTP_X_EXTROOT_TOKEN"

TOKEN_OK=0
[ -n "$REQ_TOKEN" ] && [ "$REQ_TOKEN" = "$EXPECTED_READ" ] && TOKEN_OK=1
[ -n "$REQ_TOKEN" ] && [ -n "$EXPECTED_WRITE" ] && [ "$REQ_TOKEN" = "$EXPECTED_WRITE" ] && TOKEN_OK=1
if [ "$TOKEN_OK" != "1" ]; then
    echo "Status: 403 Forbidden"; echo; echo "Bad token"; exit 0
fi

if [ -n "$FILE" ]; then
    FILE=$(echo "$FILE" | sed 's|%2[Ff]|/|g; s|%20| |g')
    case "$FILE" in
        *..*|/*|*\\*|*[!A-Za-z0-9_./-]*) echo "Status: 400 Bad Request"; echo; echo "Invalid file"; exit 0 ;;
    esac
    case "$FILE" in
        tmp/*.tar.gz|manual/*.tar.gz|*.tar.gz) ;;
        *) echo "Status: 400 Bad Request"; echo; echo "Only .tar.gz, tmp/ or manual/"; exit 0 ;;
    esac

    FOUND=""
    if [ "${FILE#tmp/}" != "$FILE" ]; then
        candidate="/tmp/${FILE#tmp/}"
        [ -f "$candidate" ] && FOUND="$candidate"
        if [ -z "$FOUND" ]; then
            for d in /tmp/.usb-extroot-*/; do
                [ -d "$d" ] || continue
                candidate="$d${FILE#tmp/}"
                if [ -f "$candidate" ]; then FOUND="$candidate"; break; fi
            done
        fi
    fi

    if [ -z "$FOUND" ]; then
        for mnt in $(awk '$3=="ext4" || $3=="f2fs" || $3=="btrfs" {print $2}' /proc/mounts); do
            candidate="$mnt/usb-extroot-backups/$FILE"
            if [ -f "$candidate" ]; then FOUND="$candidate"; break; fi
        done
    fi

    # Fallback: ручные бэкапы с внутреннего overlay лежат в /tmp
    if [ -z "$FOUND" ]; then
        base=$(basename "$FILE")
        candidate="/tmp/$base"
        [ -f "$candidate" ] && FOUND="$candidate"
        if [ -z "$FOUND" ]; then
            for d in /tmp/.usb-extroot-*/; do
                [ -d "$d" ] || continue
                candidate="$d$base"
                if [ -f "$candidate" ]; then FOUND="$candidate"; break; fi
                candidate="${d}manual/$base"
                if [ -f "$candidate" ]; then FOUND="$candidate"; break; fi
            done
        fi
    fi

    if [ -z "$FOUND" ]; then echo "Status: 404 Not Found"; echo; echo "Archive not found"; exit 0; fi

    name=$(basename "$FOUND"); size=$(ls -l "$FOUND" | awk '{print $5}'); size=${size:-0}
    echo "Content-Type: application/gzip"; echo "Content-Length: $size"
    echo "Content-Disposition: attachment; filename=\"$name\""; echo "Cache-Control: no-store"; echo
    dd if="$FOUND" bs=65536 2>/dev/null; exit 0
fi

latest=$(ls -t /tmp/.usb-extroot-*/*.tar.gz \
              /tmp/.usb-extroot-*/manual/*.tar.gz \
              /tmp/.usb-extroot-*/auto/*.tar.gz 2>/dev/null | head -1)
			  
if [ -z "$latest" ] || [ ! -f "$latest" ]; then echo "Status: 404 Not Found"; echo; echo "Not found"; exit 0; fi

name=$(basename "$latest"); size=$(ls -l "$latest" | awk '{print $5}'); size=${size:-0}
echo "Content-Type: application/gzip"; echo "Content-Length: $size"
echo "Content-Disposition: attachment; filename=\"$name\""; echo "Cache-Control: no-store"; echo
dd if="$latest" bs=65536 2>/dev/null
CGI_EOF

need_sh "$BASE_DIR/archive.cgi"
chmod +x "$BASE_DIR/archive.cgi" || die "chmod +x archive.cgi"
need_exec "$BASE_DIR/archive.cgi"
safe_ln "$BASE_DIR/archive.cgi" /www/cgi-bin/usb-extroot-archive
need_link /www/cgi-bin/usb-extroot-archive

echo "==> Устанавливаю CGI для загрузки архива (write_token)..."
cat > "$BASE_DIR/upload.cgi" <<'UPLOAD_EOF'
#!/bin/sh
REMOTE="${REMOTE_ADDR:-}"
case "$REMOTE" in
    127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;;
    *) echo "Status: 403 Forbidden"; echo; echo "Forbidden."; exit 0 ;;
esac

EXPECTED_WRITE=$(uci -q get usb-extroot.main.write_token 2>/dev/null)
if [ -z "$EXPECTED_WRITE" ]; then
    echo "Status: 503 Service Unavailable"; echo; echo "no write_token configured"
    exit 0
fi

REQ_TOKEN=""
[ -n "$HTTP_X_EXTROOT_TOKEN" ] && REQ_TOKEN="$HTTP_X_EXTROOT_TOKEN"

[ -n "$QUERY_STRING" ] && for pair in $(echo "$QUERY_STRING" | tr '&' ' '); do
    case "$pair" in
        token=*) REQ_TOKEN="${pair#token=}" ;;
    esac
done

if [ "$REQ_TOKEN" != "$EXPECTED_WRITE" ]; then
    echo "Status: 403 Forbidden"; echo; echo "Bad token"; exit 0
fi

FILE=""
[ -n "$QUERY_STRING" ] && for pair in $(echo "$QUERY_STRING" | tr '&' ' '); do
    case "$pair" in file=*) FILE="${pair#file=}" ;; esac
done

FILE=$(echo "$FILE" | sed 's|%2[Ff]|/|g; s|%20| |g')
FILE=$(basename "$FILE")

TMPFILE="/tmp/$FILE"
cat > "$TMPFILE"

if [ ! -s "$TMPFILE" ]; then echo "Status: 400"; echo; echo "No data"; exit 0; fi

case "$FILE" in
    *..*|*[!A-Za-z0-9_.-]*) echo "Status: 400 Bad Request"; echo; echo "Invalid filename"; rm -f "$TMPFILE"; exit 0 ;;
    *.tar.gz) ;;
    *) echo "Status: 400 Bad Request"; echo; echo "Only .tar.gz allowed"; rm -f "$TMPFILE"; exit 0 ;;
esac

MAGIC=$(hexdump -n 2 -e '2/1 "%02x"' "$TMPFILE" 2>/dev/null)
if [ "$MAGIC" != "1f8b" ]; then echo "Status: 400"; echo; echo "Not gzip"; rm -f "$TMPFILE"; exit 0; fi

if [ -f "$TMPFILE" ]; then
    echo "Content-Type: text/plain"; echo; echo "OK";
else
    echo "Status: 500"; echo; echo "Failed"; rm -f "$TMPFILE";
fi
UPLOAD_EOF
need_sh "$BASE_DIR/upload.cgi"
chmod +x "$BASE_DIR/upload.cgi" || die "chmod +x upload.cgi"
need_exec "$BASE_DIR/upload.cgi"
safe_ln "$BASE_DIR/upload.cgi" /www/cgi-bin/usb-extroot-upload
need_link /www/cgi-bin/usb-extroot-upload

echo "==> Устанавливаю init.d/usb-extroot-autobackup..."
cat > /etc/init.d/usb-extroot-autobackup <<'INITD_EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10

start() {
    [ -x /opt/usb-extroot/usb-extroot.sh ] || return 0
    local ovmnt ovdev parent
    ovmnt=$(awk '$2=="/overlay" {print $2; exit}' /proc/mounts)
    [ -z "$ovmnt" ] && return 0
    ovdev=$(awk -v m="$ovmnt" '$2==m {print $1; exit}' /proc/mounts)
    [ -z "$ovdev" ] && return 0
    case "$ovdev" in /dev/ubi*|/dev/mtdblock*|/dev/root) return 0 ;; esac
    case "$ovdev" in
        /dev/mmcblk*p[0-9]*) parent="${ovdev%p[0-9]*}" ;;
        /dev/sd[a-z][0-9]*)  parent="${ovdev%[0-9]*}" ;;
        *) return 0 ;;
    esac
    parent=$(basename "$parent")
    case "$parent" in
        sd[a-z]) case "$(readlink -f /sys/block/$parent 2>/dev/null)" in *"/usb"*) ;; *) return 0 ;; esac ;;
        mmcblk[0-9]*) [ "$(cat /sys/block/$parent/removable 2>/dev/null)" = "1" ] || return 0 ;;
        *) return 0 ;;
    esac
    local delay=$(uci -q get usb-extroot.main.autobackup_delay 2>/dev/null)
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
need_sh /etc/init.d/usb-extroot-autobackup
chmod +x /etc/init.d/usb-extroot-autobackup || die "chmod +x init.d"
need_exec /etc/init.d/usb-extroot-autobackup
/etc/init.d/usb-extroot-autobackup enable >/dev/null 2>&1 || true
if ! ls /etc/rc.d/S*usb-extroot-autobackup >/dev/null 2>&1; then
	echo "    ПРЕДУПРЕЖДЕНИЕ: init.d enable не создал симлинк в /etc/rc.d/"
fi

echo "==> Перезапускаю rpcd и uhttpd..."
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

# ============================================================
#  health_check
# ============================================================
health_check() {
	local fails=0

	_hc_ok()   { printf "  [OK]   %s\n" "$1"; }
	_hc_fail() { printf "  [FAIL] %s\n" "$1"; fails=$((fails + 1)); }
	_hc_warn() { printf "  [WARN] %s\n" "$1"; }
	_hc_skip() { printf "  [SKIP] %s\n" "$1"; }

	echo ""
	echo "=== Проверка установки ==="

	if [ -x "$BASE_DIR/usb-extroot.sh" ]; then
		if sh -n "$BASE_DIR/usb-extroot.sh" 2>/dev/null; then
			_hc_ok "$BASE_DIR/usb-extroot.sh (executable, sh -n ok)"
		else
			_hc_fail "$BASE_DIR/usb-extroot.sh (синтаксическая ошибка)"
		fi
	else
		if [ "$TEST_MODE" = "1" ]; then
			_hc_skip "$BASE_DIR/usb-extroot.sh (TEST_MODE)"
		else
			_hc_fail "$BASE_DIR/usb-extroot.sh не исполняемый"
		fi
	fi

	for f in luci.usb-extroot acl.json menu.json main.js archive.cgi upload.cgi; do
		p="$BASE_DIR/$f"
		if [ ! -s "$p" ]; then
			_hc_fail "$p (отсутствует или пуст)"
			continue
		fi
		case "$f" in
			luci.usb-extroot|archive.cgi|upload.cgi)
				if sh -n "$p" 2>/dev/null; then _hc_ok "$p (sh -n ok)"; else _hc_fail "$p (синтаксическая ошибка)"; fi
				;;
			*) _hc_ok "$p" ;;
		esac
	done

	for f in luci.usb-extroot archive.cgi upload.cgi; do
		p="$BASE_DIR/$f"
		[ -s "$p" ] || continue
		if [ -x "$p" ]; then _hc_ok "$p (executable)"; else _hc_fail "$p не исполняемый"; fi
	done

	for link in \
		/usr/libexec/rpcd/luci.usb-extroot \
		/usr/share/rpcd/acl.d/luci-app-usb-extroot.json \
		/usr/share/luci/menu.d/luci-app-usb-extroot.json \
		/www/luci-static/resources/view/usb-extroot/main.js \
		/www/cgi-bin/usb-extroot-archive \
		/www/cgi-bin/usb-extroot-upload
	do
		if [ -L "$link" ] && [ -e "$link" ]; then
			_hc_ok "$link -> $(readlink "$link")"
		elif [ -L "$link" ]; then
			_hc_fail "$link висит (цель не существует)"
		else
			_hc_fail "$link не создал"
		fi
	done

	if [ -x /etc/init.d/usb-extroot-autobackup ]; then
		_hc_ok "/etc/init.d/usb-extroot-autobackup (executable)"
	else
		_hc_fail "/etc/init.d/usb-extroot-autobackup отсутствует или не исполняемый"
	fi
	if ls /etc/rc.d/S*usb-extroot-autobackup >/dev/null 2>&1; then
		_hc_ok "автозапуск init.d включён"
	else
		_hc_warn "автозапуск init.d не включён (init.d enable)"
	fi

	if [ -f /etc/config/usb-extroot ]; then
		_hc_ok "/etc/config/usb-extroot"
	else
		_hc_fail "/etc/config/usb-extroot отсутствует"
	fi
	if [ -n "$(uci -q get usb-extroot.main.read_token 2>/dev/null)" ]; then
		_hc_ok "read_token задан в UCI"
	else
		_hc_fail "read_token не задан в UCI"
	fi
	if [ -n "$(uci -q get usb-extroot.main.write_token 2>/dev/null)" ]; then
		_hc_ok "write_token задан в UCI"
	else
		_hc_fail "write_token не задан в UCI"
	fi

	if wait_for_service rpcd 10; then
		_hc_ok "rpcd запущен"
	else
		_hc_warn "rpcd не запущен после 10с (перезапустите: /etc/init.d/rpcd restart)"
	fi
	if wait_for_service uhttpd 10; then
		_hc_ok "uhttpd запущен"
	else
		_hc_warn "uhttpd не запущен после 10с (перезапустите: /etc/init.d/uhttpd restart)"
	fi

	echo ""
	if [ "$fails" -eq 0 ]; then
		echo "=================================================================="
		echo " Установка завершена успешно."
		echo " Службы → USB extroot"
		echo "=================================================================="
		return 0
	else
		echo "=================================================================="
		echo " УСТАНОВКА ЗАВЕРШЕНА С ОШИБКАМИ: $fails критичных"
		echo " Проверьте перечисленные выше [FAIL] и перезапустите установщик."
		echo "=================================================================="
		return 1
	fi
}

health_check
exit $?
