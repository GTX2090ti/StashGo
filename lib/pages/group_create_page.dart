import 'package:flutter/material.dart';

import '../api/stash_api.dart';
import '../models/models.dart';
import '../widgets/common.dart';
import '../widgets/zh_toolbar.dart';
import '../l10n/l10n.dart';

/// 新建集合页；成功后 pop 新集合 id。
class GroupCreatePage extends StatefulWidget {
  const GroupCreatePage({super.key});

  @override
  State<GroupCreatePage> createState() => _GroupCreatePageState();
}

class _GroupCreatePageState extends State<GroupCreatePage> {
  final _nameCtrl = TextEditingController();
  final _dateCtrl = TextEditingController();
  final _aliasCtrl = TextEditingController();
  final _directorCtrl = TextEditingController();
  final _urlsCtrl = TextEditingController();
  final _synopsisCtrl = TextEditingController();

  int _rating = 0;
  String _studioId = '';
  Set<String> _tagIds = {};
  List<Studio> _studios = [];
  List<Tag> _tags = [];

  bool _loading = true;
  bool _saving = false;
  String _error = '';

  StashApi get _api => buildApi();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _dateCtrl.dispose();
    _aliasCtrl.dispose();
    _directorCtrl.dispose();
    _urlsCtrl.dispose();
    _synopsisCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([_api.allStudios(), _api.allTags()]);
      _studios = results[0] as List<Studio>;
      _tags = results[1] as List<Tag>;
    } catch (e) {
      _error = tr('加载失败：{error}', {'error': e});
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = tr('集合名称不能为空'));
      return;
    }
    setState(() {
      _saving = true;
      _error = '';
    });
    final extra = <String, dynamic>{};
    final date = _dateCtrl.text.trim();
    if (date.isNotEmpty) extra['date'] = date;
    final alias = _aliasCtrl.text.trim();
    if (alias.isNotEmpty) extra['aliases'] = alias;
    final director = _directorCtrl.text.trim();
    if (director.isNotEmpty) extra['director'] = director;
    final synopsis = _synopsisCtrl.text.trim();
    if (synopsis.isNotEmpty) extra['synopsis'] = synopsis;
    final urls = _urlsCtrl.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (urls.isNotEmpty) extra['urls'] = urls;
    if (_rating > 0) extra['rating100'] = _rating;
    if (_studioId.isNotEmpty) extra['studio_id'] = _studioId;
    if (_tagIds.isNotEmpty) extra['tag_ids'] = _tagIds.toList();
    try {
      final g = await _api.createGroup(name, extra);
      if (!mounted) return;
      Navigator.pop(context, g.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = tr('创建失败：{error}', {'error': e}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _studioLabel() {
    for (final s in _studios) {
      if (s.id == _studioId) return s.name;
    }
    return tr('选择工作室');
  }

  Widget _text(
    TextEditingController c,
    String label, {
    String hint = '',
    int maxLines = 1,
  }) {
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
    return Scaffold(
      appBar: AppBar(title: Text(tr('添加集合'))),
      body: _loading
          ? StatusView(loading: true, empty: '', onRetry: _load)
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                SectionTitle(tr('基本信息')),
                TextField(
                  controller: _nameCtrl,
                  contextMenuBuilder: zhContextMenuBuilder,
                  decoration: InputDecoration(labelText: tr('名称（必填）')),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _dateCtrl,
                  contextMenuBuilder: zhContextMenuBuilder,
                  inputFormatters: const [DateDashInputFormatter()],
                  decoration: InputDecoration(labelText: tr('日期（yyyy-MM-dd）')),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(tr('评分')),
                    const Spacer(),
                    Text(
                      _rating > 0
                          ? '${(_rating / 20).toStringAsFixed(1)} / 5.0'
                          : tr('未评分'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                Slider(
                  value: _rating.toDouble(),
                  max: 100,
                  divisions: 20,
                  label: _rating == 0
                      ? tr('未评分')
                      : (_rating / 20).toStringAsFixed(1),
                  onChanged: (v) => setState(() => _rating = v.round()),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final r = await showSingleSelectSheet(
                      context,
                      title: tr('选择工作室'),
                      options: [for (final s in _studios) (s.id, s.name)],
                      selectedId: _studioId.isEmpty ? null : _studioId,
                    );
                    if (r != null) setState(() => _studioId = r);
                  },
                  icon: const Icon(Icons.theater_comedy_outlined, size: 16),
                  label: Text(_studioLabel()),
                ),

                SectionTitle(tr('标签（{count}）', {'count': _tagIds.length})),
                if (_tagIds.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final t in _tags)
                        if (_tagIds.contains(t.id))
                          InputChip(
                            label: Text(
                              t.name,
                              style: const TextStyle(fontSize: 12),
                            ),
                            visualDensity: VisualDensity.compact,
                            onDeleted: () =>
                                setState(() => _tagIds.remove(t.id)),
                          ),
                    ],
                  ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final r = await showMultiSelectSheet(
                      context,
                      title: tr('选择标签'),
                      options: [for (final t in _tags) (t.id, t.name)],
                      selected: _tagIds,
                    );
                    if (r != null) setState(() => _tagIds = r);
                  },
                  icon: const Icon(Icons.sell_outlined, size: 16),
                  label: Text(tr('选择标签')),
                ),

                SectionTitle(tr('其他信息')),
                _text(_aliasCtrl, tr('别名')),
                _text(_directorCtrl, tr('导演')),
                _text(_urlsCtrl, tr('网址'), hint: tr('每行一个 URL'), maxLines: 3),
                _text(_synopsisCtrl, tr('简介'), hint: tr('简介…'), maxLines: 5),

                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFFE5533D),
                    ),
                  ),
                ],
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            height: 46,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? tr('保存中…') : tr('创建')),
            ),
          ),
        ),
      ),
    );
  }
}
