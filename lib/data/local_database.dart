import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../domain/business_rules.dart';
import '../domain/holiday_calendar.dart';
import '../domain/overtime_record.dart';

class LocalDatabase {
  LocalDatabase._(this.db, this.rootDirectory);

  static const schemaVersion = 1;
  static const databaseName = 'over_balance_flow.db';
  final Database db;
  final Directory rootDirectory;

  static Future<LocalDatabase> open({
    String? databasePath,
    Directory? rootDirectory,
  }) async {
    final root = rootDirectory ?? await getApplicationSupportDirectory();
    await root.create(recursive: true);
    final path = databasePath ?? p.join(root.path, databaseName);
    final database = await openDatabase(
      path,
      version: schemaVersion,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: _createSchema,
      onUpgrade: (db, oldVersion, newVersion) async {
        throw StateError('数据库升级必须通过显式迁移，禁止自动重建');
      },
      onDowngrade: (db, oldVersion, newVersion) async {
        throw StateError('检测到更高版本数据库，禁止用旧版 App 降级打开');
      },
    );
    return LocalDatabase._(database, root);
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE ot_records (
        id TEXT PRIMARY KEY NOT NULL,
        ot_date TEXT NOT NULL,
        start_time TEXT NOT NULL,
        end_time TEXT NOT NULL,
        duration REAL NOT NULL,
        total_hours REAL NOT NULL,
        remaining_hours REAL NOT NULL CHECK (remaining_hours >= 0),
        status TEXT NOT NULL CHECK (status IN ('待核销','部分核销','已结清','已调休')),
        memo TEXT NOT NULL DEFAULT '',
        photo_path TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX ot_records_date_idx ON ot_records(ot_date, created_at, id)',
    );
    await db.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE holiday_calendar (
        date TEXT PRIMARY KEY NOT NULL,
        is_day_off INTEGER NOT NULL CHECK (is_day_off IN (0,1)),
        source TEXT NOT NULL,
        calendar_version TEXT NOT NULL
      )
    ''');
    final batch = db.batch();
    for (final entry in HolidayCalendar.defaults2026.entries) {
      batch.insert('holiday_calendar', {
        'date': entry.key,
        'is_day_off': entry.value ? 1 : 0,
        'source': 'builtin',
        'calendar_version': '2026.1',
      });
    }
    await batch.commit(noResult: true);
  }

  Future<List<OvertimeRecord>> records() async {
    final rows = await db.query(
      'ot_records',
      orderBy: 'ot_date DESC, created_at DESC, id DESC',
    );
    return rows.map(OvertimeRecord.fromMap).toList();
  }

  Future<void> addRecord(OvertimeRecord record) async {
    await db.insert(
      'ot_records',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  Future<void> replaceCache(List<OvertimeRecord> records) async {
    await db.transaction((txn) async {
      await txn.delete('ot_records');
      for (final record in records) {
        await txn.insert(
          'ot_records',
          record.toMap(),
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
      }
    });
  }

  Future<void> reconcile({
    required String leaveId,
    required String date,
    required String startTime,
    required String endTime,
    required ReconciliationPreview preview,
    required String createdAt,
  }) async {
    if (preview.details.isEmpty || preview.deductedHours <= 0) {
      throw StateError('没有可核销的余额');
    }
    await db.transaction((txn) async {
      for (final detail in preview.details) {
        final rows = await txn.query(
          'ot_records',
          where: 'id = ?',
          whereArgs: [detail.id],
          limit: 1,
        );
        if (rows.isEmpty) throw StateError('原加班记录不存在：${detail.id}');
        final record = OvertimeRecord.fromMap(rows.single);
        if (record.remainingHours < detail.deduct)
          throw StateError('余额已变化，请重新预览');
        final remaining = _round(record.remainingHours - detail.deduct);
        final status = remaining <= 0 ? '已结清' : '部分核销';
        await txn.update(
          'ot_records',
          {'remaining_hours': remaining, 'status': status},
          where: 'id = ?',
          whereArgs: [record.id],
        );
      }
      await txn.insert(
        'ot_records',
        OvertimeRecord(
          id: leaveId,
          otDate: date,
          startTime: startTime,
          endTime: endTime,
          duration: -preview.deductedHours,
          totalHours: -preview.deductedHours,
          remainingHours: 0,
          status: '已调休',
          memo: jsonEncode(
            preview.details.map((item) => item.toMap()).toList(),
          ),
          createdAt: createdAt,
        ).toMap(),
      );
    });
  }

  Future<void> deleteRecord(String id) async {
    await db.transaction((txn) async {
      final rows = await txn.query(
        'ot_records',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('记录不存在');
      final record = OvertimeRecord.fromMap(rows.single);
      if (!record.isLeave) {
        final leaveRows = await txn.query(
          'ot_records',
          columns: ['memo'],
          where: 'status = ?',
          whereArgs: ['已调休'],
        );
        final referenced = leaveRows.any((row) {
          try {
            return ReconciliationDetail.decode(
              row['memo'] as String,
            ).any((detail) => detail.id == record.id);
          } catch (_) {
            return false;
          }
        });
        if (referenced) {
          throw StateError('该加班已有核销历史，请先删除关联的调休记录');
        }
      }
      final deleted = await txn.delete(
        'ot_records',
        where: 'id = ?',
        whereArgs: [id],
      );
      if (deleted != 1) throw StateError('删除失败，未返还任何余额');
      if (!record.isLeave || record.memo.isEmpty) return;
      for (final detail in ReconciliationDetail.decode(record.memo)) {
        final targetRows = await txn.query(
          'ot_records',
          where: 'id = ?',
          whereArgs: [detail.id],
          limit: 1,
        );
        if (targetRows.isEmpty) throw StateError('无法返还，原记录不存在：${detail.id}');
        final target = OvertimeRecord.fromMap(targetRows.single);
        final restored = _round(target.remainingHours + detail.deduct);
        if (restored > target.duration + 0.001) throw StateError('返还后余额超过原始时长');
        final status = restored >= target.duration ? '待核销' : '部分核销';
        await txn.update(
          'ot_records',
          {'remaining_hours': restored, 'status': status},
          where: 'id = ?',
          whereArgs: [target.id],
        );
      }
    });
  }

  Future<HolidayCalendar> holidays() async {
    final rows = await db.query('holiday_calendar');
    return HolidayCalendar({
      for (final row in rows) row['date'] as String: row['is_day_off'] == 1,
    });
  }

  Future<void> importHolidayCalendar(
    Map<String, bool> entries,
    String version,
  ) async {
    await db.transaction((txn) async {
      for (final entry in entries.entries) {
        if (DateTime.tryParse(entry.key) == null)
          throw FormatException('无效日期：${entry.key}');
        await txn.insert('holiday_calendar', {
          'date': entry.key,
          'is_day_off': entry.value ? 1 : 0,
          'source': 'import',
          'calendar_version': version,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<String?> setting(String key) async {
    final rows = await db.query(
      'settings',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  Future<void> setSetting(String key, String value) => db.insert('settings', {
    'key': key,
    'value': value,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<Directory> photosDirectory() async {
    final directory = Directory(p.join(rootDirectory.path, 'photos'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> photoFile(String remotePath) async {
    final normalized = p.normalize(remotePath);
    final cachePath = normalized.startsWith('photos${p.separator}')
        ? normalized.substring('photos${p.separator}'.length)
        : normalized;
    final safeSegments = cachePath
        .split(p.separator)
        .where((segment) => segment.isNotEmpty && segment != '..')
        .toList();
    final file = File(
      p.joinAll([rootDirectory.path, 'photos', ...safeSegments]),
    );
    await file.parent.create(recursive: true);
    return file;
  }

  Future<void> close() => db.close();
}

double _round(double value) => (value * 100).round() / 100;
