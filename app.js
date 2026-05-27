let currentTab = 'ot'; // 全局状态：当前所在的标签页

// 核心逻辑：多对多 FIFO 核销算法
async function handleReconciliation(offDate, offRange) {
    const offHours = parseDuration(offRange, true); // isLeave=true，跳过18:00限制
    if (offHours <= 0) return alert('时间段无效或时长太短');

    // 1. 获取所有有余额的记录，按日期升序（先加班的先休）
    let allRecords = await API.fetchRecords();
    let inventory = allRecords
        .filter(r => r.remaining_hours > 0 && r.status !== '已调休')
        .sort((a, b) => {
            const dateDiff = parseDate(a.ot_date) - parseDate(b.ot_date);
            if (dateDiff !== 0) return dateDiff;
            // 如果日期相同，按创建时间或 ID 升序排序（保证真正的 FIFO）
            return (a.created_at || a.id) > (b.created_at || b.id) ? 1 : -1;
        });

    if (inventory.length === 0) return alert('没有可用的加班余额');

    let remainingToOff = offHours;
    let totalDeducted = 0;
    let deductedData = []; // 结构化记录：{id, deduct, info}

    for (let record of inventory) {
        if (remainingToOff <= 0) break;

        let deduct = Math.min(record.remaining_hours, remainingToOff);
        let newRemaining = record.remaining_hours - deduct;
        // fix precision issues
        newRemaining = Math.round(newRemaining * 100) / 100;

        remainingToOff -= deduct;
        totalDeducted += deduct;

        let status = newRemaining <= 0 ? '已结清' : '部分核销';
        deductedData.push({
            id: record.id,
            deduct: deduct,
            info: `${record.ot_date}(${record.start_time}-${record.end_time})`
        });

        // 执行云端更新
        await API.updateRemaining(record.id, newRemaining, status);
    }

    // 2. 插入一条"调休记录"作为存根，方便后续查询已调休明细
    if (totalDeducted > 0) {
        await API.addOT({
            ot_date: offDate,
            start_time: offRange.split('-')[0],
            end_time: offRange.split('-')[1],
            duration: -totalDeducted, // 用负数或特定标记
            total_hours: totalDeducted,
            remaining_hours: 0,
            status: '已调休',
            // 存入结构化数据，用于后续删除时的"返还"逻辑
            memo: JSON.stringify(deductedData)
        });
    }

    if (remainingToOff > 0) {
        alert(`核销完成，成功扣减 ${totalDeducted.toFixed(1)}h。但仍有 ${remainingToOff.toFixed(1)}h 因余额不足未抵扣。`);
    } else {
        alert(`成功核销 ${totalDeducted} 小时`);
    }

    // 重新渲染页面
    await initApp();
}

// 辅助函数：解析 18:00-20:00 这种格式
// isLeave: 是否为调休计算，调休不受18:00限制
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

    // 业务规则：加班结束时间必须超过18:00才算加班（调休不受此限制）
    // 17:00~17:59不算加班时间，只有加班到18:00后，17:00~18:00才记作1h
    const overtimeThreshold = 18.0; // 18:00
    if (!isLeave && end < overtimeThreshold) return 0;

    // 计算原始时长
    let rawDuration = end - start;

    // 午休逻辑：8:30~11:30 和 12:00~17:00
    // 如果时间段跨越了 11:30~12:00，扣除这 0.5 小时
    const lunchStart = 11.5; // 11:30
    const lunchEnd = 12.0;   // 12:00

    // 计算交叉部分的长度
    const overlapStart = Math.max(start, lunchStart);
    const overlapEnd = Math.min(end, lunchEnd);
    const overlap = Math.max(0, overlapEnd - overlapStart);

    rawDuration -= overlap;

    // 逻辑：向下取整到0.5小时，但最小记为0.5小时
    // 例如：0-0.5h记0.5h，0.51-0.99h记0.5h，1.01-1.49h记1h，1.50-1.99h记1.5h
    if (rawDuration <= 0) return 0;
    return Math.max(0.5, Math.floor(rawDuration / 0.5) * 0.5);
}

// 渲染统计信息的函数
function renderStats(records) {
    // 过滤掉调休存根记录来计算余额
    const totalRemaining = records
        .filter(r => r.status !== '已调休')
        .reduce((sum, r) => sum + r.remaining_hours, 0);

    const container = document.getElementById('stats-container');

    // 简单的统计展示
    container.innerHTML = `
        <div class="bg-indigo-600 text-white rounded-xl p-6 shadow-lg">
            <h2 class="text-indigo-100 text-sm mb-1">当前可用调休余额</h2>
            <div class="text-4xl font-bold mb-4">${totalRemaining.toFixed(1)} <span class="text-lg font-normal">小时</span></div>
            <div class="flex gap-4 text-xs opacity-80">
                <div>总加班记录: ${records.filter(r => r.status !== '已调休').length}</div>
                <div>已核销次数: ${records.filter(r => r.status === '已调休').length}</div>
            </div>
        </div>
        ${!navigator.onLine ? `<div class="mt-2 text-xs text-orange-700 bg-orange-50 p-2 rounded">离线模式：操作已缓存，恢复网络后自动同步</div>` : ''}
    `;
}

// 渲染列表
function renderList(records) {
    // 1. 渲染主页预览列表 (只取前2条)
    const previewContainer = document.getElementById('record-list-preview');
    if (previewContainer) {
        renderListContainer(records, previewContainer, true);
    }

    // 2. 渲染历史页完整列表
    const fullContainer = document.getElementById('record-list-full');
    if (fullContainer) {
        renderListContainer(records, fullContainer, false);
    }

    // 更新历史页标题
    const historyTitle = document.getElementById('history-title');
    if (historyTitle) {
        historyTitle.innerText = currentTab === 'ot' ? '全部加班明细' : '全部调休记录';
    }
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

async function withLoading(btn, fn) {
    const orig = btn.innerHTML;
    btn.disabled = true;
    btn.textContent = '处理中...';
    try { await fn(); }
    finally { btn.innerHTML = orig; btn.disabled = false; }
}

// 核心渲染逻辑提取 (复用)
function renderListContainer(allRecords, container, isPreview) {
    container.innerHTML = '';

    // 根据 Tab 过滤
    let filteredRecords = [];
    if (currentTab === 'ot') {
        filteredRecords = allRecords.filter(r => r.status !== '已调休');
    } else {
        filteredRecords = allRecords.filter(r => r.status === '已调休');
    }

    // 排序：默认按日期倒序 (最新的在最前)
    filteredRecords.sort((a, b) => parseDate(b.ot_date) - parseDate(a.ot_date));

    // 如果是预览模式，只取前2条
    if (isPreview) {
        filteredRecords = filteredRecords.slice(0, 2);
    }

    if (filteredRecords.length === 0) {
        container.innerHTML = `<div class="text-center py-10 text-gray-400 text-sm">暂无数据</div>`;
        return;
    }

    filteredRecords.forEach(record => {
        const item = document.createElement('div');
        const isOffRecord = record.status === '已调休';

        const interactiveClass = !isOffRecord ? 'cursor-pointer hover:bg-gray-50 active:scale-95' : '';
        item.className = `group bg-white p-3 rounded-lg shadow-sm border border-gray-100 flex justify-between items-start transition-all hover:border-indigo-100 ${interactiveClass}`;

        if (!isOffRecord) {
            item.onclick = (e) => {
                if (e.target.closest('button')) return;
                showOTHistory(record, allRecords);
            };
        }

        const isDone = record.remaining_hours <= 0;
        const statusClass = isOffRecord ? 'bg-orange-100 text-orange-700' : (isDone ? 'status-done' : 'status-pending');

        let displayMemo = '';
        if (isOffRecord && record.memo) {
            // 调休记录：解析 JSON
            try {
                const data = JSON.parse(record.memo);
                displayMemo = data.map(d => `${d.info} 扣减 ${d.deduct}h`).join('\n');
            } catch (e) { displayMemo = record.memo; }
        } else if (!isOffRecord && record.memo) {
            // 加班记录：直接显示事由
            displayMemo = record.memo;
        }

        item.innerHTML = `
            <div class="flex-1">
                <div class="flex items-center gap-2">
                    <div class="font-medium text-gray-800">${record.ot_date}</div>
                    <div class="status-tag ${statusClass}">${record.status}</div>
                </div>
                <div class="text-xs text-gray-400 mt-1">${record.start_time} - ${record.end_time}</div>
                ${displayMemo ? `<div class="text-[11px] text-gray-500 bg-gray-50 p-2 mt-2 rounded border-l-2 ${isOffRecord ? 'border-orange-200' : 'border-indigo-200'} whitespace-pre-line">${escapeHtml(displayMemo)}</div>` : ''}
                ${!isOffRecord && (record.status === '部分核销' || record.status === '已结清') ? `<div class="text-[10px] text-indigo-400 mt-2 flex items-center gap-1"><svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" /></svg>点击查看核销明细</div>` : ''}
            </div>
            <div class="text-right flex flex-col items-end gap-2">
                <div class="text-sm font-bold ${isOffRecord ? 'text-orange-600' : (isDone ? 'text-gray-300' : 'text-indigo-600')}">
                    ${isOffRecord ? '-' + (-record.duration) : '余 ' + record.remaining_hours}h
                </div>
                <button data-delete-btn class="text-gray-300 hover:text-red-500 transition-colors p-1 opacity-0 group-hover:opacity-100">
                    <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
                    </svg>
                </button>
            </div>
        `;
        container.appendChild(item);

        const delBtn = item.querySelector('[data-delete-btn]');
        if (delBtn) {
            delBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                delBtn.disabled = true;
                handleDelete(record.id, record.status, record.memo || '').finally(() => { delBtn.disabled = false; });
            });
        }
    });
}

// 显示加班记录的核销历史（反向查找）
window.showOTHistory = (otRecord, allRecords) => {
    // 寻找所有 memo 中包含当前 OT ID 的调休记录
    const offRecords = allRecords.filter(r => {
        if (r.status !== '已调休' || !r.memo) return false;
        try {
            const memoData = JSON.parse(r.memo);
            return memoData.some(d => d.id === otRecord.id);
        } catch (e) {
            return false;
        }
    });

    if (offRecords.length === 0) {
        return alert('该记录尚未被核销。');
    }

    let historyText = `加班记录: ${otRecord.ot_date} (${otRecord.start_time}-${otRecord.end_time})\n`;
    historyText += `原始时长: ${otRecord.duration || otRecord.total_hours}h\n`;
    historyText += `当前余额: ${otRecord.remaining_hours}h\n`;
    historyText += `----------------------\n核销历史详情:\n`;

    offRecords.forEach(off => {
        const memoData = JSON.parse(off.memo);
        const detail = memoData.find(d => d.id === otRecord.id);
        historyText += `• ${off.ot_date} 调休(${off.start_time}-${off.end_time}) 扣减了 ${detail.deduct}h\n`;
    });

    alert(historyText);
}

// 删除 record 逻辑
window.handleDelete = async (id, status, memo) => {
    const isOffRecord = status === '已调休';
    const confirmMsg = isOffRecord
        ? '确定要删除这条调休记录吗？删除后对应的加班时长将自动返还到余额中。'
        : '确定要删除这条加班记录吗？如果是已结清的记录，删除后余额将减少。';

    if (!confirm(confirmMsg)) return;

    // 1. 先删除记录本身（删除失败则不执行返还，避免双倍返还）
    const { error } = await API.deleteRecord(id);
    if (error) {
        alert('删除失败: ' + error.message);
        return;
    }

    // 2. 如果是调休记录，执行"返还"逻辑
    if (isOffRecord && memo) {
        try {
            const data = JSON.parse(memo);
            const allRecords = await API.fetchRecords();

            for (let item of data) {
                const targetRecord = allRecords.find(r => r.id === item.id);
                if (targetRecord) {
                    const restoredRemaining = Math.round((targetRecord.remaining_hours + item.deduct) * 100) / 100;
                    const originalDuration = targetRecord.duration || targetRecord.total_hours;
                    const newStatus = restoredRemaining >= originalDuration ? '待核销' : '部分核销';

                    await API.updateRemaining(targetRecord.id, restoredRemaining, newStatus);
                }
            }
        } catch (e) {
            console.error('Undo error:', e);
            alert('记录已删除，但无法自动返还时长，请手动调整余额。');
        }
    }

    await initApp();
}

// 渲染表单
function renderForm(type) {
    currentTab = type; // 更新全局状态
    const container = document.getElementById('form-content');
    const tabOt = document.getElementById('tab-ot');
    const tabOff = document.getElementById('tab-off');

    // 获取今天日期的 YYYY-MM-DD 格式
    const today = new Date().toISOString().split('T')[0];

    // 重新渲染列表以反映 Tab 切换
    API.fetchRecords().then(renderList);

    // 切换 Tab 样式
    if (type === 'ot') {
        tabOt.className = 'flex-1 pb-2 border-b-2 border-indigo-600 font-bold text-indigo-600 text-center transition-all';
        tabOff.className = 'flex-1 pb-2 text-gray-400 text-center transition-all';

        container.innerHTML = `
            <form id="ot-form" class="space-y-4 pt-4">
                <div>
                    <label class="block text-sm font-medium text-gray-700 mb-1">加班日期</label>
                    <input type="date" id="ot-date" value="${today}" required class="w-full p-2 border rounded-lg focus:ring-2 focus:ring-indigo-500 outline-none">
                </div>
                <div class="grid grid-cols-2 gap-4">
                    <div>
                        <label class="block text-sm font-medium text-gray-700 mb-1">开始时间</label>
                        <input type="time" id="ot-start" value="17:00" required class="w-full p-2 border rounded-lg focus:ring-2 focus:ring-indigo-500 outline-none">
                    </div>
                    <div>
                        <label class="block text-sm font-medium text-gray-700 mb-1">结束时间</label>
                        <input type="time" id="ot-end" required class="w-full p-2 border rounded-lg focus:ring-2 focus:ring-indigo-500 outline-none">
                    </div>
                </div>
                <div>
                    <label class="block text-sm font-medium text-gray-700 mb-1">加班事由</label>
                    <input type="text" id="ot-memo" placeholder="例如：项目上线、紧急修复..." class="w-full p-2 border rounded-lg focus:ring-2 focus:ring-indigo-500 outline-none">
                </div>
                <button type="submit" class="w-full bg-indigo-600 text-white py-2.5 rounded-lg font-medium hover:bg-indigo-700 transition-colors">
                    确认录入 +
                </button>
            </form>
        `;

        document.getElementById('ot-form')?.addEventListener('submit', async (e) => {
            e.preventDefault();
            const btn = document.querySelector('#ot-form button[type="submit"]');
            await withLoading(btn, async () => {
                const date = document.getElementById('ot-date').value;
                const start = document.getElementById('ot-start').value;
                const end = document.getElementById('ot-end').value;
                const range = `${start}-${end}`;
                const duration = parseDuration(range);

                if (duration <= 0) { alert('时间无效或时长不满0.5h'); return; }

                const memo = document.getElementById('ot-memo').value;

                const { error } = await API.addOT({
                    ot_date: date,
                    start_time: start,
                    end_time: end,
                    duration, total_hours: duration, remaining_hours: duration, status: '待核销',
                    memo: memo || ''
                });
                if (error) { alert('录入失败: ' + error.message); return; }
                alert('加班记录已录入');
                await initApp();
            });
        });

    } else {
        tabOt.className = 'flex-1 pb-2 text-gray-400 text-center transition-all';
        tabOff.className = 'flex-1 pb-2 border-b-2 border-orange-600 font-bold text-orange-600 text-center transition-all';

        container.innerHTML = `
            <form id="off-form" class="space-y-4 pt-4">
                <div class="bg-orange-50 p-3 rounded-lg text-xs text-orange-800 mb-2">
                    请选择调休时间段，系统将自动核销最早的加班。
                </div>
                <div>
                    <label class="block text-sm font-medium text-gray-700 mb-1">调休日期</label>
                    <input type="date" id="off-date" value="${today}" required class="w-full p-2 border rounded-lg focus:ring-2 focus:ring-indigo-500 outline-none">
                </div>
                <div class="grid grid-cols-2 gap-4">
                    <div>
                        <label class="block text-sm font-medium text-gray-700 mb-1">开始时间</label>
                        <input type="time" id="off-start" required class="w-full p-2 border rounded-lg focus:ring-2 focus:ring-indigo-500 outline-none">
                    </div>
                    <div>
                        <label class="block text-sm font-medium text-gray-700 mb-1">结束时间</label>
                        <input type="time" id="off-end" value="17:00" required class="w-full p-2 border rounded-lg focus:ring-2 focus:ring-indigo-500 outline-none">
                    </div>
                </div>
                <button type="submit" class="w-full bg-orange-600 text-white py-2.5 rounded-lg font-medium hover:bg-orange-700 transition-colors">
                    确认核销 -
                </button>
            </form>
        `;

        document.getElementById('off-form')?.addEventListener('submit', async (e) => {
            e.preventDefault();
            const btn = document.querySelector('#off-form button[type="submit"]');
            await withLoading(btn, async () => {
                const date = document.getElementById('off-date').value;
                const start = document.getElementById('off-start').value;
                const end = document.getElementById('off-end').value;
                await handleReconciliation(date, `${start}-${end}`);
            });
        });
    }
}

// 初始化应用
async function initApp() {
    await API.syncPendingOps();
    const data = await API.fetchRecords();
    renderStats(data);
    renderList(data);

    // 默认展示当前 Tab 的表单内容
    renderForm(currentTab);
}

document.addEventListener('DOMContentLoaded', () => {
    initApp();

    // 绑定 Tab 切换
    document.getElementById('tab-ot')?.addEventListener('click', () => renderForm('ot'));
    document.getElementById('tab-off')?.addEventListener('click', () => renderForm('off'));

    // 绑定视图切换
    const mainView = document.getElementById('main-view');
    const historyView = document.getElementById('history-view');

    const btnViewHistory = document.getElementById('btn-view-history');
    if (btnViewHistory) {
        btnViewHistory.addEventListener('click', () => {
            mainView.classList.add('hidden');
            historyView.classList.remove('hidden');
            window.scrollTo(0, 0);
        });
    }

    const btnBackHome = document.getElementById('btn-back-home');
    if (btnBackHome) {
        btnBackHome.addEventListener('click', () => {
            historyView.classList.add('hidden');
            mainView.classList.remove('hidden');
            window.scrollTo(0, 0);
        });
    }
});
