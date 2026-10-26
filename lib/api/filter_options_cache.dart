import 'models/models.dart';
import 'stash_api.dart';

/// 工作室 / 演员 / 标签选项的进程内缓存（全 App 共用）。
///
/// 三份选项合并进 [StashApi.allFilterOptions] 的单次 GraphQL 请求：
/// - 各页面的筛选、批量选择面板命中缓存直接返回，不再各自重复拉取；
/// - 并发调用共享同一个 Future（单飞），避免同时打开多个面板时打多份；
/// - 2 分钟后过期；新建/删除演员、工作室、标签后可用 [invalidate] 立即失效。
class FilterOptionsCache {
  FilterOptionsCache._();

  static const Duration _ttl = Duration(minutes: 2);
  static FilterOptions? _data;
  static DateTime? _at;
  static Future<FilterOptions>? _inflight;

  /// 命中且未过期时返回缓存，否则返回 null。
  static FilterOptions? get peek {
    final data = _data;
    final at = _at;
    if (data == null || at == null) return null;
    return DateTime.now().difference(at) <= _ttl ? data : null;
  }

  /// 取选项：优先缓存，其次复用进行中的请求，最后才发起新请求。
  static Future<FilterOptions> load(StashApi api) {
    final hit = peek;
    if (hit != null) return Future.value(hit);
    final pending = _inflight;
    if (pending != null) return pending;
    final f = _fetch(api);
    _inflight = f;
    return f;
  }

  /// 强制刷新（新建/删除演员、工作室、标签后调用，让下次面板拿到最新数据）。
  static Future<FilterOptions> reload(StashApi api) {
    invalidate();
    return load(api);
  }

  static void invalidate() {
    _data = null;
    _at = null;
  }

  static Future<FilterOptions> _fetch(StashApi api) async {
    try {
      final o = await api.allFilterOptions();
      _data = o;
      _at = DateTime.now();
      return o;
    } finally {
      _inflight = null;
    }
  }
}
