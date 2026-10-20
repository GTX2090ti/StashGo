import 'package:flutter/material.dart';

import '../api/stash_api.dart';
import '../models/models.dart';
import '../widgets/common.dart';
import '../widgets/zh_toolbar.dart';

/// 提交回调：由页面决定调用 create 还是 update，并在成功后返回。
typedef StudioSubmit = Future<void> Function(
    BuildContext context, Map<String, dynamic> input);

/// 工作室表单（添加 / 编辑共用）。
/// 字段对齐 Stash 0.31 的 StudioCreateInput / StudioUpdateInput；
/// 编辑态只提交有变化的字段（改成空值即为清除）。
class StudioForm extends StatefulWidget {
  const StudioForm({
    super.key,
    this.studioId = '',
    required this.title,
    required this.submitLabel,
    required this.onSubmit,
  });

  /// 为空表示新建。
  final String studioId;
  final String title;
  final String submitLabel;
  final StudioSubmit onSubmit;

  @override
  State<StudioForm> createState() => _StudioFormState();
}

class _StudioFormState extends State<StudioForm> {
  final _nameCtrl = TextEditingController();
  final _aliasCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _detailsCtrl = TextEditingController();

  String _parentId = '';
  int _rating = 0;
  bool _favorite = false;
  bool _ignoreAutoTag = false;
  Set<String> _tagIds = {};

  List<Studio> _studios = [];
  List<Tag> _tags = [];
  Studio? _loaded;

  /// 进入页面时的原始值，用于「只提交变更」与「空值即清除」。
  Map<String, dynamic> _orig = const {};

  bool _loading = true;
  bool _saving = false;
  String _error = '';

  bool get _isNew => widget.studioId.isEmpty;

  StashApi get _api => buildApi();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _aliasCtrl.dispose();
    _urlCtrl.dispose();
    _detailsCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      if (!_isNew) {
        final s = await _api.findStudio(widget.studioId);
        if (s != null) {
          _loaded = s;
          _nameCtrl.text = s.name;
          _aliasCtrl.text = s.aliases.join('\n');
          _urlCtrl.text = s.urls.join('\n');
          _detailsCtrl.text = s.details;
          _parentId = s.parentId;
          _rating = s.rating100;
          _favorite = s.favorite;
          _ignoreAutoTag = s.ignoreAutoTag;
          _tagIds = s.tags.map((e) => e.id).toSet();
          _orig = _snapshot();
        } else {
          _error = '加载失败';
        }
      }
      final results = await Future.wait([_api.allStudios(), _api.allTags()]);
      _studios = results[0] as List<Studio>;
      _tags = results[1] as List<Tag>;
    } catch (e) {
      _error = '加载失败：$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  static List<String> _lines(String raw) => raw
      .split(RegExp(r'[,、\n]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  Map<String, dynamic> _snapshot() => {
        'name': _nameCtrl.text.trim(),
        'aliases': _lines(_aliasCtrl.text),
        'urls': _lines(_urlCtrl.text),
        'details': _detailsCtrl.text.trim(),
        'parent_id': _parentId,
        'rating100': _rating,
        'favorite': _favorite,
        'ignore_auto_tag': _ignoreAutoTag,
        'tag_ids': (_tagIds.toList()..sort()),
      };

  /// 新建：跳过未填写的默认值；编辑：只提交与原始值不同的字段（含清空）。
  Map<String, dynamic> _changedInput() {
    final cur = _snapshot();
    final input = <String, dynamic>{};
    if (!_isNew) input['id'] = widget.studioId;
    for (final e in cur.entries) {
      final v = e.value;
      if (e.key == 'parent_id') continue;
      if (_isNew) {
        final empty = v is String
            ? v.isEmpty
            : v is num
                ? v == 0
                : v is bool
                    ? !v
                    : (v as List).isEmpty;
        if (empty) continue;
      } else if (_same(v, _orig[e.key])) {
        continue;
      }
      input[e.key] = v;
    }
    // 清空上级工作室要用 null，空字符串会被服务端当成非法 ID。
    if (_isNew) {
      if (_parentId.isNotEmpty) input['parent_id'] = _parentId;
    } else if (_parentId != (_orig['parent_id'] ?? '')) {
      input['parent_id'] = _parentId.isEmpty ? null : _parentId;
    }
    return input;
  }

  static bool _same(dynamic a, dynamic b) {
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }
    return a == b;
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '工作室名称不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      final input = _changedInput();
      if (!_isNew && input.length <= 1) {
        showToast(context, '未做修改');
        Navigator.pop(context, false);
        return;
      }
      await widget.onSubmit(context, input);
    } catch (e) {
      if (mounted) setState(() => _error = '保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _text(TextEditingController c, String label,
      {String hint = '', int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        contextMenuBuilder: zhContextMenuBuilder,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint.isEmpty ? null : hint,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _loaded;
    // 编辑态：上级候选排除自己和自己的直接子工作室，避免成环。
    final childIds = {for (final c in s?.childStudios ?? const <Studio>[]) c.id};
    final parents = [
      for (final e in _studios)
        if (e.id != widget.studioId && !childIds.contains(e.id)) e
    ];
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? StatusView(loading: true, empty: '', onRetry: _load)
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                FoldSection(
                  title: '基本信息',
                  open: true,
                  children: [
                    _text(_nameCtrl, _isNew ? '名称（必填）' : '名称'),
                    _text(_aliasCtrl, '别名', hint: '每行一个', maxLines: 4),
                    _picker(parents),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _favorite,
                      title: const Text('收藏'),
                      onChanged: (v) => setState(() => _favorite = v),
                    ),
                    Row(children: [
                      const Text('评分'),
                      const Spacer(),
                      Text(
                        _rating > 0
                            ? '${(_rating / 20).toStringAsFixed(1)} / 5.0'
                            : '未评分',
                        style: theme.textTheme.bodySmall,
                      ),
                    ]),
                    Slider(
                      value: _rating.toDouble(),
                      max: 100,
                      divisions: 20,
                      label: _rating == 0
                          ? '未评分'
                          : (_rating / 20).toStringAsFixed(1),
                      onChanged: (v) => setState(() => _rating = v.round()),
                    ),
                  ],
                ),

                FoldSection(
                  title: '链接',
                  summary: _lines(_urlCtrl.text).isEmpty
                      ? '空'
                      : '${_lines(_urlCtrl.text).length} 个',
                  children: [
                    _text(_urlCtrl, '网址', hint: '每行一个 URL', maxLines: 4),
                  ],
                ),

                FoldSection(
                  title: '标签',
                  summary: _tagIds.isEmpty ? '空' : '${_tagIds.length} 个',
                  open: _tagIds.isNotEmpty,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final r = await showMultiSelectSheet(
                          context,
                          title: '选择标签',
                          options: [for (final t in _tags) (t.id, t.name)],
                          selected: _tagIds,
                        );
                        if (r != null) setState(() => _tagIds = r);
                      },
                      icon: const Icon(Icons.sell_outlined, size: 16),
                      label: Text('选择标签（${_tagIds.length}）'),
                    ),
                    if (_tagIds.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text('点击标签可移除',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final t in _tags)
                            if (_tagIds.contains(t.id))
                              TapChip(
                                  label: t.name,
                                  onTap: () =>
                                      setState(() => _tagIds.remove(t.id))),
                        ],
                      ),
                    ],
                  ],
                ),

                FoldSection(
                  title: '简介与其他',
                  summary: _detailsCtrl.text.trim().isEmpty ? '空' : '已填写',
                  children: [
                    _text(_detailsCtrl, '简介', hint: '工作室介绍…', maxLines: 6),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _ignoreAutoTag,
                      title: const Text('忽略自动打标'),
                      subtitle: const Text('自动打标任务跳过该工作室'),
                      onChanged: (v) => setState(() => _ignoreAutoTag = v),
                    ),
                  ],
                ),

                if (s != null)
                  FoldSection(
                    title: '服务端统计',
                    summary: '短片 ${s.sceneCount}',
                    children: [
                      InfoRow('短片', '${s.sceneCount}'),
                      InfoRow('图片', '${s.imageCount}'),
                      InfoRow('演员', '${s.performerCount}'),
                      InfoRow('子工作室', '${s.childStudios.length}'),
                      if (s.createdAt.isNotEmpty)
                        InfoRow('创建时间', _fmtTime(s.createdAt)),
                      if (s.updatedAt.isNotEmpty)
                        InfoRow('更新时间', _fmtTime(s.updatedAt)),
                    ],
                  ),

                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(_error,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: const Color(0xFFE5533D))),
                ],
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            height: 46,
            child: FilledButton(
              onPressed: _saving ? null : _submit,
              child: Text(_saving ? '保存中…' : widget.submitLabel),
            ),
          ),
        ),
      ),
    );
  }

  Widget _picker(List<Studio> parents) {
    final known = parents.any((e) => e.id == _parentId);
    // 上级不在候选里（如列表未加载成功）时补一项，避免 DropdownButton 断言失败。
    final orphan = _parentId.isNotEmpty && !known;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonHideUnderline(
        child: InputDecorator(
          decoration: const InputDecoration(labelText: '上级工作室'),
          child: DropdownButton<String>(
            value: _parentId.isEmpty ? '' : _parentId,
            isExpanded: true,
            items: [
              const DropdownMenuItem(value: '', child: Text('无')),
              if (orphan)
                DropdownMenuItem(
                  value: _parentId,
                  child: Text(
                    (_loaded?.parentName ?? '').isEmpty
                        ? _parentId
                        : _loaded!.parentName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              for (final e in parents)
                DropdownMenuItem(
                  value: e.id,
                  child: Text(e.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() => _parentId = v ?? ''),
          ),
        ),
      ),
    );
  }

  static String _fmtTime(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    final l = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}
