import 'package:flutter/material.dart';

import '../models/models.dart';
import '../widgets/common.dart';
import '../widgets/zh_toolbar.dart';
import '../l10n/l10n.dart';

/// 批量识别（Identify）：按刮削源顺序自动匹配短片元数据。
/// 范围可选全部或指定文件夹；来源多选，顺序即优先级。
class IdentifyPage extends StatefulWidget {
  const IdentifyPage({super.key});

  @override
  State<IdentifyPage> createState() => _IdentifyPageState();
}

class _IdentifyPageState extends State<IdentifyPage> {
  bool _loading = true;
  String? _error;

  // 识别范围：全部（null）或指定文件夹（多选）。
  bool _scopeAll = true;
  List<String> _libraryPaths = [];
  final Set<String> _scopePaths = {};

  // 识别来源：刮削器 + stash-box，勾选顺序即优先级。
  List<Scraper> _scrapers = [];
  List<StashBoxInfo> _stashBoxes = [];
  final Set<String> _selectedScraperIds = {};
  final Set<String> _selectedBoxEndpoints = {};

  // 识别选项。
  bool _setCover = true;
  // 默认关：本应用把 organized 当「收藏」，开着会让识别成功的短片全进收藏。
  bool _setOrganized = false;
  bool _skipMultiple = true;
  bool _skipSingleName = true;

  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = buildApi();
      final results = await Future.wait([
        api.scrapers('SCENE'),
        api.stashBoxes(),
        api.libraryPaths().catchError((_) => <String>[]),
      ]);
      if (!mounted) return;
      setState(() {
        _scrapers = results[0] as List<Scraper>;
        _stashBoxes = results[1] as List<StashBoxInfo>;
        _libraryPaths = results[2] as List<String>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  bool get _hasSource =>
      _selectedScraperIds.isNotEmpty || _selectedBoxEndpoints.isNotEmpty;

  List<Map<String, dynamic>> _buildSources() {
    final list = <Map<String, dynamic>>[];
    // 保持用户勾选的先后顺序（set 为 LinkedHashSet，插入序即优先级）。
    for (final s in _scrapers) {
      if (_selectedScraperIds.contains(s.id)) {
        list.add({'scraper_id': s.id});
      }
    }
    for (final b in _stashBoxes) {
      if (_selectedBoxEndpoints.contains(b.endpoint)) {
        list.add({'stash_box_endpoint': b.endpoint});
      }
    }
    return list;
  }

  Future<void> _submit() async {
    if (!_hasSource) {
      ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text(tr('请至少选择一个识别来源'))));
      return;
    }
    if (!_scopeAll && _scopePaths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text(tr('请选择至少一个文件夹，或改为识别全部'))));
      return;
    }
    setState(() => _submitting = true);
    try {
      await buildApi().identifyScenes(
        sources: _buildSources(),
        setCoverImage: _setCover,
        setOrganized: _setOrganized,
        skipMultipleMatches: _skipMultiple,
        skipSingleNamePerformers: _skipSingleName,
        paths: _scopeAll ? null : _scopePaths.toList(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_scopeAll
            ? tr('批量识别已提交，全部短片将按所选来源匹配')
            : tr('批量识别已提交，共 {count} 个文件夹',
                {'count': _scopePaths.length})),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('识别失败：{error}', {'error': e}))));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _pickPaths() async {
    final sel = <String>{..._scopePaths};
    final ctrl = TextEditingController();
    String query = '';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final visible = query.isEmpty
            ? _libraryPaths
            : _libraryPaths
                .where((p) => p.toLowerCase().contains(query.toLowerCase()))
                .toList();
        return StatefulBuilder(builder: (ctx, setSheet) {
          return Padding(
            padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.75),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(tr('选择识别文件夹（可多选）'),
                        style: Theme.of(ctx).textTheme.titleMedium),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      controller: ctrl,
                      contextMenuBuilder: zhContextMenuBuilder,
                      decoration: InputDecoration(
                        labelText: tr('搜索文件夹'),
                        prefixIcon: Icon(Icons.search, size: 18),
                        isDense: true,
                        suffixIcon: query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: tr('清空'),
                                icon: const Icon(Icons.clear, size: 16),
                                onPressed: () {
                                  ctrl.clear();
                                  setSheet(() => query = '');
                                },
                              ),
                      ),
                      style: const TextStyle(fontSize: 13),
                      onChanged: (v) => setSheet(() => query = v.trim()),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Row(children: [
                      TextButton(
                        onPressed: () =>
                            setSheet(() => sel.addAll(_libraryPaths)),
                        child:  Text(tr('全选'), style: TextStyle(fontSize: 13)),
                      ),
                      const SizedBox(width: 4),
                      TextButton(
                        onPressed: () => setSheet(() => sel.clear()),
                        child:  Text(tr('清空'), style: TextStyle(fontSize: 13)),
                      ),
                      const Spacer(),
                      Text(tr('已选 {count} 个', {'count': sel.length}),
                          style: Theme.of(ctx).textTheme.bodySmall),
                    ]),
                  ),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: visible.length,
                      itemBuilder: (ctx, i) {
                        final p = visible[i];
                        final checked = sel.contains(p);
                        return CheckboxListTile(
                          dense: true,
                          value: checked,
                          title: Text(
                            _pathShort(p),
                            style: const TextStyle(fontSize: 13),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onChanged: (v) => setSheet(() {
                            if (v == true) {
                              sel.add(p);
                            } else {
                              sel.remove(p);
                            }
                          }),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(38)),
                      onPressed: () {
                        setState(() {
                          _scopePaths
                            ..clear()
                            ..addAll(sel);
                        });
                        Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.check, size: 18),
                      label: Text(tr('确定（{count} 个）', {'count': sel.length})),
                    ),
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
  }

  String _pathShort(String p) {
    final parts = p
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.length <= 2) return p;
    return '…/${parts.sublist(parts.length - 2).join('/')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title:  Text(tr('批量识别'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(tr('加载失败：{error}', {'error': _error}),
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: const Color(0xFFE5533D))),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh, size: 18),
                          label:  Text(tr('重试')),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
                  children: [
                    _card(
                      theme,
                      icon: Icons.filter_center_focus_outlined,
                      title: tr('识别范围'),
                      subtitle: tr('按文件名自动匹配元数据；选择文件夹则只识别该目录内的短片。'),
                      children: [
                        RadioGroup<bool>(
                          groupValue: _scopeAll,
                          onChanged: (v) =>
                              setState(() => _scopeAll = v ?? true),
                          child: Column(children: [
                            RadioListTile<bool>(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              value: true,
                              title:  Text(tr('全部短片'),
                                  style: TextStyle(fontSize: 13)),
                            ),
                            RadioListTile<bool>(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              value: false,
                              title: Text(
                                _scopePaths.isEmpty
                                    ? tr('指定文件夹')
                                    : tr('指定文件夹（{count} 个）', {'count': _scopePaths.length}),
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                          ]),
                        ),
                        if (!_scopeAll)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                  minimumSize: const Size.fromHeight(36)),
                              onPressed: _pickPaths,
                              icon: const Icon(Icons.folder_open, size: 18),
                              label: Text(
                                _scopePaths.isEmpty
                                    ? tr('选择文件夹')
                                    : tr('已选 {count} 个，点击修改', {'count': _scopePaths.length}),
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                          ),
                      ],
                    ),
                    _card(
                      theme,
                      icon: Icons.tune_outlined,
                      title: tr('识别来源'),
                      subtitle: tr('按勾选顺序匹配，第一个命中即采用（可多选）。'),
                      children: [
                        if (_scrapers.isEmpty && _stashBoxes.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(tr('服务器未配置任何刮削器或 Stash-box'),
                                style: theme.textTheme.bodySmall),
                          )
                        else ...[
                          if (_scrapers.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(tr('刮削器'),
                                  style: theme.textTheme.bodySmall
                                      ?.copyWith(
                                          color: theme
                                              .colorScheme.onSurfaceVariant)),
                            ),
                            for (final s in _scrapers)
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                value: _selectedScraperIds.contains(s.id),
                                title: Text(s.name,
                                    style: const TextStyle(fontSize: 13),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                onChanged: (v) => setState(() {
                                  if (v == true) {
                                    _selectedScraperIds.add(s.id);
                                  } else {
                                    _selectedScraperIds.remove(s.id);
                                  }
                                }),
                              ),
                          ],
                          if (_stashBoxes.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.only(top: 4, bottom: 4),
                              child: Text('Stash-box',
                                  style: theme.textTheme.bodySmall
                                      ?.copyWith(
                                          color: theme
                                              .colorScheme.onSurfaceVariant)),
                            ),
                            for (final b in _stashBoxes)
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                value:
                                    _selectedBoxEndpoints.contains(b.endpoint),
                                title: Text(
                                  b.name.isEmpty
                                      ? b.endpoint
                                      : '${b.name}（${b.endpoint}）',
                                  style: const TextStyle(fontSize: 13),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onChanged: (v) => setState(() {
                                  if (v == true) {
                                    _selectedBoxEndpoints.add(b.endpoint);
                                  } else {
                                    _selectedBoxEndpoints.remove(b.endpoint);
                                  }
                                }),
                              ),
                          ],
                          const SizedBox(height: 4),
                          Row(children: [
                            TextButton(
                              onPressed: () => setState(() {
                                _selectedScraperIds
                                    .addAll(_scrapers.map((s) => s.id));
                                _selectedBoxEndpoints
                                    .addAll(_stashBoxes.map((b) => b.endpoint));
                              }),
                              child:  Text(tr('全选'),
                                  style: TextStyle(fontSize: 13)),
                            ),
                            const SizedBox(width: 4),
                            TextButton(
                              onPressed: () => setState(() {
                                _selectedScraperIds.clear();
                                _selectedBoxEndpoints.clear();
                              }),
                              child:  Text(tr('清空'),
                                  style: TextStyle(fontSize: 13)),
                            ),
                          ]),
                        ],
                      ],
                    ),
                    _card(
                      theme,
                      icon: Icons.settings_outlined,
                      title: tr('识别选项'),
                      subtitle: tr('匹配成功后的默认写入行为。'),
                      children: [
                        _switch(tr('自动设置封面'), _setCover,
                            (v) => setState(() => _setCover = v)),
                        _switch(tr('标记为已整理'), _setOrganized,
                            (v) => setState(() => _setOrganized = v),
                            hint: tr('识别成功后将短片标记为 organized')),
                        _switch(tr('跳过多个匹配'), _skipMultiple,
                            (v) => setState(() => _skipMultiple = v),
                            hint: tr('多个结果匹配时跳过，避免写错元数据')),
                        _switch(tr('跳过单名演员'), _skipSingleName,
                            (v) => setState(() => _skipSingleName = v)),
                        const SizedBox(height: 6),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(38)),
                          onPressed: _submitting ? null : _submit,
                          icon: _submitting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Icon(Icons.play_arrow, size: 20),
                          label: Text(_submitting ? tr('提交中…') : tr('开始批量识别')),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          tr('识别在 Stash 后台任务中运行，提交后可在「Stash 扫描」页的任务列表查看进度。'),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ],
                ),
    );
  }

  Widget _card(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(title, style: theme.textTheme.titleMedium),
            ]),
            const SizedBox(height: 4),
            Text(subtitle,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged,
      {String? hint}) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      value: value,
      title: Text(label, style: const TextStyle(fontSize: 13)),
      subtitle: hint == null
          ? null
          : Text(hint,
              style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
      onChanged: onChanged,
    );
  }
}
