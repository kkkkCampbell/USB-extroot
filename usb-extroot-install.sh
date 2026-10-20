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
            # запасной вариант без timeout: сторож убивает процесс через 10 с
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

method_run() {
    local params mode device confirm pid
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

    if [ "$confirm" != "yes" ]; then
        echo "ERROR: confirm required" >> "$LOG"
        echo '{ "error": "confirm required" }'
        return
    fi

    case "$mode" in
        format|noformat|restore|fallback_fix) ;;
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
        *) device="" ;;
    esac

    if is_running; then
        pid=$(cat "$PID_FILE" 2>/dev/null)
        echo "ERROR: already running (PID $pid)" >> "$LOG"
        printf '{ "error": "already running", "pid": %d }\n' "$pid"
        return
    fi

    rm -f "$PID_FILE"
    
    if [ -n "$device" ]; then
        setsid sh "$SCRIPT" --batch --mode="$mode" --device="$device" --confirm=yes >>"$LOG" 2>&1 &
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
        echo "ERROR: Скрипт упал при старте. PID-файл не создан." >> "$LOG"
        echo '{ "error": "Скрипт упал при старте. Проверьте лог." }'
        return
    fi
    printf '{ "result": { "pid": %d, "started": true } }\n' "$pid"
}

case "$1" in
    list)
        echo '{ "status": {}, "devices": {}, "log": { "offset": 0 }, "archive_info": {}, "version": {}, "run": { "params": {} } }'
        ;;
    call)
        method="$2"
        case "$method" in
            status)       method_status ;;
            devices)      method_devices ;;
            log)          method_log ;;
            archive_info) method_archive_info ;;
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
                "luci.usb-extroot": [ "status", "devices", "log", "archive_info", "version" ]
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
var callVersion = rpc.declare({ object: 'luci.usb-extroot', method: 'version' });
var callRun = rpc.declare({ object: 'luci.usb-extroot', method: 'run', params: [ 'mode', 'device', 'confirm' ] });

var pollTimer = null;
var logOffset = 0;

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
            E('option', { 'value': '' }, '— ВЫБЕРИТЕ ДЕЙСТВИЕ —'),
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
                self.runOp('fallback_fix', null, logPre);
            }
        }, 'Исправить аварийный режим overlay');

        var btnTransfer = E('button', {
            'class': 'cbi-button cbi-button-apply',
            'style': 'margin-right:8px;',
            'id': 'btn-transfer',
            'click': function() {
                self.runOp(modeSelect.value, deviceSelect.value, logPre);
            }
        }, 'Выполнить перенос');

        var btnRestore = E('button', {
            'class': 'cbi-button cbi-button-reset',
            'style': 'margin-right:8px;',
            'id': 'btn-restore',
            'click': function() {
                self.runOp('restore', null, logPre);
            }
        }, 'Восстановить загрузку с внутренней памяти');

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
                if (hintEl) {
                    hintEl.textContent = 'Вы загружены с внешнего накопителя. Для возврата на внутреннюю память используйте кнопку «Восстановить загрузку с внутренней памяти».';
                    hintEl.style.display = 'block';
                    hintEl.style.color = '#ffaa00';
                }
            } else {
                if (btnTransferEl) btnTransferEl.disabled = false;
                if (modeSelectEl) modeSelectEl.disabled = false;
                deviceSelect.disabled = false;
                if (btnRestoreEl) btnRestoreEl.disabled = true;
                if (hintEl) hintEl.style.display = 'none';
            }

            var fbBtn = document.getElementById('btn-fallback_fix');
            if (fbBtn) {
                fbBtn.style.display = isFallback ? 'inline-block' : 'none';
            }
        };

        // --- Единственная кнопка "Получить состояние" ---
        // callStatus() выполняется СТРОГО ПЕРВЫМ; callDevices() стартует
        // только после успешного завершения первого промиса.
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
                    // Второй шаг выполняется ТОЛЬКО после успеха первого.
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
            E('div', {}, [ btnTransfer, btnRestore, btnFallback ])
        ]);

        return E([], [
            E('h2', {}, [
                'USB extroot',
                ver ? E('span', {
                    'style': 'margin-left:12px;font-size:14px;font-weight:normal;color:#888;'
                }, ver) : ''
            ]),
            E('p', {}, 'Перенос overlay OpenWrt на USB-накопитель.'),
            controls,
            E('h3', {}, 'Журнал выполнения'),
            logPre
        ]);
    },

    runOp: function(mode, device, logPre) {
        var self = this;

        if (!mode) {
            ui.addNotification(null, E('p', {}, 'Сначала выберите действие в выпадающем списке "Режим".'), 'warning');
            return;
        }

        if ((mode === 'format' || mode === 'noformat') && !device) {
            ui.addNotification(null, E('p', {}, 'Не выбран целевой накопитель. Нажмите "Получить состояние".'), 'danger');
            return;
        }

        var devDesc = device;
        if (device) {
            var sel = document.getElementById('usb-extroot-device');
            if (sel && sel.selectedIndex >= 0) {
                devDesc = sel.options[sel.selectedIndex].text;
                devDesc = devDesc.replace(/^\/dev\//, '');
            }
        }

        var descEl;
        var pStyle = { 'style': 'font-size:16px; color:#ff5555; font-weight:bold; margin-bottom:15px;' };

        if (mode === 'format') {
            descEl = E('p', pStyle, [
                'ВНИМАНИЕ: ВСЕ ДАННЫЕ на устройстве ',
                E('span', { 'style': 'color:#ffcc00;' }, devDesc),
                ' БУДУТ УНИЧТОЖЕНЫ. Будет создана ФС ext4.'
            ]);
        } else if (mode === 'noformat') {
            descEl = E('p', pStyle, [
                'На устройстве ',
                E('span', { 'style': 'color:#ffcc00;' }, devDesc),
                ' будет удалена ТОЛЬКО структура overlay (upper/, work/, .fs_state). Остальные данные не тронуты.'
            ]);
        } else if (mode === 'restore') {
            descEl = E('p', pStyle, 'Загрузка будет переключена на внутреннюю память роутера. Данные на USB не тронуты.');
        } else if (mode === 'fallback_fix') {
            descEl = E('p', pStyle, 'Будет очищен fstab.extroot и создан /overlay. Это исправление аварийного режима.');
        }

        var code = genConfirmCode();
        var codeInput = E('input', {
            'type': 'text',
            'maxlength': '4',
            'style': 'font-size:16px;width:60px;text-align:center;padding:4px;border:1px solid #666;background:#222;color:#fff;'
        });

        var body = E('div', {}, [
            descEl,
            E('hr'),
            E('p', {}, [
                E('span', {}, 'Для подтверждения введите код: '),
                E('span', { 'style': 'font-size:16px;color:#777;font-family:monospace;letter-spacing:2px;' }, code)
            ]),
            E('p', {}, [ E('label', {}, 'Код: '), codeInput ])
        ]);

        var footer = E('div', { 'style': 'display:flex;gap:8px;justify-content:flex-end;' }, [
            E('button', {
                'class': 'cbi-button cbi-button-reset',
                'click': function() { ui.hideModal(); }
            }, 'Отмена'),
            E('button', {
                'class': 'cbi-button cbi-button-apply',
                'click': function() {
                    if (codeInput.value !== code) {
                        ui.addNotification(null, E('p', {}, 'Неверный код.'), 'danger');
                        return;
                    }
                    ui.hideModal();
                    self.executeRun(mode, device, logPre);
                }
            }, 'Действуй')
        ]);

        ui.showModal('Подтверждение операции', [ body, footer ]);
        setTimeout(function() { codeInput.focus(); }, 100);
    },

    executeRun: function(mode, device, logPre) {
        var self = this;
        logOffset = 0;
        logPre.textContent = '';

        var dev = device ? device : '';

        callRun(mode, dev, 'yes').then(function(res) {
            if (res && res.error) {
                ui.addNotification(null, E('p', {}, 'Ошибка: ' + res.error), 'danger');
                return;
            }
            self.startPolling(logPre);
        }).catch(function(err) {
            var msg = (err && err.message) ? err.message : (typeof err === 'string' ? err : 'Неизвестная ошибка');
            ui.addNotification(null, E('p', {}, 'Ошибка запуска: ' + msg), 'danger');
        });
    },

    startPolling: function(logPre) {
        if (pollTimer) clearInterval(pollTimer);
        var archiveDownloaded = false;

        pollTimer = setInterval(function() {
            callLog().then(function(res) {
                var r = unwrap(res);
                if (r && r.chunk) {
                    logPre.textContent = cleanLog(r.chunk);
                    logPre.scrollTop = logPre.scrollHeight;

                    if (!archiveDownloaded && logPre.textContent.indexOf('архив создан') !== -1) {
                        archiveDownloaded = true;

                        logPre.textContent += '\n=== Сохраняю архивную копию системы ===\n';
                        logPre.scrollTop = logPre.scrollHeight;

                        window.location.href = '/cgi-bin/usb-extroot-archive';
                        ui.addNotification(null, E('p', {}, 'Архив создан. Начинается скачивание...'), 'info');
                    }
                }
            }).catch(function() { /* ignore */ });

            callStatus().then(function(res) {
                var r = unwrap(res);
                if (r && !r.running) {
                    clearInterval(pollTimer);
                    ui.addNotification(null, E('p', {}, 'Операция завершена.'), 'warning');
                }
            }).catch(function() { /* ignore */ });
        }, 1000);
    }
});

function showArchiveButton(info) {
    if (document.getElementById('usb-extroot-archive-btn')) return;
    var logPre = document.getElementById('usb-extroot-log');
    if (!logPre) return;
    var btn = E('button', {
        'id': 'usb-extroot-archive-btn',
        'class': 'cbi-button cbi-button-action',
        'style': 'margin:8px 0;display:block;',
        'click': function() {
            window.location.href = '/cgi-bin/usb-extroot-archive';
        }
    }, 'Скачать архив (' + Math.round(info.size / 1024) + ' KB)');
    logPre.parentNode.insertBefore(btn, logPre);
}
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
        echo "Status: 403 Forbidden"
        echo "Content-Type: text/plain"
        echo
        echo "Archive download is available only from the local network."
        exit 0
        ;;
esac

latest=$(ls -t /tmp/.usb-extroot-*/overlay_backup_*.tar.gz 2>/dev/null | head -1)
if [ -z "$latest" ] || [ ! -f "$latest" ]; then
    echo "Status: 404 Not Found"
    echo "Content-Type: text/plain"
    echo
    echo "Archive not found. Please run the operation first."
    exit 0
fi

name=$(basename "$latest")
size=$(wc -c < "$latest")

echo "Content-Type: application/gzip"
echo "Content-Length: $size"
echo "Content-Disposition: attachment; filename=\"$name\""
echo "Cache-Control: no-store"
echo
cat "$latest"
CGI_EOF
chmod +x "$BASE_DIR/archive.cgi"
mkdir -p /www/cgi-bin
ln -sf "$BASE_DIR/archive.cgi" /www/cgi-bin/usb-extroot-archive

echo "==> Перезапускаю rpcd и uhttpd..."
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
echo "=================================================================="
echo " Программа установлена."
echo " Все файлы находятся в /opt/usb-extroot/"
echo " Для запуска откройте веб-интерфейс роутера:"
echo "     Службы → USB extroot"
echo "=================================================================="
