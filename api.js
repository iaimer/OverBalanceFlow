const SB_URL = "https://mwoqpheguldiuemgztkk.supabase.co";
const SB_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im13b3FwaGVndWxkaXVlbWd6dGtrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAwODk5MjksImV4cCI6MjA4NTY2NTkyOX0.zpr7Nkp1t6egnwtUbmsyghCeahjYVDdG-4ZDei6ZbKE";
const client = supabase.createClient(SB_URL, SB_KEY);

const API = {
    // 获取所有记录
    async fetchRecords() {
        const { data, error } = await client
            .from('ot_records')
            .select('*')
            .order('ot_date', { ascending: false });

        if (error) {
            console.error('Supabase Fetch Error:', error);
            alert('数据加载失败: ' + error.message);
            return [];
        }

        console.log('Fetched records:', data);
        if (!data || data.length === 0) {
            // 只有在明确是空的时候才提示，避免每次刷新都弹窗干扰
            console.warn('Fetched 0 records. This might be normal, or caused by RLS policies.');
        }
        return data || [];
    },

    // 存入新加班
    async addOT(record) {
        return await client.from('ot_records').insert([record]).select();
    },

    // 更新加班余额（核销用）
    async updateRemaining(id, newRemaining, status) {
        return await client.from('ot_records')
            .update({ remaining_hours: newRemaining, status: status })
            .eq('id', id);
    },

    // 删除记录
    async deleteRecord(id) {
        return await client.from('ot_records').delete().eq('id', id);
    }
};