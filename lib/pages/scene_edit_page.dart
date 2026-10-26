import 'package:flutter/material.dart';

import '../api/stash_api.dart';
import '../api/filter_options_cache.dart';
import '../models/models.dart';
import '../widgets/common.dart';
import '../widgets/zh_toolbar.dart';
import 'performer_create_page.dart';
import '../l10n/l10n.dart';

/// 短片编辑页：标题 / 日期 / 评分 / 工作室 / 演员 / 标签 / URL / 简介。
class SceneEditPage extends StatefulWidget {
  const SceneEditPage({super.key, required this.sceneId});

  final String sceneId;

  @override
  State<SceneEditPage> createState() => _SceneEditPageState();
}

class _SceneEditPageState extends State<SceneEditPage> {
  final _titleCtrl = TextEditingController();
  final _detailsCtrl = TextEditingController();
  final _dateCtrl = TextEditingController();
  final _urlsCtrl = TextEditingController();

  int _rating = 0;
  String _studioId = '';
  Set<String> _performerIds = {};
  Set<String> _tagIds = {};
  Set<String> _groupIds = {};

  /// 原有集合的 scene_index，写回时保留集合内顺序。
  Map<String, int?> _groupIndex = {};
  List<Group> _groups = [];
  bool _groupsLoaded = false;

  List<Studio> _studios = [];
  List<Performer> _performers = [];
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
    _titleCtrl.dispose();
    _detailsCtrl.dispose();
    _dateCtrl.dispose();
    _urlsCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final s = await _api.findScene(widget.sceneId);
      if (s != null) {
        _titleCtrl.text = s.title;
        _detailsCtrl.text = s.details;
        _dateCtrl.text = s.date;
        _urlsCtrl.text = s.urls.join('\n');
        _rating = s.rating100;
        _studioId = s.studio?.id ?? '';
        _performerIds = s.performers.map((e) => e.id).toSet();
        _tagIds = s.tags.map((e) => e.id).toSet();
      }
      final opts = await FilterOptionsCache.load(_api);
      _studios = opts.studios;
      _performers = opts.performers;
      _tags = opts.tags;
      _groups = (await _api.findGroups(perPage: 500)).items;
      final members = await _api.sceneGroups([widget.sceneId]);
      final cur = members[widget.sceneId];
      if (cur != null) {
        _groupIndex = cur;
        _groupIds = cur.keys.toSet();
        _groupsLoaded = true;
      }
    } catch (e) {
      _error = tr('加载失败：{error}', {'error': e});
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openCreatePerformer() async {
    final created = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const PerformerCreatePage()),
    );
    if (created == null || !mounted) return;
    // 重新拉全量并勾选新演员（新建后缓存必须失效，否则拿不到刚建的人）
    try {
      final opts = await FilterOptionsCache.reload(_api);
      if (!mounted) return;
      setState(() {
        _performers = opts.performers;
        _performerIds.add(created);
      });
    } catch (_) {
      if (mounted) setState(() => _performerIds.add(created));
    }
  }

  /// 新建工作室：先查同名（Stash 0.31.1 不允许重名）→ 存在则直接选中，否则创建。
  Future<void> _createStudio() async {
    final name = await _askName(tr('新建工作室'), tr('工作室名称'));
    if (name == null || name.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final existing = await _api.findStudiosByName(name);
      if (existing.isNotEmpty) {
        final s = existing.first;
        if (!mounted) return;
        setState(() {
          if (!_studios.any((e) => e.id == s.id)) {
            _studios = [..._studios, s];
          }
          _studioId = s.id;
        });
        messenger.showSnackBar(
          SnackBar(content: Text(tr('工作室已存在，已选中：{name}', {'name': s.name}))),
        );
        return;
      }
      final id = await _api.createStudio(name);
      if (!mounted) return;
      FilterOptionsCache.invalidate();
      setState(() {
        _studios = [..._studios, Studio(id: id, name: name)];
        _studioId = id;
      });
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(tr('创建失败：{error}', {'error': e}))),
        );
      }
    }
  }

  /// 新建标签：先查同名（Stash 0.31.1 不允许重名）→ 存在则直接选中，否则创建。
  Future<void> _createTag() async {
    final name = await _askName(tr('新建标签'), tr('标签名称'));
    if (name == null || name.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final existing = await _api.findTagsByName(name);
      if (existing.isNotEmpty) {
        final t = existing.first;
        if (!mounted) return;
        setState(() {
          if (!_tags.any((e) => e.id == t.id)) {
            _tags = [..._tags, t];
          }
          _tagIds.add(t.id);
        });
        messenger.showSnackBar(
          SnackBar(content: Text(tr('标签已存在，已选中：{name}', {'name': t.name}))),
        );
        return;
      }
      final id = await _api.createTag(name);
      if (!mounted) return;
      FilterOptionsCache.invalidate();
      setState(() {
        _tags = [..._tags, Tag(id: id, name: name)];
        _tagIds.add(id);
      });
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(tr('创建失败：{error}', {'error': e}))),
        );
      }
    }
  }

  Future<void> _openGroupPicker() async {
    final r = await showMultiSelectSheet(
      context,
      title: tr('选择集合'),
      options: [for (final g in _groups) (g.id, g.name)],
      selected: _groupIds,
    );
    if (r != null) setState(() => _groupIds = r);
  }

  /// 新建集合并直接勾选；集合成员关系仍由保存短片时写入。
  Future<void> _createGroup() async {
    final name = await _askName(tr('新建集合'), tr('集合名称'));
    if (name == null || name.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final g = await _api.createGroup(name);
      if (!mounted) return;
      setState(() {
        if (!_groups.any((e) => e.id == g.id)) {
          _groups = [..._groups, g];
        }
        _groupIds.add(g.id);
      });
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(tr('创建失败：{error}', {'error': e}))),
        );
      }
    }
  }

  /// 弹出名称输入框，返回输入内容（取消返回 null）。
  Future<String?> _askName(String title, String label) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          contextMenuBuilder: zhContextMenuBuilder,
          decoration: InputDecoration(labelText: label, isDense: true),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('创建')),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = '';
    });
    final input = <String, dynamic>{'id': widget.sceneId};
    if (_titleCtrl.text.trim().isNotEmpty) {
      input['title'] = _titleCtrl.text.trim();
    }
    if (_detailsCtrl.text.trim().isNotEmpty) {
      input['details'] = _detailsCtrl.text.trim();
    }
    if (_dateCtrl.text.trim().isNotEmpty) input['date'] = _dateCtrl.text.trim();
    if (_rating > 0) input['rating100'] = _rating;
    if (_studioId.isNotEmpty) input['studio_id'] = _studioId;
    input['performer_ids'] = _performerIds.toList();
    if (_tagIds.isNotEmpty) input['tag_ids'] = _tagIds.toList();
    // 读不到原有集合时不能写，否则会把已有成员关系整组覆盖掉。
    if (_groupsLoaded) {
      input['groups'] = [
        for (final id in _groupIds)
          {
            'group_id': id,
            if (_groupIndex[id] != null) 'scene_index': _groupIndex[id],
          },
      ];
    }
    final urls = _urlsCtrl.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (urls.isNotEmpty) input['urls'] = urls;
    try {
      await _api.updateScene(input);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = tr('保存失败：{error}', {'error': e}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 当前选中工作室的显示名（无选中时显示占位）。
  String _studioLabel() {
    for (final s in _studios) {
      if (s.id == _studioId) return s.name;
    }
    return tr('选择工作室');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('编辑短片'))),
      body: _loading
          ? StatusView(loading: true, empty: '', onRetry: _load)
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                SectionTitle(tr('基本信息')),
                TextField(
                  controller: _titleCtrl,
                  contextMenuBuilder: zhContextMenuBuilder,
                  decoration: InputDecoration(labelText: tr('标题')),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _dateCtrl,
                  contextMenuBuilder: zhContextMenuBuilder,
                  inputFormatters: const [DateDashInputFormatter()],
                  decoration: InputDecoration(labelText: tr('日期（yyyy-MM-dd）')),
                ),
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

                SectionTitle(tr('工作室')),
                if (_studios.isEmpty)
                  Text(tr('未加载到工作室'), style: theme.textTheme.bodySmall),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final r = await showSingleSelectSheet(
                            context,
                            title: tr('选择工作室'),
                            options: [for (final s in _studios) (s.id, s.name)],
                            selectedId: _studioId.isEmpty ? null : _studioId,
                          );
                          if (r != null) setState(() => _studioId = r);
                        },
                        icon: const Icon(
                          Icons.theater_comedy_outlined,
                          size: 16,
                        ),
                        label: Text(_studioLabel()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _createStudio,
                      icon: const Icon(Icons.add_business_outlined, size: 16),
                      label: Text(tr('新建')),
                    ),
                  ],
                ),

                SectionTitle(
                  tr('演员（{count}）', {'count': _performerIds.length}),
                ),
                if (_performers.isEmpty)
                  Text(tr('未加载到演员'), style: theme.textTheme.bodySmall),
                if (_performers.isNotEmpty && _performerIds.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final p in _performers)
                        if (_performerIds.contains(p.id))
                          InputChip(
                            label: Text(
                              p.name,
                              style: const TextStyle(fontSize: 12),
                            ),
                            visualDensity: VisualDensity.compact,
                            onDeleted: () =>
                                setState(() => _performerIds.remove(p.id)),
                          ),
                    ],
                  ),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final r = await showMultiSelectSheet(
                            context,
                            title: tr('选择演员'),
                            options: [
                              for (final p in _performers) (p.id, p.name),
                            ],
                            selected: _performerIds,
                          );
                          if (r != null) setState(() => _performerIds = r);
                        },
                        icon: const Icon(Icons.people_outline, size: 16),
                        label: Text(tr('选择演员')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _openCreatePerformer,
                      icon: const Icon(Icons.person_add_alt, size: 16),
                      label: Text(tr('新建')),
                    ),
                  ],
                ),

                SectionTitle(tr('URL（每行一个）')),
                TextField(
                  controller: _urlsCtrl,
                  maxLines: 3,
                  contextMenuBuilder: zhContextMenuBuilder,
                  decoration: const InputDecoration(hintText: 'https://…'),
                ),

                SectionTitle(tr('标签（{count}）', {'count': _tagIds.length})),
                if (_tags.isNotEmpty && _tagIds.isNotEmpty)
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
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
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
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _createTag,
                      icon: const Icon(Icons.add_box_outlined, size: 16),
                      label: Text(tr('新建')),
                    ),
                  ],
                ),

                SectionTitle(tr('集合（{count}）', {'count': _groupIds.length})),
                if (!_groupsLoaded)
                  Text(
                    tr('集合信息未加载，本次保存不会修改集合'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  )
                else ...[
                  if (_groupIds.isNotEmpty)
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final g in _groups)
                          if (_groupIds.contains(g.id))
                            InputChip(
                              label: Text(
                                g.name,
                                style: const TextStyle(fontSize: 12),
                              ),
                              visualDensity: VisualDensity.compact,
                              onDeleted: () =>
                                  setState(() => _groupIds.remove(g.id)),
                            ),
                      ],
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _openGroupPicker,
                          icon: const Icon(
                            Icons.collections_bookmark_outlined,
                            size: 16,
                          ),
                          label: Text(tr('选择集合')),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _createGroup,
                        icon: const Icon(Icons.add_box_outlined, size: 16),
                        label: Text(tr('新建')),
                      ),
                    ],
                  ),
                ],

                SectionTitle(tr('简介')),
                TextField(
                  controller: _detailsCtrl,
                  maxLines: 5,
                  contextMenuBuilder: zhContextMenuBuilder,
                  decoration: InputDecoration(hintText: tr('简介…')),
                ),

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
              child: Text(_saving ? tr('保存中…') : tr('保存')),
            ),
          ),
        ),
      ),
    );
  }
}
