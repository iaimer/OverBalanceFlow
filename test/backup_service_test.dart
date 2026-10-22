import 'dart:io';
import 'dart:convert';
import 'package:archive/archive_io.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:over_balance_flow/data/backup_service.dart';
import 'package:over_balance_flow/domain/annual_leave.dart';
import 'package:over_balance_flow/data/local_database.dart';
import 'package:over_balance_flow/data/supabase_repository.dart';
import 'package:over_balance_flow/domain/overtime_record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('ZIP 导出后可验证并按 UUID 合并恢复', () async {
    final sourceRoot = await Directory.systemTemp.createTemp('obf-source-');
    final targetRoot = await Directory.systemTemp.createTemp('obf-target-');
    final output = await Directory.systemTemp.createTemp('obf-output-');
    final source = await LocalDatabase.open(
      databasePath: '${sourceRoot.path}/source.db',
      rootDirectory: sourceRoot,
    );
    final target = await LocalDatabase.open(
      databasePath: '${targetRoot.path}/target.db',
      rootDirectory: targetRoot,
    );
    try {
      await source.addRecord(record('same', '源备份'));
      await source.addRecord(record('new', '新增'));
      await target.addRecord(record('same', '旧本地'));
      await target.addRecord(record('keep', '保留'));
      final backup = await BackupService(source).exportTo(output);
      final manifest = await BackupService(source).verify(backup);
      expect(manifest['format_version'], 2);
      await BackupService(target).restore(backup);
      final records = await target.records();
      expect(records.map((item) => item.id).toSet(), {'same', 'new', 'keep'});
      expect(records.firstWhere((item) => item.id == 'same').memo, '源备份');
      expect(
        targetRoot.listSync().whereType<Directory>().any(
          (directory) => directory.path.contains('pre-restore-'),
        ),
        isTrue,
      );
    } finally {
      await source.close();
      await target.close();
      await sourceRoot.delete(recursive: true);
      await targetRoot.delete(recursive: true);
      await output.delete(recursive: true);
    }
  });

  test('ZIP 包含年假天数与事由并可恢复', () async {
    final root = await Directory.systemTemp.createTemp('obf-annual-backup-');
    final source = await LocalDatabase.open(
      databasePath: '${root.path}/source.db',
      rootDirectory: root,
    );
    final target = await LocalDatabase.open(
      databasePath: '${root.path}/target.db',
      rootDirectory: root,
    );
    try {
      final annual = AnnualLeaveRecord(
        id: 'annual',
        startDate: '2026-08-03',
        endDate: '2026-08-03',
        slots: const [AnnualLeaveSlot('2026-08-03', 'am')],
        reason: '陪家人',
        createdAt: '2026-08-01T00:00:00Z',
      );
      await source.replaceLedgerCache([], [annual], LeaveCalendar.builtin2026);
      final file = await BackupService(
        source,
      ).exportTo(Directory('${root.path}/output'));
      await BackupService(target).restore(file);
      expect((await target.annualRecords()).single.toMap(), annual.toMap());
    } finally {
      await source.close();
      await target.close();
      await root.delete(recursive: true);
    }
  });

  test('旧版 v1 ZIP 可校验恢复且不清空既有年假', () async {
    final root = await Directory.systemTemp.createTemp('obf-v1-backup-');
    final db = await LocalDatabase.open(
      databasePath: '${root.path}/db',
      rootDirectory: root,
    );
    try {
      await db.addRecord(record('old', '旧版本'));
      final v2 = await BackupService(
        db,
      ).exportTo(Directory('${root.path}/out'));
      final archive = ZipDecoder().decodeBytes(await v2.readAsBytes());
      final old = Archive();
      for (final file in archive.files.where(
        (f) =>
            f.isFile &&
            f.name != 'annual_leave.json' &&
            f.name != 'leave_calendar.json',
      )) {
        if (file.name == 'manifest.json') {
          final manifest =
              jsonDecode(utf8.decode(file.content as List<int>))
                  as Map<String, dynamic>;
          manifest['format_version'] = 1;
          (manifest['file_hashes'] as Map).remove('annual_leave.json');
          (manifest['file_hashes'] as Map).remove('leave_calendar.json');
          final bytes = utf8.encode(jsonEncode(manifest));
          old.addFile(ArchiveFile('manifest.json', bytes.length, bytes));
        } else {
          old.addFile(file);
        }
      }
      final v1 = File('${root.path}/v1.zip');
      await v1.writeAsBytes(ZipEncoder().encode(old));
      final annual = AnnualLeaveRecord(
        id: 'keep',
        startDate: '2026-08-03',
        endDate: '2026-08-03',
        slots: const [AnnualLeaveSlot('2026-08-03', 'am')],
        createdAt: '2026-01-01T00:00:00Z',
      );
      await db.replaceLedgerCache([], [annual], LeaveCalendar.builtin2026);
      await BackupService(db).restore(v1);
      expect((await db.records()).single.id, 'old');
      expect((await db.annualRecords()).single.id, 'keep');
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });

  test('云端恢复超时且无法确认提交状态时保留已上传照片', () async {
    final root = await Directory.systemTemp.createTemp('obf-restore-timeout-');
    final db = await LocalDatabase.open(
      databasePath: '${root.path}/db',
      rootDirectory: root,
    );
    try {
      await db.addRecord(photoRecord('photo', 'photos/test.jpg'));
      await File('${root.path}/photos/test.jpg').create(recursive: true);
      await File('${root.path}/photos/test.jpg').writeAsBytes([1, 2, 3]);
      final zip = await BackupService(
        db,
      ).exportTo(Directory('${root.path}/out'));
      final remote = UncertainRestoreRemote();
      await expectLater(
        BackupService(db).restoreToCloud(zip, remote),
        throwsA(isA<HttpException>()),
      );
      expect(remote.uploaded, hasLength(1));
      expect(remote.deleted, isEmpty);
      expect(
        root.listSync().whereType<Directory>().any(
          (d) => d.path.contains('pre-cloud-restore-'),
        ),
        isTrue,
      );
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });

  test('损坏的 ZIP 在写数据库前被拒绝', () async {
    final root = await Directory.systemTemp.createTemp('obf-corrupt-');
    final database = await LocalDatabase.open(
      databasePath: '${root.path}/db.sqlite',
      rootDirectory: root,
    );
    try {
      await database.addRecord(record('safe', '原数据'));
      final broken = File('${root.path}/broken.zip')
        ..writeAsBytesSync([1, 2, 3]);
      await expectLater(
        BackupService(database).restore(broken),
        throwsA(anything),
      );
      expect((await database.records()).single.id, 'safe');
    } finally {
      await database.close();
      await root.delete(recursive: true);
    }
  });

  test('同 UUID 更换照片后恢复可清理旧照片并继续导出', () async {
    final sourceRoot = await Directory.systemTemp.createTemp(
      'obf-photo-source-',
    );
    final targetRoot = await Directory.systemTemp.createTemp(
      'obf-photo-target-',
    );
    final output = await Directory.systemTemp.createTemp('obf-photo-output-');
    final source = await LocalDatabase.open(
      databasePath: '${sourceRoot.path}/source.db',
      rootDirectory: sourceRoot,
    );
    final target = await LocalDatabase.open(
      databasePath: '${targetRoot.path}/target.db',
      rootDirectory: targetRoot,
    );
    try {
      await source.addRecord(photoRecord('same', 'photos/new.jpg'));
      await target.addRecord(photoRecord('same', 'photos/old.jpg'));
      await File('${sourceRoot.path}/photos/new.jpg')
          .create(recursive: true)
          .then((file) => file.writeAsBytes([1, 2, 3], flush: true));
      await File('${targetRoot.path}/photos/old.jpg')
          .create(recursive: true)
          .then((file) => file.writeAsBytes([4, 5, 6], flush: true));

      final backup = await BackupService(source).exportTo(output);
      await BackupService(target).restore(backup);

      expect((await target.records()).single.photoPath, 'photos/new.jpg');
      expect(File('${targetRoot.path}/photos/new.jpg').existsSync(), isTrue);
      expect(File('${targetRoot.path}/photos/old.jpg').existsSync(), isFalse);
      final recovery = targetRoot.listSync().whereType<Directory>().firstWhere(
        (item) => item.path.contains('pre-restore-'),
      );
      expect(File('${recovery.path}/photos/old.jpg').existsSync(), isTrue);
      await expectLater(BackupService(target).exportTo(output), completes);
    } finally {
      await source.close();
      await target.close();
      await sourceRoot.delete(recursive: true);
      await targetRoot.delete(recursive: true);
      await output.delete(recursive: true);
    }
  });
}

OvertimeRecord record(String id, String memo) => OvertimeRecord(
  id: id,
  otDate: '2026-01-01',
  startTime: '17:00',
  endTime: '18:00',
  duration: 1,
  totalHours: 1,
  remainingHours: 1,
  status: '待核销',
  memo: memo,
  createdAt: '2026-01-01T00:00:00Z',
);

OvertimeRecord photoRecord(String id, String photoPath) => OvertimeRecord(
  id: id,
  otDate: '2026-01-01',
  startTime: '17:00',
  endTime: '18:00',
  duration: 1,
  totalHours: 1,
  remainingHours: 1,
  status: '待核销',
  memo: '照片测试',
  createdAt: '2026-01-01T00:00:00Z',
  photoPath: photoPath,
);

class UncertainRestoreRemote extends SupabaseRepository {
  UncertainRestoreRemote()
    : super(const SupabaseConfig('https://example.invalid', 'test'));
  final uploaded = <String>[];
  final deleted = <String>[];
  @override
  Future<void> uploadPhoto(
    String path,
    List<int> bytes, {
    required String contentType,
  }) async {
    uploaded.add(path);
  }

  @override
  Future<void> restoreLedger(
    List<OvertimeRecord> records,
    List<AnnualLeaveRecord> annual,
  ) async {
    throw const HttpException('timeout');
  }

  @override
  Future<LedgerSnapshot> fetchLedger() async {
    throw const HttpException('offline');
  }

  @override
  Future<void> deletePhoto(String path) async {
    deleted.add(path);
  }
}
