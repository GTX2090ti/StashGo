import 'package:flutter/material.dart';

import '../widgets/common.dart';

/// 媒体库统计页：调用 stats query，卡片网格展示短片/图片/演员/工作室等计数。
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  bool _busy = true;
  String? _error;
  Map<String, dynamic> _s = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await buildApi().stats();
      if (!mounted) return;
      setState(() {
        _s = s;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  String _fmtNum(dynamic v) {
    if (v is int) return v.toString();
    if (v is num) return v.toStringAsFixed(0);
    return '—';
  }

  String _fmtSize(dynamic bytes) {
    if (bytes is! num) return '—';
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes.toDouble();
    var u = 0;
    while (size >= 1024 && u < units.length - 1) {
      size /= 1024;
      u++;
    }
    return '${size.toStringAsFixed(size >= 100 ? 0 : 1)} ${units[u]}';
  }

  String _fmtDur(dynamic sec) {
    if (sec is! num || sec <= 0) return '—';
    var s = sec.round();
    final h = s ~/ 3600;
    s %= 3600;
    final m = s ~/ 60;
    final ss = s % 60;
    if (h > 0) return '$h 小时 $m 分';
    if (m > 0) return '$m 分 $ss 秒';
    return '$ss 秒';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 新版用 group_count，旧版回退 movie_count
    final groupCount = (_s['group_count'] as num?) ??
        (_s['movie_count'] as num?) ??
        0;

    final items = <_StatItem>[
      _StatItem('短片', _fmtNum(_s['scene_count']), Icons.movie_outlined),
      _StatItem('短片总时长', _fmtDur(_s['scenes_duration']), Icons.timer_outlined),
      _StatItem('短片体积', _fmtSize(_s['scenes_size']), Icons.storage_outlined),
      _StatItem('图片', _fmtNum(_s['image_count']), Icons.image_outlined),
      _StatItem('图片体积', _fmtSize(_s['images_size']), Icons.storage_outlined),
      _StatItem('画廊', _fmtNum(_s['gallery_count']), Icons.collections_outlined),
      _StatItem('演员', _fmtNum(_s['performer_count']), Icons.person_outline),
      _StatItem('工作室', _fmtNum(_s['studio_count']), Icons.business_outlined),
      _StatItem('分组', _fmtNum(groupCount), Icons.folder_outlined),
      _StatItem('标签', _fmtNum(_s['tag_count']), Icons.sell_outlined),
      _StatItem('已播放短片', _fmtNum(_s['scenes_played']), Icons.play_circle_outline),
      _StatItem('播放次数', _fmtNum(_s['total_play_count']), Icons.replay_outlined),
      _StatItem('累计播放时长', _fmtDur(_s['total_play_duration']), Icons.history),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('统计'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, size: 40, color: Colors.red),
                        const SizedBox(height: 12),
                        Text('统计查询失败', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Text(_error!,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: GridView.count(
                    crossAxisCount: 2,
                    padding: const EdgeInsets.all(12),
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 1.6,
                    children: items.map((it) => _card(theme, it)).toList(),
                  ),
                ),
    );
  }

  Widget _card(ThemeData theme, _StatItem it) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
            color: theme.colorScheme.outlineVariant.withOpacity(0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(it.icon, size: 18,
                    color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(it.label,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
              ],
            ),
            Text(it.value,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

class _StatItem {
  final String label;
  final String value;
  final IconData icon;
  _StatItem(this.label, this.value, this.icon);
}
