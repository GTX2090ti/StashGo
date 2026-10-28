import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stash_scrubber_flutter/settings/app_settings.dart';

/// ApiKey 存储迁移的回归测试：旧版明文不得继续留在 SharedPreferences 里。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Profile.toJson 不再序列化 apiKey', () {
    final p = Profile(
      name: 'A',
      lanUrl: 'http://10.0.0.1:9999',
      apiKey: 'SECRET123',
    );
    expect(p.toJson().containsKey('apiKey'), isFalse);
    expect(jsonEncode(p.toJson()).contains('SECRET123'), isFalse);
    // 反序列化仍兼容旧数据
    final back = Profile.fromJson({'name': 'A', 'apiKey': 'OLD'});
    expect(back.apiKey, 'OLD');
  });

  test('旧版明文 profiles 迁移后不再含 apiKey，且 key 仍可用', () async {
    SharedPreferences.setMockInitialValues({
      'profiles_v1': jsonEncode([
        {
          'name': 'A',
          'lanUrl': 'http://10.0.0.1:9999',
          'wanUrl': '',
          'apiKey': 'SECRET123',
        },
      ]),
      'current_profile': 'A',
    });

    final cfg = AppSettings.instance;
    await cfg.load();

    // 内存态仍可正常取到 key
    expect(cfg.apiKey, 'SECRET123');

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('profiles_v1') ?? '';
    // 重写后的 profiles 里不能再出现明文
    expect(raw.contains('SECRET123'), isFalse);
    expect(raw.contains('apiKey'), isFalse);
  });

  test('legacy 单地址键迁移后删除 api_key', () async {
    SharedPreferences.setMockInitialValues({
      'base_url': 'http://10.0.0.2:9999',
      'api_key': 'LEGACYKEY',
    });

    final cfg = AppSettings.instance;
    await cfg.load();

    expect(cfg.apiKey, 'LEGACYKEY');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('api_key'), isFalse);
  });
}
