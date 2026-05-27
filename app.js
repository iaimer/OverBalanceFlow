let currentTab = 'add';

function parseDuration(range, isLeave = false) {
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

    const overtimeThreshold = 18.0;
    if (!isLeave && end < overtimeThreshold) return 0;

    const workEnd = 17.0;
    const effectiveStart = isLeave ? start : Math.max(start, workEnd);
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

function withLoading(btn, fn) {
    const orig = btn.innerHTML;
    btn.disabled = true;
    btn.textContent = '处理中...';
    try { const r = fn(); if (r && r.finally) return r.finally(() => { btn.innerHTML = orig; btn.disabled = false; }); }
    finally { btn.innerHTML = orig; btn.disabled = false; }
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

async function handleOTSubmit(e) {
    e.preventDefault();
    const btn = document.getElementById('ot-submit');
    await withLoading(btn, async () => {
        const date = document.getElementById('ot-date').value;
        const start = document.getElementById('ot-start').value;
        const end = document.getElementById('ot-end').value;
        const range = `${start}-${end}`;
        const duration = parseDuration(range);
        if (duration <= 0) { showToast('时间无效或时长不满0.5h'); return; }

        const memo = document.getElementById('ot-memo').value;
        const { error } = await API.addOT({
            ot_date: date, start_time: start, end_time: end,
            duration, total_hours: duration, remaining_hours: duration, status: '待核销',
            memo: memo || ''
        });
        if (error) { showToast('录入失败: ' + error.message); return; }
        showToast('加班已记录');
        document.getElementById('ot-form').reset();
        document.getElementById('ot-date').value = new Date().toISOString().split('T')[0];
        document.getElementById('ot-start').value = '17:00';
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
    if (offHours <= 0) { showToast('时间段无效或时长太短'); return; }

    let allRecords = await API.fetchRecords();
    let inventory = allRecords
        .filter(r => r.remaining_hours > 0 && r.status !== '已调休')
        .sort((a, b) => {
            const d = parseDate(a.ot_date) - parseDate(b.ot_date);
            return d !== 0 ? d : (a.created_at || a.id) > (b.created_at || b.id) ? 1 : -1;
        });

    if (inventory.length === 0) { showToast('没有可用的加班余额'); return; }

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
        for (let d of data.deductedData) {
            const target = allRecords.find(r => r.id === d.id);
            if (!target) continue;
            const newRemaining = Math.round((target.remaining_hours - d.deduct) * 100) / 100;
            const originalDuration = target.duration || target.total_hours;
            const newStatus = newRemaining >= originalDuration ? '待核销' : (newRemaining <= 0 ? '已结清' : '部分核销');
            await API.updateRemaining(target.id, newRemaining, newStatus);
        }

        await API.addOT({
            ot_date: data.offDate,
            start_time: data.offRange.split('-')[0],
            end_time: data.offRange.split('-')[1],
            duration: -data.totalDeducted,
            total_hours: data.totalDeducted,
            remaining_hours: 0,
            status: '已调休',
            memo: JSON.stringify(data.deductedData.map(d => ({ id: d.id, deduct: d.deduct, info: d.info })))
        });

        document.getElementById('preview-modal').classList.remove('show');
        showToast(data.remainingToOff > 0.01
            ? `核销 ${data.totalDeducted.toFixed(1)}h，剩余 ${data.remainingToOff.toFixed(1)}h 余额不足`
            : `成功核销 ${data.totalDeducted.toFixed(1)}h`);
        document.getElementById('off-form').reset();
        document.getElementById('off-date').value = new Date().toISOString().split('T')[0];
        await initApp();
    } finally {
        btn.disabled = false;
        btn.textContent = '确认核销';
    }
}

window.handleDelete = async (id, status, memo) => {
    const isOffRecord = status === '已调休';
    const confirmMsg = isOffRecord
        ? '确定删除这条调休记录？加班时长将自动返还。'
        : '确定删除这条加班记录？';
    if (!confirm(confirmMsg)) return;

    const { error } = await API.deleteRecord(id);
    if (error) { showToast('删除失败: ' + error.message); return; }

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
                    await API.updateRemaining(target.id, restoredRemaining, newStatus);
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
        try { return JSON.parse(r.memo).some(d => d.id === otRecord.id); }
        catch (e) { return false; }
    });

    if (offRecords.length === 0) { showToast('该记录尚未被核销'); return; }

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
        return `<div class="recent-item">
            <div class="recent-item-left">
                <div class="recent-item-date">${r.ot_date}</div>
                <div class="recent-item-range">${r.start_time}-${r.end_time}</div>
            </div>
            <div class="recent-item-right">
                <span class="recent-item-hours">${r.duration.toFixed(1)}h</span>
                <span class="tag ${isDone ? 'tag-done' : (r.status === '部分核销' ? 'tag-partial' : 'tag-pending')}">${statusLabel}</span>
            </div>
        </div>`;
    }).join('');
}

// === RENDERING ===

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

        let memoHtml = '';
        if (isOff && record.memo) {
            try {
                const data = JSON.parse(record.memo);
                memoHtml = `<div class="record-item-memo">${data.map(d => `${d.info} 扣 ${d.deduct}h`).join('\n')}</div>`;
            } catch (e) { memoHtml = `<div class="record-item-memo">${escapeHtml(record.memo)}</div>`; }
        } else if (!isOff && record.memo) {
            memoHtml = `<div class="record-item-memo">${escapeHtml(record.memo)}</div>`;
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
            ${memoHtml}
            <div class="record-item-actions">
                ${!isOff ? `<button data-info-btn class="btn-ghost" style="font-size:12px;padding:4px 8px">详情</button>` : ''}
                <button data-delete-btn class="btn-ghost" style="font-size:12px;padding:4px 8px;color:#dc2626">删除</button>
            </div>
        `;
        container.appendChild(item);

        const delBtn = item.querySelector('[data-delete-btn]');
        delBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            handleDelete(record.id, record.status, record.memo || '');
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
    const totalOT = records.filter(r => r.status !== '已调休').reduce((s, r) => s + (r.duration || r.total_hours || 0), 0);
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

    document.getElementById('preview-cancel').addEventListener('click', () => {
        document.getElementById('preview-modal').classList.remove('show');
        window._pendingReconcile = null;
    });
    document.getElementById('preview-confirm').addEventListener('click', executeReconciliation);

    window.addEventListener('online', updateSyncStatus);
    window.addEventListener('offline', updateSyncStatus);

    initApp();
});
