import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../domain/overtime_record.dart';
import '../domain/annual_leave.dart';

class SupabaseConfig {
  const SupabaseConfig(this.url, this.key);
  final String url;
  final String key;

  static SupabaseConfig? fromBuild() {
    const url = String.fromEnvironment('SUPABASE_URL');
    const key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
    if (url.isNotEmpty && key.isNotEmpty) return const SupabaseConfig(url, key);
    return null;
  }
}

class LedgerSnapshot {
  const LedgerSnapshot(this.records, this.annual, this.calendar);
  final List<OvertimeRecord> records;
  final List<AnnualLeaveRecord> annual;
  final LeaveCalendar calendar;
}

class SupabaseRepository {
  const SupabaseRepository(this.config);
  final SupabaseConfig config;
  static const bucket = 'ot-record-photos';
  static const _requestTimeout = Duration(seconds: 12);

  Map<String, String> get _headers => {
    'apikey': config.key,
    'Authorization': 'Bearer ${config.key}',
    'Content-Type': 'application/json',
  };

  Future<LedgerSnapshot> fetchLedger() async {
    final response = await _rpc('get_leave_ledger_snapshot', {});
    final map = jsonDecode(response.body) as Map<String, dynamic>;
    return LedgerSnapshot(
      (map['records'] as List<dynamic>)
          .map((r) => OvertimeRecord.fromMap(r as Map<String, dynamic>))
          .toList(),
      (map['annual_leave'] as List<dynamic>)
          .map((r) => AnnualLeaveRecord.fromMap(r as Map<String, dynamic>))
          .toList(),
      LeaveCalendar(
        (map['calendar'] as List<dynamic>).cast<Map<String, dynamic>>(),
      ),
    );
  }

  Future<http.Response> _rpc(String name, Map<String, Object?> payload) async {
    final response = await http
        .post(
          Uri.parse('${config.url}/rest/v1/rpc/$name'),
          headers: _headers,
          body: jsonEncode(payload),
        )
        .timeout(_requestTimeout);
    _ensureSuccess(response, '云端事务');
    return response;
  }

  Future<void> saveAnnualLeave(
    AnnualLeaveRecord record, {
    required bool allowInsert,
  }) async {
    await _rpc('save_annual_leave_atomic', {
      'payload': record.toMap(),
      'allow_insert': allowInsert,
    });
  }

  Future<void> deleteAnnualLeave(String id) async {
    await _rpc('delete_annual_leave_atomic', {'target_id': id});
  }

  Future<void> saveCompensatoryLeave(
    OvertimeRecord record,
    List<ReconciliationDetail> details, {
    required bool allowInsert,
  }) async {
    await _rpc('save_comp_leave_atomic', {
      'leave_record': record.toMap(),
      'deductions': details.map((d) => d.toMap()).toList(),
      'allow_insert': allowInsert,
    });
  }

  Future<void> restoreLedger(
    List<OvertimeRecord> records,
    List<AnnualLeaveRecord> annual,
  ) async {
    await _rpc('restore_leave_ledger_atomic', {
      'records': records.map((r) => r.toMap()).toList(),
      'annual_records': annual.map((r) => r.toMap()).toList(),
    });
  }

  Future<List<OvertimeRecord>> fetchAll() async {
    final response = await http
        .get(
          Uri.parse('${config.url}/rest/v1/ot_records').replace(
            queryParameters: {
              'select': '*',
              'order': 'ot_date.desc,created_at.desc,id.desc',
            },
          ),
          headers: _headers,
        )
        .timeout(_requestTimeout);
    _ensureSuccess(response, '读取线上账本');
    return (jsonDecode(response.body) as List<dynamic>)
        .map((item) => OvertimeRecord.fromMap(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> upsertRecords(List<OvertimeRecord> records) async {
    if (records.isEmpty) return;
    final response = await http
        .post(
          Uri.parse(
            '${config.url}/rest/v1/ot_records',
          ).replace(queryParameters: {'on_conflict': 'id'}),
          headers: {
            ..._headers,
            'Prefer': 'resolution=merge-duplicates,return=minimal',
          },
          body: jsonEncode(records.map((record) => record.toMap()).toList()),
        )
        .timeout(_requestTimeout);
    _ensureSuccess(response, '写入线上账本');
  }

  /// 通过数据库事务新增或编辑一条加班记录。
  ///
  /// RPC 会在服务端重新校验时间段重叠，并根据原记录的核销历史计算余额，
  /// 因此不能用普通 upsert 替代。
  Future<void> saveOvertimeAtomically(
    OvertimeRecord record, {
    required bool allowInsert,
  }) async {
    final response = await http
        .post(
          Uri.parse('${config.url}/rest/v1/rpc/save_ot_record_atomic'),
          headers: _headers,
          body: jsonEncode({
            'payload': record.toMap(),
            'allow_insert': allowInsert,
          }),
        )
        .timeout(_requestTimeout);
    _ensureSuccess(response, '原子保存加班记录');
  }

  Future<void> deleteRecordAtomically(String id) async {
    final response = await http
        .post(
          Uri.parse('${config.url}/rest/v1/rpc/delete_ot_record_atomic'),
          headers: _headers,
          body: jsonEncode({'target_id': id}),
        )
        .timeout(_requestTimeout);
    _ensureSuccess(response, '原子删除线上记录');
  }

  Future<void> reconcileAtomically(
    OvertimeRecord leave,
    List<ReconciliationDetail> details,
  ) async {
    final response = await http
        .post(
          Uri.parse('${config.url}/rest/v1/rpc/reconcile_ot_atomic'),
          headers: _headers,
          body: jsonEncode({
            'leave_record': leave.toMap(),
            'deductions': details.map((detail) => detail.toMap()).toList(),
          }),
        )
        .timeout(_requestTimeout);
    _ensureSuccess(response, '原子核销线上余额');
  }

  Future<void> uploadPhoto(
    String remotePath,
    List<int> bytes, {
    required String contentType,
  }) async {
    final encoded = remotePath.split('/').map(Uri.encodeComponent).join('/');
    final response = await http
        .post(
          Uri.parse('${config.url}/storage/v1/object/$bucket/$encoded'),
          headers: {
            'apikey': config.key,
            'Authorization': 'Bearer ${config.key}',
            'Content-Type': contentType,
            'x-upsert': 'false',
          },
          body: bytes,
        )
        .timeout(_requestTimeout);
    _ensureSuccess(response, '上传照片');
  }

  Future<List<int>> downloadPhoto(String remotePath) async {
    final encoded = remotePath.split('/').map(Uri.encodeComponent).join('/');
    final response = await http
        .get(
          Uri.parse('${config.url}/storage/v1/object/public/$bucket/$encoded'),
          headers: {'apikey': config.key},
        )
        .timeout(_requestTimeout);
    _ensureSuccess(response, '下载照片');
    return response.bodyBytes;
  }

  Future<void> deletePhoto(String remotePath) async {
    final response = await http
        .delete(
          Uri.parse('${config.url}/storage/v1/object/$bucket'),
          headers: _headers,
          body: jsonEncode({
            'prefixes': [remotePath],
          }),
        )
        .timeout(_requestTimeout);
    _ensureSuccess(response, '清理线上照片');
  }

  Never _throw(http.Response response, String action) {
    throw HttpException('$action失败（${response.statusCode}）：${response.body}');
  }

  void _ensureSuccess(http.Response response, String action) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _throw(response, action);
    }
  }
}
