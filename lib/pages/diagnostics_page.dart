import 'package:flutter/material.dart';

import '../settings/app_settings.dart';
import '../widgets/common.dart';
import '../l10n/l10n.dart';

/// 网络诊断页（对齐 iOS DiagnosticsView）：连接状态、Stash 版本、两侧地址延迟、选路结论。
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  bool _busy = false;
  String _version = '';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _version = '';
    });
    final cfg = AppSettings.instance;
    await cfg.probeBoth();
    if (cfg.baseUrl.isNotEmpty) {
      try {
        _version = await buildApi().version();
      } catch (e) {
        _version = tr('查询失败：{error}', {'error': e});
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  String _latency(int ms) {
    if (ms == -1) return tr('未配置');
    if (ms == -2) return tr('不可达');
    return '$ms ms';
  }

  @override
  Widget build(BuildContext context) {
    final cfg = AppSettings.instance;
    return Scaffold(
      appBar: AppBar(
        title:  Text(tr('网络诊断')),
        actions: [
          IconButton(
              tooltip: tr('重新诊断'),
              icon: const Icon(Icons.refresh),
              onPressed: _busy ? null : _run),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
           SectionTitle(tr('当前档案')),
          InfoRow(tr('档案名'), cfg.profileName),
          InfoRow(tr('生效地址'), cfg.activeSlot.label),
          InfoRow(tr('生效 URL'), cfg.baseUrl.isEmpty ? tr('（未配置）') : cfg.baseUrl),
          InfoRow(tr('选路结论'),
              cfg.lastSwitchReason.isEmpty ? '—' : cfg.lastSwitchReason),
           SectionTitle(tr('地址探测')),
          InfoRow(tr('内网地址'), _latency(cfg.lanLatencyMs)),
          InfoRow(tr('外网地址'), _latency(cfg.wanLatencyMs)),
           SectionTitle(tr('服务端')),
          InfoRow(tr('Stash 版本'), _version.isEmpty ? tr('（未检测）') : _version),
           SectionTitle(tr('操作')),
          FilledButton.tonal(
            onPressed: _busy
                ? null
                : () async {
                    await cfg.probeBoth();
                    await cfg.autoSelect(tr('诊断页重新选路'));
                  },
            child:  Text(tr('重新测速并选路')),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
