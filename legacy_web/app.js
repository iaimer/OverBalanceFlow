let currentTab = 'add';
let otPhotoFile = null;
let otPhotoPreviewUrl = '';
let activeRecordPhotoUrls = [];

function parseDuration(range, isLeave = false, isWeekend = false) {
    if (!range || !range.includes('-')) return 0;
    const parts = range.split('-');
    if (parts.length !== 2) return 0;

    const [start, end] = parts.map(t => {
        if (t === '23:59') return 24.0;
        const h_m = t.split(':');
        if (h_m.length !== 2) return 0;
        const [h, m] = h_m.map(Number);
        return h + m / 60;
    });

    if (start >= end) return 0;

    const skipRules = isLeave || isWeekend;
    const overtimeThreshold = 18.0;
    if (!skipRules && end < overtimeThreshold) return 0;

    const workEnd = 17.0;
    const effectiveStart = skipRules ? start : Math.max(start, workEnd);
    let rawDuration = end - effectiveStart;

    const lunchStart = 11.5;
    const lunchEnd = 12.0;
    const overlapStart = Math.max(effectiveStart, lunchStart);
    const overlapEnd = Math.min(end, lunchEnd);
    const overlap = Math.max(0, overlapEnd - overlapStart);
    rawDuration -= overlap;

    if (rawDuration <= 0) return 0;
    return Math.max(0.5, Math.floor(rawDuration / 0.5) * 0.5);
}

function escapeHtml(str) {
    const el = document.createElement('div');
    el.textContent = str;
    return el.innerHTML;
}

function parseDate(str) {
    if (!str) return new Date(0);
    const parts = str.split('-');
    if (parts.length !== 3) return new Date(0);
    const [y, m, d] = parts.map(Number);
    if (isNaN(y) || isNaN(m) || isNaN(d)) return new Date(0);
    return new Date(y, m - 1, d);
}

const HOLIDAYS = {
    '2026-01-01': true, '2026-01-02': true, '2026-01-03': true,
    '2026-02-16': true, '2026-02-17': true, '2026-02-18': true,
    '2026-02-19': true, '2026-02-20': true, '2026-02-21': true, '2026-02-22': true,
    '2026-04-04': true, '2026-04-05': true, '2026-04-06': true,
    '2026-05-01': true, '2026-05-02': true, '2026-05-03': true, '2026-05-04': true, '2026-05-05': true,
    '2026-06-19': true, '2026-06-20': true, '2026-06-21': true,
    '2026-09-27': true, '2026-09-28': true, '2026-09-29': true, '2026-09-30': true,
    '2026-10-01': true, '2026-10-02': true, '2026-10-03': true, '2026-10-04': true,
    '2026-01-04': false, '2026-02-14': false, '2026-02-15': false,
    '2026-05-09': false, '2026-10-10': false,
};

function isWeekendDate(dateStr) {
    if (!dateStr) return false;
    const parts = dateStr.split('-');
    if (parts.length !== 3) return false;
    const [y, m, d] = parts.map(Number);
    if (isNaN(y) || isNaN(m) || isNaN(d)) return false;
    return new Date(y, m - 1, d).getDay() % 6 === 0;
}

function checkHoliday(dateStr) {
    if (HOLIDAYS[dateStr] !== undefined) return HOLIDAYS[dateStr];
    return isWeekendDate(dateStr);
}

function withLoading(btn, fn) {
    const orig = btn.innerHTML;
    btn.disabled = true;
    btn.textContent = '处理中...';

    const restore = () => {
        btn.innerHTML = orig;
        btn.disabled = false;
    };

    try {
        const result = fn();
        if (result && typeof result.finally === 'function') {
            return result.finally(restore);
        }
        restore();
        return result;
    } catch (error) {
        restore();
        throw error;
    }
}

function showToast(msg) {
    const el = document.getElementById('toast');
    el.textContent = msg;
    el.classList.add('show');
    clearTimeout(el._hide);
    el._hide = setTimeout(() => el.classList.remove('show'), 2500);
}

function updateSyncStatus() {
    const dot = document.getElementById('sync-status');
    dot.className = navigator.onLine ? 'online' : 'offline';
    const banner = document.getElementById('offline-banner');
    banner.classList.toggle('visible', !navigator.onLine);
}

function revokeOtPhotoPreview() {
    if (otPhotoPreviewUrl) {
        URL.revokeObjectURL(otPhotoPreviewUrl);
        otPhotoPreviewUrl = '';
    }
}

function updateOtPhotoPanel() {
    const panel = document.getElementById('ot-photo-panel');
    const preview = document.getElementById('ot-photo-preview');
    if (!panel || !preview) return;

    if (!otPhotoFile || !otPhotoPreviewUrl) {
        panel.hidden = true;
        preview.removeAttribute('src');
        return;
    }

    preview.src = otPhotoPreviewUrl;
    panel.hidden = false;
}

function clearOtPhotoSelection(resetInput = true) {
    otPhotoFile = null;
    revokeOtPhotoPreview();
    if (resetInput) document.getElementById('ot-photo').value = '';
    updateOtPhotoPanel();
}

function handleOtPhotoChange(event) {
    const file = event.target.files && event.target.files[0];
    if (!file) {
        clearOtPhotoSelection(false);
        return;
    }

    otPhotoFile = file;
    revokeOtPhotoPreview();
    otPhotoPreviewUrl = URL.createObjectURL(file);
    updateOtPhotoPanel();
}

function revokeActiveRecordPhotoUrls() {
    activeRecordPhotoUrls.forEach((url) => {
        if (url.startsWith('blob:')) URL.revokeObjectURL(url);
    });
    activeRecordPhotoUrls = [];
}

function trackActiveRecordPhotoUrls(records) {
    revokeActiveRecordPhotoUrls();
    activeRecordPhotoUrls = records
        .map((record) => record.photo_url)
        .filter((url) => typeof url === 'string' && url.startsWith('blob:'));
}

function openPhotoModal(photoUrl) {
    if (!photoUrl) return;
    document.getElementById('photo-modal-image').src = photoUrl;
    document.getElementById('photo-modal').classList.add('show');
}

function closePhotoModal() {
    document.getElementById('photo-modal').classList.remove('show');
    document.getElementById('photo-modal-image').removeAttribute('src');
}

function readFileAsDataUrl(file) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(reader.error || new Error('读取图片失败'));
        reader.readAsDataURL(file);
    });
}

function loadImage(src) {
    return new Promise((resolve, reject) => {
        const img = new Image();
        img.onload = () => resolve(img);
        img.onerror = () => reject(new Error('图片加载失败'));
        img.src = src;
    });
}

async function compressPhoto(file) {
    if (!file) return null;

    const src = await readFileAsDataUrl(file);
    const image = await loadImage(src);
    const maxSide = 1600;
    const scale = Math.min(1, maxSide / Math.max(image.width, image.height));
    const width = Math.max(1, Math.round(image.width * scale));
    const height = Math.max(1, Math.round(image.height * scale));

    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext('2d');
    if (!ctx) throw new Error('无法处理图片');
    ctx.drawImage(image, 0, 0, width, height);

    const blob = await new Promise((resolve, reject) => {
        canvas.toBlob((result) => {
            if (!result) {
                reject(new Error('图片压缩失败'));
                return;
            }
            resolve(result);
        }, 'image/jpeg', 0.82);
    });

    return blob;
}

function resetOtForm() {
    document.getElementById('ot-form').reset();
    document.getElementById('ot-date').value = new Date().toISOString().split('T')[0];
    document.getElementById('ot-start').value = '17:00';
    clearOtPhotoSelection();
}

async function handleOTSubmit(e) {
    e.preventDefault();
    const btn = document.getElementById('ot-submit');
    await withLoading(btn, async () => {
        const date = document.getElementById('ot-date').value;
        const start = document.getElementById('ot-start').value;
        const end = document.getElementById('ot-end').value;
        const range = `${start}-${end}`;
        const isHoliday = checkHoliday(date);
        const duration = parseDuration(range, false, isHoliday);
        if (duration <= 0) {
            showToast('时间无效或时长不满0.5h');
            return;
        }

        let photoBlob = null;
        if (otPhotoFile) {
            try {
                photoBlob = await compressPhoto(otPhotoFile);
            } catch (error) {
                showToast(error.message || '照片处理失败');
                return;
            }
        }

        const memo = document.getElementById('ot-memo').value;
        const { error } = await API.addOT({
            ot_date: date,
            start_time: start,
            end_time: end,
            duration,
            total_hours: duration,
            remaining_hours: duration,
            status: '待核销',
            memo: memo || '',
            photo_path: null
        }, { photoBlob });

        if (error) {
            showToast('录入失败: ' + error.message);
            return;
        }

        showToast(photoBlob ? '加班和打卡照片已记录' : '加班已记录');
        resetOtForm();
        await initApp();
    });
}

async function handleReconcileSubmit(e) {
    e.preventDefault();
    const offDate = document.getElementById('off-date').value;
    const start = document.getElementById('off-start').value;
    const end = document.getElementById('off-end').value;
    const offRange = `${start}-${end}`;
    const offHours = parseDuration(offRange, true);
    if (offHours <= 0) {
        showToast('时间段无效或时长太短');
        return;
    }

    let allRecords = await API.fetchRecords();
    let inventory = allRecords
        .filter(r => r.remaining_hours > 0 && r.status !== '已调休')
        .sort((a, b) => {
            const d = parseDate(a.ot_date) - parseDate(b.ot_date);
            return d !== 0 ? d : (a.created_at || a.id) > (b.created_at || b.id) ? 1 : -1;
        });

    if (inventory.length === 0) {
        showToast('没有可用的加班余额');
        return;
    }

    let remainingToOff = offHours;
    let totalDeducted = 0;
    let deductedData = [];

    for (let record of inventory) {
        if (remainingToOff <= 0) break;
        let deduct = Math.min(record.remaining_hours, remainingToOff);
        remainingToOff -= deduct;
        totalDeducted += deduct;
        deductedData.push({
            id: record.id,
            deduct: Math.round(deduct * 100) / 100,
            info: `${record.ot_date}(${record.start_time}-${record.end_time}) 余额:${record.remaining_hours.toFixed(1)}h`
        });
    }

    window._pendingReconcile = { offDate, offRange, deductedData, totalDeducted, offHours, remainingToOff };
    renderPreviewModal(window._pendingReconcile);
}

function renderPreviewModal(data) {
    const body = document.getElementById('preview-body');
    let html = `<div style="margin-bottom:8px;font-size:14px;font-weight:600">核销确认</div>`;
    html += `<p class="help-text" style="margin-bottom:10px">调休 ${data.offDate} ${data.offRange}（共 ${data.totalDeducted.toFixed(1)}h）</p>`;
    html += `<div class="section-title">扣减明细</div>`;

    if (data.deductedData.length === 0) {
        html += `<p class="help-text warning">没有可用余额</p>`;
    } else {
        data.deductedData.forEach(d => {
            html += `<div class="inventory-item"><span>${escapeHtml(d.info)}</span><span style="font-weight:600;font-size:13px">-${d.deduct.toFixed(1)}h</span></div>`;
        });
    }

    if (data.remainingToOff > 0.01) {
        html += `<p class="help-text warning" style="margin-top:10px">余额不足，尚有 ${data.remainingToOff.toFixed(1)}h 未抵扣，需补加班</p>`;
    }

    body.innerHTML = html;
    document.getElementById('preview-modal').classList.add('show');
}

async function executeReconciliation() {
    const data = window._pendingReconcile;
    if (!data) return;
    window._pendingReconcile = null;

    const btn = document.getElementById('preview-confirm');
    btn.disabled = true;
    btn.textContent = '执行中...';

    try {
        let allRecords = await API.fetchRecords();
        const stalePreview = data.deductedData.some(d => {
            const target = allRecords.find(r => r.id === d.id);
            return !target || target.remaining_hours < d.deduct;
        });
        if (stalePreview) {
            document.getElementById('preview-modal').classList.remove('show');
            showToast('余额已变化，请重新预览核销');
            await initApp();
            return;
        }

        for (let d of data.deductedData) {
            const target = allRecords.find(r => r.id === d.id);
            const newRemaining = Math.round((target.remaining_hours - d.deduct) * 100) / 100;
            const originalDuration = target.duration || target.total_hours;
            const newStatus = newRemaining >= originalDuration ? '待核销' : (newRemaining <= 0 ? '已结清' : '部分核销');
            const { error } = await API.updateRemaining(target.id, newRemaining, newStatus);
            if (error) throw error;
        }

        const { error } = await API.addOT({
            ot_date: data.offDate,
            start_time: data.offRange.split('-')[0],
            end_time: data.offRange.split('-')[1],
            duration: -data.totalDeducted,
            total_hours: -data.totalDeducted,
            remaining_hours: 0,
            status: '已调休',
            memo: JSON.stringify(data.deductedData.map(d => ({ id: d.id, deduct: d.deduct, info: d.info }))),
            photo_path: null
        });
        if (error) throw error;

        document.getElementById('preview-modal').classList.remove('show');
        showToast(data.remainingToOff > 0.01
            ? `核销 ${data.totalDeducted.toFixed(1)}h，剩余 ${data.remainingToOff.toFixed(1)}h 余额不足`
            : `成功核销 ${data.totalDeducted.toFixed(1)}h`);
        document.getElementById('off-form').reset();
        document.getElementById('off-date').value = new Date().toISOString().split('T')[0];
        await initApp();
    } catch (error) {
        console.error('Reconciliation error:', error);
        showToast('核销失败: ' + error.message);
        await initApp();
    } finally {
        btn.disabled = false;
        btn.textContent = '确认核销';
    }
}

window.handleDelete = async (id, status, memo, photoPath) => {
    const isOffRecord = status === '已调休';
    const confirmMsg = isOffRecord
        ? '确定删除这条调休记录？加班时长将自动返还。'
        : '确定删除这条加班记录？';
    if (!confirm(confirmMsg)) return;

    const { error } = await API.deleteRecord(id);
    if (error) {
        showToast('删除失败: ' + error.message);
        return;
    }

    if (!isOffRecord && photoPath) {
        const cleanup = await API.deletePhoto(photoPath);
        if (cleanup.error) {
            console.warn('Photo cleanup failed:', photoPath, cleanup.error);
            showToast('记录已删除，但图片清理失败，请稍后重试');
        } else if (cleanup.queued) {
            showToast('记录已删除，图片将在网络恢复后自动清理');
        }
    }

    if (isOffRecord && memo) {
        try {
            const data = JSON.parse(memo);
            const allRecords = await API.fetchRecords();
            for (let item of data) {
                const target = allRecords.find(r => r.id === item.id);
                if (target) {
                    const restoredRemaining = Math.round((target.remaining_hours + item.deduct) * 100) / 100;
                    const originalDuration = target.duration || target.total_hours;
                    const newStatus = restoredRemaining >= originalDuration ? '待核销' : '部分核销';
                    const { error } = await API.updateRemaining(target.id, restoredRemaining, newStatus);
                    if (error) throw error;
                }
            }
        } catch (e) {
            console.error('Undo error:', e);
            showToast('记录已删除，但无法自动返还时长');
        }
    }

    await initApp();
};

window.showOTHistory = (otRecord, allRecords) => {
    const offRecords = allRecords.filter(r => {
        if (r.status !== '已调休' || !r.memo) return false;
        try {
            return JSON.parse(r.memo).some(d => d.id === otRecord.id);
        } catch (e) {
            return false;
        }
    });

    if (offRecords.length === 0) {
        showToast('该记录尚未被核销');
        return;
    }

    let text = `${otRecord.ot_date} (${otRecord.start_time}-${otRecord.end_time})\n`;
    text += `原始 ${otRecord.duration || otRecord.total_hours}h，余额 ${otRecord.remaining_hours}h\n`;
    text += `--- 核销历史 ---\n`;
    offRecords.forEach(off => {
        const detail = JSON.parse(off.memo).find(d => d.id === otRecord.id);
        text += `${off.ot_date} 调休扣减 ${detail.deduct}h\n`;
    });
    alert(text);
};

function renderRecentRecords(records) {
    const container = document.getElementById('recent-list');
    const sorted = records
        .filter(r => r.status !== '已调休')
        .sort((a, b) => parseDate(b.ot_date) - parseDate(a.ot_date) || b.created_at?.localeCompare(a.created_at) || 0);
    const recent = sorted.slice(0, 2);

    if (recent.length === 0) {
        container.innerHTML = '<p class="help-text" style="text-align:center;margin-top:8px">还没有加班记录</p>';
        return;
    }

    container.innerHTML = recent.map(r => {
        const isDone = r.remaining_hours <= 0;
        const statusLabel = isDone ? '已结清' : (r.status === '部分核销' ? '部分核销' : '待核销');
        const photoTag = r.photo_path || r.pending_photo_id
            ? '<span class="tag tag-photo">有打卡照</span>'
            : '';

        return `<div class="recent-item">
            <div class="recent-item-left">
                <div class="recent-item-date">${r.ot_date}</div>
                <div class="recent-item-range">${r.start_time}-${r.end_time}</div>
            </div>
            <div class="recent-item-right">
                ${photoTag}
                <span class="recent-item-hours">${Number(r.duration).toFixed(1)}h</span>
                <span class="tag ${isDone ? 'tag-done' : (r.status === '部分核销' ? 'tag-partial' : 'tag-pending')}">${statusLabel}</span>
            </div>
        </div>`;
    }).join('');
}

function renderPhotoCard(record) {
    if (!(record.photo_url || record.photo_path || record.pending_photo_id)) return null;

    const card = document.createElement(record.photo_url ? 'button' : 'div');
    card.className = 'record-photo-card';
    if (card.tagName === 'BUTTON') card.type = 'button';

    const thumb = document.createElement('img');
    thumb.className = 'record-photo-thumb';
    thumb.alt = '打卡照片';
    if (record.photo_url) thumb.src = record.photo_url;

    const meta = document.createElement('div');
    meta.className = 'record-photo-meta';

    const label = document.createElement('span');
    label.className = 'record-photo-label';
    label.textContent = record.pending_photo_id ? '打卡照片待同步' : '打卡照片';

    const action = document.createElement('span');
    action.className = 'record-photo-action';
    action.textContent = record.photo_url ? '点击查看' : '等待同步';

    meta.appendChild(label);
    meta.appendChild(action);
    card.appendChild(thumb);
    card.appendChild(meta);

    if (record.photo_url) {
        card.addEventListener('click', () => openPhotoModal(record.photo_url));
    }

    return card;
}

function renderReconcileView(records) {
    const container = document.getElementById('reconcile-inventory');
    const inventory = records.filter(r => r.remaining_hours > 0 && r.status !== '已调休');
    const totalRemaining = inventory.reduce((s, r) => s + r.remaining_hours, 0);

    if (inventory.length === 0) {
        container.innerHTML = `<div class="empty-state"><svg fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg><p>暂无可用加班余额</p></div>`;
        return;
    }

    let html = `<div style="margin-bottom:10px"><span class="section-title">可用余额</span> <span style="font-weight:600;font-size:20px">${totalRemaining.toFixed(1)}</span><span style="font-size:12px;color:#a8a29e">h</span></div>`;
    inventory.slice(0, 5).forEach(r => {
        html += `<div class="inventory-item"><span>${r.ot_date} (${r.start_time}-${r.end_time})</span><span style="font-size:12px;color:#78716c">余 ${r.remaining_hours.toFixed(1)}h</span></div>`;
    });
    if (inventory.length > 5) {
        html += `<p class="help-text" style="margin-top:4px">...还有 ${inventory.length - 5} 笔</p>`;
    }
    container.innerHTML = html;
}

function renderListView(records) {
    const container = document.getElementById('record-list-full');
    container.innerHTML = '';
    let filtered = records.filter(r => r.status !== '已调休').concat(records.filter(r => r.status === '已调休'));
    filtered.sort((a, b) => parseDate(b.ot_date) - parseDate(a.ot_date));

    if (filtered.length === 0) {
        container.innerHTML = `<div class="empty-state"><svg fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"/></svg><p>还没有记录<br><span style="font-size:12px">先去「记加班」添加第一笔吧</span></p></div>`;
        return;
    }

    filtered.forEach(record => {
        const item = document.createElement('div');
        item.className = 'record-item';
        const isOff = record.status === '已调休';
        const isDone = record.remaining_hours <= 0;

        let statusTag = '';
        if (isOff) statusTag = `<span class="tag tag-off">已调休</span>`;
        else if (isDone) statusTag = `<span class="tag tag-done">已结清</span>`;
        else if (record.status === '部分核销') statusTag = `<span class="tag tag-partial">部分核销</span>`;
        else statusTag = `<span class="tag tag-pending">待核销</span>`;

        let durClass = isOff ? 'negative' : (isDone ? 'zero' : 'positive');
        let durText = isOff ? `-${(-record.duration).toFixed(1)}h` : `${record.remaining_hours.toFixed(1)}h`;

        let memoText = '';
        if (isOff && record.memo) {
            try {
                const data = JSON.parse(record.memo);
                memoText = data.map(d => `${d.info} 扣 ${d.deduct}h`).join('\n');
            } catch (e) {
                memoText = record.memo;
            }
        } else if (!isOff && record.memo) {
            memoText = record.memo;
        }

        item.innerHTML = `
            <div class="record-item-header">
                <div style="display:flex;align-items:center;gap:8px">
                    <span class="record-item-date">${record.ot_date}</span>
                    ${statusTag}
                </div>
                <span class="record-item-duration ${durClass}">${durText}</span>
            </div>
            <div class="record-item-time">${record.start_time} - ${record.end_time}</div>
            <div class="record-item-actions">
                ${!isOff ? `<button data-info-btn class="btn-ghost" style="font-size:12px;padding:4px 8px">详情</button>` : ''}
                <button data-delete-btn class="btn-ghost" style="font-size:12px;padding:4px 8px;color:#dc2626">删除</button>
            </div>
        `;
        container.appendChild(item);

        const photoCard = !isOff ? renderPhotoCard(record) : null;
        if (photoCard) {
            item.querySelector('.record-item-actions').before(photoCard);
        }

        if (memoText) {
            const memo = document.createElement('div');
            memo.className = 'record-item-memo';
            memo.textContent = memoText;
            item.querySelector('.record-item-actions').before(memo);
        }

        const delBtn = item.querySelector('[data-delete-btn]');
        delBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            handleDelete(record.id, record.status, record.memo || '', record.photo_path || '');
        });

        const infoBtn = item.querySelector('[data-info-btn]');
        if (infoBtn) {
            infoBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                showOTHistory(record, records);
            });
        }
    });
}

function renderStatsView(records) {
    const totalOT = records.filter(r => r.status !== '已调休').reduce((s, r) => s + (Number(r.duration) || Number(r.total_hours) || 0), 0);
    const totalRemaining = records.filter(r => r.status !== '已调休').reduce((s, r) => s + r.remaining_hours, 0);
    const totalUsed = records.filter(r => r.status === '已调休').reduce((s, r) => s + (-r.duration || 0), 0);
    const otCount = records.filter(r => r.status !== '已调休').length;
    const offCount = records.filter(r => r.status === '已调休').length;

    const container = document.getElementById('stats-container');
    container.innerHTML = `
        <div class="stats-card">
            <div class="stats-label">可用调休余额</div>
            <div class="stats-number">${totalRemaining.toFixed(1)}</div>
        </div>
        <div class="stats-cards">
            <div class="stats-card-mini"><div class="num ot-color">${totalOT.toFixed(1)}</div><div class="label">已记加班</div></div>
            <div class="stats-card-mini"><div class="num leave-color">${totalUsed.toFixed(1)}</div><div class="label">已用调休</div></div>
            <div class="stats-card-mini"><div class="num">${otCount}</div><div class="label">加班次数</div></div>
            <div class="stats-card-mini"><div class="num">${offCount}</div><div class="label">调休次数</div></div>
        </div>
    `;
}

function switchTab(tab) {
    currentTab = tab;
    document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
    document.getElementById(`view-${tab}`).classList.add('active');
    document.querySelectorAll('#tab-bar .tab').forEach(t => t.classList.toggle('active', t.dataset.tab === tab));
}

async function initApp() {
    await API.syncPendingOps();
    updateSyncStatus();
    const records = await API.fetchRecords();
    trackActiveRecordPhotoUrls(records);

    renderRecentRecords(records);
    renderReconcileView(records);
    renderListView(records);
    renderStatsView(records);
}

document.addEventListener('DOMContentLoaded', () => {
    document.getElementById('ot-date').value = new Date().toISOString().split('T')[0];
    document.getElementById('off-date').value = new Date().toISOString().split('T')[0];

    document.querySelectorAll('#tab-bar .tab').forEach(tab => {
        tab.addEventListener('click', () => switchTab(tab.dataset.tab));
    });

    document.getElementById('ot-form').addEventListener('submit', handleOTSubmit);
    document.getElementById('off-form').addEventListener('submit', handleReconcileSubmit);

    document.getElementById('ot-photo').addEventListener('change', handleOtPhotoChange);
    document.getElementById('ot-photo-reselect').addEventListener('click', () => {
        document.getElementById('ot-photo').click();
    });
    document.getElementById('ot-photo-clear').addEventListener('click', () => clearOtPhotoSelection());

    document.getElementById('preview-cancel').addEventListener('click', () => {
        document.getElementById('preview-modal').classList.remove('show');
        window._pendingReconcile = null;
    });
    document.getElementById('preview-confirm').addEventListener('click', executeReconciliation);

    document.getElementById('photo-modal-close').addEventListener('click', closePhotoModal);
    document.getElementById('photo-modal').addEventListener('click', (event) => {
        if (event.target.id === 'photo-modal') closePhotoModal();
    });

    window.addEventListener('online', updateSyncStatus);
    window.addEventListener('offline', updateSyncStatus);
    window.addEventListener('beforeunload', () => {
        revokeOtPhotoPreview();
        revokeActiveRecordPhotoUrls();
    });

    initApp();
});
