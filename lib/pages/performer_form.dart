import 'package:flutter/material.dart';

import '../api/stash_api.dart';
import '../models/models.dart';
import '../widgets/common.dart';
import '../widgets/zh_toolbar.dart';

/// 提交回调：由页面决定调用 create 还是 update，并在成功后返回。
typedef PerformerSubmit = Future<void> Function(
    BuildContext context, Map<String, dynamic> input);

/// 演员表单（添加 / 编辑共用）。
/// 字段对齐 Stash 0.31.1 的 PerformerCreateInput / PerformerUpdateInput，
/// 按分组折叠；编辑态只提交有变化的字段（改成空值即为清除）。
class PerformerForm extends StatefulWidget {
  const PerformerForm({
    super.key,
    this.performerId = '',
    required this.title,
    required this.submitLabel,
    required this.onSubmit,
  });

  /// 为空表示新建。
  final String performerId;
  final String title;
  final String submitLabel;
  final PerformerSubmit onSubmit;

  @override
  State<PerformerForm> createState() => _PerformerFormState();
}

class _PerformerFormState extends State<PerformerForm> {
  final _nameCtrl = TextEditingController();
  final _disambigCtrl = TextEditingController();
  final _aliasCtrl = TextEditingController();
  final _birthCtrl = TextEditingController();
  final _deathCtrl = TextEditingController();
  final _countryCtrl = TextEditingController();
  final _ethnicityCtrl = TextEditingController();
  final _heightCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();
  final _measureCtrl = TextEditingController();
  final _fakeTitsCtrl = TextEditingController();
  final _penisCtrl = TextEditingController();
  final _eyeCtrl = TextEditingController();
  final _hairCtrl = TextEditingController();
  final _careerStartCtrl = TextEditingController();
  final _careerEndCtrl = TextEditingController();
  final _tattooCtrl = TextEditingController();
  final _piercingCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _detailsCtrl = TextEditingController();

  String _gender = '';
  String _circumcisedValue = '';
  int _rating = 0;
  bool _favorite = false;
  bool _ignoreAutoTag = false;
  Set<String> _tagIds = {};
  List<Tag> _tags = [];
  Performer? _loaded;

  /// 进入页面时的原始值，用于「只提交变更」与「空值即清除」。
  Map<String, dynamic> _orig = const {};

  bool _loading = true;
  bool _saving = false;
  String _error = '';

  bool get _isNew => widget.performerId.isEmpty;

  StashApi get _api => buildApi();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _nameCtrl,
      _disambigCtrl,
      _aliasCtrl,
      _birthCtrl,
      _deathCtrl,
      _countryCtrl,
      _ethnicityCtrl,
      _heightCtrl,
      _weightCtrl,
      _measureCtrl,
      _fakeTitsCtrl,
      _penisCtrl,
      _eyeCtrl,
      _hairCtrl,
      _careerStartCtrl,
      _careerEndCtrl,
      _tattooCtrl,
      _piercingCtrl,
      _urlCtrl,
      _detailsCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      if (!_isNew) {
        final p = await _api.findPerformer(widget.performerId);
        if (p != null) {
          _loaded = p;
          _nameCtrl.text = p.name;
          _disambigCtrl.text = p.disambiguation;
          _aliasCtrl.text = p.aliasParts.join('\n');
          _birthCtrl.text = p.birthdate;
          _deathCtrl.text = p.deathDate;
          _countryCtrl.text = p.country;
          _ethnicityCtrl.text = p.ethnicity;
          _heightCtrl.text = p.heightCm > 0 ? '${p.heightCm}' : '';
          _weightCtrl.text = p.weight > 0 ? '${p.weight}' : '';
          _measureCtrl.text = p.measurements;
          _fakeTitsCtrl.text = p.fakeTits;
          _penisCtrl.text = p.penisLength > 0
              ? p.penisLength.toStringAsFixed(1)
              : '';
          _eyeCtrl.text = p.eyeColor;
          _hairCtrl.text = p.hairColor;
          _careerStartCtrl.text = p.careerStart;
          _careerEndCtrl.text = p.careerEnd;
          _tattooCtrl.text = p.tattoos;
          _piercingCtrl.text = p.piercings;
          _urlCtrl.text = p.urls.join('\n');
          _detailsCtrl.text = p.details;
          _gender = p.gender;
          _circumcisedValue = p.circumcised;
          _rating = p.rating100;
          _favorite = p.favorite;
          _ignoreAutoTag = p.ignoreAutoTag;
          _tagIds = p.tags.map((e) => e.id).toSet();
          _orig = _snapshot();
        }
      }
      _tags = await _api.allTags();
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
        'disambiguation': _disambigCtrl.text.trim(),
        'alias_list': _lines(_aliasCtrl.text),
        'gender': _gender,
        'birthdate': _birthCtrl.text.trim(),
        'death_date': _deathCtrl.text.trim(),
        'country': _countryCtrl.text.trim(),
        'ethnicity': _ethnicityCtrl.text.trim(),
        'height_cm': int.tryParse(_heightCtrl.text.trim()) ?? 0,
        'weight': int.tryParse(_weightCtrl.text.trim()) ?? 0,
        'measurements': _measureCtrl.text.trim(),
        'fake_tits': _fakeTitsCtrl.text.trim(),
        'penis_length': double.tryParse(_penisCtrl.text.trim()) ?? 0,
        'circumcised': _circumcisedValue,
        'eye_color': _eyeCtrl.text.trim(),
        'hair_color': _hairCtrl.text.trim(),
        'career_start': _careerStartCtrl.text.trim(),
        'career_end': _careerEndCtrl.text.trim(),
        'tattoos': _tattooCtrl.text.trim(),
        'piercings': _piercingCtrl.text.trim(),
        'urls': _lines(_urlCtrl.text),
        'details': _detailsCtrl.text.trim(),
        'favorite': _favorite,
        'ignore_auto_tag': _ignoreAutoTag,
        'tag_ids': (_tagIds.toList()..sort()),
        'rating100': _rating,
      };

  /// 新建：跳过未填写的默认值；编辑：只提交与原始值不同的字段（含清空）。
  Map<String, dynamic> _changedInput() {
    final cur = _snapshot();
    final input = <String, dynamic>{};
    if (!_isNew) input['id'] = widget.performerId;
    for (final e in cur.entries) {
      final v = e.value;
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
      setState(() => _error = '演员名称不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      await widget.onSubmit(context, _changedInput());
    } catch (e) {
      if (mounted) setState(() => _error = '保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 折叠标题上的摘要：统计该组已填写的字段数。
  String _countSummary(Iterable<String> keys) {
    final cur = _snapshot();
    var n = 0;
    for (final k in keys) {
      final v = cur[k];
      final filled = v is String
          ? v.isNotEmpty
          : v is num
              ? v != 0
              : v is bool
                  ? v
                  : (v as List).isNotEmpty;
      if (filled) n++;
    }
    return n == 0 ? '空' : '$n 项';
  }

  Widget _text(TextEditingController c, String label,
      {String hint = '',
      String? unit,
      TextInputType? type,
      int maxLines = 1,
      bool date = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        keyboardType: type,
        inputFormatters: date ? const [DateDashInputFormatter()] : null,
        contextMenuBuilder: zhContextMenuBuilder,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint.isEmpty ? null : hint,
          suffixText: unit,
        ),
      ),
    );
  }

  Widget _picker(String label, String value, List<(String, String)> options,
      String clearLabel, ValueChanged<String?> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonHideUnderline(
        child: InputDecorator(
          decoration: InputDecoration(labelText: label),
          child: DropdownButton<String>(
            value: options.any((e) => e.$1 == value) ? value : null,
            isExpanded: true,
            hint: Text(clearLabel),
            items: [
              for (final (v, l) in options)
                DropdownMenuItem(value: v, child: Text(l)),
            ],
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _loaded;
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
                    _text(_disambigCtrl, '区别名',
                        hint: '同名演员的补充说明'),
                    _text(_aliasCtrl, '别名',
                        hint: '每行一个', maxLines: 4),
                    _picker('性别', _gender, kGenderOptions, '未设置',
                        (v) => setState(() => _gender = v ?? '')),
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
                  title: '出生与地区',
                  summary: _countSummary(
                      ['birthdate', 'death_date', 'country', 'ethnicity']),
                  children: [
                    _text(_birthCtrl, '出生日期（yyyy-MM-dd）', date: true),
                    _text(_deathCtrl, '去世日期（yyyy-MM-dd）', date: true),
                    _text(_countryCtrl, '国籍'),
                    _text(_ethnicityCtrl, '族裔'),
                  ],
                ),

                FoldSection(
                  title: '身体数据',
                  summary: _countSummary([
                    'height_cm',
                    'weight',
                    'measurements',
                    'fake_tits',
                    'penis_length',
                    'circumcised',
                    'eye_color',
                    'hair_color'
                  ]),
                  children: [
                    _text(_heightCtrl, '身高',
                        unit: 'cm', type: TextInputType.number),
                    _text(_weightCtrl, '体重',
                        unit: 'kg', type: TextInputType.number),
                    _text(_measureCtrl, '三围', hint: '如 34B-24-35'),
                    _text(_fakeTitsCtrl, '隆胸', hint: '如 natural / fake'),
                    _text(_penisCtrl, '阴茎长度',
                        unit: 'cm', type: const TextInputType.numberWithOptions(decimal: true)),
                    _picker('环切状态', _circumcisedValue, kCircumcisedOptions,
                        '未设置',
                        (v) => setState(() => _circumcisedValue = v ?? '')),
                    _text(_eyeCtrl, '瞳色'),
                    _text(_hairCtrl, '发色'),
                  ],
                ),

                FoldSection(
                  title: '职业生涯',
                  summary: _countSummary(['career_start', 'career_end']),
                  children: [
                    _text(_careerStartCtrl, '出道年份',
                        hint: '如 2015', type: TextInputType.number),
                    _text(_careerEndCtrl, '隐退年份',
                        hint: '如 2020', type: TextInputType.number),
                    if (_careerStartCtrl.text.isEmpty &&
                        _careerEndCtrl.text.isEmpty &&
                        (p?.careerLength.isNotEmpty ?? false))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text('服务器仅有旧字段：${p!.careerLength}',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      ),
                  ],
                ),

                FoldSection(
                  title: '纹身与穿孔',
                  summary: _countSummary(['tattoos', 'piercings']),
                  children: [
                    _text(_tattooCtrl, '纹身',
                        hint: '每行一条，如：左臂 - 玫瑰', maxLines: 4),
                    _text(_piercingCtrl, '穿孔',
                        hint: '每行一条，如：耳 - 两个', maxLines: 4),
                  ],
                ),

                FoldSection(
                  title: '链接',
                  summary: _countSummary(['urls']),
                  children: [
                    _text(_urlCtrl, '网址',
                        hint: '每行一个 URL', maxLines: 4),
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
                  summary: _countSummary(
                      ['details', 'ignore_auto_tag']),
                  children: [
                    _text(_detailsCtrl, '简介',
                        hint: '演员介绍…', maxLines: 6),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _ignoreAutoTag,
                      title: const Text('忽略自动打标'),
                      subtitle: const Text('自动打标任务跳过该演员'),
                      onChanged: (v) => setState(() => _ignoreAutoTag = v),
                    ),
                  ],
                ),

                if (!_isNew && p != null) ...[
                  FoldSection(
                    title: '服务端统计',
                    summary: '短片 ${p.sceneCount}',
                    children: [
                      InfoRow('短片', '${p.sceneCount}'),
                      InfoRow('图片', '${p.imageCount}'),
                      InfoRow('相册', '${p.galleryCount}'),
                      InfoRow('合集', '${p.groupCount}'),
                      InfoRow('O 计数', '${p.oCounter}'),
                      if (p.createdAt.isNotEmpty)
                        InfoRow('创建时间', _fmtTime(p.createdAt)),
                      if (p.updatedAt.isNotEmpty)
                        InfoRow('更新时间', _fmtTime(p.updatedAt)),
                    ],
                  ),
                ],

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

  static String _fmtTime(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    final l = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}
