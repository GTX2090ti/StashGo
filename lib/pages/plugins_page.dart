import 'package:flutter/material.dart';

import '../widgets/common.dart';

/// 插件管理页：列出 Stash 服务端已安装插件（名称/版本/启停/描述/任务与钩子）。
/// 仅做只读展示；启停需改服务端 config 并重启，不在移动端处理。
class PluginsPage extends StatefulWidget {
  const PluginsPage({super.key});

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  bool _busy = true;
  String? _error;
  List<dynamic> _plugins = [];

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
      final list = await buildApi().plugins();
      if (!mounted) return;
      setState(() {
        _plugins = list;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('插件 (${_busy ? '…' : _plugins.length})'),
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
                        const Icon(Icons.error_outline,
                            size: 40, color: Colors.red),
                        const SizedBox(height: 12),
                        Text('插件列表查询失败',
                            style: theme.textTheme.titleMedium),
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
              : _plugins.isEmpty
                  ? Center(
                      child: Text('未安装插件',
                          style: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: _plugins.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) => _card(theme, _plugins[i] as Map),
                      ),
                    ),
    );
  }

  Widget _card(ThemeData theme, Map p) {
    final name = p['name']?.toString() ?? p['id']?.toString() ?? '(未命名)';
    final version = p['version']?.toString() ?? '';
    final desc = p['description']?.toString() ?? '';
    final enabled = p['enabled'] == true;
    final tasks = (p['tasks'] as List?)?.length ?? 0;
    final hooks = (p['hooks'] as List?)?.length ?? 0;

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
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: enabled ? Colors.green : Colors.grey,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(name,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ),
                if (version.isNotEmpty)
                  Text('v$version',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
            if (desc.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(desc,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                _chip(theme, Icons.extension_outlined,
                    enabled ? '已启用' : '已停用'),
                if (tasks > 0) _chip(theme, Icons.task_alt, '$tasks 任务'),
                if (hooks > 0) _chip(theme, Icons.link, '$hooks 钩子'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(ThemeData theme, IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(text, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
