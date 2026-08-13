import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../domain/overtime_record.dart';
import '../domain/ledger_validator.dart';
import 'data_fingerprint.dart';
import 'local_database.dart';

class MigrationReport {
  const MigrationReport({required this.fingerprint, required this.completedAt});
  final DataFingerprint fingerprint;
  final DateTime completedAt;

  Map<String, Object> toMap() => {
    ...fingerprint.toMap(),
    'completed_at': completedAt.toIso8601String(),
    'verified': true,
  };
}

/// 生产迁移客户端是刻意只读的：这里只有 GET，没有写入或删除接口。
class ReadOnlySupabaseSource {
  const ReadOnlySupabaseSource({
    required this.baseUrl,
    required this.publishableKey,
    this.pageSize = 500,
  });

  final String baseUrl;
  final String publishableKey;
  final int pageSize;
  static int? _parseTotal(String? contentRange) {
    if (contentRange == null || !contentRange.contains('/')) return null;
    return int.tryParse(contentRange.split('/').last);
  }

  Map<String, String> get _headers => {
    'apikey': publishableKey,
    'Authorization': 'Bearer $publishableKey',
  };

  Future<List<OvertimeRecord>> fetchAll() async {
    final records = <OvertimeRecord>[];
    int? expectedTotal;
    for (var offset = 0; ; offset += pageSize) {
      final uri = Uri.parse('$baseUrl/rest/v1/ot_records').replace(
        queryParameters: {
          'select': '*',
          'order': 'ot_date.asc,created_at.asc,id.asc',
          'offset': '$offset',
          'limit': '$pageSize',
        },
      );
      final response = await http.get(
        uri,
        headers: {
          ..._headers,
          'Prefer': 'count=exact',
          'Range': '$offset-${offset + pageSize - 1}',
        },
      );
      if (response.statusCode != 200)
        throw HttpException('读取历史记录失败：${response.statusCode}');
      final page = (jsonDecode(response.body) as List<dynamic>)
          .map((item) => OvertimeRecord.fromMap(item as Map<String, dynamic>))
          .toList();
      records.addAll(page);
      expectedTotal ??= _parseTotal(response.headers['content-range']);
      if (page.length < pageSize) break;
    }
    if (records.isEmpty) throw StateError('云端返回空数据，为防止覆盖而中止迁移');
    if (expectedTotal == null || records.length != expectedTotal) {
      throw StateError('分页读取不完整：期望 $expectedTotal 条，实际 ${records.length} 条');
    }
    return records;
  }

  Future<List<int>> downloadPhoto(String remotePath) async {
    final encodedPath = remotePath
        .split('/')
        .map(Uri.encodeComponent)
        .join('/');
    final response = await http.get(
      Uri.parse(
        '$baseUrl/storage/v1/object/public/ot-record-photos/$encodedPath',
      ),
      headers: _headers,
    );
    if (response.statusCode != 200) throw HttpException('照片下载失败：$remotePath');
    return response.bodyBytes;
  }
}

class MigrationService {
  MigrationService(this.database, this.source, {this.expectedBaseline});
  final LocalDatabase database;
  final ReadOnlySupabaseSource source;
  final ExpectedBaseline? expectedBaseline;

  Future<MigrationReport> migrate() async {
    if (await database.setting('migration_completed') == 'true') {
      final existing = await database.records();
      return MigrationReport(
        fingerprint: DataFingerprint.fromRecords(existing),
        completedAt: DateTime.now(),
      );
    }
    final remoteRecords = await source.fetchAll();
    LedgerValidator.validate(remoteRecords);
    expectedBaseline?.verifyRecords(remoteRecords);
    final stagingRoot = Directory(
      p.join(database.rootDirectory.path, 'migration-staging'),
    );
    if (await stagingRoot.exists()) await stagingRoot.delete(recursive: true);
    await stagingRoot.create(recursive: true);
    final stagingPhotos = Directory(p.join(stagingRoot.path, 'photos'))
      ..createSync(recursive: true);
    final stagingDbPath = p.join(stagingRoot.path, 'staging.db');
    final staging = await LocalDatabase.open(
      databasePath: stagingDbPath,
      rootDirectory: stagingRoot,
    );
    try {
      final localized = <OvertimeRecord>[];
      final photoManifest = <String, Map<String, Object>>{};
      for (final record in remoteRecords) {
        var next = record;
        if (record.photoPath case final remotePath?) {
          final bytes = await source.downloadPhoto(remotePath);
          expectedBaseline?.verifyPhoto(record.id, remotePath, bytes);
          final extension = p.extension(remotePath).isEmpty
              ? '.jpg'
              : p.extension(remotePath);
          final fileName = '${sha256.convert(bytes)}$extension';
          photoManifest[record.id] = {
            'remote_path': remotePath,
            'local_file': p.join('photos', fileName),
            'sha256': sha256.convert(bytes).toString(),
            'size': bytes.length,
          };
          await File(
            p.join(stagingPhotos.path, fileName),
          ).writeAsBytes(bytes, flush: true);
          next = record.copyWith(photoPath: p.join('photos', fileName));
        }
        await staging.addRecord(next);
        localized.add(next);
      }
      final remoteFingerprint = DataFingerprint.fromRecords(remoteRecords);
      expectedBaseline?.verify(remoteFingerprint);
      final localFingerprint = DataFingerprint.fromRecords(
        await staging.records(),
      );
      _verify(remoteFingerprint, localFingerprint);

      final current = await database.records();
      if (current.isNotEmpty) throw StateError('本地已有数据，为防止覆盖而中止首次迁移');
      final livePhotos = await database.photosDirectory();
      final copiedPhotos = <File>[];
      for (final entity in stagingPhotos.listSync().whereType<File>()) {
        final target = File(p.join(livePhotos.path, p.basename(entity.path)));
        await entity.copy(target.path);
        copiedPhotos.add(target);
      }
      try {
        await database.db.transaction((txn) async {
          for (final record in localized) {
            await txn.insert(
              'ot_records',
              record.toMap(),
              conflictAlgorithm: ConflictAlgorithm.abort,
            );
          }
          await txn.insert('settings', {
            'key': 'migration_completed',
            'value': 'true',
          });
          await txn.insert('settings', {
            'key': 'migration_report',
            'value': jsonEncode({
              ...localFingerprint.toMap(),
              'external_baseline_verified': expectedBaseline != null,
              'photos': photoManifest,
            }),
          });
        });
      } catch (_) {
        for (final photo in copiedPhotos) {
          if (await photo.exists()) {
            await photo.delete();
          }
        }
        rethrow;
      }
      final report = MigrationReport(
        fingerprint: localFingerprint,
        completedAt: DateTime.now(),
      );
      await File(
        p.join(database.rootDirectory.path, 'migration-report.json'),
      ).writeAsString(
        const JsonEncoder.withIndent(
          '  ',
        ).convert({...report.toMap(), 'photos': photoManifest}),
        flush: true,
      );
      return report;
    } finally {
      await staging.close();
      if (await stagingRoot.exists()) await stagingRoot.delete(recursive: true);
    }
  }

  void _verify(DataFingerprint remote, DataFingerprint local) {
    final matches =
        remote.recordCount == local.recordCount &&
        remote.recordsSha256 == local.recordsSha256 &&
        remote.uuidSha256 == local.uuidSha256 &&
        remote.statusCounts.toString() == local.statusCounts.toString() &&
        remote.totalDuration == local.totalDuration &&
        remote.totalRemaining == local.totalRemaining &&
        remote.photoCount == local.photoCount;
    if (!matches) throw StateError('迁移指纹不一致，未写入正式本地数据库');
  }
}

class ExpectedBaseline {
  const ExpectedBaseline({
    required this.recordCount,
    required this.recordsSha256,
    required this.uuidSha256,
    required this.photoCount,
    required this.photoBindings,
  });

  final int recordCount;
  final String recordsSha256;
  final String uuidSha256;
  final int photoCount;
  final Map<String, PhotoBaseline> photoBindings;

  void verify(DataFingerprint actual) {
    if (actual.recordCount != recordCount ||
        actual.recordsSha256 != recordsSha256 ||
        actual.uuidSha256 != uuidSha256 ||
        actual.photoCount != photoCount) {
      throw StateError('Supabase 当前数据与迁移前外部只读基线不一致');
    }
    if (photoBindings.length != photoCount) {
      throw StateError('外部照片基线数量与清单不一致');
    }
  }

  void verifyRecords(List<OvertimeRecord> records) {
    final photographed = records.where((record) => record.photoPath != null);
    if (photographed.length != photoBindings.length) {
      throw StateError('记录与外部照片关联基线数量不一致');
    }
    for (final record in photographed) {
      final binding = photoBindings[record.id];
      if (binding == null || binding.remotePath != record.photoPath) {
        throw StateError('记录 ${record.id} 的照片关联与迁移前基线不一致');
      }
    }
  }

  void verifyPhoto(String recordId, String remotePath, List<int> bytes) {
    final binding = photoBindings[recordId];
    final actual = sha256.convert(bytes).toString();
    if (binding == null ||
        binding.remotePath != remotePath ||
        binding.sha256 != actual) {
      throw StateError('照片与迁移前外部基线不一致：$remotePath');
    }
  }
}

class PhotoBaseline {
  const PhotoBaseline({required this.remotePath, required this.sha256});

  final String remotePath;
  final String sha256;
}
