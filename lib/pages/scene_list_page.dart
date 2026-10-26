import 'package:flutter/material.dart';

import '../api/stash_api.dart';
import '../api/filter_options_cache.dart';
import '../models/models.dart';
import '../settings/app_settings.dart';
import '../tasks/batch_task_center.dart';
import '../widgets/common.dart';
import 'adaptive_grid.dart';
import '../widgets/zh_toolbar.dart';
import 'scene_detail_page.dart';
import 'scene_filter_sheet.dart';
import '../l10n/l10n.dart';

/// 短片列表页：单列大卡片（web app 样式）+ 无限滚动 + 搜索 + 排序 + 筛选 + 批量操作。
/// [onlyOrganized] 为 true 时固定显示已收藏（organized）短片，作为独立收藏页。
class SceneListPage extends StatefulWidget {
  const SceneListPage({
    super.key,
    this.embedded = false,
    this.onlyOrganized = false,
  });

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
  static List<(String, String)> get _sortOptions => [
    ('date', tr('发行日期')),
    ('created_at', tr('添加时间')),
    ('title', tr('标题')),
    ('rating', tr('评分')),
    ('play_count', tr('播放次数')),
    ('o_counter', tr('O 计数')),
    ('duration', tr('时长')),
    ('filesize', tr('文件大小')),
    ('performer_count', tr('演员数')),
    ('studio', tr('工作室')),
    ('tag_count', tr('标签数')),
  ];

  SceneFilterState _filter = SceneFilterState();

  bool _selectMode = false;
  Set<String> _selected = {};

  List<Tag> _allTags = [];
  bool _batchBusy = false;

  /// 后台批量每块最多 100 个 id（一次 bulkSceneUpdate）。
  static const int _bulkChunk = 100;

  int _seenCompleted = BatchTaskCenter.instance.completed;

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
    BatchTaskCenter.instance.addListener(_onBatchTasks);
    _reload();
    _warmFilterOptions();
  }

  /// 后台预取筛选面板 / 批量操作面板的选项，点开时无需再等一次请求。
  /// 失败无所谓：面板打开时会再拉一次。
  void _warmFilterOptions() {
    FilterOptionsCache.load(_api).ignore();
  }

  @override
  void dispose() {
    _cfg.removeListener(_onSettingsChanged);
    BatchTaskCenter.instance.removeListener(_onBatchTasks);
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

  Future<void> _reload({bool silent = false}) async {
    // 记录当前滚动位置，刷新后精确恢复，避免"进详情操作后返回跳回顶部/偏移"。
    final saved = _scroll.hasClients ? _scroll.offset : 0.0;
    if (silent) {
      // 后台任务完成后的静默刷新：旧列表保留到新数据返回，不闪白、不打断阅读。
      if (_loading || _loadingMore || _batchBusy) return;
      try {
        final r = await _fetchPage(1);
        if (!mounted) return;
        setState(() {
          _error = '';
          _total = r.count;
          _scenes = r.items;
          _page = 1;
          _hasMore = _scenes.length < _total;
        });
      } catch (_) {
        return;
      }
    } else {
      setState(() {
        _error = '';
        _page = 0;
        _hasMore = true;
        _scenes = [];
      });
      await _loadMore();
      if (!mounted) return;
    }
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

  /// 后台任务结束后静默刷新列表（含收藏页），避免操作完仍显示旧数据。
  void _onBatchTasks() {
    final done = BatchTaskCenter.instance.completed;
    if (done == _seenCompleted || !mounted) return;
    _seenCompleted = done;
    _reload(silent: true);
  }

  Future<FindResult<Scene>> _fetchPage(int page) {
    // 收藏页模式：无论筛选面板如何重置，强制锁定 organized=true，
    // 避免"重置筛选"后收藏页退化为显示全部短片。
    if (widget.onlyOrganized) _filter.organized = true;
    return _query.trim().isNotEmpty
        ? _api.searchScenes(
            term: _query.trim(),
            page: page,
            perPage: _perPage,
            sort: _sort,
            direction: _direction,
            sceneFilter: _filter.isEmpty ? null : _filter.toJson(),
          )
        : _api.findScenes(
            page: page,
            perPage: _perPage,
            q: _query,
            sort: _sort,
            direction: _direction,
            sceneFilter: _filter.isEmpty ? null : _filter.toJson(),
          );
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
      final r = await _fetchPage(next);
      if (!mounted) return;
      setState(() {
        _total = r.count;
        final known = _scenes.map((e) => e.id).toSet();
        _scenes = [..._scenes, ...r.items.where((e) => !known.contains(e.id))];
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
    return n > 0 ? tr('筛选 ({count})', {'count': n}) : tr('筛选');
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

  /// 批量写进后台任务中心：每 [_bulkChunk] 个 id 合成一次 bulkSceneUpdate，
  /// 连续 3 块失败即中止，避免服务器不可达时整批空转。
  void _enqueueBulk(String title, List<String> ids, Map<String, dynamic> fields) {
    if (ids.isEmpty) return;
    final api = _api;
    BatchTaskCenter.instance.enqueue(title, ids.length, (task) async {
      var consecutive = 0;
      for (var i = 0; i < ids.length; i += _bulkChunk) {
        if (task.cancelRequested) return;
        final end = i + _bulkChunk < ids.length ? i + _bulkChunk : ids.length;
        final chunk = ids.sublist(i, end);
        try {
          await api.bulkUpdateScenes(chunk, fields);
          BatchTaskCenter.instance.bump(task, done: chunk.length);
          consecutive = 0;
        } catch (_) {
          BatchTaskCenter.instance.bump(task, failed: chunk.length);
          if (++consecutive >= 3) {
            BatchTaskCenter.instance.abort(task);
            return;
          }
        }
      }
    });
  }

  /// 任务已排队：立刻退出多选，进度交给顶栏的后台任务按钮。
  void _leaveBatchToBackground() {
    setState(() {
      _selected = {};
      _selectMode = false;
    });
    showToast(context, tr('已转入后台执行，可在顶栏查看进度'));
  }

  void _batchFav(bool target) {
    if (_selected.isEmpty || _batchBusy) return;
    final ids = _selected.toList();
    _enqueueBulk(
      target
          ? tr('收藏 · {count} 个短片', {'count': ids.length})
          : tr('取消收藏 · {count} 个短片', {'count': ids.length}),
      ids,
      {'organized': target},
    );
    _leaveBatchToBackground();
  }

  /// 批量标记已看：Stash 没有批量接口，逐个加一条播放记录（4 并发）。
  void _batchPlayed() {
    if (_selected.isEmpty || _batchBusy) return;
    final ids = _selected.toList();
    final api = _api;
    const concurrency = 4;
    BatchTaskCenter.instance.enqueue(
      tr('标记已看 · {count} 个短片', {'count': ids.length}),
      ids.length,
      (task) async {
        var consecutive = 0;
        for (var i = 0; i < ids.length; i += concurrency) {
          if (task.cancelRequested) return;
          final end =
              i + concurrency < ids.length ? i + concurrency : ids.length;
          final oks = await Future.wait(
            ids.sublist(i, end).map((id) async {
              try {
                await api.markScenePlayed(id);
                return true;
              } catch (_) {
                return false;
              }
            }),
          );
          var done = 0;
          var failed = 0;
          for (final ok in oks) {
            if (ok) {
              done++;
              consecutive = 0;
            } else {
              failed++;
            }
          }
          BatchTaskCenter.instance.bump(task, done: done, failed: failed);
          if (failed > 0 && ++consecutive >= 3) {
            BatchTaskCenter.instance.abort(task);
            return;
          }
        }
      },
    );
    _leaveBatchToBackground();
  }

  /// 批量生成封面：一次任务提交所有选中短片（服务端后台执行）。
  Future<void> _batchCovers() async {
    if (_selected.isEmpty) return;
    setState(() => _batchBusy = true);
    try {
      await _api.generateCovers(_selected.toList());
      if (!mounted) return;
      showToast(
        context,
        tr('已提交 {count} 个短片的封面生成任务', {'count': _selected.length}),
      );
    } catch (e) {
      if (!mounted) return;
      showToast(context, tr('生成封面失败：{error}', {'error': e}), error: true);
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  void _batchRating(int v) {
    if (_selected.isEmpty || _batchBusy) return;
    final ids = _selected.toList();
    _enqueueBulk(
      tr('设置评分 · {count} 个短片', {'count': ids.length}),
      ids,
      {'rating100': v},
    );
    _leaveBatchToBackground();
  }

  void _batchTags(Set<String> picks, bool add) {
    if (_selected.isEmpty || picks.isEmpty || _batchBusy) return;
    final ids = _selected.toList();
    _enqueueBulk(
      add
          ? tr('添加标签 · {count} 个短片', {'count': ids.length})
          : tr('移除标签 · {count} 个短片', {'count': ids.length}),
      ids,
      {
        'tag_ids': {'ids': picks.toList(), 'mode': add ? 'ADD' : 'REMOVE'},
      },
    );
    _leaveBatchToBackground();
  }

  /// 合并完成：前台操作，结束多选并刷新列表。
  void _finishBatch(String okText) {
    showToast(context, okText);
    setState(() {
      _batchBusy = false;
      _selected = {};
      _selectMode = false;
    });
    _reload();
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
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('选择要保留的短片'),
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(tr('取消')),
                  ),
                ],
              ),
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
                    title: Text(
                      s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
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
        picked,
      );
      if (!mounted) return;
      _finishBatch(tr('已合并 {count} 个短片', {'count': scenes.length}));
    } catch (e) {
      if (!mounted) return;
      showToast(context, tr('合并失败：{error}', {'error': e}), error: true);
    } finally {
      if (mounted && _batchBusy) setState(() => _batchBusy = false);
    }
  }

  Future<void> _openTagSheet(bool add) async {
    try {
      final tags = (await FilterOptionsCache.load(_api)).tags;
      if (!mounted) return;
      setState(() => _allTags = tags);
    } catch (_) {
      if (mounted) setState(() => _allTags = const []);
    }
    if (!mounted) return;
    final picks = await showMultiSelectSheet(
      context,
      title: add ? tr('选择要添加的标签') : tr('选择要移除的标签'),
      options: [for (final t in _allTags) (t.id, t.name)],
      selected: const <String>{},
    );
    if (picks != null && picks.isNotEmpty) {
      _batchTags(picks, add);
    }
  }

  Future<void> _pickRating() async {
    final v = await showModalBottomSheet<int>(
      context: context,
      builder: (_) => const _RatingSheet(),
    );
    if (v != null) _batchRating(v);
  }

  /// 批量设置工作室：所有选中短片统一设为同一个工作室。
  Future<void> _batchStudio() async {
    if (_selected.isEmpty) return;
    List<Studio> studios;
    try {
      studios = (await FilterOptionsCache.load(_api)).studios;
    } catch (e) {
      if (mounted)
        showToast(context, tr('加载工作室失败：{error}', {'error': e}), error: true);
      return;
    }
    if (!mounted) return;
    final picked = await showSingleSelectSheet(
      context,
      title: tr('选择工作室'),
      options: [for (final s in studios) (s.id, s.name)],
    );
    if (picked == null || !mounted || _batchBusy) return;
    // 已有工作室的直接跳过，只给没设置的写，避免整批空转。
    final targets = _selectedScenes
        .where((s) => s.studio == null)
        .map((s) => s.id)
        .toList();
    if (targets.isEmpty) {
      showToast(context, tr('所选短片都已有工作室，无需设置'));
      return;
    }
    _enqueueBulk(
      tr('设置工作室 · {count} 个短片', {'count': targets.length}),
      targets,
      {'studio_id': picked},
    );
    _leaveBatchToBackground();
  }

  /// 批量添加演员：把选中的演员追加到所有选中短片。
  Future<void> _batchPerformers() async {
    if (_selected.isEmpty) return;
    List<Performer> performers;
    try {
      performers = (await FilterOptionsCache.load(_api)).performers;
    } catch (e) {
      if (mounted)
        showToast(context, tr('加载演员失败：{error}', {'error': e}), error: true);
      return;
    }
    if (!mounted) return;
    final picks = await showMultiSelectSheet(
      context,
      title: tr('选择要添加的演员'),
      options: [for (final p in performers) (p.id, p.name)],
      selected: const <String>{},
    );
    if (picks == null || picks.isEmpty || !mounted || _batchBusy) return;
    // 已含全部所选演员的直接跳过，只给还缺的写，避免整批空转。
    final targets = _selectedScenes
        .where((s) => !picks.every(s.performers.map((p) => p.id).contains))
        .map((s) => s.id)
        .toList();
    if (targets.isEmpty) {
      showToast(context, tr('所选短片都已含这些演员，无需添加'));
      return;
    }
    _enqueueBulk(
      tr('添加演员 · {count} 个短片', {'count': targets.length}),
      targets,
      {
        'performer_ids': {'ids': picks.toList(), 'mode': 'ADD'},
      },
    );
    _leaveBatchToBackground();
  }

  /// 批量加入集合：成员关系存在短片侧，先读现有 groups 再整体追加。
  Future<void> _batchAddToGroups() async {
    if (_selected.isEmpty || _batchBusy) return;
    List<Group> groups;
    try {
      groups = (await _api.findGroups(perPage: 500)).items;
    } catch (e) {
      if (mounted) {
        showToast(context, tr('加载集合失败：{error}', {'error': e}), error: true);
      }
      return;
    }
    if (!mounted) return;
    if (groups.isEmpty) {
      showToast(context, tr('没有集合'));
      return;
    }
    final picks = await showMultiSelectSheet(
      context,
      title: tr('选择要加入的集合'),
      options: [for (final g in groups) (g.id, g.name)],
      selected: const <String>{},
    );
    if (picks == null || picks.isEmpty || !mounted || _batchBusy) return;
    // 用 BulkUpdateIds 的 ADD 模式追加成员，不覆盖短片已有的集合与 scene_index。
    final ids = _selected.toList();
    _enqueueBulk(
      tr('加入集合 · {count} 个短片', {'count': ids.length}),
      ids,
      {
        'group_ids': {'ids': picks.toList(), 'mode': 'ADD'},
      },
    );
    _leaveBatchToBackground();
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
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        tr('排序方式'),
                        style: theme.textTheme.titleMedium,
                      ),
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

  Future<void> _openFilter() async {
    final result = await Navigator.push<SceneFilterState>(
      context,
      MaterialPageRoute(builder: (_) => SceneFilterSheet(initial: _filter)),
    );
    if (result != null) {
      setState(() => _filter = result);
      _reload();
    }
  }

  /// 详情页里改完数据时，列表仍被路由遮住：此时刷新会清空 _scenes、把网格
  /// 换成 StatusView，滚动位置恢复拿不到已挂载的 controller，退出后便回到顶部。
  /// 因此只记脏标记，等详情页真正弹出、列表重新可见后再刷新。
  bool _sceneDirty = false;

  void _openScene(String id) {
    if (_selectMode) {
      _toggleSelect(id);
      return;
    }
    _sceneDirty = false;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            SceneDetailPage(sceneId: id, onChanged: () => _sceneDirty = true),
      ),
    ).then((_) {
      if (!mounted || !_sceneDirty) return;
      _sceneDirty = false;
      _reload();
    });
  }

  // ---------- 生效地址栏 ----------

  Widget _searchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(fontSize: 13),
              textInputAction: TextInputAction.search,
              contextMenuBuilder: zhContextMenuBuilder,
              onSubmitted: (_) => _reload(),
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: tr('搜索标题 / 演员 / 标签'),
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
              child: Text(tr('搜索'), style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 28,
              child: OutlinedButton(
                onPressed: _openFilter,
                child: Text(
                  _filterSummary,
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SizedBox(
              height: 28,
              child: OutlinedButton(
                onPressed: _openSortSheet,
                child: Text(
                  _sortLabel,
                  style: const TextStyle(fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
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
                minimumSize: const Size(34, 28),
              ),
              onPressed: () {
                setState(
                  () => _direction = _direction == 'DESC' ? 'ASC' : 'DESC',
                );
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
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
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
              child: Text(
                _selectMode ? tr('取消') : tr('多选'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
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
          _error.isNotEmpty ? tr('加载失败，上拉重试') : tr('已经到底了'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
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
            padding: EdgeInsets.zero,
            minimumSize: Size(width, 28),
          ),
          onPressed: onPressed,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      color: theme.colorScheme.surfaceContainerHighest,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // 状态提示置于最前：横向滚动时始终可见。
            // 全选与高频批量（已看/标签/工作室/演员）在前，低频操作置尾；
            // 未勾选 → 除「全选」外全部置灰（有意为之）；批量执行中 → 全部置灰并显示进度。
            if (_batchBusy) ...[
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 6),
              Text(tr('处理中…'), style: theme.textTheme.bodySmall),
            ] else
              Text(
                _selected.isEmpty
                    ? tr('请先勾选短片')
                    : tr('已选 {count}', {'count': _selected.length}),
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(width: 8),
            btn(
              label: tr('全选'),
              onPressed: (_scenes.isEmpty || _batchBusy)
                  ? null
                  : () {
                      _toggleSelectAll();
                    },
            ),
            const SizedBox(width: 4),
            btn(label: tr('已看'), onPressed: has ? _batchPlayed : null),
            const SizedBox(width: 4),
            btn(
              label: tr('标签'),
              onPressed: has ? () => _openTagSheet(true) : null,
            ),
            const SizedBox(width: 4),
            btn(
              label: tr('集合'),
              onPressed: has ? _batchAddToGroups : null,
              width: 56,
            ),
            const SizedBox(width: 4),
            btn(label: tr('工作室'), onPressed: has ? _batchStudio : null),
            const SizedBox(width: 4),
            btn(label: tr('演员'), onPressed: has ? _batchPerformers : null),
            // 低频操作置尾：收藏 / 合并 / 评分 / 封面。
            const SizedBox(width: 4),
            btn(
              label: _allSelectedOrganized ? tr('取消收藏') : tr('收藏'),
              onPressed: has ? () => _batchFav(!_allSelectedOrganized) : null,
              width: 68,
            ),
            const SizedBox(width: 4),
            btn(
              label: tr('合并'),
              onPressed: (_selected.length >= 2 && !_batchBusy)
                  ? _batchMerge
                  : null,
            ),
            const SizedBox(width: 4),
            btn(label: tr('评分'), onPressed: has ? _pickRating : null),
            const SizedBox(width: 4),
            btn(label: tr('封面'), onPressed: has ? _batchCovers : null),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        _toolRow(),
        _searchRow(),
        Expanded(
          child: _scenes.isEmpty && !_loadingMore
              ? StatusView(
                  loading: _loading,
                  empty: _error.isNotEmpty ? _error : tr('没有短片'),
                  error: _error,
                  onRetry: _reload,
                )
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: LayoutBuilder(
                    builder: (context, c) {
                      return GridView.builder(
                        key: PageStorageKey(
                          widget.onlyOrganized ? 'fav_grid' : 'scene_grid',
                        ),
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: adaptiveColumnCount(c.maxWidth),
                          childAspectRatio: 0.95,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 12,
                        ),
                        itemCount:
                            _scenes.length +
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
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.primary
                                            : Colors.black.withValues(
                                                alpha: 0.55,
                                              ),
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
                    },
                  ),
                ),
        ),
        if (_selectMode) _batchBar(),
      ],
    );

    if (widget.embedded) return Scaffold(body: body);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _total > 0
              ? '${widget.onlyOrganized ? '收藏' : '短片'} ($_total)'
              : widget.onlyOrganized
              ? tr('收藏')
              : tr('短片'),
        ),
      ),
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
            title: Text(tr('清除评分')),
            onTap: () => Navigator.pop(context, 0),
          ),
        ],
      ),
    );
  }
}
