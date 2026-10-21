import 'package:flutter/material.dart';

import '../models/models.dart';
import '../widgets/common.dart';
import 'performer_edit_page.dart';
import 'performer_merge_page.dart';
import 'scene_detail_page.dart';
import 'scrape_page.dart';
import 'tag_detail_page.dart';

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
    _loadMore();
  }

  @override
  void dispose() {
    widget.scrollController?.removeListener(_onScroll);
    super.dispose();
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

  /// 进入短片前记住外层列表的位置，返回后恢复，避免长列表被刷回顶部。
  Future<void> _openScene(Scene s) async {
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
    setState(() {
      _page = 0;
      _hasMore = true;
      _scenes.clear();
      _total = 0;
    });
    _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_total == 0 && !_loadingMore && _error.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SectionTitle('相关短片'),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text('暂无相关短片',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: SectionTitle('短片（$_total）')),
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
                  child: const Text('加载失败，点击重试',
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
                    child: Text('已经到底了',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  );
          }
          final s = _scenes[i];
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
    return '${list.take(show).join('、')} 等 ${list.length} 个';
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
      if (p == null && mounted) setState(() => _error = '加载失败');
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
      showToast(context, p.favorite ? '已取消收藏' : '已收藏');
      _load();
    } catch (e) {
      if (!mounted) return;
      showToast(context, '操作失败：$e', error: true);
    }
  }

  /// 确认并删除演员；删除成功后返回上一页并刷新列表。
  Future<void> _confirmDelete() async {
    final name = _p?.name ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除演员'),
        content: Text('确定删除「${name.isEmpty ? '此演员' : name}」吗？\n'
            '该演员不会从已有短片中移除，但演员档案会被永久删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE5533D)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
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
          .showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _p;
    return Scaffold(
      appBar: AppBar(
          title: Text(p?.name.isNotEmpty == true ? p!.name : '演员详情',
              overflow: TextOverflow.ellipsis),
          actions: [
            if (p != null)
              IconButton(
                tooltip: p.favorite ? '取消收藏' : '收藏',
                onPressed: _toggleFav,
                icon: Icon(p.favorite ? Icons.star : Icons.star_border),
              ),
            if (p != null)
              IconButton(
                tooltip: '合并演员',
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
                tooltip: '删除演员',
                onPressed: () => _confirmDelete(),
                icon: const Icon(Icons.delete_outline),
              ),
          ]),
      body: _loading
          ? StatusView(loading: true, empty: '', onRetry: _load)
          : p == null
              ? StatusView(
                  loading: false,
                  empty: _error.isNotEmpty ? _error : '加载失败',
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
                              onPressed: _openEdit, child: const Text('编辑'))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: OutlinedButton(
                              onPressed: _openScrape, child: const Text('削刮'))),
                    ]),

                    FoldSection(
                      title: '基本信息',
                      open: true,
                      children: [
                        if (p.aliasParts.isNotEmpty) ...[
                          InfoRow('别名',
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
                                      ? '收起'
                                      : '查看更多 ${p.aliasParts.length - 5} 个',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                        ],
                        if (p.gender.isNotEmpty)
                          InfoRow('性别', enumLabel(kGenderOptions, p.gender)),
                        if (p.birthdate.isNotEmpty)
                          InfoRow('出生日期', p.birthdate),
                        if (p.ageText.isNotEmpty)
                          InfoRow('年龄', p.ageText),
                        if (p.deathDate.isNotEmpty)
                          InfoRow('去世日期', p.deathDate),
                        if (p.country.isNotEmpty) InfoRow('国家', p.country),
                        if (p.ethnicity.isNotEmpty) InfoRow('族裔', p.ethnicity),
                        if (p.rating100 > 0)
                          InfoRow('评分',
                              '${(p.rating100 / 20).toStringAsFixed(1)} / 5.0'),
                        if (p.ignoreAutoTag) const InfoRow('自动打标', '已忽略'),
                      ],
                    ),

                    _foldIf('身体数据', [
                      if (p.heightCm > 0) InfoRow('身高', '${p.heightCm} cm'),
                      if (p.weight > 0) InfoRow('体重', '${p.weight} kg'),
                      if (p.measurements.isNotEmpty)
                        InfoRow('三围', p.measurements),
                      if (p.fakeTits.isNotEmpty) InfoRow('隆胸', p.fakeTits),
                      if (p.penisLength > 0)
                        InfoRow('阴茎长度', '${p.penisLength.toStringAsFixed(1)} cm'),
                      if (p.circumcised.isNotEmpty)
                        InfoRow('环切状态',
                            enumLabel(kCircumcisedOptions, p.circumcised)),
                      if (p.eyeColor.isNotEmpty) InfoRow('瞳色', p.eyeColor),
                      if (p.hairColor.isNotEmpty) InfoRow('发色', p.hairColor),
                    ], summary: '${_filledCount([
                      p.heightCm > 0,
                      p.weight > 0,
                      p.measurements.isNotEmpty,
                      p.fakeTits.isNotEmpty,
                      p.penisLength > 0,
                      p.circumcised.isNotEmpty,
                      p.eyeColor.isNotEmpty,
                      p.hairColor.isNotEmpty,
                    ])} 项'),

                    _foldIf('职业生涯', [
                      if (p.careerText.isNotEmpty)
                        InfoRow('从业年限', p.careerText),
                      if (p.tattoos.isNotEmpty) InfoRow('纹身', p.tattoos),
                      if (p.piercings.isNotEmpty) InfoRow('穿孔', p.piercings),
                    ], summary: '${_filledCount([
                      p.careerText.isNotEmpty,
                      p.tattoos.isNotEmpty,
                      p.piercings.isNotEmpty,
                    ])} 项'),

                    if (p.urls.isNotEmpty)
                      FoldSection(
                        title: '链接',
                        summary: '${p.urls.length} 个',
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
                        title: '标签',
                        summary: '${p.tags.length} 个',
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

                    _foldIf('档案', [
                      if (p.details.isNotEmpty)
                        Text(p.details,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(height: 1.6)),
                      InfoRow('短片', '${p.sceneCount}'),
                      if (p.imageCount > 0) InfoRow('图片', '${p.imageCount}'),
                      if (p.galleryCount > 0)
                        InfoRow('相册', '${p.galleryCount}'),
                      if (p.groupCount > 0) InfoRow('合集', '${p.groupCount}'),
                      if (p.oCounter > 0) InfoRow('O 计数', '${p.oCounter}'),
                      if (p.updatedAt.isNotEmpty)
                        InfoRow('更新时间', _fmtTime(p.updatedAt)),
                    ], summary: p.details.isEmpty ? '统计' : '简介 + 统计'),

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
