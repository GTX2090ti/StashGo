import 'dart:async';

import 'package:flutter/material.dart';

import '../api/stash_api.dart';
import '../models/models.dart';
import '../widgets/common.dart';
import '../l10n/l10n.dart';

/// 削刮器包列表排序：更新时间（包索引里的 date）或名称。
enum _ScraperSort { updated, name }

/// 削刮器包管理页：查看服务器上已安装的包，并从索引源搜索、勾选安装。
///
/// Stash 的安装是后台任务：提交后拿到 job id，轮询队列直到该 id 消失或
/// FINISHED；装完必须 reloadScrapers 才会出现在削刮源列表里（不用重启容器）。
class ScraperPackagesPage extends StatefulWidget {
  const ScraperPackagesPage({super.key});

  @override
  State<ScraperPackagesPage> createState() => _ScraperPackagesPageState();
}

class _ScraperPackagesPageState extends State<ScraperPackagesPage>
    with SingleTickerProviderStateMixin {
  static const _communityIndex =
      'https://stashapp.github.io/CommunityScrapers/stable/index.yml';

  late final TabController _tab;
  final TextEditingController _sourceCtl = TextEditingController();
  final TextEditingController _searchCtl = TextEditingController();

  bool _busy = true;
  String? _error;
  List<ScraperPkg> _installed = [];
  List<PackageSource> _sources = [];
  _ScraperSort _sortBy = _ScraperSort.updated;

  bool _availBusy = false;
  String? _availError;
  List<ScraperPkg> _available = [];
  final Set<String> _picked = {};

  bool _installing = false;
  String _installMsg = '';

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _tab.addListener(() {
      if (mounted) setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    _sourceCtl.dispose();
    _searchCtl.dispose();
    super.dispose();
  }

  Set<String> get _installedIds =>
      _installed.map((e) => e.id.toLowerCase()).toSet();

  List<ScraperPkg> get _filtered {
    final term = _searchCtl.text.trim().toLowerCase();
    final list =
        _available
            .where(
              (p) =>
                  term.isEmpty ||
                  p.display.toLowerCase().contains(term) ||
                  p.id.toLowerCase().contains(term) ||
                  p.synopsis.toLowerCase().contains(term),
            )
            .toList()
          ..sort(_comparePkg);
    return list;
  }

  /// 排序：更新时间取包索引里的 date，倒序；空日期排最后；其次按名称升序。
  int _comparePkg(ScraperPkg a, ScraperPkg b) {
    if (_sortBy == _ScraperSort.updated) {
      final da = DateTime.tryParse(a.date);
      final db = DateTime.tryParse(b.date);
      if (da != null && db != null) {
        final byDate = db.compareTo(da);
        if (byDate != 0) return byDate;
      } else if (da != null || db != null) {
        return da != null ? -1 : 1;
      } else if (a.date != b.date) {
        return b.date.compareTo(a.date);
      }
    }
    return a.display.toLowerCase().compareTo(b.display.toLowerCase());
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = buildApi();
      final installed = await api.installedPackages();
      final sources = await api.scraperPackageSources();
      if (!mounted) return;
      setState(() {
        _installed = installed;
        _sources = sources;
        _busy = false;
      });
      if (_sourceCtl.text.isEmpty) {
        final first = sources.firstWhere(
          (e) => e.url.isNotEmpty,
          orElse: () => PackageSource(url: _communityIndex),
        );
        _sourceCtl.text = first.url.isNotEmpty ? first.url : _communityIndex;
      }
      _loadAvailable();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  Future<void> _loadAvailable() async {
    final url = _sourceCtl.text.trim();
    if (url.isEmpty) {
      setState(() {
        _available = [];
        _availError = tr('先填写包索引地址（index.yml 的完整 URL）');
      });
      return;
    }
    setState(() {
      _availBusy = true;
      _availError = null;
    });
    try {
      final list = await buildApi().availablePackages(url);
      if (!mounted) return;
      setState(() {
        _available = list;
        _availBusy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _availError = '$e';
        _availBusy = false;
      });
    }
  }

  Future<void> _reloadScrapers() async {
    try {
      await buildApi().reloadScrapers();
      if (!mounted) return;
      showToast(context, tr('已重新加载削刮器'));
    } catch (e) {
      if (!mounted) return;
      showToast(context, tr('重新加载失败：{error}', {'error': e}), error: true);
    }
  }

  /// 补齐依赖：社区包里多个刮削器 requires py_common，服务端不会自动装，
  /// 漏了会在刮削时 import 失败。
  List<ScraperPkg> _withRequirements(List<ScraperPkg> picked) {
    // 依赖名在不同版本里可能是 package_id 也可能是 name，两个都建索引。
    final byName = <String, ScraperPkg>{};
    for (final p in _available) {
      if (p.id.isNotEmpty) byName[p.id.toLowerCase()] = p;
      if (p.name.isNotEmpty) byName.putIfAbsent(p.name.toLowerCase(), () => p);
    }
    final skip = <String>{};
    for (final p in _installed) {
      if (p.id.isNotEmpty) skip.add(p.id.toLowerCase());
      if (p.name.isNotEmpty) skip.add(p.name.toLowerCase());
    }
    final out = <String, ScraperPkg>{};
    for (final p in picked) {
      out[p.id.toLowerCase()] = p;
    }
    final queue = out.values.toList();
    var guard = 0;
    while (queue.isNotEmpty && guard++ < 200) {
      final cur = queue.removeAt(0);
      for (final req in cur.requires) {
        final key = req.toLowerCase();
        if (out.containsKey(key) || skip.contains(key)) continue;
        final dep = byName[key];
        if (dep == null) continue;
        out[dep.id.toLowerCase()] = dep;
        queue.add(dep);
      }
    }
    return out.values.toList();
  }

  Future<void> _install() async {
    final picked = _available
        .where((p) => _picked.contains(p.id.toLowerCase()))
        .toList();
    if (picked.isEmpty || _installing) return;
    final all = _withRequirements(picked);
    final deps = all
        .where((p) => !_picked.contains(p.id.toLowerCase()))
        .toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('安装 {count} 个包', {'count': all.length})),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(all.map((e) => e.display).join('、')),
              if (deps.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(tr('含自动补齐的依赖：{deps}',
                    {'deps': deps.map((e) => e.display).join('、')})),
              ],
              const SizedBox(height: 10),
               Text(tr('安装后会自动重新加载削刮器，无需重启容器。')),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:  Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:  Text(tr('安装')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _installing = true;
      _installMsg = tr('正在提交安装任务…');
    });
    String? failure;
    try {
      final api = buildApi();
      // PackageSpecInput.sourceURL 是非空字段：包对象没带回来就用当前索引地址。
      final indexUrl = _sourceCtl.text.trim();
      final jobId = await api.installPackages(
        all
            .map((p) => {
                  'id': p.id,
                  'source': p.sourceUrl.isNotEmpty ? p.sourceUrl : indexUrl,
                })
            .toList(),
      );
      await _watchJob(api, jobId);
      try {
        await api.reloadScrapers();
      } catch (_) {
        // 老版本没有该 mutation：装完重启容器即可，不视为安装失败
      }
      if (mounted) {
        final installed = await api.installedPackages();
        if (mounted) setState(() => _installed = installed);
      }
    } catch (e) {
      failure = '$e';
    }
    if (!mounted) return;
    setState(() {
      _installing = false;
      _installMsg = '';
      _picked.clear();
    });
    if (failure != null) {
      showToast(context, tr('安装失败：{failure}', {'failure': failure}),
          error: true);
    } else {
      showToast(context,
          tr('已安装 {count} 个包并重新加载削刮器', {'count': all.length}));
    }
  }

  /// 轮询任务队列：job id 消失或 FINISHED 即结束，FAILED/CANCELLED 当失败。
  Future<void> _watchJob(StashApi api, String jobId) async {
    if (jobId.isEmpty) {
      await Future.delayed(const Duration(seconds: 3));
      return;
    }
    for (var i = 0; i < 90; i++) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      Map<String, dynamic>? job;
      try {
        job = await api.findJob(jobId);
      } catch (_) {
        return;
      }
      if (job == null) return;
      final status = job['status']?.toString() ?? '';
      final progress = job['progress'];
      final pct = progress is num
          ? ' ${progress.toDouble().clamp(0, 100).toStringAsFixed(0)}%'
          : '';
      setState(() => _installMsg =
          tr('安装中（{status}{pct}）', {'status': status, 'pct': pct}));
      if (status == 'FINISHED') return;
      if (status == 'FAILED' || status == 'CANCELLED') {
        final err = job['error']?.toString() ?? '';
        throw ApiException(
            err.isEmpty ? tr('安装任务{status}', {'status': status}) : err);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title:  Text(tr('削刮器包')),
        actions: [
          PopupMenuButton<_ScraperSort>(
            tooltip: tr('排序方式'),
            icon: const Icon(Icons.sort),
            initialValue: _sortBy,
            enabled: !_busy && !_installing,
            onSelected: (v) => setState(() => _sortBy = v),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: _ScraperSort.updated,
                checked: _sortBy == _ScraperSort.updated,
                child:  Text(tr('按更新时间排序')),
              ),
              CheckedPopupMenuItem(
                value: _ScraperSort.name,
                checked: _sortBy == _ScraperSort.name,
                child:  Text(tr('按名称排序')),
              ),
            ],
          ),
          IconButton(
            tooltip: tr('重新加载削刮器'),
            icon: const Icon(Icons.sync),
            onPressed: _busy || _installing ? null : _reloadScrapers,
          ),
          IconButton(
            tooltip: tr('刷新'),
            icon: const Icon(Icons.refresh),
            onPressed: _busy || _installing ? null : _load,
          ),
        ],
        bottom: _busy
            ? null
            : TabBar(
                controller: _tab,
                tabs: [
                  Tab(text: tr('已安装 ({count})', {'count': _installed.length})),
                  Tab(text: tr('可安装 ({count})',
                      {'count': _availBusy ? '…' : _available.length})),
                ],
              ),
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 40,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 12),
                    Text(tr('削刮器包查询失败'), style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label:  Text(tr('重试')),
                    ),
                  ],
                ),
              ),
            )
          : TabBarView(
              controller: _tab,
              children: [_installedTab(theme), _availableTab(theme)],
            ),
    );
  }

  Widget _installedTab(ThemeData theme) {
    if (_installed.isEmpty) {
      return Center(
        child: Text(
          tr('未安装削刮器包'),
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final list = [..._installed]..sort(_comparePkg);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _card(theme, list[i]),
      ),
    );
  }

  Widget _availableTab(ThemeData theme) {
    final list = _filtered;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _sourceCtl,
                  enabled: !_installing,
                  decoration:  InputDecoration(
                    labelText: tr('包索引地址'),
                    hintText: '…/index.yml',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _loadAvailable(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _availBusy || _installing ? null : _loadAvailable,
                child:  Text(tr('加载')),
              ),
            ],
          ),
        ),
        if (_sources.any((e) => e.url.isNotEmpty))
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: _sources
                  .where((e) => e.url.isNotEmpty)
                  .map(
                    (e) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text(e.name.isNotEmpty ? e.name : e.localPath),
                        onPressed: _installing
                            ? null
                            : () {
                                _sourceCtl.text = e.url;
                                _loadAvailable();
                              },
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TextField(
            controller: _searchCtl,
            enabled: !_installing,
            decoration: InputDecoration(
              labelText: tr('在已加载的 {count} 个包里搜索',
                  {'count': _available.length}),
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        if (_installing)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_installMsg, style: theme.textTheme.bodySmall),
                const SizedBox(height: 6),
                const LinearProgressIndicator(),
              ],
            ),
          ),
        Expanded(
          child: _availBusy
              ? const Center(child: CircularProgressIndicator())
              : _availError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      tr('可安装包加载失败：{error}', {'error': _availError}),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                )
              : list.isEmpty
              ? Center(
                  child: Text(
                    _available.isEmpty ? tr('该索引没有可安装的包') : tr('没有匹配的包'),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (_, i) => _availItem(theme, list[i]),
                ),
        ),
        if (_picked.isNotEmpty)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _installing
                        ? null
                        : () => setState(_picked.clear),
                    child:  Text(tr('清空')),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _installing ? null : _install,
                    icon: const Icon(Icons.download),
                    label: Text(tr('安装 {count} 个', {'count': _picked.length})),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _availItem(ThemeData theme, ScraperPkg p) {
    final key = p.id.toLowerCase();
    final installed = _installedIds.contains(key);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withOpacity(0.6),
        ),
      ),
      child: CheckboxListTile(
        value: _picked.contains(key),
        onChanged: _installing
            ? null
            : (v) => setState(() {
                if (v == true) {
                  _picked.add(key);
                } else {
                  _picked.remove(key);
                }
              }),
        controlAffinity: ListTileControlAffinity.leading,
        dense: true,
        title: Row(
          children: [
            Expanded(
              child: Text(
                p.display,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (installed)
              Text(
                tr('已安装'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        subtitle: _meta(theme, p),
      ),
    );
  }

  Widget _card(ThemeData theme, ScraperPkg p) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withOpacity(0.6),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              p.display,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            _meta(theme, p),
          ],
        ),
      ),
    );
  }

  Widget _meta(ThemeData theme, ScraperPkg p) {
    final parts = <String>[
      if (p.id.isNotEmpty && p.display != p.id) p.id,
      if (p.version.isNotEmpty && p.display != p.version) 'v${p.version}',
      if (p.date.isNotEmpty) p.date,
      if (p.author.isNotEmpty) p.author,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (parts.isNotEmpty)
          Text(
            parts.join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        if (p.synopsis.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            p.synopsis,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (p.requires.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            tr('依赖：{deps}', {'deps': p.requires.join('、')}),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}
