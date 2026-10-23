import 'package:flutter/material.dart';

import '../models/models.dart';
import '../settings/app_settings.dart';
import '../widgets/common.dart';
import '../widgets/zh_toolbar.dart';
import 'group_create_page.dart';
import 'group_detail_page.dart';
import '../l10n/l10n.dart';

/// 集合列表：行式列表 + 搜索 + 排序 + 翻页。
class GroupsPage extends StatefulWidget {
  const GroupsPage({super.key, this.embedded = false});

  /// true 时由资料库页提供 Scaffold，本页只出内容。
  final bool embedded;

  @override
  State<GroupsPage> createState() => _GroupsPageState();
}

class _GroupsPageState extends State<GroupsPage> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  List<Group> _items = [];
  int _total = 0;
  int _page = 0;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String _error = '';
  String _query = '';
  String _sort = 'name';
  String _direction = 'ASC';

  /// 排序选项（Stash 0.31.1 GroupSorter 白名单：studio 之类会报 invalid sort）。
  static List<(String, String)> get _sortOptions => [
    ('name', tr('名称')),
    ('date', tr('发行日期')),
    ('scenes_count', tr('短片数')),
    ('rating', tr('评分')),
    ('created_at', tr('添加时间')),
    ('updated_at', tr('更新时间')),
  ];

  String get _sortLabel {
    for (final (s, l) in _sortOptions) {
      if (s == _sort) return l;
    }
    return _sort;
  }

  static const int _perPage = 60;

  String _lastBase = '';
  String _lastKey = '';

  @override
  void initState() {
    super.initState();
    _lastBase = AppSettings.instance.baseUrl;
    _lastKey = AppSettings.instance.apiKey;
    AppSettings.instance.addListener(_onCfg);
    _scroll.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onCfg);
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onCfg() {
    final b = AppSettings.instance.baseUrl;
    final k = AppSettings.instance.apiKey;
    if (b != _lastBase || k != _lastKey) {
      _lastBase = b;
      _lastKey = k;
      _reload();
    } else if (mounted) {
      setState(() {});
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _reload() async {
    // 从详情返回时保持原滚动位置，避免长列表跳回顶部。
    final saved = _scroll.hasClients ? _scroll.offset : 0.0;
    setState(() {
      _error = '';
      _page = 0;
      _hasMore = true;
      _items = [];
    });
    await _loadMore();
    if (!mounted || saved <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      while (mounted && _scroll.hasClients && _hasMore) {
        final max = _scroll.position.maxScrollExtent;
        if (max >= saved) break;
        await _loadMore();
        if (!mounted) return;
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo(saved <= max ? saved : max);
    });
  }

  Future<void> _openSortSheet() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        tr('排序方式'),
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => Navigator.pop(ctx, 'toggle_dir'),
                      icon: Icon(
                        _direction == 'DESC'
                            ? Icons.arrow_downward
                            : Icons.arrow_upward,
                        size: 16,
                      ),
                      label: Text(
                        _direction == 'DESC' ? tr('从新到旧') : tr('从旧到新'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final (s, l) in _sortOptions)
                      ListTile(
                        dense: true,
                        title: Text(l, style: const TextStyle(fontSize: 13)),
                        trailing: s == _sort
                            ? Icon(
                                Icons.check,
                                size: 18,
                                color: theme.colorScheme.primary,
                              )
                            : null,
                        onTap: () => Navigator.pop(ctx, s),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    if (picked == 'toggle_dir') {
      setState(() => _direction = _direction == 'DESC' ? 'ASC' : 'DESC');
    } else {
      setState(() => _sort = picked);
    }
    _reload();
  }

  Future<void> _openCreate() async {
    final id = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const GroupCreatePage()),
    );
    if (id == null || !mounted) return;
    _reload();
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final next = _page + 1;
    setState(() {
      _loading = true;
      _loadingMore = _page > 0;
    });
    _error = '';
    try {
      final r = await buildApi().findGroups(
        page: next,
        perPage: _perPage,
        q: _query,
        sort: _sort,
        direction: _direction,
      );
      if (!mounted) return;
      setState(() {
        _total = r.count;
        final known = _items.map((e) => e.id).toSet();
        _items = [..._items, ...r.items.where((e) => !known.contains(e.id))];
        _page = next;
        if (_items.length >= _total) _hasMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  Widget _footer() {
    final theme = Theme.of(context);
    if (_loadingMore || _loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text(
          _error.isNotEmpty ? tr('加载失败，上拉重试') : tr('已经到底了'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  style: const TextStyle(fontSize: 13),
                  textInputAction: TextInputAction.search,
                  contextMenuBuilder: zhContextMenuBuilder,
                  onChanged: (v) => setState(() => _query = v),
                  onSubmitted: (_) => _reload(),
                  decoration: InputDecoration(
                    hintText: tr('搜索集合'),
                    isDense: true,
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: tr('清空'),
                            icon: const Icon(Icons.clear, size: 16),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _query = '');
                              _reload();
                            },
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                height: 30,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  onPressed: _reload,
                  child: Text(tr('搜索'), style: const TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                height: 30,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: _openSortSheet,
                  child: Text(
                    _sortLabel,
                    style: const TextStyle(fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                height: 30,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: _openCreate,
                  icon: const Icon(Icons.add, size: 15),
                  label: Text(tr('添加'), style: const TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _items.isEmpty && !_loadingMore
              ? StatusView(
                  loading: _loading,
                  empty: _error.isNotEmpty ? _error : tr('没有集合'),
                  error: _error,
                  onRetry: _reload,
                )
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView.builder(
                    key: const PageStorageKey('group_list'),
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                    itemCount:
                        _items.length + ((_hasMore || _loadingMore) ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i >= _items.length) return _footer();
                      final g = _items[i];
                      final meta = <String>[
                        if (g.date.isNotEmpty) g.date,
                        if (g.studio != null && g.studio!.name.isNotEmpty)
                          g.studio!.name,
                        tr('{count} 个短片', {'count': g.sceneCount}),
                      ].join(' · ');
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        child: ListTile(
                          leading: SizedBox(
                            width: 56,
                            height: 56,
                            child: AuthImage(
                              rawPath: g.frontImagePath,
                              radius: 8,
                              width: 56,
                              height: 56,
                              fallbackIcon: Icons.collections_bookmark_outlined,
                            ),
                          ),
                          title: Text(
                            g.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => GroupDetailPage(groupId: g.id),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );

    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: Text(_total > 0 ? '${tr('集合')} ($_total)' : tr('集合')),
      ),
      body: body,
    );
  }
}
