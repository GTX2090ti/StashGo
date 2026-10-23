import 'package:flutter/material.dart';

import '../models/models.dart';
import '../tasks/batch_task_center.dart';
import '../widgets/common.dart';
import 'performer_edit_page.dart';
import 'performer_merge_page.dart';
import 'scene_detail_page.dart';
import 'scrape_page.dart';
import 'tag_detail_page.dart';
import '../l10n/l10n.dart';

/// 关联短片双列横卡 + 无限滚动（演员 / 工作室 / 标签详情共用）。
class RelatedScenes extends StatefulWidget {
  const RelatedScenes(
      {super.key, required this.sceneFilter, this.scrollController});

  final Map<String, dynamic> sceneFilter;

  /// 外层滚动控制器：滚动接近底部时自动加载下一页。
  final ScrollController? scrollController;

  @override
  State<RelatedScenes> createState() => _RelatedScenesState();
}

class _RelatedScenesState extends State<RelatedScenes> {
  final List<Scene> _scenes = [];
  int _total = 0;
  int _page = 0;
  bool _loadingMore = false;
  bool _hasMore = true;
  String _error = '';
  String _sort = 'date';
  String _direction = 'DESC';

  bool _selectMode = false;
  Set<String> _selected = {};
  bool _batchBusy = false;
  List<Tag> _allTags = [];

  /// 后台批量每块最多 100 个 id（一次 bulkSceneUpdate）。
  static const int _bulkChunk = 100;

  int _seenCompleted = BatchTaskCenter.instance.completed;

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

  String get _sortLabel {
    for (final (s, l) in _sortOptions) {
      if (s == _sort) return l;
    }
    return _sort;
  }

  static const int _perPage = 30;

  @override
  void initState() {
    super.initState();
    widget.scrollController?.addListener(_onScroll);
    BatchTaskCenter.instance.addListener(_onBatchTasks);
    _loadMore();
  }

  @override
  void dispose() {
    BatchTaskCenter.instance.removeListener(_onBatchTasks);
    widget.scrollController?.removeListener(_onScroll);
    super.dispose();
  }

  /// 后台任务结束后静默刷新，避免批量改完仍显示旧状态。
  void _onBatchTasks() {
    final done = BatchTaskCenter.instance.completed;
    if (done == _seenCompleted || !mounted) return;
    _seenCompleted = done;
    _reload(silent: true);
  }

  void _onScroll() {
    final c = widget.scrollController;
    if (c == null || !c.hasClients) return;
    if (c.position.pixels >= c.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() {
      _loadingMore = true;
      _error = '';
    });
    try {
      final r = await buildApi().findScenes(
        page: _page + 1,
        perPage: _perPage,
        sort: _sort,
        direction: _direction,
        sceneFilter: widget.sceneFilter,
      );
      if (!mounted) return;
      setState(() {
        _scenes.addAll(r.items);
        _total = r.count;
        _page++;
        _hasMore = _scenes.length < r.count;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// 重新加载：silent 时保留现有列表，返回后静默替换，避免闪白。
  Future<void> _reload({bool silent = false}) async {
    final c = widget.scrollController;
    final saved = (c != null && c.hasClients) ? c.offset : 0.0;
    if (silent) {
      if (_loadingMore || _batchBusy) return;
      try {
        final r = await buildApi().findScenes(
          page: 1,
          perPage: _perPage,
          sort: _sort,
          direction: _direction,
          sceneFilter: widget.sceneFilter,
        );
        if (!mounted) return;
        setState(() {
          _error = '';
          _total = r.count;
          _scenes
            ..clear()
            ..addAll(r.items);
          _page = 1;
          _hasMore = _scenes.length < _total;
          final ids = _scenes.map((s) => s.id).toSet();
          _selected.removeWhere((id) => !ids.contains(id));
        });
      } catch (_) {
        return;
      }
    } else {
      setState(() {
        _error = '';
        _page = 0;
        _hasMore = true;
        _total = 0;
        _scenes.clear();
      });
      await _loadMore();
      if (!mounted) return;
    }
    if (saved <= 0 || c == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      while (mounted &&
          c.hasClients &&
          c.position.hasContentDimensions &&
          _hasMore &&
          c.position.maxScrollExtent < saved) {
        await _loadMore();
        if (!mounted) return;
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!mounted || !c.hasClients || !c.position.hasContentDimensions) return;
      final max = c.position.maxScrollExtent;
      final target = saved <= max ? saved : max;
      if ((c.offset - target).abs() > 1) c.jumpTo(target);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// 进入短片前记住外层列表的位置，返回后恢复，避免长列表被刷回顶部。
  Future<void> _openScene(Scene s) async {
    if (_selectMode) {
      _toggleSelect(s.id);
      return;
    }
    final c = widget.scrollController;
    final saved = (c != null && c.hasClients) ? c.offset : 0.0;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SceneDetailPage(sceneId: s.id)),
    );
    if (!mounted || c == null || saved <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      while (mounted &&
          c.hasClients &&
          c.position.hasContentDimensions &&
          _hasMore &&
          c.position.maxScrollExtent < saved) {
        await _loadMore();
        if (!mounted) return;
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!mounted || !c.hasClients || !c.position.hasContentDimensions) return;
      final max = c.position.maxScrollExtent;
      final target = saved <= max ? saved : max;
      if ((c.offset - target).abs() > 1) c.jumpTo(target);
    });
    WidgetsBinding.instance.scheduleFrame();
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
                    child: Text(tr('排序方式'),
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
                      _direction == 'DESC' ? tr('从新到旧') : tr('从旧到新'),
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

  // ---------- 批量（与主页短片列表一致） ----------

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
      if (_scenes.isNotEmpty &&
          _scenes.every((s) => _selected.contains(s.id))) {
        _selected.clear();
      } else {
        _selected = _scenes.map((s) => s.id).toSet();
      }
    });
  }

  /// 批量写进后台任务中心：每 [_bulkChunk] 个 id 合成一次 bulkSceneUpdate，
  /// 连续 3 块失败即中止，避免服务器不可达时整批空转。
  void _enqueueBulk(
      String title, List<String> ids, Map<String, dynamic> fields) {
    if (ids.isEmpty) return;
    final api = buildApi();
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
    final api = buildApi();
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
      await buildApi().generateCovers(_selected.toList());
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
      await buildApi().mergeScenes(
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
      final tags = await buildApi().allTags();
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
      builder: (_) => const _RelatedRatingSheet(),
    );
    if (v != null) _batchRating(v);
  }

  /// 批量设置工作室：只给还没设置工作室的短片写，避免整批空转。
  Future<void> _batchStudio() async {
    if (_selected.isEmpty) return;
    List<Studio> studios;
    try {
      studios = await buildApi().allStudios();
    } catch (e) {
      if (mounted) {
        showToast(context, tr('加载工作室失败：{error}', {'error': e}),
            error: true);
      }
      return;
    }
    if (!mounted) return;
    final picked = await showSingleSelectSheet(
      context,
      title: tr('选择工作室'),
      options: [for (final s in studios) (s.id, s.name)],
    );
    if (picked == null || !mounted || _batchBusy) return;
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

  /// 批量添加演员：追加到所有选中短片，已含全部所选演员的跳过。
  Future<void> _batchPerformers() async {
    if (_selected.isEmpty) return;
    List<Performer> performers;
    try {
      performers = await buildApi().allPerformers();
    } catch (e) {
      if (mounted) {
        showToast(context, tr('加载演员失败：{error}', {'error': e}),
            error: true);
      }
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

  /// 批量加入集合：用 BulkUpdateIds 的 ADD 追加，不覆盖短片已有集合。
  Future<void> _batchAddToGroups() async {
    if (_selected.isEmpty || _batchBusy) return;
    List<Group> groups;
    try {
      groups = (await buildApi().findGroups(perPage: 500)).items;
    } catch (e) {
      if (mounted) {
        showToast(context, tr('加载集合失败：{error}', {'error': e}),
            error: true);
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
            ),
            const SizedBox(width: 4),
            btn(label: tr('工作室'), onPressed: has ? _batchStudio : null),
            const SizedBox(width: 4),
            btn(label: tr('演员'), onPressed: has ? _batchPerformers : null),
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
    final theme = Theme.of(context);
    if (_total == 0 && !_loadingMore && _error.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
         SectionTitle(tr('相关短片')),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(tr('暂无相关短片'),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
            child: SectionTitle(tr('短片（{total}）', {'total': _total}))),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: TextButton(
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
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 28)),
            child: Text(_selectMode ? tr('取消') : tr('多选'),
                style: const TextStyle(fontSize: 11)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: TextButton.icon(
            onPressed: _openSortSheet,
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 28)),
            icon: Icon(
              _direction == 'DESC'
                  ? Icons.arrow_downward
                  : Icons.arrow_upward,
              size: 13,
            ),
            label: Text(_sortLabel,
                style: const TextStyle(fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ),
      ]),
      if (_selectMode) _batchBar(),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 2),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.95,
          crossAxisSpacing: 10,
          mainAxisSpacing: 12,
        ),
        itemCount: _scenes.length + ((_hasMore || _loadingMore) ? 1 : 0),
        itemBuilder: (_, i) {
          if (i >= _scenes.length) {
            if (_error.isNotEmpty) {
              return Center(
                child: TextButton(
                  onPressed: _loadMore,
                  child:  Text(tr('加载失败，点击重试'),
                      style: TextStyle(fontSize: 12)),
                ),
              );
            }
            return _loadingMore
                ? const Center(
                    child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : Center(
                    child: Text(tr('已经到底了'),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  );
          }
          final s = _scenes[i];
          final sel = _selected.contains(s.id);
          final artist = [
            if (s.studio != null) s.studio!.name,
            ...s.performers.map((p) => p.name),
          ].join(' · ');
          return SceneListCard(
            title: s.title,
            rawCover: s.paths.raw,
            date: s.date,
            rating100: s.rating100,
            organized: s.organized,
            duration: s.duration,
            height: s.files.isEmpty ? 0 : s.files.first.height,
            artist: artist,
            tagCount: s.tags.length,
            hasCaption: s.captions.isNotEmpty,
            onTap: () => _openScene(s),
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
                            ? theme.colorScheme.primary
                            : Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Text(
                        sel ? '✓' : '○',
                        style: TextStyle(
                          fontSize: 13,
                          color: sel ? Colors.white : Colors.white70,
                        ),
                      ),
                    ),
                  )
                : null,
          );
        },
      ),
      if (_total == 0 && _loadingMore)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: SizedBox(
                width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        ),
    ]);
  }
}

class _RelatedRatingSheet extends StatelessWidget {
  const _RelatedRatingSheet();

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

/// 演员详情页：档案 + 关联短片。
class PerformerDetailPage extends StatefulWidget {
  const PerformerDetailPage({super.key, required this.performerId});

  final String performerId;

  @override
  State<PerformerDetailPage> createState() => _PerformerDetailPageState();
}

class _PerformerDetailPageState extends State<PerformerDetailPage> {
  Performer? _p;
  bool _loading = true;
  String _error = '';
  bool _showAllAliases = false;
  final _scroll = ScrollController();

  /// 别名预览：默认只显示前 5 个，太多就省略并标注总数。
  String _aliasPreview(String raw) {
    final list = raw
        .split(RegExp('[,、]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (list.isEmpty) return raw;
    const show = 5;
    if (list.length <= show) return list.join('、');
    return '${list.take(show).join('、')} ${tr('等 {count} 个', {'count': list.length})}';
  }

  static int _filledCount(List<bool> filled) =>
      filled.where((e) => e).length;

  /// 组内无内容时整组不显示。
  Widget _foldIf(String title, List<Widget> children, {String summary = ''}) {
    if (children.isEmpty) return const SizedBox.shrink();
    return FoldSection(title: title, summary: summary, children: children);
  }

  static String _fmtTime(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    final l = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // 已有内容时静默刷新：切到 StatusView 会销毁关联短片列表，滚动位置随之一并丢失。
    if (_p == null) setState(() => _loading = true);
    _error = '';
    try {
      final p = await buildApi().findPerformer(widget.performerId);
      if (!mounted) return;
      setState(() {
        _p = p;
        _loading = false;
      });
      if (p == null && mounted) setState(() => _error = tr('加载失败'));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _openEdit() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => PerformerEditPage(performerId: widget.performerId)),
    );
    if (changed == true) _load();
  }

  void _openScrape() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ScrapePage(
          kind: ScrapeKind.performer,
          targetId: widget.performerId,
          targetTitle: _p?.name ?? '',
        ),
      ),
    ).then((v) {
      if (v == true) _load();
    });
  }

  /// 切换收藏星标；成功后刷新详情并通知列表。
  Future<void> _toggleFav() async {
    final p = _p;
    if (p == null) return;
    try {
      await buildApi()
          .updatePerformer({'id': p.id, 'favorite': !p.favorite});
      if (!mounted) return;
      showToast(context, p.favorite ? tr('已取消收藏') : tr('已收藏'));
      _load();
    } catch (e) {
      if (!mounted) return;
      showToast(context, tr('操作失败：{error}', {'error': e}), error: true);
    }
  }

  /// 确认并删除演员；删除成功后返回上一页并刷新列表。
  Future<void> _confirmDelete() async {
    final name = _p?.name ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:  Text(tr('删除演员')),
        content: Text(tr(
            '确定删除「{name}」吗？\n该演员不会从已有短片中移除，但演员档案会被永久删除。',
            {'name': name.isEmpty ? tr('此演员') : name})),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child:  Text(tr('取消'))),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE5533D)),
              onPressed: () => Navigator.pop(ctx, true),
              child:  Text(tr('删除'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await buildApi().destroyPerformer(widget.performerId);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('删除失败：{error}', {'error': e}))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _p;
    return Scaffold(
      appBar: AppBar(
          title: Text(p?.name.isNotEmpty == true ? p!.name : tr('演员详情'),
              overflow: TextOverflow.ellipsis),
          actions: [
            if (p != null)
              IconButton(
                tooltip: p.favorite ? tr('取消收藏') : tr('收藏'),
                onPressed: _toggleFav,
                icon: Icon(p.favorite ? Icons.star : Icons.star_border),
              ),
            if (p != null)
              IconButton(
                tooltip: tr('合并演员'),
                onPressed: () async {
                  final ok = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                        builder: (_) => PerformerMergePage(
                              targetId: widget.performerId,
                              targetName: p.name,
                            )),
                  );
                  if (ok == true && mounted) _load();
                },
                icon: const Icon(Icons.merge_type),
              ),
            if (p != null)
              IconButton(
                tooltip: tr('删除演员'),
                onPressed: () => _confirmDelete(),
                icon: const Icon(Icons.delete_outline),
              ),
          ]),
      body: _loading
          ? StatusView(loading: true, empty: '', onRetry: _load)
          : p == null
              ? StatusView(
                  loading: false,
                  empty: _error.isNotEmpty ? _error : tr('加载失败'),
                  error: _error,
                  onRetry: _load)
              : ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(16),
                  children: [
                    Center(
                      child: p.imagePath.isEmpty
                          ? CircleAvatar(
                              radius: 80,
                              backgroundColor:
                                  theme.colorScheme.surfaceContainerHighest,
                              child: Text(
                                p.name.isEmpty ? '?' : p.name.substring(0, 1),
                                style: const TextStyle(fontSize: 56),
                              ),
                            )
                          : AuthImage(
                              rawPath: p.imagePath,
                              radius: 80,
                              width: 160,
                              height: 160,
                              fallbackIcon: Icons.person_outline,
                            ),
                    ),
                    const SizedBox(height: 10),
                    Text(p.name,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    if (p.disambiguation.isNotEmpty)
                      Text(p.disambiguation,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                          child: OutlinedButton(
                              onPressed: _openEdit, child:  Text(tr('编辑')))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: OutlinedButton(
                              onPressed: _openScrape, child:  Text(tr('削刮')))),
                    ]),

                    FoldSection(
                      title: tr('基本信息'),
                      open: true,
                      children: [
                        if (p.aliasParts.isNotEmpty) ...[
                          InfoRow(tr('别名'),
                              _showAllAliases
                                  ? p.aliasParts.join('、')
                                  : _aliasPreview(p.aliases)),
                          if (p.aliasParts.length > 5)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 0),
                                    minimumSize: const Size(0, 28)),
                                onPressed: () => setState(
                                    () => _showAllAliases = !_showAllAliases),
                                child: Text(
                                  _showAllAliases
                                      ? tr('收起')
                                      : tr('查看更多 {count} 个', {'count': p.aliasParts.length - 5}),
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                        ],
                        if (p.gender.isNotEmpty)
                          InfoRow(tr('性别'), enumLabel(kGenderOptions, p.gender)),
                        if (p.birthdate.isNotEmpty)
                          InfoRow(tr('出生日期'), p.birthdate),
                        if (p.ageText.isNotEmpty)
                          InfoRow(tr('年龄'), p.ageText),
                        if (p.deathDate.isNotEmpty)
                          InfoRow(tr('去世日期'), p.deathDate),
                        if (p.country.isNotEmpty) InfoRow(tr('国家'), p.country),
                        if (p.ethnicity.isNotEmpty) InfoRow(tr('族裔'), p.ethnicity),
                        if (p.rating100 > 0)
                          InfoRow(tr('评分'),
                              '${(p.rating100 / 20).toStringAsFixed(1)} / 5.0'),
                        if (p.ignoreAutoTag)  InfoRow(tr('自动打标'), tr('已忽略')),
                      ],
                    ),

                    _foldIf(tr('身体数据'), [
                      if (p.heightCm > 0) InfoRow(tr('身高'), '${p.heightCm} cm'),
                      if (p.weight > 0) InfoRow(tr('体重'), '${p.weight} kg'),
                      if (p.measurements.isNotEmpty)
                        InfoRow(tr('三围'), p.measurements),
                      if (p.fakeTits.isNotEmpty) InfoRow(tr('隆胸'), p.fakeTits),
                      if (p.penisLength > 0)
                        InfoRow(tr('阴茎长度'), '${p.penisLength.toStringAsFixed(1)} cm'),
                      if (p.circumcised.isNotEmpty)
                        InfoRow(tr('环切状态'),
                            enumLabel(kCircumcisedOptions, p.circumcised)),
                      if (p.eyeColor.isNotEmpty) InfoRow(tr('瞳色'), p.eyeColor),
                      if (p.hairColor.isNotEmpty) InfoRow(tr('发色'), p.hairColor),
                    ], summary: tr('{count} 项', {
                      'count': _filledCount([
                        p.heightCm > 0,
                        p.weight > 0,
                        p.measurements.isNotEmpty,
                        p.fakeTits.isNotEmpty,
                        p.penisLength > 0,
                        p.circumcised.isNotEmpty,
                        p.eyeColor.isNotEmpty,
                        p.hairColor.isNotEmpty,
                      ])
                    })),

                    _foldIf(tr('职业生涯'), [
                      if (p.careerText.isNotEmpty)
                        InfoRow(tr('从业年限'), p.careerText),
                      if (p.tattoos.isNotEmpty) InfoRow(tr('纹身'), p.tattoos),
                      if (p.piercings.isNotEmpty) InfoRow(tr('穿孔'), p.piercings),
                    ], summary: tr('{count} 项', {
                      'count': _filledCount([
                        p.careerText.isNotEmpty,
                        p.tattoos.isNotEmpty,
                        p.piercings.isNotEmpty,
                      ])
                    })),

                    if (p.urls.isNotEmpty)
                      FoldSection(
                        title: tr('链接'),
                        summary: tr('{count} 个', {'count': p.urls.length}),
                        children: [
                          for (final u in p.urls)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: SelectableText(u,
                                  style: theme.textTheme.bodySmall),
                            ),
                        ],
                      ),

                    if (p.tags.isNotEmpty)
                      FoldSection(
                        title: tr('标签'),
                        summary: tr('{count} 个', {'count': p.tags.length}),
                        children: [
                          Wrap(children: [
                            for (final t in p.tags)
                              TapChip(
                                  label: t.name,
                                  onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            TagDetailPage(tagId: t.id)),
                                  )),
                          ]),
                        ],
                      ),

                    _foldIf(tr('档案'), [
                      if (p.details.isNotEmpty)
                        Text(p.details,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(height: 1.6)),
                      InfoRow(tr('短片'), '${p.sceneCount}'),
                      if (p.imageCount > 0) InfoRow(tr('图片'), '${p.imageCount}'),
                      if (p.galleryCount > 0)
                        InfoRow(tr('相册'), '${p.galleryCount}'),
                      if (p.groupCount > 0) InfoRow(tr('合集'), '${p.groupCount}'),
                      if (p.oCounter > 0) InfoRow(tr('O 计数'), '${p.oCounter}'),
                      if (p.updatedAt.isNotEmpty)
                        InfoRow(tr('更新时间'), _fmtTime(p.updatedAt)),
                    ], summary: p.details.isEmpty ? tr('统计') : tr('简介 + 统计')),

                    RelatedScenes(
                      scrollController: _scroll,
                      sceneFilter: {
                        'performers': {
                          'value': [widget.performerId],
                          'modifier': 'INCLUDES',
                        }
                      },
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
    );
  }
}
