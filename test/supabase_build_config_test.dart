import 'package:flutter_test/flutter_test.dart';
import 'package:over_balance_flow/data/supabase_repository.dart';

void main() {
  test('Supabase 使用实际编译参数创建云端连接配置', () {
    const url = String.fromEnvironment('SUPABASE_URL');
    const key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
    final config = SupabaseConfig.fromBuild();
    if (url.isEmpty || key.isEmpty) {
      expect(config, isNull);
    } else {
      expect(config, isNotNull);
      expect(config!.url, url);
      expect(config.key, key);
    }
  });
}
