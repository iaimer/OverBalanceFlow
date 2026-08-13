import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:over_balance_flow/data/data_fingerprint.dart';
import 'package:over_balance_flow/domain/overtime_record.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('用法：dart run tool/baseline_fingerprint.dart <基线目录>');
    exitCode = 64;
    return;
  }
  final root = Directory(args.single);
  final recordsFile = File(p.join(root.path, 'records.json'));
  if (!await recordsFile.exists()) throw StateError('缺少 records.json');
  final records =
      (jsonDecode(await recordsFile.readAsString()) as List<dynamic>)
          .map((item) => OvertimeRecord.fromMap(item as Map<String, dynamic>))
          .toList();
  final fingerprint = DataFingerprint.fromRecords(records);
  final photoBindings = <String, Map<String, String>>{};
  final photoRoot = Directory(p.join(root.path, 'photos'));
  if (await photoRoot.exists()) {
    final manifestFile = File(p.join(root.path, 'manifest.json'));
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    for (final item in (manifest['photos'] as List<dynamic>? ?? const [])) {
      final photo = item as Map<String, dynamic>;
      final file = File(p.join(photoRoot.path, photo['file'] as String));
      final remotePath = photo['path'] as String;
      final matching = records.where(
        (record) => record.photoPath == remotePath,
      );
      if (matching.length != 1) {
        throw StateError('照片路径必须且只能关联一条记录：$remotePath');
      }
      photoBindings[matching.single.id] = {
        'path': remotePath,
        'sha256': sha256.convert(await file.readAsBytes()).toString(),
      };
    }
  }
  stdout.writeln('BASELINE_RECORD_COUNT=${fingerprint.recordCount}');
  stdout.writeln('BASELINE_RECORDS_SHA256=${fingerprint.recordsSha256}');
  stdout.writeln('BASELINE_UUID_SHA256=${fingerprint.uuidSha256}');
  stdout.writeln('BASELINE_PHOTO_COUNT=${fingerprint.photoCount}');
  stdout.writeln('BASELINE_PHOTOS_JSON=${jsonEncode(photoBindings)}');
}
