import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../domain/overtime_record.dart';

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

class SupabaseRepository {
  const SupabaseRepository(this.config);
  final SupabaseConfig config;
  static const bucket = 'ot-record-photos';

  Map<String, String> get _headers => {
    'apikey': config.key,
    'Authorization': 'Bearer ${config.key}',
    'Content-Type': 'application/json',
  };

  Future<List<OvertimeRecord>> fetchAll() async {
    final response = await http.get(
      Uri.parse('${config.url}/rest/v1/ot_records').replace(
        queryParameters: {
          'select': '*',
          'order': 'ot_date.desc,created_at.desc,id.desc',
        },
      ),
      headers: _headers,
    );
    _ensureSuccess(response, '读取线上账本');
    return (jsonDecode(response.body) as List<dynamic>)
        .map((item) => OvertimeRecord.fromMap(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> upsertRecords(List<OvertimeRecord> records) async {
    if (records.isEmpty) return;
    final response = await http.post(
      Uri.parse(
        '${config.url}/rest/v1/ot_records',
      ).replace(queryParameters: {'on_conflict': 'id'}),
      headers: {
        ..._headers,
        'Prefer': 'resolution=merge-duplicates,return=minimal',
      },
      body: jsonEncode(records.map((record) => record.toMap()).toList()),
    );
    _ensureSuccess(response, '写入线上账本');
  }

  Future<void> deleteRecordAtomically(String id) async {
    final response = await http.post(
      Uri.parse('${config.url}/rest/v1/rpc/delete_ot_record_atomic'),
      headers: _headers,
      body: jsonEncode({'target_id': id}),
    );
    _ensureSuccess(response, '原子删除线上记录');
  }

  Future<void> reconcileAtomically(
    OvertimeRecord leave,
    List<ReconciliationDetail> details,
  ) async {
    final response = await http.post(
      Uri.parse('${config.url}/rest/v1/rpc/reconcile_ot_atomic'),
      headers: _headers,
      body: jsonEncode({
        'leave_record': leave.toMap(),
        'deductions': details.map((detail) => detail.toMap()).toList(),
      }),
    );
    _ensureSuccess(response, '原子核销线上余额');
  }

  Future<void> uploadPhoto(
    String remotePath,
    List<int> bytes, {
    required String contentType,
  }) async {
    final encoded = remotePath.split('/').map(Uri.encodeComponent).join('/');
    final response = await http.post(
      Uri.parse('${config.url}/storage/v1/object/$bucket/$encoded'),
      headers: {
        'apikey': config.key,
        'Authorization': 'Bearer ${config.key}',
        'Content-Type': contentType,
        'x-upsert': 'false',
      },
      body: bytes,
    );
    _ensureSuccess(response, '上传照片');
  }

  Future<List<int>> downloadPhoto(String remotePath) async {
    final encoded = remotePath.split('/').map(Uri.encodeComponent).join('/');
    final response = await http.get(
      Uri.parse('${config.url}/storage/v1/object/public/$bucket/$encoded'),
      headers: {'apikey': config.key},
    );
    _ensureSuccess(response, '下载照片');
    return response.bodyBytes;
  }

  Future<void> deletePhoto(String remotePath) async {
    final response = await http.delete(
      Uri.parse('${config.url}/storage/v1/object/$bucket'),
      headers: _headers,
      body: jsonEncode({
        'prefixes': [remotePath],
      }),
    );
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
