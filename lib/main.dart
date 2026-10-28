import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/l10n.dart';
import 'pages/home_page.dart';
import 'pages/lock_page.dart';
import 'pages/login_page.dart';
import 'pages/settings_page.dart';
import 'settings/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // release 下 build 异常默认显示纯灰屏，换成可见的报错文本，便于定位问题。
  // release 不渲染异常原文：其中可能带内网地址、服务器路径等内部信息。
  ErrorWidget.builder = (details) => ColoredBox(
        color: const Color(0xFF111318),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              kReleaseMode
                  ? tr('页面渲染出错')
                  : tr('页面渲染出错\n{error}', {'error': details.exception}),
              style: const TextStyle(color: Colors.white, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
  // 存储初始化失败也必须进入 runApp，否则永久白屏
  try {
    await AppSettings.instance.load();
  } catch (e) {
    debugPrint('AppSettings load failed: $e');
  }
  runApp(const StashScrubberApp());
}

class StashScrubberApp extends StatefulWidget {
  const StashScrubberApp({super.key});

  @override
  State<StashScrubberApp> createState() => _StashScrubberAppState();
}

class _StashScrubberAppState extends State<StashScrubberApp>
    with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  bool _lockShowing = false;
  bool _wasBackgrounded = false;

  /// 内容遮挡：从 inactive 起就盖住界面，避免系统拍后台快照时把内容留在
  /// 多任务缩略图里。需要锁屏时一直保持，直到验证通过才撤。
  bool _obscure = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppSettings.instance.addListener(_onSettingsChanged);
    // 首帧渲染后检查是否需要面容解锁（App 启动场景）
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowLock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppSettings.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    setState(() {});
  }

  void _setObscure(bool v) {
    if (!mounted || _obscure == v) return;
    setState(() => _obscure = v);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cfg = AppSettings.instance;
    switch (state) {
      // 系统在 inactive 阶段就会拍后台快照，必须先遮住
      case AppLifecycleState.inactive:
        _setObscure(true);
        break;
      // 真正切到后台才算；inactive（Face ID 弹窗、控制中心）不触发重新验证
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _wasBackgrounded = true;
        _setObscure(true);
        break;
      case AppLifecycleState.resumed:
        if (_wasBackgrounded) {
          _wasBackgrounded = false;
          if (cfg.biometricLock) {
            cfg.resetUnlocked();
            _maybeShowLock();
          }
        }
        // 需要验证时保持遮挡，等 LockPage 验证通过再撤
        _setObscure(cfg.biometricLock && !cfg.unlockedThisSession);
        break;
      default:
        break;
    }
  }

  /// 已开启面容解锁且本次会话未验证时，弹出锁屏页。
  void _maybeShowLock() {
    final cfg = AppSettings.instance;
    if (!cfg.biometricLock || cfg.unlockedThisSession || _lockShowing) return;
    final nav = _navKey.currentState;
    // 路由还没就绪时不能提前置位，否则 push 没执行、标记却已占位，
    // 本次会话就再也不会弹锁屏（fail-open）。
    if (nav == null) return;
    _lockShowing = true;
    _setObscure(true);
    nav
        .push(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => LockPage(onUnlocked: _onUnlocked),
          ),
        )
        .whenComplete(() {
          // 非正常退出（未通过验证就被移除）时复位，下次仍会拦截
          if (!AppSettings.instance.unlockedThisSession) {
            _lockShowing = false;
            _setObscure(true);
          }
        });
  }

  void _onUnlocked() {
    _lockShowing = false;
    _setObscure(false);
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  ThemeData _buildTheme(Brightness brightness) {
    const seed = Color(0xFF3D7EFF);
    final dark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: brightness),
      scaffoldBackgroundColor: dark ? const Color(0xFF0E0F13) : const Color(0xFFF2F2F7),
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? const Color(0xFF15181F) : null,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: dark ? const Color(0xFF1A1E26) : Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
        isDense: true,
      ),
      dividerTheme: const DividerThemeData(space: 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mode = switch (AppSettings.instance.appearance) {
      Appearance.light => ThemeMode.light,
      Appearance.dark => ThemeMode.dark,
      Appearance.system => ThemeMode.system,
    };
    final home =
        AppSettings.instance.hasProfile ? const HomePage() : const LoginPage();
    return MaterialApp(
      // 语言切换后整棵界面重建，避免未依赖 Localizations 的页面停留在旧文案
      key: ValueKey('root-${L10n.effectiveCode}'),
      title: 'StashGo',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navKey,
      themeMode: mode,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
        Locale('ja', 'JP'),
      ],
      locale: L10n.materialLocale,
      // 快照遮挡层：盖在 Navigator 之上，锁屏页本身不透明故不需要它
      builder: (context, child) {
        final app = child ?? const SizedBox.shrink();
        if (!_obscure || _lockShowing) return app;
        return Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              app,
              const Positioned.fill(
                child: AbsorbPointer(
                  child: ColoredBox(
                    color: Color(0xFF0E0F13),
                    child: Center(
                      child: Icon(
                        Icons.lock_outline,
                        size: 40,
                        color: Color(0xFF3D7EFF),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
      routes: {
        '/login': (_) => const LoginPage(),
        '/home': (_) => const HomePage(),
        '/settings': (_) => const SettingsPage(),
      },
      home: home,
    );
  }
}
