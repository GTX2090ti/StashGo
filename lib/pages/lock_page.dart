import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../settings/app_settings.dart';
import '../l10n/l10n.dart';

/// 面容解锁页：App 启动或回前台且开启了面容解锁时显示，
/// 通过 Face ID / Touch ID 验证后进入主界面。
class LockPage extends StatefulWidget {
  const LockPage({super.key, this.onUnlocked});

  /// 验证成功后的回调（用于上层复位锁屏状态标记）。
  final VoidCallback? onUnlocked;

  @override
  State<LockPage> createState() => _LockPageState();
}

class _LockPageState extends State<LockPage> {
  final LocalAuthentication _auth = LocalAuthentication();
  bool _checking = false;
  bool _hasBiometrics = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    setState(() {
      _checking = true;
      _status = '';
    });
    try {
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      _hasBiometrics = supported && canCheck;
    } catch (e) {
      _hasBiometrics = false;
      debugPrint('biometric check failed: $e');
    }
    setState(() => _checking = false);
    if (_hasBiometrics) {
      // 自动拉起系统验证，失败可点按钮重试
      await _authenticate();
    }
  }

  Future<void> _authenticate() async {
    setState(() {
      _checking = true;
      _status = '';
    });
    try {
      final ok = await _auth.authenticate(
        localizedReason: tr('验证您的身份以解锁 Stash'),
        options: const AuthenticationOptions(
          // 允许回退到系统密码，避免 Face ID 不可用时锁死
          stickyAuth: true,
        ),
      );
      if (!mounted) return;
      if (ok) {
        AppSettings.instance.markUnlocked();
        widget.onUnlocked?.call();
        // 关闭锁屏页，回到主界面
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _checking = false;
          _status = tr('验证失败，请重试');
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _status = tr('无法使用生物识别：{error}', {'error': e});
      });
    }
  }

  /// 解困出口：设备没有可用生物识别（或权限被拒）时，锁屏页原本既不能后退
  /// 也进不了设置，用户只能重装。这里给一条需要二次确认的降级路径。
  Future<void> _disableLockAndEnter() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('无法验证身份？')),
        content: Text(
          tr('继续将关闭面容解锁保护并直接进入应用，下次启动不再要求验证。'
              '可在「设置 → 隐私」中重新开启。'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('关闭保护并进入')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // setBiometricLock(false) 会清掉会话解锁标记，故之后要显式标记已解锁，
    // 否则外层 _maybeShowLock 会再次拦截。
    await AppSettings.instance.setBiometricLock(false);
    AppSettings.instance.markUnlocked();
    widget.onUnlocked?.call();
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF0E0F13) : const Color(0xFFF2F2F7);
    return Scaffold(
      backgroundColor: bg,
      body: PopScope(
        // 锁屏页不允许返回键/手势退出
        canPop: false,
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 72,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Stash',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _hasBiometrics ? tr('使用面容或指纹解锁') : tr('此设备不支持生物识别'),
                    style: TextStyle(
                      fontSize: 14,
                      color: dark ? const Color(0xFF9AA0A6) : const Color(0xFF6B6F76),
                    ),
                  ),
                  const SizedBox(height: 32),
                  if (_checking)
                    const CircularProgressIndicator()
                  else ...[
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: FilledButton.icon(
                        onPressed: _hasBiometrics ? _authenticate : null,
                        icon: const Icon(Icons.face_retouching_natural),
                        label: Text(_hasBiometrics ? tr('面容 / 指纹解锁') : tr('无法验证')),
                      ),
                    ),
                    if (_status.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        _status,
                        style: TextStyle(
                          fontSize: 13,
                          color: dark ? const Color(0xFFE5533D) : const Color(0xFFC43D1F),
                        ),
                      ),
                    ],
                    if (!_hasBiometrics) ...[
                      const SizedBox(height: 12),
                      Text(
                        tr('未检测到可用的面容或指纹：请检查系统生物识别设置及本 App 的权限'),
                        style: TextStyle(
                          fontSize: 12,
                          color: dark ? const Color(0xFF9AA0A6) : const Color(0xFF6B6F76),
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      TextButton(
                        onPressed: _checking ? null : _init,
                        child: Text(tr('重新检测')),
                      ),
                    ],
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _disableLockAndEnter,
                      child: Text(
                        tr('无法验证？关闭锁屏保护并进入'),
                        style: TextStyle(
                          fontSize: 12,
                          color: dark ? const Color(0xFF7A8088) : const Color(0xFF8E9299),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
