const SB_URL = "https://mwoqpheguldiuemgztkk.supabase.co";
const SB_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im13b3FwaGVndWxkaXVlbWd6dGtrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAwODk5MjksImV4cCI6MjA4NTY2NTkyOX0.zpr7Nkp1t6egnwtUbmsyghCeahjYVDdG-4ZDei6ZbKE";
const client = supabase.createClient(SB_URL, SB_KEY);
const QUEUE_KEY = "pending_ops";
const CACHE_VERSION = 1;
const CACHE_VERSION_KEY = "cache_version";

function getQueue() {
    const s = localStorage.getItem(QUEUE_KEY);
    return s ? JSON.parse(s) : [];
}
function setQueue(q) {
    localStorage.setItem(QUEUE_KEY, JSON.stringify(q));
}
function pushOp(op) {
    const q = getQueue();
    q.push(op);
    setQueue(q);
    if ("serviceWorker" in navigator) {
        navigator.serviceWorker.ready.then((reg) => {
            if ("sync" in reg) reg.sync.register("sync-ops");
        });
    }
}
function shouldQueueWrite(error) {
    return !navigator.onLine || !error.code;
}
function getCached() {
    if (localStorage.getItem(CACHE_VERSION_KEY) != CACHE_VERSION) {
        localStorage.removeItem("cached_records");
        localStorage.setItem(CACHE_VERSION_KEY, String(CACHE_VERSION));
        return [];
    }
    const s = localStorage.getItem("cached_records");
    return s ? JSON.parse(s) : [];
}
function setCached(data) {
    localStorage.setItem(CACHE_VERSION_KEY, String(CACHE_VERSION));
    localStorage.setItem("cached_records", JSON.stringify(data));
}
function createLocalId() {
    if (globalThis.crypto && crypto.randomUUID) return "local-" + crypto.randomUUID();
    return "local-" + Date.now() + "-" + Math.random().toString(36).slice(2);
}
function addLocalRecord(record) {
    const rec = { ...record };
    if (!rec.id) rec.id = createLocalId();
    const data = getCached();
    data.unshift(rec);
    setCached(data);
    return rec;
}
function updateLocalRecord(id, remaining, status) {
    const data = getCached();
    const idx = data.findIndex((r) => r.id === id);
    if (idx >= 0) {
        data[idx] = { ...data[idx], remaining_hours: remaining, status };
        setCached(data);
    }
}
function deleteLocalRecord(id) {
    const data = getCached().filter((r) => r.id !== id);
    setCached(data);
}
function replaceRecordReference(record, oldId, newId) {
    const next = { ...record };
    if (next.id === oldId) next.id = newId;
    if (!next.memo) return next;

    try {
        const details = JSON.parse(next.memo);
        if (!Array.isArray(details)) return next;
        let changed = false;
        const rewritten = details.map((detail) => {
            if (detail.id !== oldId) return detail;
            changed = true;
            return { ...detail, id: newId };
        });
        if (changed) next.memo = JSON.stringify(rewritten);
    } catch (e) {
        return next;
    }
    return next;
}
function replaceLocalId(oldId, serverRecord, queue) {
    const cached = getCached().map((record) => {
        if (record.id === oldId) return serverRecord;
        return replaceRecordReference(record, oldId, serverRecord.id);
    });
    setCached(cached);

    queue.forEach((op) => {
        if (op.id === oldId) op.id = serverRecord.id;
        if (op.record) op.record = replaceRecordReference(op.record, oldId, serverRecord.id);
    });
}
function hasLocalReference(record) {
    if (!record.memo) return false;
    try {
        const details = JSON.parse(record.memo);
        return Array.isArray(details) && details.some((detail) => String(detail.id).startsWith("local-"));
    } catch (e) {
        return false;
    }
}

const API = {
    async fetchRecords() {
        const { data, error } = await client
            .from('ot_records')
            .select('*')
            .order('ot_date', { ascending: false });

        if (error) {
            console.warn('Supabase Fetch Error:', error);
            const cached = getCached();
            if (!cached.length) alert('数据加载失败: ' + error.message);
            return cached;
        }

        setCached(data || []);
        return data || [];
    },

    async addOT(record) {
        const { data, error } = await client.from('ot_records').insert([record]).select();
        if (error) {
            if (!shouldQueueWrite(error)) return { data: null, error };
            const local = addLocalRecord(record);
            pushOp({ type: "add", record: local });
            return { data: [local], error: null };
        }
        const merged = [ ...(getCached()), ...(data || []) ];
        setCached(merged);
        return { data, error: null };
    },

    async updateRemaining(id, newRemaining, status) {
        const { data, error } = await client.from('ot_records')
            .update({ remaining_hours: newRemaining, status: status })
            .eq('id', id);
        if (error) {
            if (!shouldQueueWrite(error)) return { data: null, error };
            updateLocalRecord(id, newRemaining, status);
            pushOp({ type: "update", id, remaining: newRemaining, status });
            return { data: null, error: null };
        }
        updateLocalRecord(id, newRemaining, status);
        return { data, error: null };
    },

    async deleteRecord(id) {
        const { error } = await client.from('ot_records').delete().eq('id', id);
        if (error) {
            if (!shouldQueueWrite(error)) return { error };
            deleteLocalRecord(id);
            pushOp({ type: "delete", id });
            return { error: null };
        }
        deleteLocalRecord(id);
        return { error: null };
    },

    async syncPendingOps() {
        if (!navigator.onLine) return;
        let q = getQueue();
        if (!q.length) return;
        const adds = q.filter((o) => o.type === "add");
        const others = q.filter((o) => o.type !== "add");
        for (const op of adds) {
            try {
                if (hasLocalReference(op.record)) continue;
                const payload = { ...op.record };
                if (String(payload.id).startsWith("local-")) delete payload.id;
                const { data, error } = await client.from('ot_records').insert([payload]).select();
                if (!error && data && data[0]) {
                    const srv = data[0];
                    replaceLocalId(op.record.id, srv, q);
                    q = q.filter((x) => x !== op);
                    setQueue(q);
                } else if (error) {
                    console.warn('Sync error (add):', error);
                } else {
                    console.warn('Sync error (add): no record returned');
                }
            } catch (e) { console.warn('Sync error (add):', e); }
        }
        for (const op of others) {
            try {
                if (op.type === "update") {
                    if (String(op.id).startsWith("local-")) continue;
                    const { error } = await client.from('ot_records')
                        .update({ remaining_hours: op.remaining, status: op.status })
                        .eq('id', op.id);
                    if (error) {
                        console.warn('Sync error (update):', error);
                        continue;
                    }
                    q = q.filter((x) => x !== op);
                    setQueue(q);
                } else if (op.type === "delete") {
                    if (String(op.id).startsWith("local-")) continue;
                    const { error } = await client.from('ot_records').delete().eq('id', op.id);
                    if (error) {
                        console.warn('Sync error (delete):', error);
                        continue;
                    }
                    q = q.filter((x) => x !== op);
                    setQueue(q);
                }
            } catch (e) { console.warn('Sync error (update/delete):', e); }
        }
    }
};
