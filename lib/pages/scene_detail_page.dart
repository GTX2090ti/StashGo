import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/stash_api.dart';
import '../models/models.dart';
import '../widgets/common.dart';
import 'merge_page.dart';
import 'performer_detail_page.dart';
import 'scrape_page.dart';
import 'scene_edit_page.dart';
import 'studio_detail_page.dart';
import '../l10n/l10n.dart';


/// 短片详情页：工作室 / 演员 / 标签可点击进入对应详情。
class SceneDetailPage extends StatefulWidget {
  const SceneDetailPage({super.key, required this.sceneId, this.onChanged});

  final String sceneId;
  final VoidCallback? onChanged;

  @override
  State<SceneDetailPage> createState() => _SceneDetailPageState();
}

class _SceneDetailPageState extends State<SceneDetailPage> {
  Scene? _scene;
  bool _loading = true;
  String _error = '';
  bool _favBusy = false;
  bool _playBusy = false;
  bool _genBusy = false;
  bool _clearBusy = false;
  String _primaryFileId = '';
  bool _primaryBusy = false;

  /// 封面是否宽屏（宽高比 >= 1.4）：宽屏铺满，方形/竖图完整显示不裁切。
  bool _coverWide = true;

  StashApi get _api => buildApi();

  /// 探测封面原始宽高比，决定铺满还是完整显示。
  void _probeCoverRatio(String rawPath) {
    if (rawPath.isEmpty) return;
    final url = _api.imageUrl(rawPath);
    if (url.isEmpty) return;
    try {
      final provider = NetworkImage(url, headers: _api.imageHeaders);
      final stream = provider.resolve(ImageConfiguration.empty);
      stream.addListener(
        ImageStreamListener(
          (info, _) {
            if (!mounted) return;
            final w = info.image.width.toDouble();
            final h = info.image.height.toDouble();
            if (h > 0) {
              setState(() => _coverWide = (w / h) >= 1.4);
            }
          },
          onError: (_, __) {},
        ),
      );
    } catch (_) {}
  }

  /// 设置默认文件（Stash 0.31+ SceneUpdateInput.primary_file_id）。
  Future<void> _setPrimaryFile(String fileId) async {
    final s = _scene;
    if (s == null || _primaryBusy) return;
    setState(() => _primaryBusy = true);
    try {
      await _api.updateScene({'id': s.id, 'primary_file_id': fileId});
      if (!mounted) return;
      setState(() => _primaryFileId = fileId);
      showToast(context, tr('已设为默认文件'));
    } catch (e) {
      if (!mounted) return;
      showToast(context, tr('设置失败：{error}', {'error': e}));
    } finally {
      if (mounted) setState(() => _primaryBusy = false);
    }
  }

  /// 为当前短片生成封面（服务端后台任务，只补缺失，不覆盖已有封面）。
  Future<void> _generateCover() async {
    setState(() => _genBusy = true);
    try {
      await _api.generateCovers([widget.sceneId]);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
         SnackBar(content: Text(tr('已提交生成封面任务，可到「Stash 任务」查看进度'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('生成封面失败：{error}', {'error': e}))));
    } finally {
      if (mounted) setState(() => _genBusy = false);
    }
  }

  /// 清除当前短片的全部削刮结果：标题改为文件名，其余削刮写入的字段清空。需二次确认。
  Future<void> _clearScrape() async {
    final s = _scene;
    if (s == null || _clearBusy) return;
    final name = s.fileBaseName;
    if (name.isEmpty) {
      showToast(context, tr('该短片没有可取名的文件'));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:  Text(tr('清除削刮')),
        content: Text(tr(
            '将清空该短片的简介、日期、链接、工作室、演员与标签，并把标题改为文件名「{name}」。\n评分、已看次数与封面不受影响。此操作无法撤销。',
            {'name': name})),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child:  Text(tr('取消'))),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE5533D)),
              onPressed: () => Navigator.pop(ctx, true),
              child:  Text(tr('清除'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _clearBusy = true);
    try {
      await _api.clearSceneScrape(s.id, name);
      await _load();
      widget.onChanged?.call();
      if (mounted) {
        showToast(context, tr('已清除削刮，标题改为「{name}」', {'name': name}));
      }
    } catch (e) {
      if (mounted) showToast(context, tr('清除失败：{error}', {'error': e}));
    } finally {
      if (mounted) setState(() => _clearBusy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    _error = '';
    try {
      final s = await _api.findScene(widget.sceneId);
      if (!mounted) return;
      setState(() {
        _scene = s;
        _loading = false;
      });
      if (s == null) {
        if (mounted) setState(() => _error = tr('加载失败'));
      } else {
        _probeCoverRatio(s.coverPath);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _toggleFavorite() async {
    final s = _scene;
    if (s == null || _favBusy) return;
    setState(() => _favBusy = true);
    final target = !s.organized;
    try {
      await _api.updateScene({'id': widget.sceneId, 'organized': target});
      if (mounted) setState(() => _scene = s.copyWith(organized: target));
      // 通知列表刷新（已修复刷新后保持滚动位置），收藏页下同步移除/更新条目。
      widget.onChanged?.call();
    } catch (_) {
      // 忽略失败
    }
    if (mounted) setState(() => _favBusy = false);
  }

  /// 标记已看一次（Stash 的播放次数，不是 O 计数）。
  Future<void> _markPlayed() async {
    final s = _scene;
    if (s == null || _playBusy) return;
    setState(() => _playBusy = true);
    try {
      final count = await _api.markScenePlayed(s.id);
      if (!mounted) return;
      setState(() => _scene = s.copyWith(playCount: count));
      showToast(context, tr('已标记已看（{count} 次）', {'count': count}));
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      showToast(context, tr('标记已看失败：{error}', {'error': e}),
          error: true);
    } finally {
      if (mounted) setState(() => _playBusy = false);
    }
  }

  /// 清零已看次数（需二次确认）。
  Future<void> _confirmResetPlayed() async {
    final s = _scene;
    if (s == null || _playBusy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('重置已看')),
        content: Text(tr('将「{title}」的已看次数清零？', {'title': s.displayTitle})),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('取消'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('重置'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _playBusy = true);
    try {
      await _api.resetScenePlayCount(s.id);
      if (!mounted) return;
      setState(() => _scene = s.copyWith(playCount: 0));
      showToast(context, tr('已重置已看'));
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      showToast(context, tr('重置失败：{error}', {'error': e}), error: true);
    } finally {
      if (mounted) setState(() => _playBusy = false);
    }
  }

  Future<void> _openEdit() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => SceneEditPage(sceneId: widget.sceneId)),
    );
    if (changed == true) {
      _load();
      widget.onChanged?.call();
    }
  }

  void _openScrape() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ScrapePage(
          kind: ScrapeKind.scene,
          targetId: widget.sceneId,
          targetTitle: _scene?.title ?? '',
        ),
      ),
    ).then((applied) {
      if (applied == true) {
        _load();
        widget.onChanged?.call();
      }
    });
  }

  void _openMerge() {
    final nav = Navigator.of(context);
    nav
        .push(
      MaterialPageRoute(
        builder: (_) => MergePage(
          targetId: widget.sceneId,
          targetTitle: _scene?.title ?? '',
        ),
      ),
    )
        .then((merged) {
      if (merged == true && mounted) {
        nav.pop();
        widget.onChanged?.call();
      }
    });
  }

  void _toastCopy(String path) {
    Clipboard.setData(ClipboardData(text: path));
    showToast(context, tr('路径已复制'));
  }

  /// 文件大小格式化。
  /// 演员标签文案：演员有出生日期时附上拍摄时年龄，没有则只显示名字。
  static String _performerLabel(Performer p, String sceneDate) {
    final age = p.ageAt(sceneDate);
    return age.isEmpty ? p.name : '${p.name} · $age';
  }

  static String _fmtSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes >= (1 << 30)) {
      return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
    }
    if (bytes >= (1 << 20)) {
      return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    }
    if (bytes >= (1 << 10)) {
      return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  /// 时长格式化（秒 → HH:MM:SS / MM:SS）。
  static String _fmtDur(double sec) {
    if (sec <= 0) return '';
    final t = sec.round();
    final h = t ~/ 3600, m = (t % 3600) ~/ 60, s = t % 60;
    String p(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${p(m)}:${p(s)}' : '$m:${p(s)}';
  }

  /// ISO8601 时间 → 可读（本地 UTC 标注）。
  static String _fmtTime(String t) {
    if (t.isEmpty) return '';
    final norm = t.replaceAll('T', ' ').replaceAll('Z', '').replaceAll('+00:00', '');
    return norm.length >= 16 ? norm.substring(0, 16) : norm;
  }

  /// 封面角上的快捷操作按钮：半透明黑底 + 白色图标，压在图片上也清晰。
  Widget _coverAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color color = Colors.white,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, color: color, size: 20),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.45),
        disabledBackgroundColor: Colors.black.withValues(alpha: 0.25),
        minimumSize: const Size(34, 34),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _scene;
    return Scaffold(
      appBar: AppBar(
        title: Text(s != null && s.title.isNotEmpty ? s.title : tr('短片详情'),
            overflow: TextOverflow.ellipsis),
        actions: [
          if (s != null)
            IconButton(
              tooltip: tr('生成封面'),
              onPressed: _genBusy ? null : () => _generateCover(),
              icon: const Icon(Icons.image_outlined),
            ),
        ],
      ),
      body: _loading
          ? StatusView(loading: true, empty: '', onRetry: _load)
          : s == null
              ? StatusView(
                  loading: false,
                  empty: _error.isNotEmpty ? _error : tr('加载失败'),
                  error: _error,
                  onRetry: _load)
              : LayoutBuilder(builder: (context, c) {
                  final wide = c.maxWidth >= 700;
                  final cover = ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // 方形/竖图完整显示时的暗色底
                        const Positioned.fill(
                          child: ColoredBox(color: Color(0xFF0B0D12)),
                        ),
                        AuthImage(
                          rawPath: s.coverPath,
                          fit: BoxFit.contain,
                          radius: 0,
                          fallbackIcon: Icons.movie_outlined,
                        ),
                        // 底部渐变过渡，播放器式背景衔接正文
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            height: 90,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [
                                  Colors.black.withValues(alpha: 0.55),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                        ),
                        // 标记已看 / 清除已看 / 收藏：压在封面底部两角，避免占用 AppBar
                        Positioned(
                          left: 8,
                          bottom: 8,
                          child: Row(children: [
                            _coverAction(
                              icon: Icons.visibility_outlined,
                              tooltip: tr('看过'),
                              onPressed: _playBusy ? null : _markPlayed,
                            ),
                            const SizedBox(width: 8),
                            _coverAction(
                              icon: Icons.restart_alt,
                              tooltip: tr('清除已看'),
                              onPressed: (_playBusy || (s.playCount <= 0))
                                  ? null
                                  : _confirmResetPlayed,
                            ),
                          ]),
                        ),
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: _coverAction(
                            icon: s.organized
                                ? Icons.star
                                : Icons.star_border,
                            tooltip:
                                s.organized ? tr('取消收藏') : tr('收藏'),
                            color: s.organized
                                ? const Color(0xFFFF9F0A)
                                : Colors.white,
                            onPressed: _favBusy ? null : _toggleFavorite,
                          ),
                        ),
                      ],
                    ),
                  );
                  final info = <Widget>[
                    Text(
                      s.title.isNotEmpty ? s.title : tr('（无标题）'),
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                          child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4),
                                  visualDensity: VisualDensity.compact),
                              onPressed: _openEdit,
                              child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(tr('编辑'),
                                      maxLines: 1,
                                      softWrap: false,
                                      style: const TextStyle(fontSize: 14))))),
                      const SizedBox(width: 6),
                      Expanded(
                          child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4),
                                  visualDensity: VisualDensity.compact),
                              onPressed: _openScrape,
                              child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(tr('削刮'),
                                      maxLines: 1,
                                      softWrap: false,
                                      style: const TextStyle(fontSize: 14))))),
                      const SizedBox(width: 6),
                      Expanded(
                          child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4),
                                  visualDensity: VisualDensity.compact),
                              onPressed: _openMerge,
                              child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(tr('合并'),
                                      maxLines: 1,
                                      softWrap: false,
                                      style: const TextStyle(fontSize: 14))))),
                      const SizedBox(width: 6),
                      Expanded(
                          child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4),
                                  visualDensity: VisualDensity.compact,
                                  foregroundColor:
                                      const Color(0xFFE5533D)),
                              onPressed: _clearBusy ? null : _clearScrape,
                              child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(tr('清除'),
                                      maxLines: 1,
                                      softWrap: false,
                                      style: const TextStyle(fontSize: 14))))),
                    ]),

                     SectionTitle(tr('基本信息')),
                    if (s.date.isNotEmpty) InfoRow(tr('日期'), s.date),
                    if (s.rating100 > 0)
                      InfoRow(tr('评分'), '${(s.rating100 / 20).toStringAsFixed(1)} / 5.0'),
                    InfoRow(tr('O 计数'), '${s.oCounter}'),
                    InfoRow(tr('已看次数'), '${s.playCount}'),

                    if (s.studio != null) ...[
                       SectionTitle(tr('工作室')),
                      InkWell(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  StudioDetailPage(studioId: s.studio!.id)),
                        ),
                        child: Text(
                          s.studio!.name,
                          style: TextStyle(
                            fontSize: 14,
                            color: theme.colorScheme.primary,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ],

                    if (s.performers.isNotEmpty) ...[
                      SectionTitle(
                          tr('演员（{count}）', {'count': s.performers.length})),
                      Wrap(
                        children: [
                          for (final p in s.performers)
                            TapChip(
                              label: _performerLabel(p, s.date),
                              kind: ChipKind.performer,
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) =>
                                        PerformerDetailPage(performerId: p.id)),
                              ),
                            ),
                        ],
                      ),
                    ],

                    if (s.urls.isNotEmpty) ...[
                      const SectionTitle('URL'),
                      for (final u in s.urls)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(u,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.colorScheme.primary)),
                        ),
                    ],

                    if (s.files.isNotEmpty) ...[
                       SectionTitle(tr('文件')),
                      for (final f in s.files) ...[
                        InkWell(
                          onTap: () => _toastCopy(f.path),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // 路径单独一行，长路径允许完整折行显示
                                Text(f.path,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme
                                            .colorScheme.onSurfaceVariant)),
                                const SizedBox(height: 2),
                                // 大小 / 时长 / 修改时间
                                Text(
                                  [
                                    if (f.size > 0)
                                      tr('大小 {size}',
                                          {'size': _fmtSize(f.size)}),
                                    if (f.duration > 0)
                                      tr('时长 {duration}',
                                          {'duration': _fmtDur(f.duration)}),
                                    if (f.modTime.isNotEmpty)
                                      tr('修改 {time}',
                                          {'time': _fmtTime(f.modTime)}),
                                  ].join(' · '),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      fontSize: 10,
                                      color: theme
                                          .colorScheme.onSurfaceVariant),
                                ),
                                const SizedBox(height: 2),
                                // 默认文件标记 / 设为默认按钮
                                if (_primaryFileId == f.id)
                                  Padding(
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 2),
                                    child: Text(
                                      tr('★ 默认文件'),
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                              fontSize: 11,
                                              color: theme
                                                  .colorScheme.primary,
                                              fontWeight: FontWeight.w600),
                                    ),
                                  )
                                else
                                  TextButton.icon(
                                    onPressed: _primaryBusy
                                        ? null
                                        : () => _setPrimaryFile(f.id),
                                    style: TextButton.styleFrom(
                                        minimumSize: const Size(0, 26),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 4)),
                                    icon: const Icon(Icons.star_border,
                                        size: 13),
                                    label:  Text(tr('设为默认'),
                                        style: TextStyle(fontSize: 11)),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        // 修改时间等元数据展示后自动添加分割线，分隔多个文件
                        Divider(
                          height: 14,
                          thickness: 0.6,
                          color: theme.colorScheme.outlineVariant
                              .withValues(alpha: 0.7),
                        ),
                      ],
                    ],

                    if (s.tags.isNotEmpty) ...[
                      SectionTitle(tr('标签（{count}）', {'count': s.tags.length})),
                      Wrap(
                        children: [
                          for (final t in s.tags)
                            TapChip(
                              label: t.name,
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => TagDetailPage(tagId: t.id)),
                              ),
                            ),
                        ],
                      ),
                    ],

                    if (s.details.isNotEmpty) ...[
                       SectionTitle(tr('简介')),
                      Text(s.details,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(height: 1.6)),
                    ],
                    const SizedBox(height: 24),
                  ];
                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: wide
                        ? [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                    width: c.maxWidth * 0.42,
                                    height: 340,
                                    child: cover),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: info,
                                  ),
                                ),
                              ],
                            ),
                          ]
                        : [SizedBox(height: 280, child: cover), ...info],
                  );
                }),
    );
  }
}
