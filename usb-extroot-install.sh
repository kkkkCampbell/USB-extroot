#!/bin/sh
# ============================================================
#  usb-extroot-install.sh  — установщик usb-extroot + веб-морда
#  sh <( wget -qO- https://raw.githubusercontent.com/kkkkCampbell/USB-extroot/refs/heads/draft/usb-extroot-install.sh )
# ============================================================
TEST_MODE=0
BASE_DIR="/opt/usb-extroot"

if [ "$(id -u)" != "0" ]; then
    echo "Запустите от root" >&2
    exit 1
fi

mkdir -p "$BASE_DIR"

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
chmod +x "$BASE_DIR/usb-extroot.sh"

# ---- UCI config (только для дефолтов, если нет файла) ----
if [ ! -f /etc/config/usb-extroot ]; then
	echo "==> Создаю /etc/config/usb-extroot..."
	cat > /etc/config/usb-extroot <<'UCI_EOF'
config usb-extroot 'main'
	option autobackup_delay '300'
UCI_EOF
fi

echo "==> Устанавливаю rpcd-плагин..."
cat > "$BASE_DIR/luci.usb-extroot" <<'RPCD_EOF'
#!/bin/sh
# ============================================================
#  rpcd-плагин luci.usb-extroot
# ============================================================

SCRIPT=/opt/usb-extroot/usb-extroot.sh
LOG=/tmp/usb-extroot.log
PID_FILE=/tmp/usb-extroot.pid

esc_json() {
    awk 'BEGIN{printf "\""} {gsub(/\\/,"\\\\");gsub(/"/,"\\\"");gsub(/\t/,"\\t");if(NR>1)printf "\\n";printf "%s",$0} END{printf "\""}'
}

is_running() {
    [ -f "$PID_FILE" ] || return 1
    local pid=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$pid" ] || return 1
    
    if kill -0 "$pid" 2>/dev/null; then
        if grep -q "usb-extroot" "/proc/$pid/cmdline" 2>/dev/null; then
            return 0
        fi
    fi
    rm -f "$PID_FILE"
    return 1
}

run_script_action() {
    local action="$1"
    local out
    if [ ! -x "$SCRIPT" ]; then
        echo "NOT_FOUND"
        return 1
    fi
    
    if command -v timeout >/dev/null 2>&1; then
        out=$(timeout -s KILL 10 "$SCRIPT" --batch --action="$action" 2>&1)
    else
        out=$("$SCRIPT" --batch --action="$action" 2>&1)
    fi
    local rc=$?
    
    if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
        echo "TIMEOUT"
        return 124
    fi
    if [ $rc -ne 0 ]; then
        echo "SCRIPT_ERROR: $out"
        return $rc
    fi
    echo "$out"
    return 0
}

method_version() {
    local v="" tmp="/tmp/usb-extroot.ver.$$" p w
    if [ -x "$SCRIPT" ]; then
        if command -v timeout >/dev/null 2>&1; then
            timeout -s KILL 10 "$SCRIPT" --version >"$tmp" 2>/dev/null
        else
            "$SCRIPT" --version >"$tmp" 2>/dev/null &
            p=$!
            ( sleep 10; kill -9 "$p" 2>/dev/null ) &
            w=$!
            wait "$p" 2>/dev/null
            kill "$w" 2>/dev/null
        fi
        [ -s "$tmp" ] && v=$(head -n1 "$tmp")
        rm -f "$tmp"
    fi
    printf '{ "result": { "version": '
    printf '%s' "$v" | esc_json
    printf ' } }\n'
}

method_status() {
    local out running="false"
    is_running && running="true"
    out=$(run_script_action status)
    if [ "$out" = "TIMEOUT" ]; then
        echo '{ "error": "script timeout" }'
        return
    elif [ "$out" = "NOT_FOUND" ]; then
        echo '{ "error": "usb-extroot.sh not found" }'
        return
    elif [ "${out#SCRIPT_ERROR}" != "$out" ]; then
        echo "{ \"error\": \"$out\" }"
        return
    fi
    printf '{ "result": {'
    printf '%s' "$out" | awk -F= '
        BEGIN { first=1 }
        NF>=2 {
            if (!first) printf ","
            first=0
            k=$1; $1=""; v=substr($0,2)
            gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v)
            printf "\"%s\":\"%s\"", k, v
        }
    '
    printf ', "running": %s } }\n' "$running"
}

method_devices() {
    local out
    out=$(run_script_action devices)
    if [ "$out" = "TIMEOUT" ]; then
        echo '{ "error": "script timeout" }'
        return
    elif [ "$out" = "NOT_FOUND" ]; then
        echo '{ "error": "usb-extroot.sh not found" }'
        return
    elif [ "${out#SCRIPT_ERROR}" != "$out" ]; then
        echo "{ \"error\": \"$out\" }"
        return
    fi
    printf '{ "result": ['
    printf '%s\n' "$out" | awk -F'|' '
        NF>=3 {
            if (cnt++) printf ","
            dev=$1; fs=$2; desc=$3
            gsub(/\\/, "\\\\", dev); gsub(/"/, "\\\"", dev)
            gsub(/\\/, "\\\\", fs); gsub(/"/, "\\\"", fs)
            gsub(/\\/, "\\\\", desc); gsub(/"/, "\\\"", desc)
            printf "{\"dev\":\"%s\",\"fs\":\"%s\",\"desc\":\"%s\"}", dev, fs, desc
        }
    '
    printf '] }\n'
}

method_log() {
    local chunk=""
    [ -f "$LOG" ] && chunk=$(cat "$LOG" 2>/dev/null)
    printf '{ "result": { "chunk": '
    printf '%s' "$chunk" | esc_json
    printf ' } }\n'
}

method_archive_info() {
    local out
    out=$(run_script_action archive-info)
    if [ "$out" = "TIMEOUT" ]; then
        echo '{ "error": "script timeout" }'
        return
    elif [ "$out" = "NOT_FOUND" ]; then
        echo '{ "error": "usb-extroot.sh not found" }'
        return
    elif [ "${out#SCRIPT_ERROR}" != "$out" ]; then
        echo "{ \"error\": \"$out\" }"
        return
    fi
    printf '{ "result": {'
    printf '%s' "$out" | awk -F= '
        BEGIN { first=1 }
        NF>=2 {
            if (!first) printf ","
            first=0
            k=$1; $1=""; v=substr($0,2)
            gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v)
            if (v ~ /^[0-9]+$/) printf "\"%s\":%s", k, v
            else printf "\"%s\":\"%s\"", k, v
        }
    '
    printf '} }\n'
}

method_archive_list() {
    local out
    out=$(run_script_action archive-list)
    if [ "$out" = "TIMEOUT" ]; then
        echo '{ "error": "script timeout" }'
        return
    elif [ "$out" = "NOT_FOUND" ]; then
        echo '{ "error": "usb-extroot.sh not found" }'
        return
    elif [ "${out#SCRIPT_ERROR}" != "$out" ]; then
        echo "{ \"error\": \"$out\" }"
        return
    fi
    printf '{ "result": ['
    printf '%s\n' "$out" | awk -F'|' '
        NF>=2 {
            if (cnt++) printf ","
            name=$1; size=$2
            gsub(/\\/, "\\\\", name); gsub(/"/, "\\\"", name)
            printf "{\"name\":\"%s\",\"size\":%s}", name, size
        }
    '
    printf '] }\n'
}

method_run() {
    local params mode device confirm archive pid
    params=$(cat)

    : > "$LOG"

    if [ ! -x "$SCRIPT" ]; then
        echo "ERROR: usb-extroot.sh not found" >> "$LOG"
        echo '{ "error": "usb-extroot.sh not found" }'
        return
    fi

    mode=$(echo "$params" | jsonfilter -e '@.mode' 2>/dev/null)
    device=$(echo "$params" | jsonfilter -e '@.device' 2>/dev/null)
    confirm=$(echo "$params" | jsonfilter -e '@.confirm' 2>/dev/null)
    archive=$(echo "$params" | jsonfilter -e '@.archive' 2>/dev/null)

    if [ "$confirm" != "yes" ]; then
        echo "ERROR: confirm required" >> "$LOG"
        echo '{ "error": "confirm required" }'
        return
    fi

    case "$mode" in
        format|noformat|restore|fallback_fix|restore_archive|backup|backup_manual) ;;
        *) 
            echo "ERROR: invalid mode '$mode'" >> "$LOG"
            echo '{ "error": "invalid mode" }'
            return 
            ;;
    esac

    case "$mode" in
        format|noformat)
            if [ -z "$device" ] || [ "${device#/dev/}" = "$device" ]; then
                echo "ERROR: invalid device '$device'" >> "$LOG"
                echo '{ "error": "invalid device" }'
                return
            fi
            ;;
        restore_archive)
            if [ -z "$device" ] || [ "${device#/dev/}" = "$device" ]; then
                echo "ERROR: invalid device '$device'" >> "$LOG"
                echo '{ "error": "invalid device" }'
                return
            fi
            if [ -z "$archive" ]; then
                echo "ERROR: archive required for restore_archive" >> "$LOG"
                echo '{ "error": "archive required" }'
                return
            fi
            ;;
        *)
            device=""
            archive=""
            ;;
    esac

    if is_running; then
        pid=$(cat "$PID_FILE" 2>/dev/null)
        echo "ERROR: already running (PID $pid)" >> "$LOG"
        printf '{ "error": "already running", "pid": %d }\n' "$pid"
        return
    fi

    rm -f "$PID_FILE"
    
    if [ -n "$device" ]; then
        setsid sh "$SCRIPT" --batch --mode="$mode" --device="$device" --archive="$archive" --confirm=yes >>"$LOG" 2>&1 &
    else
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
        if [ -s "$LOG" ] && grep -q "СТАРТ ОПЕРАЦИИ" "$LOG" 2>/dev/null; then
            printf '{ "result": { "pid": 0, "started": true, "note": "finished-fast" } }\n'
            return
        fi
        echo "ERROR: Скрипт упал при старте. PID-файл не создан." >> "$LOG"
        echo '{ "error": "Скрипт упал при старте. Проверьте лог." }'
        return
    fi
    printf '{ "result": { "pid": %d, "started": true } }\n' "$pid"
}

case "$1" in
    list)
        echo '{ "status": {}, "devices": {}, "log": { "offset": 0 }, "archive_info": {}, "archive_list": {}, "version": {}, "run": { "params": {} } }'
        ;;
    call)
        method="$2"
        case "$method" in
            status)       method_status ;;
            devices)      method_devices ;;
            log)          method_log ;;
            archive_info) method_archive_info ;;
            archive_list) method_archive_list ;;
            version)      method_version ;;
            run)          method_run ;;
            *) echo '{ "error": "unknown method" }' ;;
        esac
        ;;
esac
RPCD_EOF
chmod +x "$BASE_DIR/luci.usb-extroot"

echo "==> Создаю симлинки для rpcd..."
mkdir -p /usr/libexec/rpcd
ln -sf "$BASE_DIR/luci.usb-extroot" /usr/libexec/rpcd/luci.usb-extroot

echo "==> Устанавливаю ACL..."
cat > "$BASE_DIR/acl.json" <<'ACL_EOF'
{
    "luci-app-usb-extroot": {
        "description": "USB extroot management",
        "read": {
            "ubus": {
                "luci.usb-extroot": [ "status", "devices", "log", "archive_info", "archive_list", "version" ]
            }
        },
        "write": {
            "ubus": {
                "luci.usb-extroot": [ "run" ]
            }
        }
    }
}
ACL_EOF
mkdir -p /usr/share/rpcd/acl.d
ln -sf "$BASE_DIR/acl.json" /usr/share/rpcd/acl.d/luci-app-usb-extroot.json

echo "==> Устанавливаю меню..."
cat > "$BASE_DIR/menu.json" <<'MENU_EOF'
{
    "admin/services/usb-extroot": {
        "title": "USB extroot",
        "order": 30,
        "action": {
            "type": "view",
            "path": "usb-extroot/main"
        },
        "depends": {
            "acl": [ "luci-app-usb-extroot" ]
        }
    }
}
MENU_EOF
mkdir -p /usr/share/luci/menu.d
ln -sf "$BASE_DIR/menu.json" /usr/share/luci/menu.d/luci-app-usb-extroot.json

echo "==> Устанавливаю view..."
cat > "$BASE_DIR/main.js" <<'VIEW_EOF'
'use strict';
'require view';
'require ui';
'require rpc';
'require dom';

var callStatus = rpc.declare({ object: 'luci.usb-extroot', method: 'status' });
var callDevices = rpc.declare({ object: 'luci.usb-extroot', method: 'devices' });
var callLog = rpc.declare({ object: 'luci.usb-extroot', method: 'log' });
var callArchiveInfo = rpc.declare({ object: 'luci.usb-extroot', method: 'archive_info' });
var callArchiveList = rpc.declare({ object: 'luci.usb-extroot', method: 'archive_list' });
var callVersion = rpc.declare({ object: 'luci.usb-extroot', method: 'version' });
var callRun = rpc.declare({ object: 'luci.usb-extroot', method: 'run', params: [ 'mode', 'device', 'archive', 'confirm' ] });

var pollTimer = null;

function unwrap(res) {
    if (res && typeof res === 'object' && 'result' in res) {
        return res.result;
    }
    return res;
}

function cleanLog(str) {
    return str.replace(/\r/g, '').replace(/[\u001b\u009b][[()#;?]*(?:[0-9]{1,4}(?:;[0-9]{0,4})*)?[0-9A-ORZcf-nqry=><]/g, '');
}

function genConfirmCode() {
    var n = '';
    for (var i = 0; i < 4; i++) n += Math.floor(Math.random() * 10);
    return n;
}

return view.extend({
    load: function() {
        return callVersion().catch(function() { return null; });
    },

    render: function(verRes) {
        var self = this;
        var ver = (unwrap(verRes) || {}).version || '';

        var logPre = E('pre', {
            'id': 'usb-extroot-log',
            'style': 'background:#111;color:#ccc;padding:10px;height:400px;overflow:auto;font-family:monospace;font-size:12px;white-space:pre-wrap;border:1px solid #444;margin-top:10px;'
        }, '');

        var deviceSelect = E('select', { 'id': 'usb-extroot-device', 'style': 'width:100%;padding:4px;' }, [
            E('option', { 'value': '' }, '— нажмите "Получить состояние" —')
        ]);

        var modeSelect = E('select', { 'id': 'usb-extroot-mode', 'style': 'width:100%;padding:4px;' }, [
            E('option', { 'value': '' }, '— ВЫБЕРИТЕ ВАРИАНТ ПЕРЕНОСА ДАННЫХ —'),
            E('option', { 'value': 'format' }, 'С форматированием (mkfs.ext4)'),
            E('option', { 'value': 'noformat' }, 'Без форматирования (только overlay-структура)')
        ]);

        var statusText = E('div', { 'style': 'margin-bottom:4px;color:#aaa; font-weight:bold;' }, 'Статус не проверен.');
        var hintText = E('div', { 'id': 'usb-extroot-hint', 'style': 'margin-bottom:10px; color:#ffaa00; font-size:12px; display:none;' }, '');

        var btnFallback = E('button', {
            'class': 'cbi-button cbi-button-negative',
            'style': 'margin-right:8px; display:none;',
            'id': 'btn-fallback_fix',
            'click': function() {
                self.runOp('fallback_fix', null, null, logPre);
            }
        }, 'Исправить аварийный режим overlay');

        var btnTransfer = E('button', {
            'class': 'cbi-button cbi-button-apply',
            'style': 'margin-right:8px;',
            'id': 'btn-transfer',
            'click': function() {
                self.runOp(modeSelect.value, deviceSelect.value, null, logPre);
            }
        }, 'Выполнить перенос');

        var btnRestore = E('button', {
            'class': 'cbi-button cbi-button-reset',
            'style': 'margin-right:8px;',
            'id': 'btn-restore',
            'click': function() {
                self.runOp('restore', null, null, logPre);
            }
        }, 'Восстановить загрузку с внутренней памяти');

        var btnRestoreArchive = E('button', {
            'class': 'cbi-button cbi-button-reset',
            'style': 'margin-right:8px;',
            'id': 'btn-restore-archive',
            'click': function() {
                self.showArchiveList(logPre);
            }
        }, 'Восстановить из архива на флешке');

        var btnBackup = E('button', {
            'class': 'cbi-button cbi-button-action',
            'style': 'margin-right:8px;',
            'id': 'btn-backup-manual',
            'click': function() {
                self.runBackupManual(logPre);
            }
        }, 'Создать бэкап сейчас');

        var btnUpload = E('button', {
            'class': 'cbi-button cbi-button-action',
            'style': 'margin-right:8px;',
            'id': 'btn-upload-archive',
            'click': function() {
                self.showUploadDialog(logPre);
            }
        }, 'Загрузить архив с ПК');

        var updateUI = function(status, devices) {
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
                deviceSelect.appendChild(E('option', { 'value': '' }, '— нет доступных съёмных накопителей —'));
            }

            var btnTransferEl = document.getElementById('btn-transfer');
            var modeSelectEl = document.getElementById('usb-extroot-mode');
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

            if (isFallback) {
                statusText.style.color = '#ff5555';
            } else if (isExtroot) {
                statusText.style.color = '#32cd32';
            } else {
                statusText.style.color = '#aaa';
            }

            if (isFallback) {
                if (btnTransferEl) btnTransferEl.disabled = true;
                if (modeSelectEl) modeSelectEl.disabled = true;
                deviceSelect.disabled = true;
                if (btnRestoreEl) btnRestoreEl.disabled = true;
                if (btnRestoreArchiveEl) btnRestoreArchiveEl.disabled = true;
                if (btnBackupEl) btnBackupEl.disabled = true;
                if (btnUploadEl) btnUploadEl.disabled = true;
                if (hintEl) {
                    hintEl.textContent = 'ВНИМАНИЕ: Обнаружен аварийный режим overlay (фоллбэк). Сначала нажмите «Исправить аварийный режим overlay».';
                    hintEl.style.display = 'block';
                    hintEl.style.color = '#ff5555';
                }
            } else if (isExtroot) {
                if (btnTransferEl) btnTransferEl.disabled = true;
                if (modeSelectEl) modeSelectEl.disabled = true;
                deviceSelect.disabled = true;
                if (btnRestoreEl) btnRestoreEl.disabled = false;
                if (btnRestoreArchiveEl) btnRestoreArchiveEl.disabled = false;
                if (btnBackupEl) btnBackupEl.disabled = false;
                if (btnUploadEl) btnUploadEl.disabled = false;
                if (hintEl) {
                    hintEl.textContent = 'Вы загружены с внешнего накопителя.';
                    hintEl.style.display = 'block';
                    hintEl.style.color = '#ffaa00';
                }
            } else {
                if (btnTransferEl) btnTransferEl.disabled = false;
                if (modeSelectEl) modeSelectEl.disabled = false;
                deviceSelect.disabled = false;
                if (btnRestoreEl) btnRestoreEl.disabled = true;
                if (btnRestoreArchiveEl) btnRestoreArchiveEl.disabled = true;
                if (btnBackupEl) btnBackupEl.disabled = true;
                if (btnUploadEl) btnUploadEl.disabled = true;
                if (hintEl) hintEl.style.display = 'none';
            }

            var fbBtn = document.getElementById('btn-fallback_fix');
            if (fbBtn) fbBtn.style.display = isFallback ? 'inline-block' : 'none';

            var getStateBtn = document.getElementById('btn-get-state');
            if (getStateBtn) getStateBtn.disabled = false;
        };

        self._updateUI = updateUI;

        self._lockUI = function(disabled) {
            ['btn-transfer', 'btn-restore', 'btn-fallback_fix', 'btn-restore-archive',
             'btn-backup-manual', 'btn-upload-archive', 'btn-get-state'].forEach(function(id) {
                var el = document.getElementById(id);
                if (el) el.disabled = disabled;
            });
            var modeSelectEl = document.getElementById('usb-extroot-mode');
            if (modeSelectEl) modeSelectEl.disabled = disabled;
            var deviceSelectEl = document.getElementById('usb-extroot-device');
            if (deviceSelectEl) deviceSelectEl.disabled = disabled;
        };

        var btnGetState = E('button', {
            'class': 'cbi-button cbi-button-action',
            'style': 'margin-right:8px;',
            'id': 'btn-get-state',
            'click': function(ev) {
                var btn = ev.currentTarget;
                btn.disabled = true;
                btn.textContent = 'Получение...';

                var resetBtn = function() {
                    btn.disabled = false;
                    btn.textContent = 'Получить состояние';
                };

                callStatus().then(function(statusRes) {
                    var status = unwrap(statusRes) || {};
                    return callDevices().then(function(devRes) {
                        return { status: status, devices: unwrap(devRes) };
                    });
                }).then(function(data) {
                    updateUI(data.status, data.devices);
                    resetBtn();
                }).catch(function(err) {
                    var msg = (err && err.message) ? err.message : (typeof err === 'string' ? err : 'Неизвестная ошибка');
                    ui.addNotification(null, E('p', {}, 'Ошибка: ' + msg), 'danger');
                    resetBtn();
                });
            }
        }, 'Получить состояние');

        var controls = E('div', { 'style': 'margin:10px 0;padding:10px;background:rgba(0,0,0,0.05);border:1px solid rgba(255,255,255,0.1);' }, [
            E('div', { 'style': 'margin-bottom:8px;' }, [ btnGetState ]),
            statusText,
            hintText,
            E('hr', { 'style': 'border:0;border-top:1px solid rgba(255,255,255,0.1);margin:10px 0;' }),
            E('div', { 'style': 'margin-bottom:8px;display:flex;gap:10px;align-items:center;' }, [
                E('label', { 'style': 'font-weight:bold;white-space:nowrap;' }, 'Режим:'), modeSelect
            ]),
            E('div', { 'style': 'margin-bottom:12px;display:flex;gap:10px;align-items:center;' }, [
                E('label', { 'style': 'font-weight:bold;white-space:nowrap;' }, 'Накопитель:'), deviceSelect
            ]),
            E('div', {}, [ btnTransfer, btnRestore, btnRestoreArchive, btnBackup, btnUpload, btnFallback ])
        ]);

        return E([], [
            E('h2', {}, [
                'USB extroot',
                ver ? E('span', { 'style': 'margin-left:12px;font-size:14px;font-weight:normal;color:#888;' }, ver) : ''
            ]),
            E('p', {}, 'Перенос overlay OpenWrt на USB-накопитель.'),
            controls,
            E('h3', {}, 'Журнал выполнения'),
            logPre
        ]);
    },

    runBackupManual: function(logPre) {
        var self = this;
        logPre.textContent = '';
        self._lockUI(true);
        callRun('backup_manual', '', '', 'yes').then(function(res) {
            if (res && res.error) ui.addNotification(null, E('p', {}, 'Ошибка: ' + res.error), 'danger');
            self.startPolling(logPre, 'backup_manual');
        }).catch(function(err) {
            ui.addNotification(null, E('p', {}, 'Ошибка запуска: ' + err), 'danger');
            self._lockUI(false);
        });
    },

    showUploadDialog: function(logPre) {
        var self = this;
        var fileInput = E('input', { 'type': 'file', 'accept': '.tar.gz', 'style': 'margin-bottom:10px; width:100%;' });
        var statusText = E('p', { 'style': 'margin-top:10px; font-weight:bold;' }, '');
        var progressBar = E('div', { 'style': 'width:100%; height:10px; background:#333; margin-top:10px; display:none;' }, [
            E('div', { 'style': 'width:0%; height:100%; background:#32cd32; transition:width 0.2s;' })
        ]);

        var body = E('div', {}, [
            E('p', {}, 'Выберите файл .tar.gz (архив overlay/upper) для загрузки на роутер:'),
            fileInput,
            statusText,
            progressBar
        ]);

        var footer = E('div', { 'style': 'display:flex;gap:8px;justify-content:flex-end;' }, [
            E('button', { 'class': 'cbi-button cbi-button-reset', 'click': function() { ui.hideModal(); } }, 'Закрыть'),
            E('button', {
                'class': 'cbi-button cbi-button-apply',
                'click': function() {
                    var file = fileInput.files[0];
                    if (!file || !file.name.endsWith('.tar.gz')) {
                        ui.addNotification(null, E('p', {}, 'Выберите .tar.gz файл.'), 'danger');
                        return;
                    }
                    statusText.textContent = 'Загрузка... (' + Math.round(file.size / 1024) + ' KB)';
                    progressBar.style.display = 'block';

                    var xhr = new XMLHttpRequest();
                    xhr.open('POST', '/cgi-bin/usb-extroot-upload?file=' + encodeURIComponent(file.name), true);
                    xhr.setRequestHeader('Content-Type', 'application/octet-stream');
                    
                    xhr.upload.onprogress = function(e) {
                        if (e.lengthComputable) {
                            var percent = Math.round((e.loaded / e.total) * 100);
                            progressBar.firstChild.style.width = percent + '%';
                            statusText.textContent = 'Загрузка: ' + percent + '%';
                        }
                    };

                    xhr.onload = function() {
                        if (xhr.status >= 200 && xhr.status < 300) {
                            statusText.textContent = 'Успешно загружено! Файл доступен в списке.';
                            statusText.style.color = '#32cd32';
                            progressBar.firstChild.style.background = '#32cd32';
                            ui.addNotification(null, E('p', {}, 'Архив загружен.'), 'info');
                            self._lockUI(false);
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
            }, 'Загрузить')
        ]);
        ui.showModal('Загрузка архива с ПК', [ body, footer ]);
    },

    showArchiveList: function(logPre) {
        var self = this;
        Promise.all([ callArchiveList(), callDevices() ]).then(function(results) {
            var list = unwrap(results[0]);
            var devices = unwrap(results[1]) || [];

            if (!list || list.length === 0) {
                ui.addNotification(null, E('p', {}, 'На примонтированных разделах нет архивов.'), 'warning');
                return;
            }
            if (!devices || devices.length === 0) {
                ui.addNotification(null, E('p', {}, 'Нет доступных съёмных накопителей.'), 'danger');
                return;
            }

            var archiveSelect = E('select', { 'style': 'width:100%;padding:4px;margin-bottom:10px;' }, [
                E('option', { 'value': '' }, '— выберите архив —')
            ]);
            list.forEach(function(a) {
                var sizeKb = Math.round(a.size / 1024);
                archiveSelect.appendChild(E('option', { 'value': a.name }, a.name + ' (' + sizeKb + ' KB)'));
            });

            var deviceSelect = E('select', { 'style': 'width:100%;padding:4px;margin-bottom:10px;' }, [
                E('option', { 'value': '' }, '— выберите флешку —')
            ]);
            devices.forEach(function(d) {
                deviceSelect.appendChild(E('option', { 'value': d.dev }, d.desc));
            });

            var body = E('div', {}, [
                E('p', { 'style': 'color:#ff5555;font-weight:bold;' }, 'ВНИМАНИЕ: архив будет развёрнут на выбранную флешку.'),
                E('p', {}, 'Архив:'), archiveSelect,
                E('p', {}, 'Целевая флешка:'), deviceSelect
            ]);

            var footer = E('div', { 'style': 'display:flex;gap:8px;justify-content:flex-end;' }, [
                E('button', { 'class': 'cbi-button cbi-button-reset', 'click': function() { ui.hideModal(); } }, 'Отмена'),
                E('button', {
                    'class': 'cbi-button cbi-button-apply',
                    'click': function() {
                        var arc = archiveSelect.value;
                        var dev = deviceSelect.value;
                        if (!arc || !dev) {
                            ui.addNotification(null, E('p', {}, 'Выберите архив и флешку.'), 'danger');
                            return;
                        }
                        ui.hideModal();
                        self.runOp('restore_archive', dev, arc, logPre);
                    }
                }, 'Развернуть')
            ]);
            ui.showModal('Восстановление из архива на флешку', [ body, footer ]);
        }).catch(function(err) {
            ui.addNotification(null, E('p', {}, 'Ошибка получения списков: ' + err), 'danger');
        });
    },

    runOp: function(mode, device, archive, logPre) {
        var self = this;
        if (!mode) { ui.addNotification(null, E('p', {}, 'Выберите действие.'), 'warning'); return; }
        if ((mode === 'format' || mode === 'noformat') && !device) {
            ui.addNotification(null, E('p', {}, 'Выберите накопитель.'), 'danger'); return;
        }

        var devDesc = device || '';
        if (device) {
            var sel = document.getElementById('usb-extroot-device');
            if (sel && sel.selectedIndex >= 0) devDesc = sel.options[sel.selectedIndex].text;
        }

        var descEl, pStyle = { 'style': 'font-size:16px; color:#ff5555; font-weight:bold; margin-bottom:15px;' };
        if (mode === 'format') descEl = E('p', pStyle, 'ВСЕ ДАННЫЕ на устройстве ' + devDesc + ' БУДУТ УНИЧТОЖЕНЫ.');
        else if (mode === 'noformat') descEl = E('p', pStyle, 'На устройстве ' + devDesc + ' будет удалена структура overlay.');
        else if (mode === 'restore') descEl = E('p', pStyle, 'Загрузка будет переключена на внутреннюю память.');
        else if (mode === 'fallback_fix') descEl = E('p', pStyle, 'Будет очищен fstab.extroot и создан /overlay.');
        else if (mode === 'restore_archive') descEl = E('p', pStyle, 'Восстановление из архива ' + archive);

        var code = genConfirmCode();
        var codeInput = E('input', { 'type': 'text', 'maxlength': '4', 'style': 'font-size:16px;width:60px;text-align:center;padding:4px;' });

        var body = E('div', {}, [
            descEl, E('hr'),
            E('p', {}, [ 'Код: ', E('span', { 'style': 'font-size:16px;color:#777;font-family:monospace;' }, code) ]),
            E('p', {}, [ E('label', {}, 'Ввод: '), codeInput ])
        ]);

        var footer = E('div', { 'style': 'display:flex;gap:8px;justify-content:flex-end;' }, [
            E('button', { 'class': 'cbi-button cbi-button-reset', 'click': function() { ui.hideModal(); } }, 'Отмена'),
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
        logPre.textContent = '';
        self._lockUI(true);
        callRun(mode, device || '', archive || '', 'yes').then(function(res) {
            if (res && res.error) ui.addNotification(null, E('p', {}, 'Ошибка: ' + res.error), 'danger');
            self.startPolling(logPre, mode);
        }).catch(function(err) {
            ui.addNotification(null, E('p', {}, 'Ошибка запуска: ' + err), 'danger');
            self._lockUI(false);
        });
    },

    startPolling: function(logPre, mode) {
        if (pollTimer) clearInterval(pollTimer);
        var archiveDownloaded = false;
        var runningNotified = false;
        var manualDownloaded = false;
        var watchArchiveInfo = (mode !== 'backup_manual');
        var watchManualReady = (mode === 'backup_manual');
        var self = this;

        pollTimer = setInterval(function() {
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
                            window.location.href = '/cgi-bin/usb-extroot-archive?file=' + encodeURI(rel);
                            ui.addNotification(null, E('p', {}, 'Бэкап создан, скачиваем...'), 'info');
                        }
                    }
                }
            }).catch(function() {});

            if (watchArchiveInfo && !archiveDownloaded) {
                callArchiveInfo().then(function(res) {
                    var r = unwrap(res);
                    if (r && r.exists === 'yes' && !archiveDownloaded) {
                        archiveDownloaded = true;
                        window.location.href = '/cgi-bin/usb-extroot-archive';
                    }
                }).catch(function() {});
            }

            if (!runningNotified) {
                callStatus().then(function(res) {
                    var r = unwrap(res);
                    if (r && r.running === false) {
                        runningNotified = true;
                        clearInterval(pollTimer);
                        callStatus().then(function(sRes) {
                            return callDevices().then(function(dRes) {
                                return { status: unwrap(sRes) || {}, devices: unwrap(dRes) };
                            });
                        }).then(function(data) {
                            self._updateUI(data.status, data.devices);
                        }).catch(function() { self._lockUI(false); });
                    }
                }).catch(function() {});
            }
        }, 1000);
    }
});
VIEW_EOF
mkdir -p /www/luci-static/resources/view/usb-extroot
ln -sf "$BASE_DIR/main.js" /www/luci-static/resources/view/usb-extroot/main.js

echo "==> Устанавливаю CGI для отдачи архива..."
cat > "$BASE_DIR/archive.cgi" <<'CGI_EOF'
#!/bin/sh
REMOTE="${REMOTE_ADDR:-}"
case "$REMOTE" in
    127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;;
    *)
        echo "Status: 403 Forbidden"; echo; echo "Forbidden."; exit 0 ;;
esac

FILE=""
[ -n "$QUERY_STRING" ] && for pair in $(echo "$QUERY_STRING" | tr '&' ' '); do
    case "$pair" in file=*) FILE="${pair#file=}" ;; esac
done

if [ -n "$FILE" ]; then
    FILE=$(echo "$FILE" | sed 's|%2[Ff]|/|g; s|%20| |g')
    case "$FILE" in
        *..*|/*|*\\*|*[!A-Za-z0-9_./-]*) echo "Status: 400 Bad Request"; echo; echo "Invalid file"; exit 0 ;;
    esac
    case "$FILE" in
        manual/*.tar.gz|*.tar.gz) ;;
        *) echo "Status: 400 Bad Request"; echo; echo "Only .tar.gz or manual/"; exit 0 ;;
    esac

    FOUND=""
    for mnt in $(awk '$3=="ext4" || $3=="f2fs" || $3=="btrfs" {print $2}' /proc/mounts); do
        candidate="$mnt/usb-extroot-backups/$FILE"
        if [ -f "$candidate" ]; then FOUND="$candidate"; break; fi
    done
    if [ -z "$FOUND" ]; then echo "Status: 404 Not Found"; echo; echo "Archive not found"; exit 0; fi
    name=$(basename "$FOUND"); size=$(wc -c < "$FOUND")
    echo "Content-Type: application/gzip"; echo "Content-Length: $size"
    echo "Content-Disposition: attachment; filename=\"$name\""; echo "Cache-Control: no-store"; echo
    cat "$FOUND"; exit 0
fi

latest=$(ls -t /tmp/.usb-extroot-*/overlay_backup_*.tar.gz 2>/dev/null | head -1)
if [ -z "$latest" ] || [ ! -f "$latest" ]; then echo "Status: 404 Not Found"; echo; echo "Not found"; exit 0; fi
name=$(basename "$latest"); size=$(wc -c < "$latest")
echo "Content-Type: application/gzip"; echo "Content-Length: $size"
echo "Content-Disposition: attachment; filename=\"$name\""; echo "Cache-Control: no-store"; echo
cat "$latest"
CGI_EOF
chmod +x "$BASE_DIR/archive.cgi"
ln -sf "$BASE_DIR/archive.cgi" /www/cgi-bin/usb-extroot-archive

echo "==> Устанавливаю CGI для загрузки архива..."
cat > "$BASE_DIR/upload.cgi" <<'UPLOAD_EOF'
#!/bin/sh
REMOTE="${REMOTE_ADDR:-}"
case "$REMOTE" in
    127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;;
    *) echo "Status: 403 Forbidden"; echo; echo "Forbidden."; exit 0 ;;
esac

FILE=""
[ -n "$QUERY_STRING" ] && for pair in $(echo "$QUERY_STRING" | tr '&' ' '); do
    case "$pair" in file=*) FILE="${pair#file=}" ;; esac
done

FILE=$(echo "$FILE" | sed 's|%2[Ff]|/|g; s|%20| |g')
FILE=$(basename "$FILE")

# ВАЖНО: Сначала читаем ВЕСЬ файл из stdin. 
# Если выйти раньше, браузер получит Network Error.
TMPFILE="/tmp/upload_$$.tar.gz"
cat > "$TMPFILE"

if [ ! -s "$TMPFILE" ]; then echo "Status: 400"; echo; echo "No data"; rm -f "$TMPFILE"; exit 0; fi

case "$FILE" in
    *..*|*[!A-Za-z0-9_.-]*) echo "Status: 400 Bad Request"; echo; echo "Invalid filename"; rm -f "$TMPFILE"; exit 0 ;;
    *.tar.gz) ;;
    *) echo "Status: 400 Bad Request"; echo; echo "Only .tar.gz allowed"; rm -f "$TMPFILE"; exit 0 ;;
esac

MAGIC=$(hexdump -n 2 -e '2/1 "%02x"' "$TMPFILE" 2>/dev/null)
if [ "$MAGIC" != "1f8b" ]; then echo "Status: 400"; echo; echo "Not gzip"; rm -f "$TMPFILE"; exit 0; fi

SAVED=0
# 1. Ищем любую внешнюю флешку (ext4/f2fs/btrfs), кроме внутренней памяти
for mnt in $(awk '$3=="ext4" || $3=="f2fs" || $3=="btrfs" {print $2}' /proc/mounts); do
    dev=$(awk -v m="$mnt" '$2==m {print $1; exit}' /proc/mounts)
    case "$dev" in
        /dev/ubi*|/dev/mtdblock*|/dev/root) continue ;;
    esac
    DIR="$mnt/usb-extroot-backups/manual"
    mkdir -p "$DIR" 2>/dev/null
    if mv "$TMPFILE" "$DIR/$FILE" 2>/dev/null; then
        SAVED=1
        break
    fi
done

# 2. Если флешки нет, кладем в /tmp
if [ "$SAVED" = "0" ]; then
    mv "$TMPFILE" "/tmp/$FILE"
    SAVED=1
fi

if [ "$SAVED" = "1" ]; then 
    echo "Content-Type: text/plain"; echo; echo "OK"; 
else 
    echo "Status: 500"; echo; echo "Failed"; rm -f "$TMPFILE"; 
fi
UPLOAD_EOF
chmod +x "$BASE_DIR/upload.cgi"
ln -sf "$BASE_DIR/upload.cgi" /www/cgi-bin/usb-extroot-upload

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
mkdir -p /opt/usb-extroot
chmod +x /etc/init.d/usb-extroot-autobackup
/etc/init.d/usb-extroot-autobackup enable 2>/dev/null || true

echo "==> Перезапускаю rpcd и uhttpd..."
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo "=================================================================="
echo " Программа установлена."
echo " Службы → USB extroot"
echo "=================================================================="
