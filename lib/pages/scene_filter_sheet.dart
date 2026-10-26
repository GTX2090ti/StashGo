import 'package:flutter/material.dart';

import '../api/filter_options_cache.dart';
import '../api/stash_api.dart';
import '../models/models.dart';
import '../widgets/common.dart';
import '../widgets/zh_toolbar.dart';
import '../l10n/l10n.dart';

/// 完整场景筛选器（对齐 iOS SceneFilterSheet）：
/// 工作室/演员/标签多选 + 评分/O计数/时长/日期/分辨率 + 已整理 + 仅看封面。
class SceneFilterSheet extends StatefulWidget {
  final SceneFilterState initial;

  const SceneFilterSheet({super.key, required this.initial});

  @override
  State<SceneFilterSheet> createState() => _SceneFilterSheetState();
}

class _SceneFilterSheetState extends State<SceneFilterSheet> {
  late final SceneFilterState _f = widget.initial.copy();

  List<Studio> _studios = [];
  List<Performer> _performers = [];
  List<Tag> _tags = [];
  bool _loading = true;
  String? _error;

  /// 各多选区（工作室/演员/标签）的搜索词。
  final Map<String, String> _multiSearch = {};

  /// 标签 chip 当前展开的数量（标签动辄上百，先显示一批，可继续加载）。
  int _tagVisible = 100;

  final _api = buildApi();

  @override
  void initState() {
    super.initState();
    final cached = FilterOptionsCache.peek;
    if (cached != null) {
      _apply(cached);
      _loading = false;
    } else {
      _load(fromRetry: false);
    }
  }

  void _apply(FilterOptions o) {
    _studios = o.studios;
    _performers = o.performers;
    _tags = o.tags;
  }

  Future<void> _load({bool fromRetry = true}) async {
    if (fromRetry) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final o = await FilterOptionsCache.load(_api);
      if (!mounted) return;
      setState(() {
        _apply(o);
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

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final from = _f.dateFrom.isNotEmpty
        ? DateTime.tryParse(_f.dateFrom)
        : null;
    final to = _f.dateTo.isNotEmpty ? DateTime.tryParse(_f.dateTo) : null;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: now,
      initialDateRange: (from != null && to != null)
          ? DateTimeRange(start: from, end: to)
          : null,
      helpText: tr('选择日期范围（可不选）'),
      saveText: tr('确定'),
    );
    if (picked != null && mounted) {
      setState(() {
        _f.dateFrom = _fmtDate(picked.start);
        _f.dateTo = _fmtDate(picked.end);
      });
    }
  }

  String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Widget _multiSelect<T>({
    required String title,
    required List<T> items,
    required List<String> selected,
    required String Function(T) label,
    required String Function(T) id,
  }) {
    final theme = Theme.of(context);
    final q = (_multiSearch[title] ?? '').trim().toLowerCase();
    final shown = q.isEmpty
        ? items
        : items
            .where((it) => label(it).toLowerCase().contains(q))
            .toList();
    return ExpansionTile(
      title: Text(title),
      subtitle: selected.isEmpty
          ? null
          : Text(tr('已选 {count} 项', {'count': selected.length}),
              style: TextStyle(color: theme.colorScheme.primary)),
      children: [
        _searchField(title),
        if (_loading)
          _loadingRow()
        else if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(tr('（无）')),
          )
        else
          for (final it in shown)
            CheckboxListTile(
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(label(it),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              value: selected.contains(id(it)),
              onChanged: (v) => setState(() {
                if (v == true) {
                  if (!selected.contains(id(it))) selected.add(id(it));
                } else {
                  selected.remove(id(it));
                }
              }),
            ),
      ],
    );
  }

  /// 该区块自己的加载态，等三份数据回来前也不挡住其它筛选条件。
  Widget _loadingRow() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(tr('加载中…'), style: const TextStyle(fontSize: 12)),
          ],
        ),
      );

  /// 三个多选区共用的搜索框；改词后把标签 chip 重新从第一批展开。
  Widget _searchField(String title) {
    final q = (_multiSearch[title] ?? '').trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: TextField(
        contextMenuBuilder: zhContextMenuBuilder,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: tr('搜索{title}', {'title': title}),
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 18),
          suffixIcon: q.isEmpty
              ? null
              : IconButton(
                  tooltip: tr('清空'),
                  icon: const Icon(Icons.clear, size: 16),
                  onPressed: () => setState(() {
                    _multiSearch[title] = '';
                    _tagVisible = 100;
                  }),
                ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onChanged: (v) => setState(() {
          _multiSearch[title] = v;
          _tagVisible = 100;
        }),
      ),
    );
  }

  /// 标签数量通常上百，用 chip 云代替逐行勾选：
  /// 已选标签固定置顶、可单个移除，其余按名称排序并分批展开。
  Widget _tagSelect() {
    final theme = Theme.of(context);
    final q = (_multiSearch['标签'] ?? '').trim().toLowerCase();
    int byName(Tag a, Tag b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());

    final selected = _tags
        .where((t) => _f.tags.contains(t.id))
        .toList()
      ..sort(byName);
    final rest = _tags
        .where((t) => !_f.tags.contains(t.id))
        .where((t) => q.isEmpty || t.name.toLowerCase().contains(q))
        .toList()
      ..sort(byName);
    final shown = rest.take(_tagVisible).toList();
    final left = rest.length - shown.length;

    return ExpansionTile(
      title: Text(tr('标签')),
      subtitle: selected.isEmpty
          ? null
          : Text(tr('已选 {count} 项', {'count': selected.length}),
              style: TextStyle(color: theme.colorScheme.primary)),
      children: [
        _searchField('标签'),
        if (_loading)
          _loadingRow()
        else ...[
          if (selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final t in selected)
                      InputChip(
                        label: Text(t.name),
                        onDeleted: () => setState(() => _f.tags.remove(t.id)),
                        deleteIcon: const Icon(Icons.close, size: 16),
                      ),
                  ],
                ),
              ),
            ),
          if (rest.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(tr('（无）')),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final t in shown)
                      FilterChip(
                        label: Text(t.name),
                        selected: false,
                        onSelected: (_) => setState(() => _f.tags.add(t.id)),
                      ),
                  ],
                ),
              ),
            ),
          if (left > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _tagVisible += 100),
                  child:
                      Text(tr('显示更多（剩余 {count} 项）', {'count': left})),
                ),
              ),
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title:  Text(tr('筛选')),
        actions: [
          TextButton(
            onPressed: () => setState(() => _f
              ..studios.clear()
              ..tags.clear()
              ..performers.clear()
              ..rating100 = 0
              ..oCounter = 0
              ..durationSeconds = 0
              ..resolution = 0
              ..dateFrom = ''
              ..dateTo = ''
              ..organized = false
              ..coversOnly = false),
            child:  Text(tr('重置')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _f),
            child:  Text(tr('应用')),
          ),
          const SizedBox(width: 8),
        ],
        bottom: _loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (_error != null) _errorBar(),
                _multiSelect<Studio>(
                  title: tr('工作室'),
                  items: _studios,
                  selected: _f.studios,
                  label: (s) => s.name,
                  id: (s) => s.id,
                ),
                _multiSelect<Performer>(
                  title: tr('演员'),
                  items: _performers,
                  selected: _f.performers,
                  label: (p) => p.name,
                  id: (p) => p.id,
                ),
                _tagSelect(),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr('评分 ≥'), style: theme.textTheme.titleSmall),
                      Row(
                        children: [
                          for (var i = 1; i <= 10; i++)
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              iconSize: 20,
                              icon: Icon(
                                _f.rating100 >= i * 10
                                    ? Icons.star
                                    : Icons.star_border,
                                color: const Color(0xFFFF9F0A),
                              ),
                              onPressed: () => setState(() {
                                _f.rating100 =
                                    _f.rating100 == i * 10 ? 0 : i * 10;
                              }),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(tr('O 计数 ≥'), style: theme.textTheme.titleSmall),
                      Row(
                        children: [
                          for (var i = 0; i <= 5; i++)
                            ChoiceChip(
                              label: Text(i == 0 ? tr('不限') : '$i'),
                              selected: _f.oCounter == i,
                              onSelected: (_) =>
                                  setState(() => _f.oCounter = i),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(tr('时长 ≥（分钟）'), style: theme.textTheme.titleSmall),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final (v, label) in [
                            (0, tr('不限')),
                            (10, '10'),
                            (30, '30'),
                            (60, '60'),
                            (120, '120'),
                          ])
                            ChoiceChip(
                              label: Text(label),
                              selected: _f.durationSeconds == v * 60,
                              onSelected: (_) => setState(
                                  () => _f.durationSeconds = v * 60),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(tr('分辨率 ≥'), style: theme.textTheme.titleSmall),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final (v, label) in [
                            (0, tr('不限')),
                            (720, '720p'),
                            (1080, '1080p'),
                            (2160, '4K'),
                          ])
                            ChoiceChip(
                              label: Text(label),
                              selected: _f.resolution == v,
                              onSelected: (_) =>
                                  setState(() => _f.resolution = v),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(tr('日期范围'), style: theme.textTheme.titleSmall),
                      const SizedBox(height: 4),
                      OutlinedButton.icon(
                        onPressed: _pickDate,
                        icon: const Icon(Icons.date_range, size: 18),
                        label: Text(_f.dateFrom.isEmpty && _f.dateTo.isEmpty
                            ? tr('不限')
                            : '${_f.dateFrom.isNotEmpty ? _f.dateFrom : '…'} ~ '
                                '${_f.dateTo.isNotEmpty ? _f.dateTo : '…'}'),
                      ),
                      const SizedBox(height: 12),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title:  Text(tr('仅看已收藏')),
                        value: _f.organized,
                        onChanged: (v) => setState(() => _f.organized = v),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title:  Text(tr('仅看有封面')),
                        value: _f.coversOnly,
                        onChanged: (v) => setState(() => _f.coversOnly = v),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  /// 拉取失败时面板顶部的提示条，可直接重试，不挡住其余筛选条件。
  Widget _errorBar() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tr('加载筛选选项失败：{error}', {'error': _error}),
              style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
            ),
          ),
          TextButton(onPressed: () => _load(), child: Text(tr('重试'))),
        ],
      ),
    );
  }
}
