import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../l10n/l10n.dart';
import '../settings/app_settings.dart';
import 'diagnostics_page.dart';
import 'net_log_page.dart';
import 'server_settings_page.dart';
import 'stash_tasks_page.dart';
import 'identify_page.dart';
import 'duplicate_page.dart';
import 'tags_page.dart';
import 'stats_page.dart';
import 'plugins_page.dart';
import 'scraper_packages_page.dart';

/// 构建脚本从 pubspec 注入，避免「关于」里的版本号与包内版本脱节。
const _appVersion = String.fromEnvironment('APP_VERSION');

const _githubRepoUrl = 'https://github.com/GTX2090ti/StashScrubber';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.embedded = false});
  final bool embedded;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppSettings get _cfg => AppSettings.instance;

  final LocalAuthentication _auth = LocalAuthentication();
  bool _bioAvailable = false;

  @override
  void initState() {
    super.initState();
    _cfg.addListener(_onCfg);
    _checkBiometrics();
  }

  @override
  void dispose() {
    _cfg.removeListener(_onCfg);
    super.dispose();
  }

  Future<void> _checkBiometrics() async {
    try {
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      if (!mounted) return;
      setState(() => _bioAvailable = supported && canCheck);
    } catch (e) {
      if (!mounted) return;
      setState(() => _bioAvailable = false);
    }
  }

  Future<void> _toggleBiometricLock(bool v) async {
    if (v && !_bioAvailable) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('此设备不支持生物识别，无法开启面容解锁'))));
      return;
    }
    await _cfg.setBiometricLock(v);
    if (v) {
      // 开启后立即要求验证一次（首次生效）
      try {
        final ok = await _auth.authenticate(
          localizedReason: tr('验证您的身份以启用面容解锁'),
        );
        if (ok) {
          _cfg.markUnlocked();
        }
      } catch (e) {
        debugPrint('biometric enable auth failed: $e');
      }
    }
  }

  void _onCfg() {
    if (mounted) setState(() {});
  }

  Future<void> _pickLanguage() async {
    final selected = await showDialog<AppLanguage>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('语言')),
        children: [
          for (final lang in AppLanguage.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, lang),
              child: Row(
                children: [
                  Expanded(child: Text(L10n.languageName(lang))),
                  if (lang == _cfg.language) const Icon(Icons.check, size: 20),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected != null && selected != _cfg.language) {
      await _cfg.setLanguage(selected);
    }
  }

  String normalizeLabel(String url) {
    final m = RegExp(r'^https?://').firstMatch(url);
    return m == null ? url : url.substring(m.end);
  }

  Future<void> _copyRepoUrl() async {
    await Clipboard.setData(const ClipboardData(text: _githubRepoUrl));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr('已复制仓库地址'))));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(tr('外观'), style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<Appearance>(
          segments: [
            ButtonSegment(
              value: Appearance.system,
              label: Text(tr('跟随系统')),
              icon: Icon(Icons.brightness_auto_outlined),
            ),
            ButtonSegment(
              value: Appearance.light,
              label: Text(tr('白天')),
              icon: Icon(Icons.light_mode_outlined),
            ),
            ButtonSegment(
              value: Appearance.dark,
              label: Text(tr('黑暗')),
              icon: Icon(Icons.dark_mode_outlined),
            ),
          ],
          selected: {_cfg.appearance},
          onSelectionChanged: (sel) => _cfg.setAppearance(sel.first),
        ),

        const SizedBox(height: 24),
        Text(tr('语言'), style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.translate),
          title: Text(tr('语言')),
          subtitle: Text(L10n.languageName(_cfg.language)),
          trailing: const Icon(Icons.chevron_right),
          onTap: _pickLanguage,
        ),

        const SizedBox(height: 24),
        Text(tr('服务器'), style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.dns_outlined),
          title: Text(tr('服务器档案 / 生效地址')),
          subtitle: Text(
            _cfg.hasProfile
                ? '${_cfg.currentProfileName} · ${normalizeLabel(_cfg.baseUrl)}'
                : tr('尚未配置服务器'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ServerSettingsPage()),
          ),
        ),

        const SizedBox(height: 24),
        Text(tr('浏览'), style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.label_outline),
          title: Text(tr('标签浏览')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const TagsPage()),
          ),
        ),

        const SizedBox(height: 24),
        Text(tr('隐私'), style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.visibility_off_outlined),
          title: Text(tr('安全模式')),
          subtitle: Text(tr('缩略图打码，长按可临时查看')),
          value: _cfg.safeMode,
          onChanged: (v) => _cfg.setSafeMode(v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.face_retouching_natural),
          title: Text(tr('面容解锁')),
          subtitle: Text(
            _bioAvailable
                ? tr('启动 App 与回到前台时需 Face ID / 指纹验证')
                : tr('此设备不支持生物识别'),
          ),
          value: _cfg.biometricLock,
          onChanged: _bioAvailable ? _toggleBiometricLock : null,
        ),

        const SizedBox(height: 24),
        Text(tr('网络'), style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.document_scanner_outlined),
          title: Text(tr('Stash 扫描')),
          subtitle: Text(tr('扫描新短片与图片')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const StashTasksPage()),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.manage_search_outlined),
          title: Text(tr('批量识别')),
          subtitle: Text(tr('按刮削源自动匹配短片元数据')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const IdentifyPage()),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.content_copy_outlined),
          title: Text(tr('去重')),
          subtitle: Text(tr('按相似度查找重复短片并合并')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const DuplicatePage()),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.insights_outlined),
          title: Text(tr('统计')),
          subtitle: Text(tr('短片/图片/演员/工作室等媒体库汇总')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const StatsPage()),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.extension_outlined),
          title: Text(tr('插件')),
          subtitle: Text(tr('查看已安装插件及其任务/钩子')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const PluginsPage()),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.download_outlined),
          title: Text(tr('削刮器包')),
          subtitle: Text(tr('查看已安装削刮器包，从索引源搜索并安装')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ScraperPackagesPage()),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.network_check),
          title: Text(tr('网络诊断')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const DiagnosticsPage()),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.article_outlined),
          title: Text(tr('网络日志')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const NetLogPage()),
          ),
        ),

        const SizedBox(height: 24),
        Text(tr('关于'), style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.info_outline),
          title: Text(tr('版本')),
          subtitle: Text(_appVersion.isEmpty ? 'Stash' : _appVersion),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.code),
          title: Text(tr('GitHub 仓库')),
          subtitle: const Text(
            _githubRepoUrl,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.copy_all_outlined),
          onTap: _copyRepoUrl,
        ),
        if (!_cfg.storageAvailable)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              tr('本地存储不可用，设置不会持久化'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFFE5533D),
              ),
            ),
          ),
        const SizedBox(height: 24),
      ],
    );

    if (widget.embedded) return Scaffold(body: body);
    return Scaffold(
      appBar: AppBar(title: Text(tr('设置'))),
      body: body,
    );
  }
}
