import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'data/backup_service.dart';
import 'data/local_database.dart';
import 'data/migration_service.dart';
import 'data/supabase_repository.dart';
import 'domain/business_rules.dart';
import 'domain/holiday_calendar.dart';
import 'domain/overtime_record.dart';

class AppController extends ChangeNotifier {
  AppController(this.database)
    : backupService = BackupService(database),
      remote = _buildRemote(),
      _holidays = HolidayCalendar(HolidayCalendar.defaults2026);

  final LocalDatabase database;
  final BackupService backupService;
  final SupabaseRepository? remote;
  final _uuid = const Uuid();
  List<OvertimeRecord> records = [];
  HolidayCalendar _holidays;
  bool loading = true;
  bool migrationRequired = false;
  String? migrationError;
  String? migrationReport;
  bool usingOfflineCache = false;
  bool syncing = false;
  String? syncError;
  Future<void>? _activeSync;
  bool _mutating = false;

  Future<void> initialize() async {
    records = await database.records();
    _holidays = HolidayCalendar(HolidayCalendar.defaults2026);
    migrationRequired = remote == null && records.isEmpty;
    migrationReport = await database.setting('migration_report');
    loading = false;
    usingOfflineCache = records.isNotEmpty;
    notifyListeners();
    if (remote != null) {
      syncing = true;
      notifyListeners();
      unawaited(_syncInitially());
    }
  }

  Future<void> _syncInitially() async {
    try {
      await syncFromCloud();
    } catch (_) {
      // 同步入口会保留缓存并记录真实失败状态。
    }
  }

  Future<void> syncFromCloud() => _syncFromCloud();

  Future<void> _syncFromCloud({bool allowDuringMutation = false}) {
    if (_mutating && !allowDuringMutation) {
      throw StateError('正在提交云端账本，请完成后再刷新');
    }
    final active = _activeSync;
    if (active != null) return active;
    syncing = true;
    syncError = null;
    notifyListeners();
    final sync = _performCloudSync();
    _activeSync = sync.whenComplete(() {
      _activeSync = null;
      syncing = false;
      notifyListeners();
    });
    return _activeSync!;
  }

  Future<void> _performCloudSync() async {
    final repository = remote;
    if (repository == null) throw StateError('安装包未配置 Supabase');
    try {
      final cloudRecords = await repository.fetchAll();
      if (cloudRecords.isEmpty && records.isNotEmpty) {
        throw StateError('线上返回空账本，为避免覆盖缓存已中止同步');
      }
      await database.replaceCache(cloudRecords);
      records = cloudRecords;
      usingOfflineCache = false;
      syncError = null;
      notifyListeners();
      unawaited(_cacheCloudPhotos(repository, cloudRecords));
    } catch (error) {
      usingOfflineCache = records.isNotEmpty;
      syncError = records.isEmpty ? '尚未取得云端账本：$error' : '云端同步失败：$error';
      rethrow;
    }
  }

  Future<void> _cacheCloudPhotos(
    SupabaseRepository repository,
    List<OvertimeRecord> source,
  ) async {
    for (final record in source) {
      final remotePath = record.photoPath;
      if (remotePath == null) continue;
      final file = await database.photoFile(remotePath);
      if (await file.exists()) continue;
      try {
        await file.writeAsBytes(
          await repository.downloadPhoto(remotePath),
          flush: true,
        );
      } catch (_) {
        // 记录缓存仍可用；照片会在下次同步继续下载。
      }
    }
  }

  Future<void> migrate() async {
    const url = String.fromEnvironment('SUPABASE_URL');
    const key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
    const baselineCount = int.fromEnvironment('BASELINE_RECORD_COUNT');
    const baselineRecordsHash = String.fromEnvironment(
      'BASELINE_RECORDS_SHA256',
    );
    const baselineUuidHash = String.fromEnvironment('BASELINE_UUID_SHA256');
    const baselinePhotoCount = int.fromEnvironment('BASELINE_PHOTO_COUNT');
    const baselinePhotosJson = String.fromEnvironment('BASELINE_PHOTOS_JSON');
    if (url.isEmpty || key.isEmpty) {
      migrationError = '安装包未包含只读迁移配置，请使用正式迁移版 APK。';
      notifyListeners();
      return;
    }
    if (baselineCount <= 0 ||
        baselineRecordsHash.isEmpty ||
        baselineUuidHash.isEmpty ||
        baselinePhotosJson.isEmpty) {
      migrationError = '缺少迁移前外部只读基线，已拒绝不受保护的历史迁移。';
      notifyListeners();
      return;
    }
    Map<String, PhotoBaseline> baselinePhotos;
    try {
      baselinePhotos = (jsonDecode(baselinePhotosJson) as Map<String, dynamic>)
          .map((recordId, value) {
            final item = value as Map<String, dynamic>;
            return MapEntry(
              recordId,
              PhotoBaseline(
                remotePath: item['path'] as String,
                sha256: item['sha256'] as String,
              ),
            );
          });
    } catch (_) {
      migrationError = 'BASELINE_PHOTOS_JSON 格式无效，已拒绝迁移。';
      notifyListeners();
      return;
    }
    loading = true;
    migrationError = null;
    notifyListeners();
    try {
      final report = await MigrationService(
        database,
        const ReadOnlySupabaseSource(baseUrl: url, publishableKey: key),
        expectedBaseline: ExpectedBaseline(
          recordCount: baselineCount,
          recordsSha256: baselineRecordsHash,
          uuidSha256: baselineUuidHash,
          photoCount: baselinePhotoCount,
          photoBindings: baselinePhotos,
        ),
      ).migrate();
      records = await database.records();
      migrationRequired = false;
      migrationReport =
          await database.setting('migration_report') ??
          jsonEncode(report.toMap());
    } catch (error) {
      migrationError = error.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> restoreFreshInstall(File backup) async {
    loading = true;
    migrationError = null;
    notifyListeners();
    try {
      await restoreBackupToCloud(backup);
      migrationRequired = false;
      loading = false;
      notifyListeners();
    } catch (error) {
      migrationError = '备份恢复失败：$error';
      loading = false;
      notifyListeners();
    }
  }

  Future<void> restoreBackupToCloud(File backup) => _runCloudMutation(() async {
    final repository = remote;
    if (repository == null) throw StateError('安装包未配置 Supabase');
    await backupService.restoreToCloud(backup, repository);
    await _syncFromCloud(allowDuringMutation: true);
  });

  /// 只供 debug 构建的首次安装演练使用。固定 UUID 让重复点击可被安全拒绝，
  /// 整批数据在一个事务中写入，绝不连接 Supabase。
  Future<void> loadDebugSampleData() async {
    if (!kDebugMode) throw StateError('模拟数据只能在 debug 构建中使用');
    if ((await database.records()).isNotEmpty) {
      throw StateError('本地已有记录，拒绝载入模拟数据');
    }
    const created = '2026-08-13T08:00:00.000Z';
    final samples = <OvertimeRecord>[
      const OvertimeRecord(
        id: 'debug-ot-001',
        otDate: '2026-07-28',
        startTime: '17:00',
        endTime: '20:00',
        duration: 3,
        totalHours: 3,
        remainingHours: 0,
        status: '已结清',
        memo: '月末项目收尾（模拟）',
        createdAt: created,
      ),
      const OvertimeRecord(
        id: 'debug-ot-002',
        otDate: '2026-08-03',
        startTime: '17:00',
        endTime: '19:30',
        duration: 2.5,
        totalHours: 2.5,
        remainingHours: 1,
        status: '部分核销',
        memo: '版本发布支持（模拟）',
        createdAt: '2026-08-03T11:30:00.000Z',
      ),
      const OvertimeRecord(
        id: 'debug-ot-003',
        otDate: '2026-08-09',
        startTime: '09:00',
        endTime: '11:00',
        duration: 2,
        totalHours: 2,
        remainingHours: 2,
        status: '待核销',
        memo: '周末现场处理（模拟）',
        createdAt: '2026-08-09T03:00:00.000Z',
      ),
      OvertimeRecord(
        id: 'debug-leave-001',
        otDate: '2026-08-12',
        startTime: '09:00',
        endTime: '13:30',
        duration: -4.5,
        totalHours: -4.5,
        remainingHours: 0,
        status: '已调休',
        memo: jsonEncode(const [
          {'id': 'debug-ot-001', 'deduct': 3.0, 'info': '2026-07-28'},
          {'id': 'debug-ot-002', 'deduct': 1.5, 'info': '2026-08-03'},
        ]),
        createdAt: '2026-08-12T05:30:00.000Z',
      ),
    ];
    await database.db.transaction((txn) async {
      for (final record in samples) {
        await txn.insert('ot_records', record.toMap());
      }
      await txn.insert('settings', {
        'key': 'migration_completed',
        'value': 'true',
      });
      await txn.insert('settings', {
        'key': 'migration_report',
        'value': jsonEncode({
          'source': 'debug_sample',
          'record_count': samples.length,
          'verified': true,
        }),
      });
    });
    records = await database.records();
    migrationRequired = false;
    migrationReport = await database.setting('migration_report');
    notifyListeners();
  }

  double duration(
    String start,
    String end,
    DateTime date, {
    bool leave = false,
  }) => parseDuration(
    start,
    end,
    isLeave: leave,
    isDayOff: _holidays.isDayOff(date),
  );

  DayType dayType(DateTime date) => _holidays.dayType(date);

  Future<void> addOvertime({
    required DateTime date,
    required String start,
    required String end,
    required String memo,
    XFile? photo,
  }) async {
    await _runCloudMutation(() async {
      final hours = duration(start, end, date);
      if (hours <= 0) throw StateError('时间无效或时长不足 0.5 小时');
      final repository = remote;
      if (repository == null) throw StateError('未配置 Supabase，不能新增线上记录');
      final recordId = _uuid.v4();
      String? remotePhoto;
      List<int>? photoBytes;
      if (photo != null) {
        photoBytes = await photo.readAsBytes();
        final extension = p.extension(photo.path).isEmpty
            ? '.jpg'
            : p.extension(photo.path);
        remotePhoto =
            'ot/$recordId/${DateTime.now().millisecondsSinceEpoch}$extension';
        await repository.uploadPhoto(
          remotePhoto,
          photoBytes,
          contentType: extension == '.png' ? 'image/png' : 'image/jpeg',
        );
      }
      try {
        await repository.upsertRecords([
          OvertimeRecord(
            id: recordId,
            otDate: _date(date),
            startTime: start,
            endTime: end,
            duration: hours,
            totalHours: hours,
            remainingHours: hours,
            status: '待核销',
            memo: memo,
            createdAt: DateTime.now().toUtc().toIso8601String(),
            photoPath: remotePhoto,
          ),
        ]);
      } catch (_) {
        if (remotePhoto != null) {
          try {
            await repository.deletePhoto(remotePhoto);
          } catch (_) {
            // 未引用对象不影响线上账本；后续可由 Storage 审计清理。
          }
        }
        rethrow;
      }
      if (remotePhoto != null && photoBytes != null) {
        await (await database.photoFile(
          remotePhoto,
        )).writeAsBytes(photoBytes, flush: true);
      }
      await _syncFromCloud(allowDuringMutation: true);
    });
  }

  ReconciliationPreview previewLeave(String start, String end) {
    final hours = parseDuration(start, end, isLeave: true);
    if (hours <= 0) throw StateError('调休时间无效');
    return previewFifo(records, hours);
  }

  Future<void> reconcile({
    required DateTime date,
    required String start,
    required String end,
    required ReconciliationPreview preview,
  }) async {
    await _runCloudMutation(() async {
      final repository = remote;
      if (repository == null) throw StateError('未配置 Supabase，不能核销线上账本');
      final byId = {for (final record in records) record.id: record};
      final updates = <OvertimeRecord>[];
      for (final detail in preview.details) {
        final record = byId[detail.id];
        if (record == null || record.remainingHours < detail.deduct) {
          throw StateError('线上缓存余额已变化，请刷新后重新预览');
        }
        final remaining = record.remainingHours - detail.deduct;
        updates.add(
          record.copyWith(
            remainingHours: remaining,
            status: remaining <= 0 ? '已结清' : '部分核销',
          ),
        );
      }
      final leaveRecord = OvertimeRecord(
        id: _uuid.v4(),
        otDate: _date(date),
        startTime: start,
        endTime: end,
        duration: -preview.deductedHours,
        totalHours: -preview.deductedHours,
        remainingHours: 0,
        status: '已调休',
        memo: jsonEncode(preview.details.map((item) => item.toMap()).toList()),
        createdAt: DateTime.now().toUtc().toIso8601String(),
      );
      await repository.reconcileAtomically(leaveRecord, preview.details);
      await _syncFromCloud(allowDuringMutation: true);
    });
  }

  Future<bool> delete(String id) async {
    return _runCloudMutation(() async {
      final target = records.where((record) => record.id == id).firstOrNull;
      final repository = remote;
      if (repository == null) throw StateError('未配置 Supabase，不能删除线上记录');
      await repository.deleteRecordAtomically(id);
      var cleanupDeferred = false;
      if (target?.photoPath case final photoPath?) {
        try {
          await _syncFromCloud(allowDuringMutation: true);
          final remaining = records;
          if (!remaining.any((record) => record.photoPath == photoPath)) {
            await repository.deletePhoto(photoPath);
            final file = await database.photoFile(photoPath);
            if (await file.exists()) await file.delete();
          }
        } catch (_) {
          cleanupDeferred = true;
          try {
            await _queuePhotoCleanup(photoPath);
          } catch (_) {
            // 账本删除已经提交，诊断队列写入失败也必须刷新 UI 的真实状态。
          }
        }
      }
      if (target?.photoPath == null) {
        await _syncFromCloud(allowDuringMutation: true);
      }
      return cleanupDeferred;
    });
  }

  Future<void> _queuePhotoCleanup(String photoPath) async {
    final stored = await database.setting('pending_photo_cleanup');
    final pending = <String>{};
    if (stored != null) {
      try {
        pending.addAll((jsonDecode(stored) as List<dynamic>).cast<String>());
      } catch (_) {
        // 损坏的诊断设置不能影响已提交的账本删除。
      }
    }
    pending.add(photoPath);
    await database.setSetting(
      'pending_photo_cleanup',
      jsonEncode(pending.toList()),
    );
  }

  Future<void> refresh() async {
    records = await database.records();
    notifyListeners();
  }

  Future<void> reloadHolidays() async {
    _holidays = await database.holidays();
    notifyListeners();
  }

  void _ensureMutationReady() {
    if (syncing || _mutating) {
      throw StateError('正在同步云端账本，请完成后再操作');
    }
  }

  Future<T> _runCloudMutation<T>(Future<T> Function() action) async {
    _ensureMutationReady();
    _mutating = true;
    notifyListeners();
    try {
      return await action();
    } finally {
      _mutating = false;
      notifyListeners();
    }
  }

  double get totalRemaining => records
      .where((record) => !record.isLeave)
      .fold(0, (sum, record) => sum + record.remainingHours);
  double get totalOvertime => records
      .where((record) => !record.isLeave)
      .fold(0, (sum, record) => sum + record.duration);
  double get totalLeave => records
      .where((record) => record.isLeave)
      .fold(0, (sum, record) => sum - record.duration);

  static String _date(DateTime value) =>
      value.toIso8601String().substring(0, 10);

  static SupabaseRepository? _buildRemote() {
    final config = SupabaseConfig.fromBuild();
    return config == null ? null : SupabaseRepository(config);
  }
}
