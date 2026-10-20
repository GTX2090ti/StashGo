import 'package:flutter/material.dart';

import '../api/stash_api.dart';
import '../models/models.dart';
import '../settings/app_settings.dart';
import '../widgets/common.dart';
import 'adaptive_grid.dart';
import '../widgets/zh_toolbar.dart';
import 'scene_detail_page.dart';
import 'scene_filter_sheet.dart';

/// 短片列表页：单列大卡片（web app 样式）+ 无限滚动 + 搜索 + 排序 + 筛选 + 批量操作。
/// [onlyOrganized] 为 true 时固定显示已收藏（organized）短片，作为独立收藏页。
class SceneListPage extends StatefulWidget {
  const SceneListPage({super.key, this.embedded = false, this.onlyOrganized = false});

  /// true 时由 HomePage 提供 Scaffold/AppBar，本页只出内容。
  final bool embedded;

  /// 收藏页模式：只显示已整理短片。
  final bool onlyOrganized;

  @override
  State<SceneListPage> createState() => _SceneListPageState();
}

class _SceneListPageState extends State<SceneListPage> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  List<Scene> _scenes = [];
  int _total = 0;
  int _page = 0;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String _error = '';
  String _query = '';

  String _sort = 'date';
  String _direction = 'DESC';

  /// 排序选项（与 Stash 0.31.1 SceneSorter 对齐：date_added→created_at、file_size→filesize、studio_name→studio）。
  static const List<(String, String)> _sortOptions = [
    ('date', '发行日期'),
    ('created_at', '添加时间'),
    ('title', '标题'),
    ('rating', '评分'),
    ('o_counter', '播放次数'),
    ('duration', '时长'),
    ('filesize', '文件大小'),
    ('performer_count', '演员数'),
    ('studio', '工作室'),
    ('tag_count', '标签数'),
  ];

  SceneFilterState _filter = SceneFilterState();

  bool _selectMode = false;
  Set<String> _selected = {};

  List<Tag> _allTags = [];
  bool _batchBusy = false;

  static const int _perPage = 60;

  AppSettings get _cfg => AppSettings.instance;

  StashApi get _api => buildApi();

  String _lastBase = '';
  String _lastKey = '';

  @override
  void initState() {
    super.initState();
    if (widget.onlyOrganized) {
      _filter.organized = true;
    }
    _lastBase = _cfg.baseUrl;
    _lastKey = _cfg.apiKey;
    _cfg.addListener(_onSettingsChanged);
    _scroll.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    _cfg.removeListener(_onSettingsChanged);
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    final b = _cfg.baseUrl;
    final k = _cfg.apiKey;
    if (b != _lastBase || k != _lastKey) {
      _lastBase = b;
      _lastKey = k;
      _reload();
    } else if (mounted) {
      setState(() {});
    }
  }

  /// 无限滚动：接近底部时加载下一页。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _reload() async {
    // 记录当前滚动位置，刷新后精确恢复，避免"进详情操作后返回跳回顶部/偏移"。
    final saved = _scroll.hasClients ? _scroll.offset : 0.0;
    setState(() {
      _error = '';
      _page = 0;
      _hasMore = true;
      _scenes = [];
    });
    await _loadMore();
    if (!mounted) return;
    if (saved <= 0) return;
    // 等列表完成布局后：先按需加载到能容纳原位置，再精确跳回。
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

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final next = _page + 1;
    setState(() {
      _loading = true;
      _loadingMore = _page > 0;
    });
    _error = '';
    try {
      // 收藏页模式：无论筛选面板如何重置，强制锁定 organized=true，
      // 避免"重置筛选"后收藏页退化为显示全部短片。
      if (widget.onlyOrganized) _filter.organized = true;
      final r = _query.trim().isNotEmpty
          ? await _api.searchScenes(
              term: _query.trim(),
              page: next,
              perPage: _perPage,
              sort: _sort,
              direction: _direction,
              sceneFilter: _filter.isEmpty ? null : _filter.toJson(),
            )
          : await _api.findScenes(
              page: next,
              perPage: _perPage,
              q: _query,
              sort: _sort,
              direction: _direction,
              sceneFilter: _filter.isEmpty ? null : _filter.toJson(),
            );
      if (!mounted) return;
      setState(() {
        _total = r.count;
        final known = _scenes.map((e) => e.id).toSet();
        _scenes = [
          ..._scenes,
          ...r.items.where((e) => !known.contains(e.id)),
        ];
        _page = next;
        if (_scenes.length >= _total) _hasMore = false;
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

  String get _sortLabel {
    for (final (s, l) in _sortOptions) {
      if (s == _sort) return l;
    }
    return _sort;
  }

  String get _filterSummary {
    final n = _filter.activeCount;
    return n > 0 ? '筛选 ($n)' : '筛选';
  }

  // ---------- 批量 ----------

  List<Scene> get _selectedScenes =>
      _scenes.where((s) => _selected.contains(s.id)).toList();

  bool get _allSelectedOrganized =>
      _selectedScenes.isNotEmpty && _selectedScenes.every((s) => s.organized);

  void _toggleSelect(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selected.length == _scenes.length) {
        _selected.clear();
      } else {
        _selected = _scenes.map((s) => s.id).toSet();
      }
    });
  }

  /// 批量写并发闸门：6 并发跑完条目；连续 3 次失败立即中止。
  /// 逐个串行 + 每次请求 10s 超时，会在服务器不可达时让批量条长时间处于
  /// 「处理中」（此时除合并/全选外全部置灰），故改为并发 + 快速失败。
  Future<(int, int, bool)> _fanOut(
      List<String> ids, Future<void> Function(String id) one) async {
    var done = 0;
    var failed = 0;
    var consecutive = 0;
    var aborted = false;
    for (var i = 0; i < ids.length && !aborted; i += 6) {
      final chunk = ids.skip(i).take(6);
      final oks = await Future.wait(chunk.map((id) async {
        try {
          await one(id);
          return true;
        } catch (_) {
          return false;
        }
      }));
      for (final ok in oks) {
        if (ok) {
          done++;
          consecutive = 0;
        } else {
          failed++;
          if (++consecutive >= 3) aborted = true;
        }
      }
    }
    return (done, failed, aborted);
  }

  Future<void> _batchFav(bool target) async {
    if (_selected.isEmpty || _batchBusy) return;
    setState(() => _batchBusy = true);
    try {
      final (done, failed, aborted) = await _fanOut(_selected.toList(),
          (id) => _api.updateScene({'id': id, 'organized': target}));
      if (!mounted) return;
      _finishBatch('${target ? "已收藏" : "已取消收藏"} $done 个', failed,
          aborted: aborted);
    } finally {
      if (mounted && _batchBusy) setState(() => _batchBusy = false);
    }
  }

  /// 批量生成封面：一次任务提交所有选中短片（服务端后台执行）。
  Future<void> _batchCovers() async {
    if (_selected.isEmpty) return;
    setState(() => _batchBusy = true);
    try {
      await _api.generateCovers(_selected.toList());
      if (!mounted) return;
      showToast(context, '已提交 ${_selected.length} 个短片的封面生成任务');
    } catch (e) {
      if (!mounted) return;
      showToast(context, '生成封面失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  Future<void> _batchRating(int v) async {
    if (_selected.isEmpty || _batchBusy) return;
    setState(() => _batchBusy = true);
    try {
      final (done, failed, aborted) = await _fanOut(_selected.toList(),
          (id) => _api.updateScene({'id': id, 'rating100': v}));
      if (!mounted) return;
      _finishBatch('已设置评分 $done 个', failed, aborted: aborted);
    } finally {
      if (mounted && _batchBusy) setState(() => _batchBusy = false);
    }
  }

  Future<void> _batchTags(Set<String> picks, bool add) async {
    if (_selected.isEmpty || picks.isEmpty || _batchBusy) return;
    final targets = _selectedScenes;
    if (targets.isEmpty) return;
    final byId = {for (final s in targets) s.id: s};
    setState(() => _batchBusy = true);
    try {
      final (done, failed, aborted) =
          await _fanOut(targets.map((s) => s.id).toList(), (id) async {
        final cur = byId[id]!.tags.map((t) => t.id).toSet();
        final next = add ? cur.union(picks) : cur.difference(picks);
        await _api.updateScene({'id': id, 'tag_ids': next.toList()});
      });
      if (!mounted) return;
      _finishBatch('${add ? "已添加标签" : "已移除标签"} $done 个', failed,
          aborted: aborted);
    } finally {
      if (mounted && _batchBusy) setState(() => _batchBusy = false);
    }
  }

  /// 结束批量：中止时保留勾选，方便用户在链路恢复后重试。
  void _finishBatch(String okText, int failed, {bool aborted = false}) {
    final tail = failed > 0
        ? '，$failed 个失败${aborted ? '（已中止）' : ''}'
        : '';
    showToast(context, '$okText$tail', error: failed > 0);
    setState(() {
      _batchBusy = false;
      if (!aborted) {
        _selected = {};
        _selectMode = false;
      }
    });
    if (!aborted) _reload();
  }

  /// 多选合并：弹窗选择保留的目标短片，其余合入（服务端 sceneMerge）。
  Future<void> _batchMerge() async {
    final scenes = _selectedScenes;
    if (scenes.length < 2 || _batchBusy) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(children: [
                Expanded(
                  child: Text('选择要保留的短片',
                      style: Theme.of(ctx).textTheme.titleMedium),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
              ]),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: scenes.length,
                itemBuilder: (_, i) {
                  final s = scenes[i];
                  return ListTile(
                    dense: true,
                    leading: SizedBox(
                      width: 34,
                      height: 46,
                      child: AuthImage(
                        rawPath: s.paths.raw,
                        radius: 6,
                        width: 34,
                        height: 46,
                      ),
                    ),
                    title: Text(s.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                    onTap: () => Navigator.pop(ctx, s.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _batchBusy = true);
    try {
      await _api.mergeScenes(
          scenes.where((s) => s.id != picked).map((s) => s.id).toList(),
          picked);
      if (!mounted) return;
      _finishBatch('已合并 ${scenes.length} 个短片', 0);
    } catch (e) {
      if (!mounted) return;
      showToast(context, '合并失败：$e', error: true);
    } finally {
      if (mounted && _batchBusy) setState(() => _batchBusy = false);
    }
  }

  Future<void> _openTagSheet(bool add) async {
    try {
      final tags = await _api.allTags();
      if (!mounted) return;
      setState(() => _allTags = tags);
    } catch (_) {
      if (mounted) setState(() => _allTags = const []);
    }
    if (!mounted) return;
    final picks = await showMultiSelectSheet(
      context,
      title: add ? '选择要添加的标签' : '选择要移除的标签',
      options: [for (final t in _allTags) (t.id, t.name)],
      selected: const <String>{},
    );
    if (picks != null && picks.isNotEmpty) {
      await _batchTags(picks, add);
    }
  }

  Future<void> _pickRating() async {
    final v = await showModalBottomSheet<int>(
      context: context,
      builder: (_) => const _RatingSheet(),
    );
    if (v != null) await _batchRating(v);
  }

  /// 批量设置工作室：所有选中短片统一设为同一个工作室。
  Future<void> _batchStudio() async {
    if (_selected.isEmpty) return;
    List<Studio> studios;
    try {
      studios = await _api.allStudios();
    } catch (e) {
      if (mounted) showToast(context, '加载工作室失败：$e', error: true);
      return;
    }
    if (!mounted) return;
    final picked = await showSingleSelectSheet(
      context,
      title: '选择工作室',
      options: [for (final s in studios) (s.id, s.name)],
    );
    if (picked == null || !mounted || _batchBusy) return;
    // 已有工作室的直接跳过，只给没设置的写，避免整批空转。
    final targets =
        _selectedScenes.where((s) => s.studio == null).map((s) => s.id).toList();
    final skipped = _selected.length - targets.length;
    if (targets.isEmpty) {
      showToast(context, '所选短片都已有工作室，无需设置');
      return;
    }
    setState(() => _batchBusy = true);
    try {
      final (done, failed, aborted) = await _fanOut(targets,
          (id) => _api.updateScene({'id': id, 'studio_id': picked}));
      if (!mounted) return;
      _finishBatch(
          '已设置工作室 $done 个'
          '${skipped > 0 ? '，跳过已有工作室 $skipped 个' : ''}',
          failed,
          aborted: aborted);
    } finally {
      if (mounted && _batchBusy) setState(() => _batchBusy = false);
    }
  }

  /// 批量添加演员：把选中的演员追加到所有选中短片。
  Future<void> _batchPerformers() async {
    if (_selected.isEmpty) return;
    List<Performer> performers;
    try {
      performers = await _api.allPerformers();
    } catch (e) {
      if (mounted) showToast(context, '加载演员失败：$e', error: true);
      return;
    }
    if (!mounted) return;
    final picks = await showMultiSelectSheet(
      context,
      title: '选择要添加的演员',
      options: [for (final p in performers) (p.id, p.name)],
      selected: const <String>{},
    );
    if (picks == null || picks.isEmpty || !mounted || _batchBusy) return;
    // 已含全部所选演员的直接跳过，只给还缺的写，避免整批空转。
    final targets = _selectedScenes
        .where((s) => !picks.every(s.performers.map((p) => p.id).contains))
        .toList();
    final skipped = _selected.length - targets.length;
    if (targets.isEmpty) {
      showToast(context, '所选短片都已含这些演员，无需添加');
      return;
    }
    final byId = {for (final s in targets) s.id: s};
    setState(() => _batchBusy = true);
    try {
      final (done, failed, aborted) =
          await _fanOut(targets.map((s) => s.id).toList(), (id) async {
        final cur = byId[id]!.performers.map((p) => p.id).toSet();
        await _api.updateScene(
            {'id': id, 'performer_ids': cur.union(picks).toList()});
      });
      if (!mounted) return;
      _finishBatch(
          '已添加演员 $done 个'
          '${skipped > 0 ? '，跳过已含全部所选演员 $skipped 个' : ''}',
          failed,
          aborted: aborted);
    } finally {
      if (mounted && _batchBusy) setState(() => _batchBusy = false);
    }
  }

  /// 排序方式弹窗（与 Stash 对齐，含方向切换）。
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
                child: Row(children: [
                  Expanded(
                    child: Text('排序方式',
                        style: theme.textTheme.titleMedium),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx, 'toggle_dir');
                    },
                    icon: Icon(
                      _direction == 'DESC'
                          ? Icons.arrow_downward
                          : Icons.arrow_upward,
                      size: 16,
                    ),
                    label: Text(
                      _direction == 'DESC' ? '从新到旧' : '从旧到新',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ]),
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
                            ? Icon(Icons.check,
                                size: 18, color: theme.colorScheme.primary)
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

  Future<void> _openFilter() async {    final result = await Navigator.push<SceneFilterState>(
      context,
      MaterialPageRoute(
        builder: (_) => SceneFilterSheet(initial: _filter),
      ),
    );
    if (result != null) {
      setState(() => _filter = result);
      _reload();
    }
  }

  void _openScene(String id) {
    if (_selectMode) {
      _toggleSelect(id);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => SceneDetailPage(sceneId: id, onChanged: _reload)),
    );
  }

  // ---------- 生效地址栏 ----------

  Widget _searchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _searchCtrl,
            style: const TextStyle(fontSize: 13),
            textInputAction: TextInputAction.search,
            contextMenuBuilder: zhContextMenuBuilder,
            onSubmitted: (_) => _reload(),
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: '搜索标题 / 演员 / 标签',
              isDense: true,
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空',
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
                padding: const EdgeInsets.symmetric(horizontal: 10)),
            onPressed: _reload,
            child: const Text('搜索', style: TextStyle(fontSize: 12)),
          ),
        ),
      ]),
    );
  }

  Widget _toolRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(children: [
        Expanded(
          child: SizedBox(
            height: 28,
            child: OutlinedButton(
              onPressed: _openFilter,
              child: Text(_filterSummary,
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SizedBox(
            height: 28,
            child: OutlinedButton(
              onPressed: _openSortSheet,
              child: Text(_sortLabel,
                  style: const TextStyle(fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 34,
          height: 28,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(34, 28)),
            onPressed: () {
              setState(() =>
                  _direction = _direction == 'DESC' ? 'ASC' : 'DESC');
              _reload();
            },
            child: Icon(
              _direction == 'DESC'
                  ? Icons.arrow_downward
                  : Icons.arrow_upward,
              size: 15,
            ),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          height: 28,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10)),
            onPressed: _scenes.isEmpty
                ? null
                : () {
                    setState(() {
                      if (_selectMode) {
                        _selectMode = false;
                        _selected = {};
                      } else {
                        _selectMode = true;
                      }
                    });
                  },
            child: Text(_selectMode ? '取消' : '多选',
                style: const TextStyle(fontSize: 12)),
          ),
        ),
      ]),
    );
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
          _error.isNotEmpty ? '加载失败，上拉重试' : '已经到底了',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _batchBar() {
    final has = _selected.isNotEmpty && !_batchBusy;
    final theme = Theme.of(context);
    Widget btn({
      required String label,
      required VoidCallback? onPressed,
      double width = 56,
    }) {
      return SizedBox(
        width: width,
        height: 28,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
              padding: EdgeInsets.zero, minimumSize: Size(width, 28)),
          onPressed: onPressed,
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      color: theme.colorScheme.surfaceContainerHighest,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          // 状态提示置于最前：横向滚动时始终可见。
          // 未勾选 → 除「全选」外全部置灰（有意为之）；批量执行中 → 全部置灰并显示进度。
          if (_batchBusy) ...[
            const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 6),
            Text('处理中…', style: theme.textTheme.bodySmall),
          ] else
            Text(
              _selected.isEmpty ? '请先勾选短片' : '已选 ${_selected.length}',
              style: theme.textTheme.bodySmall,
            ),
          const SizedBox(width: 8),
          btn(
            label: _allSelectedOrganized ? '取消收藏' : '收藏',
            onPressed: has ? () => _batchFav(!_allSelectedOrganized) : null,
            width: 68,
          ),
          const SizedBox(width: 4),
          btn(
            label: '评分',
            onPressed: has ? _pickRating : null,
          ),
          const SizedBox(width: 4),
          btn(
            label: '标签',
            onPressed: has ? () => _openTagSheet(true) : null,
          ),
          const SizedBox(width: 4),
          btn(
            label: '工作室',
            onPressed: has ? _batchStudio : null,
            width: 56,
          ),
          const SizedBox(width: 4),
          btn(
            label: '演员',
            onPressed: has ? _batchPerformers : null,
            width: 56,
          ),
          const SizedBox(width: 4),
          btn(
            label: '合并',
            onPressed: (_selected.length >= 2 && !_batchBusy)
                ? _batchMerge
                : null,
          ),
          const SizedBox(width: 4),
          btn(
            label: '封面',
            onPressed: has ? _batchCovers : null,
            width: 56,
          ),
          const SizedBox(width: 4),
          btn(
            label: '全选',
            onPressed: (_scenes.isEmpty || _batchBusy)
                ? null
                : () {
                    _toggleSelectAll();
                  },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(children: [
      _toolRow(),
      _searchRow(),
      Expanded(
        child: _scenes.isEmpty && !_loadingMore
            ? StatusView(
                loading: _loading,
                empty: _error.isNotEmpty ? _error : '没有短片',
                error: _error,
                onRetry: _reload,
              )
            : RefreshIndicator(
                onRefresh: _reload,
                child: LayoutBuilder(builder: (context, c) {
                  return GridView.builder(
                  key: PageStorageKey(widget.onlyOrganized ? 'fav_grid' : 'scene_grid'),
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: adaptiveColumnCount(c.maxWidth),
                    childAspectRatio: 0.95,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: _scenes.length +
                      ((_hasMore || _loadingMore) ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i >= _scenes.length) return _footer();
                    final s = _scenes[i];
                    final sel = _selected.contains(s.id);
                    final artist = [
                      if (s.studio != null) s.studio!.name,
                      ...s.performers.map((p) => p.name),
                    ].join(' · ');
                    return SceneListCard(
                      title: s.title,
                      rawCover: s.coverPath,
                      date: s.date,
                      rating100: s.rating100,
                      organized: s.organized,
                      duration: s.duration,
                      height: s.files.isEmpty ? 0 : s.files.first.height,
                      artist: artist,
                      tagCount: s.tags.length,
                      hasCaption: s.captions.isNotEmpty,
                      onTap: () => _openScene(s.id),
                      trailing: _selectMode
                          ? Positioned(
                              left: 6,
                              top: 6,
                              child: Container(
                                width: 22,
                                height: 22,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: sel
                                      ? Theme.of(context).colorScheme.primary
                                      : Colors.black.withValues(alpha: 0.55),
                                  borderRadius: BorderRadius.circular(11),
                                ),
                                child: Text(
                                  sel ? '✓' : '○',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: sel
                                        ? Colors.white
                                        : Colors.white70,
                                  ),
                                ),
                              ),
                            )
                          : null,
                    );
                  },
                );
                }),
              ),
      ),
      if (_selectMode) _batchBar(),
    ]);

    if (widget.embedded) return Scaffold(body: body);
    return Scaffold(
      appBar: AppBar(
          title: Text(_total > 0
              ? '${widget.onlyOrganized ? '收藏' : '短片'} ($_total)'
              : widget.onlyOrganized ? '收藏' : '短片')),
      body: body,
    );
  }
}

class _RatingSheet extends StatelessWidget {
  const _RatingSheet();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final v in [20, 40, 60, 80, 100])
            ListTile(
              dense: true,
              title: Text('★ ${(v / 20).round()}'),
              onTap: () => Navigator.pop(context, v),
            ),
          ListTile(
            dense: true,
            title: const Text('清除评分'),
            onTap: () => Navigator.pop(context, 0),
          ),
        ],
      ),
    );
  }
}
