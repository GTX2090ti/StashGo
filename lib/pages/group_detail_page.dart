import 'package:flutter/material.dart';

import '../models/models.dart';
import '../widgets/common.dart';
import 'performer_detail_page.dart';
import 'studio_detail_page.dart';
import '../l10n/l10n.dart';

/// 集合详情：封面 + 基本信息 + 关联短片。
class GroupDetailPage extends StatefulWidget {
  const GroupDetailPage({super.key, required this.groupId});

  final String groupId;

  @override
  State<GroupDetailPage> createState() => _GroupDetailPageState();
}

class _GroupDetailPageState extends State<GroupDetailPage> {
  Group? _g;
  bool _loading = true;
  String _error = '';
  final _scroll = ScrollController();

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
    setState(() => _loading = true);
    _error = '';
    try {
      final g = await buildApi().findGroup(widget.groupId);
      if (!mounted) return;
      setState(() {
        _g = g;
        _loading = false;
      });
      if (g == null && mounted) setState(() => _error = tr('加载失败'));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  static String _fmtDur(int sec) {
    if (sec <= 0) return '';
    final h = sec ~/ 3600, m = (sec % 3600) ~/ 60, s = sec % 60;
    String p(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${p(m)}:${p(s)}' : '$m:${p(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final g = _g;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          g != null && g.name.isNotEmpty ? g.name : tr('集合详情'),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _loading
          ? StatusView(loading: true, empty: '', onRetry: _load)
          : g == null
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
                      child: g.frontImagePath.isEmpty
                          ? Container(
                              width: 160,
                              height: 160,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.collections_bookmark_outlined,
                                size: 52,
                                color: theme.colorScheme.outline,
                              ),
                            )
                          : AuthImage(
                              rawPath: g.frontImagePath,
                              radius: 12,
                              width: 160,
                              height: 160,
                              fallbackIcon: Icons.collections_bookmark_outlined,
                            ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      g.name,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    if (g.aliases.isNotEmpty)
                      Text(
                        g.aliases,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    if (g.rating100 > 0)
                      Text(
                        tr('评分：{rating} / 5.0',
                            {'rating': (g.rating100 / 20).toStringAsFixed(1)}),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    const SizedBox(height: 12),

                    InfoRow(tr('短片数'), '${g.sceneCount}'),
                    if (g.date.isNotEmpty) InfoRow(tr('日期'), g.date),
                    if (g.duration > 0) InfoRow(tr('时长'), _fmtDur(g.duration)),
                    if (g.director.isNotEmpty) InfoRow(tr('导演'), g.director),

                    if (g.studio != null) ...[
                      SectionTitle(tr('工作室')),
                      InkWell(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  StudioDetailPage(studioId: g.studio!.id)),
                        ),
                        child: Text(
                          g.studio!.name,
                          style: TextStyle(
                            fontSize: 14,
                            color: theme.colorScheme.primary,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ],

                    if (g.tags.isNotEmpty) ...[
                      SectionTitle(
                          tr('标签（{count}）', {'count': g.tags.length})),
                      Wrap(
                        children: [
                          for (final t in g.tags)
                            TapChip(
                              label: t.name,
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) =>
                                        TagDetailPage(tagId: t.id)),
                              ),
                            ),
                        ],
                      ),
                    ],

                    if (g.synopsis.isNotEmpty) ...[
                      SectionTitle(tr('简介')),
                      Text(g.synopsis,
                          style: theme.textTheme.bodySmall?.copyWith(height: 1.4)),
                    ],

                    if (g.urls.isNotEmpty) ...[
                      const SectionTitle('URL'),
                      for (final u in g.urls)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(u,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.primary)),
                        ),
                    ],

                    RelatedScenes(
                      scrollController: _scroll,
                      sceneFilter: {
                        'groups': {
                          'value': [widget.groupId],
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
