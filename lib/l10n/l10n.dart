import 'dart:ui' as ui;

import 'translations_en.dart';
import 'translations_ja.dart';

/// 手动语言偏好。`system` 跟随设备语言（非中/日时回落英文）。
enum AppLanguage { system, zh, en, ja }

/// 轻量文案层：以中文原文为键，运行时按当前语言查表。
/// 未收录的原文直接返回，保证分批接入时不会出现空文本。
class L10n {
  L10n._();

  static AppLanguage preference = AppLanguage.system;

  static String get effectiveCode {
    switch (preference) {
      case AppLanguage.zh:
        return 'zh';
      case AppLanguage.en:
        return 'en';
      case AppLanguage.ja:
        return 'ja';
      case AppLanguage.system:
        final code = ui.PlatformDispatcher.instance.locale.languageCode;
        return code == 'zh' || code == 'ja' ? code : 'en';
    }
  }

  /// `null` 表示跟随系统（交给 Flutter 按 supportedLocales 解析）。
  static ui.Locale? get materialLocale {
    switch (preference) {
      case AppLanguage.system:
        return null;
      case AppLanguage.zh:
        return const ui.Locale('zh', 'CN');
      case AppLanguage.en:
        return const ui.Locale('en', 'US');
      case AppLanguage.ja:
        return const ui.Locale('ja', 'JP');
    }
  }

  static String translate(String source, [Map<String, Object?>? args]) {
    var out = source;
    final code = effectiveCode;
    if (code != 'zh') {
      out = (code == 'ja' ? jaStrings : enStrings)[source] ?? source;
    }
    if (args != null) {
      args.forEach((key, value) {
        out = out.replaceAll('{$key}', '${value ?? ''}');
      });
    }
    return out;
  }

  /// 语言选择器里展示的名字始终使用该语言自己的写法。
  static String languageName(AppLanguage lang) {
    switch (lang) {
      case AppLanguage.system:
        return translate('跟随系统');
      case AppLanguage.zh:
        return '简体中文';
      case AppLanguage.en:
        return 'English';
      case AppLanguage.ja:
        return '日本語';
    }
  }
}

String tr(String source, [Map<String, Object?>? args]) =>
    L10n.translate(source, args);
