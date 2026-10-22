import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../domain/overtime_record.dart';
import '../domain/annual_leave.dart';
import '../domain/ledger_validator.dart';
import 'data_fingerprint.dart';
import 'local_database.dart';
import 'supabase_repository.dart';

class BackupService {
  BackupService(this.database);
  static const formatVersion = 2;
  final LocalDatabase database;

  Future<File> exportTo(Directory destination) async {
    final records = await database.records();
    final annual = await database.annualRecords();
    validateAnnualLedger(annual, records);
    final calendar = await database.leaveCalendar();
    final holidays = await database.db.query('holiday_calendar');
    final fingerprint = DataFingerprint.fromRecords(records);
    final staging = await Directory.systemTemp.createTemp('obf-export-');
    try {
      final recordsFile = File(p.join(staging.path, 'records.json'));
      final calendarFile = File(p.join(staging.path, 'holiday_calendar.json'));
      await recordsFile.writeAsString(
        jsonEncode(records.map((record) => record.toMap()).toList()),
        flush: true,
      );
      await calendarFile.writeAsString(jsonEncode(holidays), flush: true);
      final photoDirectory = await database.photosDirectory();
      final hashes = <String, String>{};
      for (final entry in <String, Object>{
        'annual_leave.json': annual.map((r) => r.toMap()).toList(),
        'leave_calendar.json': calendar.rows,
      }.entries) {
        final bytes = utf8.encode(jsonEncode(entry.value));
        await File(
          p.join(staging.path, entry.key),
        ).writeAsBytes(bytes, flush: true);
        hashes[entry.key] = sha256.convert(bytes).toString();
      }
      final referencedPhotos = records
          .map((record) => record.photoPath)
          .whereType<String>()
          .toSet();
      final diskPhotos = photoDirectory
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => p.relative(file.path, from: photoDirectory.path))
          .toSet();
      final orphaned = diskPhotos.difference(referencedPhotos);
      for (final referencedPath in referencedPhotos) {
        final source = await database.photoFile(referencedPath);
        if (!await source.exists()) {
          throw StateError('记录引用的照片不存在：$referencedPath');
        }
        final archivePath = referencedPath;
        final target = File(p.join(staging.path, archivePath));
        await target.parent.create(recursive: true);
        await source.copy(target.path);
        hashes[archivePath] = sha256
            .convert(await target.readAsBytes())
            .toString();
      }
      hashes['records.json'] = sha256
          .convert(await recordsFile.readAsBytes())
          .toString();
      hashes['holiday_calendar.json'] = sha256
          .convert(await calendarFile.readAsBytes())
          .toString();
      final manifest = {
        'format_version': formatVersion,
        'exported_at': DateTime.now().toIso8601String(),
        'fingerprint': fingerprint.toMap(),
        'file_hashes': hashes,
        'orphan_photos_ignored': orphaned.toList()..sort(),
      };
      await File(p.join(staging.path, 'manifest.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert(manifest),
        flush: true,
      );
      await destination.create(recursive: true);
      final file = File(
        p.join(destination.path, _backupFileName(DateTime.now())),
      );
      final encoder = ZipFileEncoder()..create(file.path);
      await encoder.addDirectory(staging, includeDirName: false);
      await encoder.close();
      await verify(file);
      await database.setSetting(
        'last_backup_at',
        DateTime.now().toIso8601String(),
      );
      return file;
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<Map<String, dynamic>> verify(File zipFile) async {
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    final files = <String, List<int>>{};
    for (final item in archive.files.where((item) => item.isFile)) {
      if (files.containsKey(item.name)) {
        throw FormatException('备份包含重复路径：${item.name}');
      }
      files[item.name] = item.content as List<int>;
    }
    final manifestBytes = files['manifest.json'];
    if (manifestBytes == null) throw FormatException('备份缺少 manifest.json');
    final manifest =
        jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
    if (manifest['format_version'] != 1 &&
        manifest['format_version'] != formatVersion)
      throw FormatException('不支持的备份版本');
    final hashes = manifest['file_hashes'] as Map<String, dynamic>;
    final expectedHashedFiles = files.keys
        .where((name) => name != 'manifest.json')
        .toSet();
    if (hashes.keys.toSet().length != expectedHashedFiles.length ||
        !hashes.keys.toSet().containsAll(expectedHashedFiles)) {
      throw const FormatException('备份哈希清单不完整或包含未知项目');
    }
    for (final entry in hashes.entries) {
      final bytes = files[entry.key];
      if (bytes == null || sha256.convert(bytes).toString() != entry.value) {
        throw FormatException('备份文件损坏：${entry.key}');
      }
    }
    final recordsBytes = files['records.json'];
    if (recordsBytes == null) throw const FormatException('备份缺少 records.json');
    final records = (jsonDecode(utf8.decode(recordsBytes)) as List<dynamic>)
        .map((item) => OvertimeRecord.fromMap(item as Map<String, dynamic>))
        .toList();
    LedgerValidator.validate(records);
    final annual = _annualFromFiles(files, manifest['format_version'] as int);
    validateAnnualLedger(annual, records);
    if (manifest['format_version'] == 2) {
      final calendarBytes = files['leave_calendar.json'];
      if (calendarBytes == null) throw const FormatException('备份缺少年假日历');
      final calendar = LeaveCalendar(
        (jsonDecode(utf8.decode(calendarBytes)) as List<dynamic>)
            .cast<Map<String, dynamic>>(),
      );
      validateAnnualCalendar(annual, calendar);
    }
    for (final record in records) {
      if (record.photoPath != null && !files.containsKey(record.photoPath)) {
        throw FormatException('记录 ${record.id} 引用的照片不在备份中');
      }
    }
    final manifestFingerprint =
        manifest['fingerprint'] as Map<String, dynamic>?;
    final actualFingerprint = DataFingerprint.fromRecords(records).toMap();
    if (manifestFingerprint == null ||
        jsonEncode(manifestFingerprint) != jsonEncode(actualFingerprint)) {
      throw const FormatException('备份记录指纹与 manifest 不一致');
    }
    return manifest;
  }

  static List<AnnualLeaveRecord> _annualFromFiles(
    Map<String, List<int>> files,
    int version,
  ) {
    if (version == 1) return [];
    final bytes = files['annual_leave.json'];
    if (bytes == null) throw const FormatException('备份缺少年假记录');
    return (jsonDecode(utf8.decode(bytes)) as List<dynamic>)
        .map((r) => AnnualLeaveRecord.fromMap(r as Map<String, dynamic>))
        .toList();
  }

  static String _backupFileName(DateTime timestamp) {
    final local = timestamp.toLocal();
    String part(int value, int width) => value.toString().padLeft(width, '0');
    final date = '${local.year}-${part(local.month, 2)}-${part(local.day, 2)}';
    final time =
        '${part(local.hour, 2)}${part(local.minute, 2)}${part(local.second, 2)}';
    return '偷闲半日-备份-$date-$time.zip';
  }

  Future<Directory> createRecoveryPoint(String label) async {
    final recovery = Directory(
      p.join(
        database.rootDirectory.path,
        '$label-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await recovery.create(recursive: true);
    final checkpoint = await database.db.rawQuery(
      'PRAGMA wal_checkpoint(FULL)',
    );
    if (checkpoint.any((row) => row['busy'] != 0)) {
      throw StateError('数据库仍在写入，无法创建完整恢复点，请稍后重试');
    }
    await File(database.db.path).copy(p.join(recovery.path, 'database.db'));
    final photos = await database.photosDirectory();
    for (final photo in photos.listSync(recursive: true).whereType<File>()) {
      final target = File(
        p.join(
          recovery.path,
          'photos',
          p.relative(photo.path, from: photos.path),
        ),
      );
      await target.parent.create(recursive: true);
      await photo.copy(target.path);
    }
    return recovery;
  }

  Future<void> restore(File zipFile) async {
    final manifest = await verify(zipFile);
    await createRecoveryPoint('pre-restore');
    final photos = await database.photosDirectory();
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    final recordsEntry = archive.files.firstWhere(
      (item) => item.name == 'records.json',
    );
    final incoming =
        (jsonDecode(utf8.decode(recordsEntry.content as List<int>))
                as List<dynamic>)
            .map((item) => OvertimeRecord.fromMap(item as Map<String, dynamic>))
            .toList();
    final files = {
      for (final item in archive.files.where((f) => f.isFile))
        item.name: item.content as List<int>,
    };
    final incomingAnnual = _annualFromFiles(
      files,
      manifest['format_version'] as int,
    );
    final mergedAnnual = <String, AnnualLeaveRecord>{
      for (final record in await database.annualRecords()) record.id: record,
      for (final record in incomingAnnual) record.id: record,
    }.values.toList();
    final current = await database.records();
    final merged = <String, OvertimeRecord>{
      for (final record in current) record.id: record,
      for (final record in incoming) record.id: record,
    }.values.toList();
    LedgerValidator.validate(merged);
    validateAnnualLedger(mergedAnnual, merged);
    final createdPhotos = <File>[];
    try {
      final incomingPhotoPaths = incoming
          .map((record) => record.photoPath)
          .whereType<String>()
          .toSet();
      for (final item in archive.files.where(
        (item) => item.isFile && incomingPhotoPaths.contains(item.name),
      )) {
        final target = await database.photoFile(item.name);
        if (await target.exists()) {
          final existingHash = sha256
              .convert(await target.readAsBytes())
              .toString();
          final incomingHash = sha256
              .convert(item.content as List<int>)
              .toString();
          if (existingHash != incomingHash) {
            throw FormatException('本地存在同名但内容不同的照片：${item.name}');
          }
        } else {
          await target.writeAsBytes(item.content as List<int>, flush: true);
          createdPhotos.add(target);
        }
      }
      await database.db.transaction((txn) async {
        for (final record in incoming) {
          await txn.insert(
            'ot_records',
            record.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final record in incomingAnnual) {
          await txn.insert(
            'annual_leave_records',
            record.toDatabaseMap(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        if (files.containsKey('leave_calendar.json')) {
          final rows =
              (jsonDecode(utf8.decode(files['leave_calendar.json']!))
                      as List<dynamic>)
                  .cast<Map<String, dynamic>>();
          for (final row in LeaveCalendar(rows).rows) {
            await txn.insert('leave_calendar', {
              ...row,
              'is_day_off': row['is_day_off'] == true ? 1 : 0,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
        final calendarEntries = archive.files.where(
          (item) => item.name == 'holiday_calendar.json',
        );
        if (calendarEntries.isNotEmpty) {
          final calendar =
              jsonDecode(
                    utf8.decode(calendarEntries.first.content as List<int>),
                  )
                  as List<dynamic>;
          for (final item in calendar) {
            await txn.insert(
              'holiday_calendar',
              item as Map<String, dynamic>,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
      });
    } catch (_) {
      for (final photo in createdPhotos) {
        if (await photo.exists()) {
          await photo.delete();
        }
      }
      rethrow;
    }
    final referencedAfterRestore = merged
        .map((record) => record.photoPath)
        .whereType<String>()
        .map(
          (path) => path.startsWith('photos/')
              ? path.substring('photos/'.length)
              : path,
        )
        .toSet();
    final pendingCleanup = <String>[];
    for (final photo in photos.listSync(recursive: true).whereType<File>()) {
      final relative = p.relative(photo.path, from: photos.path);
      if (referencedAfterRestore.contains(relative)) continue;
      try {
        await photo.delete();
      } catch (_) {
        pendingCleanup.add(relative);
      }
    }
    try {
      await database.setSetting(
        'pending_photo_cleanup',
        jsonEncode(pendingCleanup),
      );
    } catch (_) {
      // 账本事务已经提交；诊断信息写入失败不能把成功恢复误报为失败。
    }
    try {
      await database.setSetting(
        'last_restore_at',
        DateTime.now().toIso8601String(),
      );
    } catch (_) {
      // 恢复事务已经提交，元数据写入失败不能把成功恢复误报为失败。
    }
  }

  Future<void> restoreToCloud(
    File zipFile,
    SupabaseRepository repository,
  ) async {
    final manifest = await verify(zipFile);
    await createRecoveryPoint('pre-cloud-restore');
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    final files = {
      for (final item in archive.files.where((item) => item.isFile))
        item.name: item.content as List<int>,
    };
    final records =
        (jsonDecode(utf8.decode(files['records.json']!)) as List<dynamic>)
            .map((item) => OvertimeRecord.fromMap(item as Map<String, dynamic>))
            .toList();
    final uploaded = <String>[];
    final rewritten = <OvertimeRecord>[];
    try {
      for (final record in records) {
        final oldPath = record.photoPath;
        if (oldPath == null) {
          rewritten.add(record);
          continue;
        }
        final bytes = files[oldPath];
        if (bytes == null) throw FormatException('备份缺少照片：$oldPath');
        final extension = p.extension(oldPath).isEmpty
            ? '.jpg'
            : p.extension(oldPath);
        final newPath =
            'restore/${record.id}/${DateTime.now().microsecondsSinceEpoch}$extension';
        await repository.uploadPhoto(
          newPath,
          bytes,
          contentType: extension == '.png' ? 'image/png' : 'image/jpeg',
        );
        uploaded.add(newPath);
        rewritten.add(record.copyWith(photoPath: newPath));
      }
      LedgerValidator.validate(rewritten);
      final annual = _annualFromFiles(files, manifest['format_version'] as int);
      validateAnnualLedger(annual, rewritten);
      await repository.restoreLedger(rewritten, annual);
    } catch (_) {
      // 请求超时也可能已经提交。只有重新读到快照、确认对象未被引用才清理。
      try {
        final snapshot = await repository.fetchLedger();
        final referenced = snapshot.records
            .map((r) => r.photoPath)
            .whereType<String>()
            .toSet();
        for (final path in uploaded.where(
          (path) => !referenced.contains(path),
        )) {
          try {
            await repository.deletePhoto(path);
          } catch (_) {
            /* 保留待审计的未引用照片。 */
          }
        }
      } catch (_) {
        /* 无法确认远端状态时保留所有已上传对象。 */
      }
      rethrow;
    }
  }
}
