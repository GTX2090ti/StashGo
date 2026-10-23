import 'package:flutter/material.dart';

import '../models/models.dart';
import '../widgets/common.dart';
import '../widgets/zh_toolbar.dart';
import '../l10n/l10n.dart';

/// 合并短片页：搜索源短片（可多选）→ 合并到目标短片（sceneMerge）。
class MergePage extends StatefulWidget {
  const MergePage({super.key, required this.targetId, required this.targetTitle});

  final String targetId;
  final String targetTitle;

  @override
  State<MergePage> createState() => _MergePageState();
}

class _MergePageState extends State<MergePage> {
  final _ctrl = TextEditingController();
  List<Scene> _scenes = [];
  final Set<String> _selected = {};
  bool _loading = false;
  bool _merging = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final r = await buildApi().findScenes(
        page: 1,
        perPage: 100,
        q: _ctrl.text.trim(),
        sort: 'date',
        direction: 'DESC',
      );
      if (!mounted) return;
      setState(() => _scenes = r.items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = tr('搜索失败：{error}', {'error': e}));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _merge() async {
    if (_selected.isEmpty) return;
    setState(() {
      _merging = true;
      _error = '';
    });
    try {
      await buildApi().mergeScenes(_selected.toList(), widget.targetId);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = tr('合并失败：{error}', {'error': e}));
    } finally {
      if (mounted) setState(() => _merging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title:  Text(tr('合并短片'))),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            controller: _ctrl,
            textInputAction: TextInputAction.search,
            contextMenuBuilder: zhContextMenuBuilder,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: tr('搜索短片标题'),
              isDense: true,
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_ctrl.text.isNotEmpty)
                    IconButton(
                      tooltip: tr('清空'),
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () {
                        _ctrl.clear();
                        setState(() {});
                        _search();
                      },
                    ),
                  IconButton(
                    icon: const Icon(Icons.search, size: 18),
                    onPressed: _search,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(tr('已选 {count} 个源短片', {'count': _selected.length}),
                  style: theme.textTheme.bodySmall),
            ),
          ),
        Expanded(
          child: _loading
              ? StatusView(loading: true, empty: '', onRetry: _search)
              : _scenes.isEmpty
                  ? StatusView(
                      loading: false, empty: tr('没有匹配的短片'), onRetry: _search)
                  : ListView.builder(
                      itemCount: _scenes.length,
                      itemBuilder: (_, i) {
                        final s = _scenes[i];
                        return CheckboxListTile(
                          dense: true,
                          value: _selected.contains(s.id),
                          controlAffinity: ListTileControlAffinity.trailing,
                          secondary: SizedBox(
                            width: 64,
                            height: 36,
                            child: AuthImage(rawPath: s.paths.raw, radius: 6),
                          ),
                          title: Text(s.displayTitle,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: s.date.isEmpty ? null : Text(s.date),
                          onChanged: (v) => setState(() {
                            if (v == true) {
                              _selected.add(s.id);
                            } else {
                              _selected.remove(s.id);
                            }
                          }),
                        );
                      },
                    ),
        ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_error,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: const Color(0xFFE5533D))),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(children: [
            Text(
              tr('选择要并入「{name}」的短片（可多选）。',
                      {'name': widget.targetTitle.isEmpty
                          ? tr('当前短片')
                          : widget.targetTitle}) +
                  tr('合并后演员/标签/文件取并集，源短片条目删除（视频文件挂到本片），播放与 O 记录一并合并。'),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: _merging || _selected.isEmpty ? null : _merge,
              child: Text(_merging
                  ? tr('合并中…')
                  : tr('合并（{count}）', {'count': _selected.length})),
            ),
          ]),
        ),
      ]),
    );
  }
}
