const SB_URL = "https://mwoqpheguldiuemgztkk.supabase.co";
const SB_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im13b3FwaGVndWxkaXVlbWd6dGtrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAwODk5MjksImV4cCI6MjA4NTY2NTkyOX0.zpr7Nkp1t6egnwtUbmsyghCeahjYVDdG-4ZDei6ZbKE";
const client = supabase.createClient(SB_URL, SB_KEY);
const QUEUE_KEY = "pending_ops";
const CACHE_VERSION = 2;
const CACHE_VERSION_KEY = "cache_version";
const PHOTO_BUCKET = "ot-record-photos";
const PHOTO_DB_NAME = "obf-photo-cache";
const PHOTO_STORE_NAME = "pending_photos";

let photoDbPromise = null;

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

function hasQueuedPhotoDelete(photoPath) {
    return getQueue().some((op) => op.type === "photo-delete" && op.photoPath === photoPath);
}

function pullQueuedAdd(id) {
    const queue = getQueue();
    const addOp = queue.find((op) => op.type === "add" && op.record && op.record.id === id);
    if (!addOp) return null;

    const nextQueue = queue.filter((op) => {
        if (op === addOp) return false;
        if (op.id === id) return false;
        return !(op.record && op.record.id === id);
    });
    setQueue(nextQueue);
    return addOp;
}

function shouldQueueWrite(error) {
    return !navigator.onLine || !error.code;
}

function sanitizeRecordForCache(record) {
    if (!record) return record;
    const next = { ...record };
    delete next.photo_url;
    return next;
}

function mergeRecords(primary, secondary) {
    const merged = [];
    const seen = new Set();

    [...primary, ...secondary].forEach((record) => {
        if (!record || !record.id || seen.has(record.id)) return;
        seen.add(record.id);
        merged.push(sanitizeRecordForCache(record));
    });

    return merged;
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
    localStorage.setItem("cached_records", JSON.stringify(data.map(sanitizeRecordForCache)));
}

function createLocalId() {
    if (globalThis.crypto && crypto.randomUUID) return "local-" + crypto.randomUUID();
    return "local-" + Date.now() + "-" + Math.random().toString(36).slice(2);
}

function createServerId() {
    if (globalThis.crypto && crypto.randomUUID) return crypto.randomUUID();
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (char) => {
        const rand = Math.random() * 16 | 0;
        const value = char === "x" ? rand : (rand & 0x3 | 0x8);
        return value.toString(16);
    });
}

function buildPhotoPath(recordId) {
    return `ot/${recordId}/${Date.now()}.jpg`;
}

function getPublicPhotoUrl(photoPath) {
    if (!photoPath) return "";
    const { data } = client.storage.from(PHOTO_BUCKET).getPublicUrl(photoPath);
    return data?.publicUrl || "";
}

function addLocalRecord(record) {
    const rec = {
        created_at: new Date().toISOString(),
        ...sanitizeRecordForCache(record)
    };
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
        if (record.id === oldId) return sanitizeRecordForCache(serverRecord);
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

function openPhotoDb() {
    if (photoDbPromise) return photoDbPromise;
    photoDbPromise = new Promise((resolve, reject) => {
        const request = indexedDB.open(PHOTO_DB_NAME, 1);
        request.onupgradeneeded = () => {
            const db = request.result;
            if (!db.objectStoreNames.contains(PHOTO_STORE_NAME)) {
                db.createObjectStore(PHOTO_STORE_NAME, { keyPath: "id" });
            }
        };
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
    });
    return photoDbPromise;
}

async function putPendingPhoto(blob) {
    const db = await openPhotoDb();
    const id = "pending-photo-" + createLocalId();

    return new Promise((resolve, reject) => {
        const tx = db.transaction(PHOTO_STORE_NAME, "readwrite");
        tx.objectStore(PHOTO_STORE_NAME).put({ id, blob, created_at: Date.now() });
        tx.oncomplete = () => resolve(id);
        tx.onerror = () => reject(tx.error);
    });
}

async function getPendingPhoto(pendingPhotoId) {
    if (!pendingPhotoId) return null;
    const db = await openPhotoDb();

    return new Promise((resolve, reject) => {
        const tx = db.transaction(PHOTO_STORE_NAME, "readonly");
        const request = tx.objectStore(PHOTO_STORE_NAME).get(pendingPhotoId);
        request.onsuccess = () => resolve(request.result?.blob || null);
        request.onerror = () => reject(request.error);
    });
}

async function deletePendingPhoto(pendingPhotoId) {
    if (!pendingPhotoId) return;
    const db = await openPhotoDb();

    return new Promise((resolve, reject) => {
        const tx = db.transaction(PHOTO_STORE_NAME, "readwrite");
        tx.objectStore(PHOTO_STORE_NAME).delete(pendingPhotoId);
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error);
    });
}

async function hydrateRecord(record) {
    const next = { ...record };
    if (next.photo_path) {
        next.photo_url = getPublicPhotoUrl(next.photo_path);
        return next;
    }
    if (!next.pending_photo_id) return next;

    try {
        const blob = await getPendingPhoto(next.pending_photo_id);
        if (blob) next.photo_url = URL.createObjectURL(blob);
    } catch (error) {
        console.warn("Pending photo hydrate failed:", error);
    }
    return next;
}

async function hydrateRecords(records) {
    return Promise.all((records || []).map(hydrateRecord));
}

async function uploadPhotoBlob(recordId, photoBlob) {
    const photoPath = buildPhotoPath(recordId);
    const { error } = await client.storage.from(PHOTO_BUCKET).upload(photoPath, photoBlob, {
        contentType: photoBlob.type || "image/jpeg",
        upsert: false
    });

    if (error) return { photoPath: "", error };
    return { photoPath, error: null };
}

async function deletePhotoObject(photoPath) {
    if (!photoPath) return { error: null };
    const { error } = await client.storage.from(PHOTO_BUCKET).remove([photoPath]);
    return { error };
}

function queuePhotoDelete(photoPath) {
    if (!photoPath || hasQueuedPhotoDelete(photoPath)) return;
    pushOp({ type: "photo-delete", photoPath });
}

async function queuePhotoRecord(record, photoBlob) {
    const pendingPhotoId = await putPendingPhoto(photoBlob);
    const localRecord = addLocalRecord({
        ...record,
        photo_path: "",
        pending_photo_id: pendingPhotoId
    });
    pushOp({ type: "add", record: localRecord, pending_photo_id: pendingPhotoId });
    return { data: [await hydrateRecord(localRecord)], error: null };
}

async function queuePlainRecord(record) {
    const localRecord = addLocalRecord(record);
    pushOp({ type: "add", record: localRecord });
    return { data: [await hydrateRecord(localRecord)], error: null };
}

const API = {
    async fetchRecords() {
        const { data, error } = await client
            .from("ot_records")
            .select("*")
            .order("ot_date", { ascending: false });

        if (error) {
            console.warn("Supabase Fetch Error:", error);
            const cached = getCached();
            if (!cached.length) alert("数据加载失败: " + error.message);
            return hydrateRecords(cached);
        }

        setCached(data || []);
        return hydrateRecords(data || []);
    },

    async addOT(record, options = {}) {
        const baseRecord = {
            ...sanitizeRecordForCache(record),
            photo_path: record.photo_path || null
        };
        const photoBlob = options.photoBlob || null;

        if (photoBlob) {
            if (!navigator.onLine) return queuePhotoRecord(baseRecord, photoBlob);

            const recordId = baseRecord.id || createServerId();
            const uploadResult = await uploadPhotoBlob(recordId, photoBlob);
            if (uploadResult.error) {
                if (!navigator.onLine) return queuePhotoRecord(baseRecord, photoBlob);
                return { data: null, error: uploadResult.error };
            }

            const payload = {
                ...baseRecord,
                id: recordId,
                photo_path: uploadResult.photoPath
            };
            const { data, error } = await client.from("ot_records").insert([payload]).select();

            if (error) {
                if (shouldQueueWrite(error)) {
                    const queuedRecord = {
                        ...payload,
                        photo_path: uploadResult.photoPath
                    };
                    return queuePlainRecord(queuedRecord);
                }

                const cleanup = await deletePhotoObject(uploadResult.photoPath);
                if (cleanup.error) console.warn("Photo cleanup failed:", cleanup.error);
                return { data: null, error };
            }

            setCached(mergeRecords(data || [], getCached()));
            return { data: await hydrateRecords(data || []), error: null };
        }

        const { data, error } = await client.from("ot_records").insert([baseRecord]).select();
        if (error) {
            if (!shouldQueueWrite(error)) return { data: null, error };
            return queuePlainRecord(baseRecord);
        }

        setCached(mergeRecords(data || [], getCached()));
        return { data: await hydrateRecords(data || []), error: null };
    },

    async updateRemaining(id, newRemaining, status) {
        const { data, error } = await client.from("ot_records")
            .update({ remaining_hours: newRemaining, status: status })
            .eq("id", id);
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
        if (String(id).startsWith("local-")) {
            const addOp = pullQueuedAdd(id);
            deleteLocalRecord(id);
            if (addOp?.pending_photo_id) {
                try {
                    await deletePendingPhoto(addOp.pending_photo_id);
                } catch (error) {
                    console.warn("Pending photo cleanup failed:", error);
                }
            }
            return { error: null };
        }

        const { error } = await client.from("ot_records").delete().eq("id", id);
        if (error) {
            if (!shouldQueueWrite(error)) return { error };
            deleteLocalRecord(id);
            pushOp({ type: "delete", id });
            return { error: null };
        }
        deleteLocalRecord(id);
        return { error: null };
    },

    async deletePhoto(photoPath) {
        if (!photoPath) return { error: null, queued: false };

        const cleanup = await deletePhotoObject(photoPath);
        if (!cleanup.error) return { error: null, queued: false };

        console.warn("Photo cleanup failed:", photoPath, cleanup.error);

        if (shouldQueueWrite(cleanup.error)) {
            queuePhotoDelete(photoPath);
            return { error: null, queued: true };
        }

        return { error: cleanup.error, queued: false };
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

                const payload = sanitizeRecordForCache(op.record);
                const pendingPhotoId = op.pending_photo_id || payload.pending_photo_id || null;

                if (pendingPhotoId) {
                    const blob = await getPendingPhoto(pendingPhotoId);
                    if (!blob) {
                        console.warn("Sync error (add): pending photo missing");
                        continue;
                    }

                    const serverId = createServerId();
                    const uploadResult = await uploadPhotoBlob(serverId, blob);
                    if (uploadResult.error) {
                        console.warn("Sync error (photo upload):", uploadResult.error);
                        continue;
                    }

                    payload.id = serverId;
                    payload.photo_path = uploadResult.photoPath;
                    delete payload.pending_photo_id;
                } else if (String(payload.id).startsWith("local-")) {
                    delete payload.id;
                }

                const { data, error } = await client.from("ot_records").insert([payload]).select();
                if (!error && data && data[0]) {
                    const serverRecord = data[0];
                    if (String(op.record.id).startsWith("local-")) {
                        replaceLocalId(op.record.id, serverRecord, q);
                    } else {
                        setCached(mergeRecords([serverRecord], getCached()));
                    }
                    if (pendingPhotoId) await deletePendingPhoto(pendingPhotoId);
                    q = q.filter((x) => x !== op);
                    setQueue(q);
                } else if (error) {
                    console.warn("Sync error (add):", error);
                } else {
                    console.warn("Sync error (add): no record returned");
                }
            } catch (e) {
                console.warn("Sync error (add):", e);
            }
        }

        for (const op of others) {
            try {
                if (op.type === "update") {
                    if (String(op.id).startsWith("local-")) continue;
                    const { error } = await client.from("ot_records")
                        .update({ remaining_hours: op.remaining, status: op.status })
                        .eq("id", op.id);
                    if (error) {
                        console.warn("Sync error (update):", error);
                        continue;
                    }
                    q = q.filter((x) => x !== op);
                    setQueue(q);
                } else if (op.type === "delete") {
                    if (String(op.id).startsWith("local-")) continue;
                    const { error } = await client.from("ot_records").delete().eq("id", op.id);
                    if (error) {
                        console.warn("Sync error (delete):", error);
                        continue;
                    }
                    q = q.filter((x) => x !== op);
                    setQueue(q);
                } else if (op.type === "photo-delete") {
                    const cleanup = await deletePhotoObject(op.photoPath);
                    if (cleanup.error) {
                        console.warn("Sync error (photo-delete):", op.photoPath, cleanup.error);
                        continue;
                    }
                    q = q.filter((x) => x !== op);
                    setQueue(q);
                }
            } catch (e) {
                console.warn("Sync error (update/delete):", e);
            }
        }
    }
};
