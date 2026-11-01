'use strict';
'require view';
'require ui';
'require rpc';
'require dom';

var OBJ = 'luci.usb-extroot';

var callVersion         = rpc.declare({ object: OBJ, method: 'version' });
var callReadToken       = rpc.declare({ object: OBJ, method: 'api_read_token' });
var callWriteToken      = rpc.declare({ object: OBJ, method: 'api_write_token' });

function cgiCall(params) {
	var url = '/cgi-bin/usb-extroot-action?' + Object.keys(params).map(function(k) {
		return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
	}).join('&');

	return new Promise(function(resolve, reject) {
		var xhr = new XMLHttpRequest();
		xhr.open('GET', url, true);
		xhr.onload = function() {
			if (xhr.status >= 200 && xhr.status < 300) {
				var ct = xhr.getResponseHeader('Content-Type') || '';
				if (ct.indexOf('json') !== -1) {
					try { resolve(JSON.parse(xhr.responseText)); }
					catch(e) { reject(new Error('JSON parse error')); }
				} else {
					resolve(xhr.responseText);
				}
			} else {
				reject(new Error('HTTP ' + xhr.status + ': ' + xhr.responseText));
			}
		};
		xhr.onerror = function() { reject(new Error('Network error')); };
		xhr.send();
	});
}

function callStatus() { return cgiCall({ action: 'status', token: window._writeToken || '' }); }
function callDevices() { return cgiCall({ action: 'devices', token: window._writeToken || '' }); }
function callSwitchTargets() { return cgiCall({ action: 'switch-targets', token: window._writeToken || '' }); }
function callBackupSources() { return cgiCall({ action: 'backup-sources', token: window._writeToken || '' }); }
function callArchiveList() { return cgiCall({ action: 'archive-list', token: window._writeToken || '' }); }
function callGetSettings() { return cgiCall({ action: 'get-settings', token: window._writeToken || '' }); }

function callRun(mode, device, archive, confirm, backup) {
	var params = { mode: mode, confirm: confirm, backup: backup, token: window._writeToken || '' };
	if (device) params.device = device;
	if (archive) params.archive = archive;
	return cgiCall(params);
}

function unwrap(res) {
	return (res && typeof res === 'object' && 'result' in res) ? res.result : res;
}

function cleanLog(str) {
	return String(str || '')
		.replace(/\r/g, '')
		.replace(/[\u001b\u009b][[()#;?]*(?:[0-9]{1,4}(?:;[0-9]{1,4})*)?[0-9A-ORZcf-nqry=><]/g, '')
		.replace(/EXTROOT_READY_CODE_777888/g, '');
}

function genCode() {
	var s = '';
	for (var i = 0; i < 4; i++) s += Math.floor(Math.random() * 10);
	return s;
}

function dlUrl(relPath, token) {
	var u = '/cgi-bin/usb-extroot-getfile?file=' + encodeURIComponent(relPath);
	if (token) u += '&token=' + encodeURIComponent(token);
	return u;
}

function ulUrl(name, token, saveUsb) {
	var u = '/cgi-bin/usb-extroot-upload?file=' + encodeURIComponent(name);
	if (token) u += '&token=' + encodeURIComponent(token);
	u += '&save_usb=' + (saveUsb ? '1' : '0');
	return u;
}

function statusLine(st) {
	if (!st) return 'Статус не проверен.';
	var ext = st.extroot === 'yes';
	var fb  = st.fallback === 'yes';
	var line = ext
		? 'Используется накопитель ' + (st.extroot_desc || st.extroot_dev || '')
		: 'Используется внутренний накопитель роутера';
	line += ' | Ошибки: ' + (fb ? 'ДА (требуется исправление)' : 'НЕТ');
	return line;
}

return view.extend({

	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		return Promise.all([
			callVersion().catch(function(){ return null; }),
			callReadToken().catch(function(){ return null; }),
			callWriteToken().catch(function(){ return null; })
		]);
	},

	render: function(res) {
		var self = this;

		var css = E('link', { 'rel': 'stylesheet', 'href': L.resource('view/usb-extroot/main.css') });
		document.head.appendChild(css);

		var verObj = unwrap(res && res[0]) || {};
		var rtObj  = unwrap(res && res[1]) || {};
		var wtObj  = unwrap(res && res[2]) || {};

		self._ver        = verObj.version || '';
		self._readToken  = rtObj.read_token || '';
		self._writeToken = wtObj.write_token || '';
		self._canWrite   = !!self._writeToken;

		window._writeToken = self._writeToken;

		self._state = {
			busy: false, mode: '', device: '', archive: '', backup: 'no',
			tick: 0, lastArchivePath: '', lastArchiveName: '',
			shownDownload: false, shownFatal: false, shownManual: false, timer: null
		};
		self._lastStatus = null;
		self._lastSwError = '';

		self._logPre = E('pre', { 'id': 'usb-extroot-log', 'class': 'usb-extroot-log' }, '');
		self._statusText = E('div', { 'class': 'usb-extroot-status' }, 'Статус не проверен.');
		self._hintText   = E('div', { 'class': 'usb-extroot-hint-info', 'style': 'display:none;' }, '');

		self._modeSelect = E('select', { 'id': 'usb-extroot-mode', 'disabled': true }, [
			E('option', { 'value': '' }, '— выберите режим —'),
			E('option', { 'value': 'format' }, 'С форматированием (mkfs.ext4)'),
			E('option', { 'value': 'noformat' }, 'Без форматирования (только overlay)')
		]);
		self._deviceSelect = E('select', { 'id': 'usb-extroot-device', 'disabled': true }, [
			E('option', { 'value': '' }, '— нажмите «Получить состояние» —')
		]);
		self._switchSelect = E('select', { 'id': 'usb-extroot-switch-device', 'disabled': true }, [
			E('option', { 'value': '' }, '— нажмите «Получить состояние» —')
		]);

		self._btnGetState   = E('button', { 'class': 'cbi-button cbi-button-action', 'id': 'btn-get-state',
			'click': function(){ self.loadState(); } }, 'Получить состояние');

		self._btnTransfer   = E('button', { 'class': 'cbi-button', 'id': 'btn-transfer', 'disabled': true,
			'click': function(){ self.runOp(self._modeSelect.value, self._deviceSelect.value, ''); }
		}, 'Выполнить перенос');

		self._btnFallback   = E('button', { 'class': 'cbi-button cbi-button-negative', 'id': 'btn-fallback-fix',
			'style': 'display:none;', 'disabled': true,
			'click': function(){ self.runOp('fallback_fix', '', ''); }
		}, 'Исправить аварийный режим');

		self._btnSwitch     = E('button', { 'class': 'cbi-button cbi-button-apply', 'id': 'btn-switch-overlay',
			'disabled': true,
			'click': function(){
				var d = self._switchSelect.value;
				if (!d) return;
				if (d === 'internal' || d === '__internal__') {
					self.runOp('revert_extroot', '', '');
				} else {
					self.runOp('switch_overlay', d, '');
				}
			}
		}, 'Сменить загрузочный накопитель');

		self._btnBackup     = E('button', { 'class': 'cbi-button', 'id': 'btn-backup-manual', 'disabled': true,
			'click': function(){ self.showBackupSourceDialog(); }
		}, 'Создать бэкап сейчас');

		self._btnRestore    = E('button', { 'class': 'cbi-button', 'id': 'btn-restore-archive', 'disabled': true,
			'click': function(){ self.showArchiveList(); }
		}, 'Восстановить из архива');

		self._btnUpload     = E('button', { 'class': 'cbi-button', 'id': 'btn-upload-archive', 'disabled': true,
			'click': function(){ self.showUploadDialog(); }
		}, 'Загрузить архив с ПК');

		self._btnFactory    = E('button', { 'class': 'cbi-button cbi-button-negative', 'id': 'btn-factory-reset',
			'style': 'display:none;margin-top:20px;', 'disabled': true,
			'click': function(){ self.runOp('reset_keep_extroot', '', ''); }
		}, 'Сбросить настройки (оставить загрузку с флешки)');

		self._btnSettings   = E('button', { 'class': 'cbi-button cbi-button-action', 'id': 'btn-settings',
			'click': function(){ self.showSettings(); }
		}, '⚙ Настройки');

		var controls = E('div', { 'class': 'usb-extroot-controls' }, [
			E('div', { 'class': 'usb-extroot-row' }, [ self._btnGetState ]),
			self._statusText,
			self._hintText,
			E('hr'),
			E('div', { 'class': 'usb-extroot-row-inline' }, [ E('label', {}, 'Режим:'), self._modeSelect ]),
			E('div', { 'class': 'usb-extroot-row-inline' }, [ E('label', {}, 'Накопитель:'), self._deviceSelect ]),
			E('div', { 'class': 'usb-extroot-actions' }, [ self._btnTransfer, self._btnFallback ]),
			E('hr'),
			E('div', { 'class': 'usb-extroot-row-inline' }, [ E('label', {}, 'Загрузочный диск:'), self._switchSelect ]),
			E('div', { 'class': 'usb-extroot-actions' }, [ self._btnSwitch ]),
			E('hr'),
			E('div', { 'class': 'usb-extroot-actions' }, [ self._btnBackup, self._btnRestore, self._btnUpload ])
		]);

		return E('div', { 'class': 'usb-extroot-page' }, [
			E('div', { 'class': 'usb-extroot-header' }, [
				E('h2', {}, ['USB extroot', self._ver ? E('span', { 'class': 'usb-extroot-version' }, self._ver) : '']),
				self._btnSettings
			]),
			E('p', {}, 'Перенос overlay OpenWrt на USB-накопитель и управление загрузкой.'),
			controls,
			E('h3', {}, 'Журнал выполнения'),
			self._logPre,
			self._btnFactory
		]);
	},

	_lockUI: function(disabled) {
		var ids = [
			'btn-get-state', 'btn-transfer', 'btn-fallback-fix', 'btn-switch-overlay',
			'btn-backup-manual', 'btn-restore-archive', 'btn-upload-archive',
			'btn-factory-reset', 'btn-settings',
			'usb-extroot-mode', 'usb-extroot-device', 'usb-extroot-switch-device'
		];
		for (var i = 0; i < ids.length; i++) {
			var el = document.getElementById(ids[i]);
			if (el) el.disabled = disabled;
		}
		this._state.busy = disabled;
	},

	loadState: function() {
		var self = this;
		var b = document.getElementById('btn-get-state');
		if (b) { b.disabled = true; b.textContent = '...'; }

		Promise.all([
			callStatus().catch(function(){ return ''; }),
			callDevices().catch(function(){ return ''; }),
			callSwitchTargets().catch(function(){ return ''; })
		]).then(function(r){
			var st = {};
			if (r[0]) {
				r[0].split('\n').forEach(function(line) {
					var m = line.match(/^(\w+)=(.*)$/);
					if (m) st[m[1]] = m[2];
				});
			}
			
			var dv = [];
			if (r[1]) {
				r[1].split('\n').forEach(function(line) {
					if (!line.trim()) return;
					var p = line.split('|');
					if (p.length >= 3) dv.push({ dev: p[0], fs: p[1], desc: p[2] });
				});
			}
			
			var sw = [];
			if (r[2]) {
				r[2].split('\n').forEach(function(line) {
					if (!line.trim()) return;
					var p = line.split('|');
					if (p.length >= 2) sw.push({ dev: p[0], desc: p[1] });
				});
			}
			
			self._lastStatus = st;
			self._lastSwError = '';
			self._updateUI(st, dv, sw);
			
			if (b) { b.disabled = false; b.textContent = 'Получить состояние'; }
		});
	},

	_updateUI: function(st, dv, sw) {
		var self = this;
		var isExt = st.extroot === 'yes';
		var isFb  = st.fallback === 'yes';
		var curDev = st.extroot_dev || '';
		var canW = self._canWrite;

		self._statusText.textContent = statusLine(st);
		self._statusText.className = 'usb-extroot-status ' + (isFb ? 'error' : (isExt ? 'ok' : ''));

		self._deviceSelect.innerHTML = '';
		var avail = 0;
		for (var i = 0; i < dv.length; i++) {
			if (isExt && dv[i].dev === curDev) continue;
			self._deviceSelect.appendChild(E('option', { 'value': dv[i].dev }, dv[i].desc));
			avail++;
		}
		if (avail === 0) self._deviceSelect.appendChild(E('option', { 'value': '' }, '— нет накопителей —'));

		self._switchSelect.innerHTML = '';
		self._switchSelect.appendChild(E('option', { 'value': '' }, '— выберите —'));
		var savail = 0;
		for (var j = 0; j < sw.length; j++) {
			self._switchSelect.appendChild(E('option', { 'value': sw[j].dev }, sw[j].desc));
			savail++;
		}
		
		if (savail === 0 && !isExt) {
			for (var k = 0; k < dv.length; k++) {
				if (dv[k].dev === curDev) continue;
				self._switchSelect.appendChild(E('option', { 'value': dv[k].dev }, dv[k].desc));
				savail++;
			}
		}
		if (isExt) {
			self._switchSelect.appendChild(E('option', { 'value': 'internal' }, 'Внутренняя память роутера'));
			savail++;
		}
		if (savail === 0) self._switchSelect.appendChild(E('option', { 'value': '' }, '— нет целей —'));

		self._modeSelect.disabled    = !canW || isFb || avail === 0;
		self._deviceSelect.disabled  = !canW || isFb || avail === 0;
		self._btnTransfer.disabled   = !canW || isFb || avail === 0;
		self._switchSelect.disabled  = !canW || isFb || savail === 0;
		self._btnSwitch.disabled     = !canW || isFb || savail === 0;
		self._btnBackup.disabled     = !canW;
		self._btnRestore.disabled    = !canW;
		self._btnUpload.disabled     = !canW;
		self._btnFallback.style.display = (isFb && canW) ? 'inline-block' : 'none';
		self._btnFallback.disabled   = !canW;
		self._btnFactory.style.display  = (isExt && canW) ? 'block' : 'none';
		self._btnFactory.disabled    = !canW;

		if (isFb) {
			self._hintText.textContent = 'ВНИМАНИЕ: аварийный режим overlay (фоллбэк). Сначала нажмите «Исправить аварийный режим».';
			self._hintText.className = 'usb-extroot-hint-error';
			self._hintText.style.display = 'block';
		} else if (!canW) {
			self._hintText.textContent = 'У вас только чтение (нет write-ACL). Действия записи недоступны.';
			self._hintText.className = 'usb-extroot-hint-error';
			self._hintText.style.display = 'block';
		} else if (self._lastSwError) {
			self._hintText.textContent = 'Ошибка: ' + self._lastSwError;
			self._hintText.className = 'usb-extroot-hint-error';
			self._hintText.style.display = 'block';
		} else {
			self._hintText.style.display = 'none';
		}
	},

	_showConfirmCode: function(title, desc, onOk) {
		var self = this;
		var code = genCode();
		var input = E('input', { 'type': 'text', 'maxlength': '4', 'class': 'usb-extroot-code-input' });

		var body = E('div', {}, [
			E('p', { 'class': 'usb-extroot-warn' }, desc),
			E('hr'),
			E('p', {}, [ 'Код: ', E('span', { 'class': 'usb-extroot-code' }, code) ]),
			E('p', {}, [ E('label', {}, 'Ввод: '), input ])
		]);
		var footer = E('div', { 'class': 'usb-extroot-modal-footer' }, [
			E('button', { 'class': 'cbi-button cbi-button-reset',
				'click': function(){ ui.hideModal(); self._lockUI(false); }
			}, 'Отмена'),
			E('button', { 'class': 'cbi-button cbi-button-apply',
				'click': function(){
					if (input.value !== code) {
						ui.addNotification(null, E('p', {}, 'Неверный код.'), 'danger');
						return;
					}
					ui.hideModal();
					onOk();
				}
			}, 'Действуй')
		]);
		ui.showModal(title, [ body, footer ]);
		setTimeout(function(){ input.focus(); }, 100);
	},

	_showBackupPrompt: function(mode, device, archive, onDecide) {
		var self = this;
		var target = (device === 'internal' || !device) ? 'внутреннюю память' : device;

		var body = E('div', {}, [
			E('p', { 'class': 'usb-extroot-warn-bold' }, 'Цель: ' + target),
			E('p', {}, 'Текущий overlay на цели будет уничтожен. Рекомендуем создать архив перед операцией.'),
			E('p', {}, 'Создать архив ДАННЫХ ЦЕЛИ (того, что будет стёрто)?')
		]);
		var footer = E('div', { 'class': 'usb-extroot-modal-footer' }, [
			E('button', { 'class': 'cbi-button cbi-button-reset',
				'click': function(){ ui.hideModal(); self._lockUI(false); }
			}, 'Отмена'),
			E('button', { 'class': 'cbi-button cbi-button-negative',
				'click': function(){ ui.hideModal(); onDecide('no'); }
			}, 'Без бэкапа'),
			E('button', { 'class': 'cbi-button cbi-button-apply',
				'click': function(){ ui.hideModal(); onDecide('yes'); }
			}, 'С бэкапом')
		]);
		ui.showModal('Сохранить текущее состояние?', [ body, footer ]);
	},

	runOp: function(mode, device, archive) {
		var self = this;
		if (!self._canWrite) {
			ui.addNotification(null, E('p', {}, 'Нет write-ACL.'), 'danger');
			return;
		}
		if (!mode) {
			ui.addNotification(null, E('p', {}, 'Выберите действие.'), 'warning');
			return;
		}
		if ((mode === 'format' || mode === 'noformat' || mode === 'switch_overlay') && !device) {
			ui.addNotification(null, E('p', {}, 'Выберите накопитель.'), 'danger');
			return;
		}

		self._lockUI(true);

		if (mode === 'format' || mode === 'noformat' || mode === 'restore_archive') {
			self._showBackupPrompt(mode, device, archive, function(backup) {
				self._showConfirmCode('Подтверждение', self._opDesc(mode, device, archive), function() {
					self._executeRun(mode, device, archive, backup);
				});
			});
			return;
		}

		self._showConfirmCode('Подтверждение', self._opDesc(mode, device, archive), function() {
			self._executeRun(mode, device, archive, 'no');
		});
	},

	_opDesc: function(mode, device, archive) {
		if (mode === 'format')             return 'ВСЕ ДАННЫЕ на устройстве ' + device + ' БУДУТ УНИЧТОЖЕНЫ.';
		if (mode === 'noformat')           return 'На устройстве ' + device + ' будет удалена структура overlay.';
		if (mode === 'switch_overlay')     return 'Загрузочный накопитель будет изменён на: ' + device;
		if (mode === 'revert_extroot')     return 'Загрузка будет переключена на внутреннюю память.';
		if (mode === 'fallback_fix')       return 'Будет очищен fstab.extroot и создан /overlay.';
		if (mode === 'restore_archive')    return 'Архив ' + archive + ' будет развёрнут на ' + (device === 'internal' ? 'ВНУТРЕННЮЮ ПАМЯТЬ' : device) + '.';
		if (mode === 'reset_keep_extroot') return 'ВНИМАНИЕ: все настройки будут сброшены.';
		return 'Операция: ' + mode;
	},

	_executeRun: function(mode, device, archive, backup) {
		var self = this;
		self._state.mode    = mode;
		self._state.device  = device;
		self._state.archive = archive;
		self._state.backup  = backup;
		self._state.tick    = 0;
		self._state.lastArchivePath = '';
		self._state.lastArchiveName = '';
		self._state.shownDownload   = false;
		self._state.shownFatal      = false;
		self._state.shownManual     = false;
		self._logPre.textContent    = '[UI] Запуск операции: ' + mode + '...\n';

		callRun(mode, device || '', archive || '', 'yes', backup).then(function(res) {
			if (res && res.error) {
				ui.addNotification(null, E('p', {}, 'Ошибка запуска: ' + res.error), 'danger');
                self._logPre.textContent += '\n[UI] Ошибка запуска: ' + res.error;
				self._lockUI(false);
				return;
			}
			self._startPolling();
		}).catch(function(err) {
            var msg = String(err);
			ui.addNotification(null, E('p', {}, 'Ошибка CGI: ' + msg), 'danger');
            self._logPre.textContent += '\n[UI] Ошибка CGI: ' + msg;
			self._lockUI(false);
		});
	},

	_startPolling: function() {
		var self = this;
		if (self._state.timer) clearInterval(self._state.timer);
		self._state.timer = setInterval(function(){ self._poll(); }, 1000);
	},

	_poll: function() {
		var self = this;
		self._state.tick++;

		cgiCall({ action: 'log', token: window._writeToken }).catch(function(){ return ''; }).then(function(chunk) {
			chunk = chunk || '';
			self._logPre.textContent = cleanLog(chunk);
			self._logPre.scrollTop = self._logPre.scrollHeight;

			// 1. Ловим ошибки в логе
			if (!self._state.shownFatal && /(^|\n)(ОШИБКА|СТОП):/.test(chunk)) {
				self._state.shownFatal = true;
				ui.addNotification(null, E('p', {}, 'Операция завершилась с ошибкой. Проверьте лог.'), 'danger');
				if (self._state.timer) { clearInterval(self._state.timer); self._state.timer = null; }
				self._lockUI(false);
				return;
			}

			var re = /(?:MANUAL_ARCHIVE_READY|EMERGENCY_ARCHIVE_READY)=(\S+)/g;
			var m, last = null;
			while ((m = re.exec(chunk)) !== null) last = m[1];
			if (last) {
				self._state.lastArchivePath = last;
				var slash = last.lastIndexOf('/');
				self._state.lastArchiveName = slash >= 0 ? last.substring(slash + 1) : last;
			}

			if (self._state.mode === 'backup_manual' && !self._state.shownManual && /MANUAL_ARCHIVE_READY=/.test(chunk) && self._state.lastArchivePath) {
				self._state.shownManual = true;
				self._autoDownload(self._state.lastArchiveName);
			}

			if (self._state.backup === 'yes' && !self._state.shownDownload && chunk.indexOf('EXTROOT_READY_CODE_777888') !== -1) {
				self._state.shownDownload = true;
				if (self._state.lastArchivePath) self._autoDownload(self._state.lastArchiveName);
				self._showDownloadModal();
			}

			// 2. Проверяем, жив ли процесс, каждые 3 секунды
			if (self._state.tick >= 3 && !self._state.shownFatal) {
				callStatus().catch(function(){ return 'running=false'; }).then(function(sres){
					var st = {};
					if (sres) {
						sres.split('\n').forEach(function(line) {
							var match = line.match(/^(\w+)=(.*)$/);
							if (match) st[match[1]] = match[2];
						});
					}
					if (st.running === 'false' && self._state.timer) {
						clearInterval(self._state.timer);
						self._state.timer = null;
						self.loadState();
						self._lockUI(false);
					}
				});
			}
		});
	},

	_autoDownload: function(name) {
		if (!name || !this._readToken) return;
		var a = document.createElement('a');
		a.href = dlUrl(name, this._readToken);
		a.download = name;
		document.body.appendChild(a);
		a.click();
		document.body.removeChild(a);
	},

	_showDownloadModal: function() {
		var self = this;
		if (document.getElementById('usb-extroot-dl-modal')) return;
		var name = self._state.lastArchiveName;

		var btnDl = E('button', { 'class': 'cbi-button cbi-button-apply',
			'click': function(){
				if (name) self._autoDownload(name);
				else ui.addNotification(null, E('p', {}, 'Имя архива не найдено в логе.'), 'warning');
			}
		}, '📥 Скачать архив');

		var btnReboot = E('button', { 'class': 'cbi-button cbi-button-negative',
			'click': function(){
				cgiCall({ action: 'reboot-now', token: window._writeToken }).then(function(){
					ui.hideModal();
					ui.addNotification(null, E('p', {}, 'Сигнал перезагрузки отправлен. Роутер уйдёт в ребут.'), 'info');
				}).catch(function(err){
					ui.addNotification(null, E('p', {}, 'Ошибка: ' + err), 'danger');
				});
			}
		}, '🔄 Перезагрузить');

		var btnCancel = E('button', { 'class': 'cbi-button cbi-button-reset',
			'click': function(){
				cgiCall({ action: 'reboot-cancel', token: window._writeToken }).then(function(){
					ui.hideModal();
					ui.addNotification(null, E('p', {}, 'Отменено. Изменения применены — перезагрузите роутер вручную, когда будете готовы.'), 'warning');
					if (self._state.timer) { clearInterval(self._state.timer); self._state.timer = null; }
					self._lockUI(false);
				}).catch(function(err){
					ui.addNotification(null, E('p', {}, 'Ошибка: ' + err), 'danger');
				});
			}
		}, 'Отменить перезагрузку');

		var body = E('div', { 'id': 'usb-extroot-dl-modal' }, [
			E('p', { 'class': 'usb-extroot-warn-bold' }, 'Операция завершена. Изменения применены.'),
			E('p', {}, 'Перед перезагрузкой скачайте архив старого состояния — на случай, если что-то пойдёт не так.'),
			E('p', { 'class': 'usb-extroot-path' }, name || '(имя архива не найдено)'),
			E('div', { 'class': 'usb-extroot-modal-footer' }, [ btnDl, btnReboot, btnCancel ])
		]);
		ui.showModal('Требуется действие', [ body ]);
	},

	_showFatalModal: function() {
		var self = this;
		var name = self._state.lastArchiveName;

		var btnDl = E('button', { 'class': 'cbi-button cbi-button-apply',
			'click': function(){
				if (name) { self._autoDownload(name); return; }
				cgiCall({ action: 'emergency-archive', token: window._writeToken }).then(function(res){
					if (res && res.trim()) {
						var p = res.trim();
						var slash = p.lastIndexOf('/');
						var n = slash >= 0 ? p.substring(slash + 1) : p;
						self._autoDownload(n);
					} else {
						ui.addNotification(null, E('p', {}, 'Архив не найден.'), 'warning');
					}
				});
			}
		}, '📥 Скачать архив');

		var btnOk = E('button', { 'class': 'cbi-button cbi-button-reset',
			'click': function(){ ui.hideModal(); self._lockUI(false); }
		}, 'Закрыть');

		var body = E('div', {}, [
			E('p', { 'class': 'usb-extroot-error-bold' }, 'Операция завершилась с ошибкой.'),
			E('p', {}, 'Но бэкап старого состояния создан. Скачайте его сейчас — это единственный шанс вернуть систему к рабочему состоянию.'),
			E('p', { 'class': 'usb-extroot-path' }, name || '(имя архива не найдено)'),
			E('div', { 'class': 'usb-extroot-modal-footer' }, [ btnDl, btnOk ])
		]);
		ui.showModal('Операция не завершена', [ body ]);
	},

	showBackupSourceDialog: function() {
		var self = this;
		if (!self._canWrite) return;

		callBackupSources().then(function(res){
			var src = [];
			if (res) {
				res.split('\n').forEach(function(line) {
					if (!line.trim()) return;
					var p = line.split('|');
					if (p.length >= 2) src.push({ dev: p[0], desc: p[1] });
				});
			}
			if (!src.length) {
				ui.addNotification(null, E('p', {}, 'Нет доступных источников.'), 'danger');
				return;
			}
			var sel = E('select', {}, []);
			src.forEach(function(s){ sel.appendChild(E('option', { 'value': s.dev }, s.desc)); });

			var body = E('div', {}, [ E('p', { 'class': 'usb-extroot-warn-bold' }, 'Источник:'), sel ]);
			var footer = E('div', { 'class': 'usb-extroot-modal-footer' }, [
				E('button', { 'class': 'cbi-button cbi-button-reset', 'click': function(){ ui.hideModal(); } }, 'Отмена'),
				E('button', { 'class': 'cbi-button cbi-button-apply',
					'click': function(){
						ui.hideModal();
						self._lockUI(true);
						self._state.mode = 'backup_manual';
						self._state.backup = 'no';
						self._state.lastArchivePath = '';
						self._state.lastArchiveName = '';
						self._state.shownManual = false;
						self._state.shownFatal  = false;
						self._logPre.textContent = '[UI] Запуск ручного бэкапа...\n';
						callRun('backup_manual', sel.value, '', 'yes', 'no').then(function(r){
							if (r && r.error) {
								ui.addNotification(null, E('p', {}, 'Ошибка: ' + r.error), 'danger');
								self._lockUI(false);
								return;
							}
							self._startPolling();
						}).catch(function(e){
							ui.addNotification(null, E('p', {}, 'Ошибка CGI: ' + String(e)), 'danger');
							self._lockUI(false);
						});
					}
				}, 'Создать')
			]);
			ui.showModal('Создание бэкапа', [ body, footer ]);
		}).catch(function(e){
			ui.addNotification(null, E('p', {}, 'Ошибка CGI: ' + String(e)), 'danger');
		});
	},

	showArchiveList: function() {
		var self = this;
		if (!self._canWrite) return;

		Promise.all([
			callArchiveList().catch(function(){ return ''; }),
			callDevices().catch(function(){ return ''; })
		]).then(function(r){
			var list = [];
			if (r[0]) {
				r[0].split('\n').forEach(function(line) {
					if (!line.trim()) return;
					var p = line.split('|');
					if (p.length >= 2) list.push({ path: p[0], size: parseInt(p[1], 10) || 0 });
				});
			}
			var dv = [];
			if (r[1]) {
				r[1].split('\n').forEach(function(line) {
					if (!line.trim()) return;
					var p = line.split('|');
					if (p.length >= 3) dv.push({ dev: p[0], fs: p[1], desc: p[2] });
				});
			}
			
			if (!list.length) {
				ui.addNotification(null, E('p', {}, 'Архивов не найдено.'), 'warning');
				return;
			}

			var aSel = E('select', {}, [ E('option', { 'value': '' }, '— выберите архив —') ]);
			list.forEach(function(a){
				var kb = Math.round((a.size || 0) / 1024);
				aSel.appendChild(E('option', { 'value': a.path }, a.path + ' (' + kb + ' KB)'));
			});

			var dSel = E('select', {}, [ E('option', { 'value': 'internal' }, 'Внутренняя память роутера (/overlay)') ]);
			dv.forEach(function(d){ dSel.appendChild(E('option', { 'value': d.dev }, d.desc)); });

			var body = E('div', {}, [
				E('p', { 'class': 'usb-extroot-warn-bold' }, 'ВНИМАНИЕ: overlay на выбранной цели будет заменён содержимым архива.'),
				E('p', {}, 'Архив:'), aSel,
				E('p', {}, 'Цель:'),  dSel
			]);
			var footer = E('div', { 'class': 'usb-extroot-modal-footer' }, [
				E('button', { 'class': 'cbi-button cbi-button-reset', 'click': function(){ ui.hideModal(); } }, 'Отмена'),
				E('button', { 'class': 'cbi-button cbi-button-apply',
					'click': function(){
						var arc = aSel.value, dev = dSel.value;
						if (!arc || !dev) {
							ui.addNotification(null, E('p', {}, 'Выберите архив и цель.'), 'danger');
							return;
						}
						ui.hideModal();
						self.runOp('restore_archive', dev, arc);
					}
				}, 'Развернуть')
			]);
			ui.showModal('Восстановление из архива', [ body, footer ]);
		}).catch(function(e){
			ui.addNotification(null, E('p', {}, 'Ошибка CGI: ' + String(e)), 'danger');
		});
	},

	showUploadDialog: function() {
		var self = this;
		if (!self._canWrite) return;

		var fileIn = E('input', { 'type': 'file', 'accept': '.tar.gz' });
		var saveUsb = E('input', { 'type': 'checkbox', 'checked': true });
		var status  = E('p', { 'class': 'usb-extroot-hint-info' }, '');
		var barWrap = E('div', { 'class': 'usb-extroot-progress' }, [ E('div', { 'class': 'usb-extroot-progress-bar', 'style': 'width:0%' }) ]);
		barWrap.style.display = 'none';

		var btnClose = E('button', { 'class': 'cbi-button cbi-button-reset', 'click': function(){ ui.hideModal(); } }, 'Закрыть');

		var btnUpload = E('button', { 'class': 'cbi-button cbi-button-apply',
			'click': function(){
				var f = fileIn.files[0];
				if (!f || !f.name.match(/\.tar\.gz$/)) {
					ui.addNotification(null, E('p', {}, 'Выберите .tar.gz.'), 'danger');
					return;
				}
				status.textContent = 'Загрузка (' + Math.round(f.size/1024) + ' KB)...';
				barWrap.style.display = 'block';

				var xhr = new XMLHttpRequest();
				xhr.open('POST', ulUrl(f.name, self._writeToken, saveUsb.checked ? 1 : 0), true);
				xhr.setRequestHeader('Content-Type', 'application/octet-stream');
				xhr.setRequestHeader('X-Extroot-Token', self._writeToken);

				xhr.upload.onprogress = function(e){
					if (e.lengthComputable) {
						var p = Math.round(e.loaded / e.total * 100);
						barWrap.firstChild.style.width = p + '%';
						status.textContent = 'Загрузка: ' + p + '%';
					}
				};
				xhr.onload = function(){
					var resp = {};
					try { resp = JSON.parse(xhr.responseText); } catch (_) {}
					if (xhr.status >= 200 && xhr.status < 300 && resp.ok) {
						ui.hideModal();
						ui.addNotification(null, E('p', {}, 'Архив загружен: ' + (resp.path || f.name)), 'info');
						self._showUploadRestoreTarget(f.name, resp.path || '');
					} else {
						status.textContent = 'Ошибка: ' + (resp.error || xhr.responseText);
						status.className = 'usb-extroot-hint-error';
					}
				};
				xhr.onerror = function(){
					status.textContent = 'Ошибка сети';
					status.className = 'usb-extroot-hint-error';
				};
				xhr.send(f);
			}
		}, 'Загрузить');

		var body = E('div', {}, [
			E('p', {}, 'Выберите .tar.gz архив для загрузки:'),
			fileIn,
			E('p', {}, [ saveUsb, ' ', E('label', {}, 'Сохранить на флешку (иначе — только для восстановления)') ]),
			status,
			barWrap
		]);
		ui.showModal('Загрузка архива с ПК', [ body, E('div', { 'class': 'usb-extroot-modal-footer' }, [ btnClose, btnUpload ]) ]);
	},

	_showUploadRestoreTarget: function(archiveName, uploadedPath) {
		var self = this;
		Promise.all([
			callDevices().catch(function(){ return ''; }),
			callStatus().catch(function(){ return ''; })
		]).then(function(r){
			var dv = [];
			if (r[0]) {
				r[0].split('\n').forEach(function(line) {
					if (!line.trim()) return;
					var p = line.split('|');
					if (p.length >= 3) dv.push({ dev: p[0], fs: p[1], desc: p[2] });
				});
			}
			var st = {};
			if (r[1]) {
				r[1].split('\n').forEach(function(line) {
					var m = line.match(/^(\w+)=(.*)$/);
					if (m) st[m[1]] = m[2];
				});
			}

			var dSel = E('select', {}, [ E('option', { 'value': 'internal' }, 'Внутренняя память роутера (/overlay)') ]);
			dv.forEach(function(d){ dSel.appendChild(E('option', { 'value': d.dev }, d.desc)); });
			if (st.extroot_dev) dSel.value = st.extroot_dev;

			var body = E('div', {}, [
				E('p', { 'class': 'usb-extroot-warn-bold' }, 'Архив: ' + archiveName),
				E('p', {}, 'Цель восстановления:'), dSel
			]);
			var footer = E('div', { 'class': 'usb-extroot-modal-footer' }, [
				E('button', { 'class': 'cbi-button cbi-button-reset', 'click': function(){ ui.hideModal(); } }, 'Отмена'),
				E('button', { 'class': 'cbi-button cbi-button-apply',
					'click': function(){
						var dev = dSel.value;
						if (!dev) return;
						ui.hideModal();
						self.runOp('restore_archive', dev, archiveName);
					}
				}, 'Восстановить')
			]);
			ui.showModal('Выбор цели', [ body, footer ]);
		}).catch(function(e){
			ui.addNotification(null, E('p', {}, 'Ошибка CGI: ' + String(e)), 'danger');
		});
	},

	showSettings: function() {
		var self = this;
		if (!self._canWrite) return;

		callGetSettings().then(function(res){
			var r = {};
			if (res) {
				res.split('\n').forEach(function(line) {
					var m = line.match(/^(\w+)=(.*)$/);
					if (m) r[m[1]] = m[2];
				});
			}
			
			var enVal   = String(r.autobackup_enabled == null ? '1' : r.autobackup_enabled);
			var manVal  = parseInt(r.manual_rotate, 10); if (isNaN(manVal)) manVal = 50;
			var autoVal = parseInt(r.auto_rotate, 10);   if (isNaN(autoVal)) autoVal = 30;

			var cbEn = E('input', { 'type': 'checkbox', 'checked': enVal === '1' ? true : null });
			var iMan = E('input', { 'type': 'number', 'min': '5', 'max': '50', 'value': String(manVal) });
			var iAuto= E('input', { 'type': 'number', 'min': '3', 'max': '20', 'value': String(autoVal) });

			var body = E('div', { 'class': 'usb-extroot-settings' }, [
				E('div', {}, [ cbEn, ' ', E('label', {}, 'Автобэкап при загрузке') ]),
				E('div', {}, [ E('label', {}, 'Ротация ручных (5–50): '), iMan ]),
				E('div', {}, [ E('label', {}, 'Ротация авто (3–20): '), iAuto ])
			]);
			var footer = E('div', { 'class': 'usb-extroot-modal-footer' }, [
				E('button', { 'class': 'cbi-button cbi-button-reset', 'click': function(){ ui.hideModal(); } }, 'Отмена'),
				E('button', { 'class': 'cbi-button cbi-button-apply',
					'click': function(){
						var m = parseInt(iMan.value, 10), a = parseInt(iAuto.value, 10);
						if (isNaN(m) || m < 5 || m > 50) { ui.addNotification(null, E('p', {}, 'Ротация ручных: 5–50'), 'danger'); return; }
						if (isNaN(a) || a < 3 || a > 20) { ui.addNotification(null, E('p', {}, 'Ротация авто: 3–20'), 'danger'); return; }
						cgiCall({ action: 'save-settings', autobackup_enabled: cbEn.checked ? '1' : '0', manual_rotate: m, auto_rotate: a, token: window._writeToken }).then(function(){
							ui.hideModal();
							ui.addNotification(null, E('p', {}, 'Сохранено.'), 'info');
						}).catch(function(err){
							ui.addNotification(null, E('p', {}, 'Ошибка: ' + err), 'danger');
						});
					}
				}, 'Сохранить')
			]);
			ui.showModal('Настройки USB extroot', [ body, footer ]);
		}).catch(function(e){
			ui.addNotification(null, E('p', {}, 'Ошибка CGI: ' + String(e)), 'danger');
		});
	}
});