import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ApiKey 的安全存储。
///
/// iOS 走 Keychain（flutter_secure_storage），apiKey 不再写进 SharedPreferences
/// 明文 plist。HarmonyOS 没有该插件的实现（插件被工具链过滤、调用会抛
/// MissingPluginException），此时自动回退到 SharedPreferences —— 安全性等同旧版，
/// 但保证功能不坏。[isSecure] 供设置页提示当前实际档位。
class SecureStore {
  SecureStore._();

  static final SecureStore instance = SecureStore._();

  static const String _prefix = 'apikey:';
  static const String _fallbackPrefix = 'apikey_fallback:';

  final FlutterSecureStorage _secure = const FlutterSecureStorage(
    iOptions: IOSOptions(
      // 设备解锁过一次即可读（允许后台刷新），且不随备份迁移到新设备
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  bool _healthy = true;

  /// 当前是否真的用了系统安全存储。
  bool get isSecure => _healthy;

  Future<String?> read(String profile) async {
    if (profile.isEmpty) return null;
    if (_healthy) {
      try {
        final v = await _secure.read(key: '$_prefix$profile');
        if (v != null && v.isNotEmpty) return v;
      } catch (e) {
        _markUnhealthy(e);
      }
    }
    final p = await SharedPreferences.getInstance();
    final fb = p.getString('$_fallbackPrefix$profile');
    return (fb == null || fb.isEmpty) ? null : fb;
  }

  /// 写入并返回是否落到了安全存储（false = 已降级为 SharedPreferences）。
  Future<bool> write(String profile, String value) async {
    if (profile.isEmpty) return false;
    if (_healthy) {
      try {
        await _secure.write(key: '$_prefix$profile', value: value);
        // 清掉可能残留的降级副本，避免两处并存
        try {
          final p = await SharedPreferences.getInstance();
          await p.remove('$_fallbackPrefix$profile');
        } catch (_) {}
        return true;
      } catch (e) {
        _markUnhealthy(e);
      }
    }
    final p = await SharedPreferences.getInstance();
    await p.setString('$_fallbackPrefix$profile', value);
    return false;
  }

  Future<void> delete(String profile) async {
    if (profile.isEmpty) return;
    if (_healthy) {
      try {
        await _secure.delete(key: '$_prefix$profile');
      } catch (e) {
        _markUnhealthy(e);
      }
    }
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove('$_fallbackPrefix$profile');
    } catch (_) {}
  }

  void _markUnhealthy(Object e) {
    if (!_healthy) return;
    _healthy = false;
    debugPrint('SecureStore: 安全存储不可用，降级 SharedPreferences ($e)');
  }
}
