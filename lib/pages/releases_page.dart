import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../l10n/l10n.dart';
import '../widgets/common.dart';

/// 构建脚本从 pubspec 注入；用于在列表里标记当前已安装的版本。
const _appVersion = String.fromEnvironment('APP_VERSION');

/// 版本发布页：拉取 GitHub Releases，展示更新说明与附件下载链接。
class ReleasesPage extends StatefulWidget {
  const ReleasesPage({super.key});

  @override
  State<ReleasesPage> createState() => _ReleasesPageState();
}

class _ReleasesPageState extends State<ReleasesPage> {
  static const _apiUrl =
      'https://api.github.com/repos/GTX2090ti/StashGo/releases?per_page=100';

  List<_Release>? _releases;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _releases = null;
      _error = null;
    });
    try {
      final resp = await http
          .get(
            Uri.parse(_apiUrl),
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'StashGo-App',
            },
          )
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        throw 'HTTP ${resp.statusCode}';
      }
      final list = jsonDecode(utf8.decode(resp.bodyBytes)) as List;
      if (!mounted) return;
      setState(() {
        _releases = list
            .map((e) => _Release.fromApi(e as Map<String, dynamic>))
            .toList();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _copyLink(_Asset a) async {
    await Clipboard.setData(ClipboardData(text: a.url));
    if (!mounted) return;
    showToast(context, tr('下载链接已复制'));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('版本发布')),
        actions: [
          IconButton(
            tooltip: tr('重试'),
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${tr('加载失败')}：$error',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: _load,
                child: Text(tr('重试')),
              ),
            ],
          ),
        ),
      );
    }
    final releases = _releases;
    if (releases == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (releases.isEmpty) {
      return Center(child: Text(tr('暂无发布版本')));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: releases.length,
      itemBuilder: (context, i) =>
          _buildCard(context, theme, releases[i], expanded: i == 0),
    );
  }

  Widget _buildCard(
    BuildContext context,
    ThemeData theme,
    _Release r, {
    required bool expanded,
  }) {
    final installed = r.tag == 'v$_appVersion' || r.tag == _appVersion;
    final dateText = r.dateText;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: expanded,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        title: Row(
          children: [
            Expanded(
              child: Text(
                r.title,
                style: theme.textTheme.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (installed) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: theme.colorScheme.primary),
                ),
                child: Text(
                  tr('已安装'),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
            ],
          ],
        ),
        subtitle: dateText == null ? null : Text(dateText),
        children: [
          if (r.cleanBody.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                r.cleanBody,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
              ),
            ),
          for (final a in r.assets)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.download_outlined, size: 20),
              title: Text(
                a.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
              subtitle: Text(a.sizeText, style: theme.textTheme.bodySmall),
              trailing: const Icon(Icons.copy_all_outlined, size: 18),
              onTap: () => _copyLink(a),
            ),
        ],
      ),
    );
  }
}

class _Release {
  _Release({
    required this.tag,
    required this.name,
    this.publishedAt,
    required this.body,
    required this.assets,
  });

  factory _Release.fromApi(Map<String, dynamic> j) {
    return _Release(
      tag: (j['tag_name'] as String?) ?? '',
      name: (j['name'] as String?) ?? '',
      publishedAt: DateTime.tryParse((j['published_at'] as String?) ?? ''),
      body: (j['body'] as String?) ?? '',
      assets: ((j['assets'] as List?) ?? const [])
          .map((a) => _Asset.fromApi(a as Map<String, dynamic>))
          .toList(),
    );
  }

  final String tag;
  final String name;
  final DateTime? publishedAt;
  final String body;
  final List<_Asset> assets;

  String get title => name.isNotEmpty ? name : tag;

  String? get dateText {
    final d = publishedAt?.toLocal();
    if (d == null) return null;
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)}';
  }

  /// 轻量清洗：去掉标题井号与代码反引号，列表破折号换成圆点。
  String get cleanBody {
    if (body.trim().isEmpty) return '';
    return body
        .split('\n')
        .map((l) {
          var x = l.replaceAll('`', '');
          if (x.startsWith('## ')) {
            x = x.substring(3);
          } else if (x.startsWith('# ')) {
            x = x.substring(2);
          } else if (x.startsWith('- ')) {
            x = '•  ${x.substring(2)}';
          }
          return x;
        })
        .join('\n')
        .trim();
  }
}

class _Asset {
  _Asset({required this.name, required this.url, required this.size});

  factory _Asset.fromApi(Map<String, dynamic> j) {
    return _Asset(
      name: (j['name'] as String?) ?? '',
      url: (j['browser_download_url'] as String?) ?? '',
      size: (j['size'] as num?)?.toInt() ?? 0,
    );
  }

  final String name;
  final String url;
  final int size;

  String get sizeText {
    if (size >= 1048576) return '${(size / 1048576).toStringAsFixed(1)} MB';
    if (size >= 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '$size B';
  }
}
