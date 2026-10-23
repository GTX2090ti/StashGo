import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'net_health.dart';
import 'net_log.dart';
import '../l10n/l10n.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);

  @override
  String toString() => message;
}

/// Stash GraphQL 客户端：ApiKey 走请求头（对齐 ArkTS 版 StashAPI）。
class StashApi {
  StashApi(this.baseUrl, this.apiKey);

  final String baseUrl;
  final String apiKey;

  Uri get _endpoint => Uri.parse('${normalizeBase(baseUrl)}/graphql');

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    if (apiKey.isNotEmpty) 'ApiKey': apiKey,
  };

  /// 查询（query）失败自动重试一次；变更（mutation）不重试（对齐 iOS GraphQLClient）。
  /// 链路层失败（超时 / 连接错误）时先重建会话丢弃吊死连接，再重试一次。
  Future<dynamic> query(
    String q, [
    Map<String, dynamic>? vars,
    Duration? timeout,
  ]) async {
    final isMutation = q.trimLeft().toLowerCase().startsWith('mutation');
    try {
      final r = await _queryOnce(q, vars, timeout);
      NetHealth.instance.noteSuccess();
      return r;
    } catch (e) {
      if (isConnectivity(e)) {
        final reason = _friendly(e);
        ApiSession.instance.reset(
          tr('查询链路失败（{reason}），重建会话丢弃吊死连接', {'reason': reason}),
        );
        if (!isMutation) {
          try {
            final r = await _queryOnce(q, vars, timeout);
            NetHealth.instance.noteSuccess();
            NetLog.instance.record(
              category: 'Network',
              level: 'WARN',
              title: tr('自动重试成功'),
              message: tr('首次失败（{reason}），重建会话后重试成功', {'reason': reason}),
            );
            return r;
          } catch (_) {}
        }
        // 连续链路失败累加：达到阈值触发自愈选路（内外网翻面）。
        NetHealth.instance.noteFailure(reason);
      }
      rethrow;
    }
  }

  String _friendly(Object e) {
    if (e is TimeoutException) return tr('超时');
    if (e is http.ClientException) return e.message;
    return '$e';
  }

  Future<dynamic> _queryOnce(
    String q, [
    Map<String, dynamic>? vars,
    Duration? timeout,
  ]) async {
    final body = jsonEncode({'query': q, 'variables': vars ?? const {}});
    final sw = Stopwatch()..start();
    final kind = q.trimLeft().toLowerCase().startsWith('mutation')
        ? 'mutation'
        : 'query';
    final firstLine = q.trim().split('\n').first.trim();
    final title = firstLine.length > 60
        ? firstLine.substring(0, 60)
        : firstLine;
    http.Response resp;
    try {
      resp = await ApiSession.instance.client
          .post(_endpoint, headers: _headers, body: body)
          .timeout(timeout ?? const Duration(seconds: 10));
    } on TimeoutException {
      NetLog.instance.record(
        category: 'Network',
        level: 'ERROR',
        title: '$kind $title',
        message: tr('连接超时'),
        method: 'POST',
        url: _endpoint.toString(),
        ms: sw.elapsedMilliseconds,
      );
      throw ApiException(tr('连接超时'));
    } catch (e) {
      NetLog.instance.record(
        category: 'Network',
        level: 'ERROR',
        title: '$kind $title',
        message: tr('网络错误: {error}', {'error': e}),
        method: 'POST',
        url: _endpoint.toString(),
        ms: sw.elapsedMilliseconds,
      );
      throw ApiException(tr('网络错误: {error}', {'error': e}));
    }
    if (resp.statusCode != 200) {
      // 尽力带出服务端返回的具体错误信息（GraphQL errors / message / body 片段）。
      var detail = 'HTTP ${resp.statusCode}';
      try {
        final d = jsonDecode(resp.body);
        final es = d?['errors'];
        if (es is List && es.isNotEmpty) {
          final msgs = es
              .map((e) => e is Map ? e['message']?.toString() : null)
              .whereType<String>()
              .where((m) => m.isNotEmpty)
              .toList();
          if (msgs.isNotEmpty) detail += '：${msgs.join('；')}';
        } else if (d is Map && d['message'] != null) {
          detail += '：${d['message']}';
        }
      } catch (_) {
        if (resp.body.isNotEmpty) {
          detail +=
              '：${resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body}';
        }
      }
      NetLog.instance.record(
        category: 'Network',
        level: 'ERROR',
        title: '$kind $title',
        message: detail,
        method: 'POST',
        url: _endpoint.toString(),
        status: resp.statusCode,
        ms: sw.elapsedMilliseconds,
      );
      throw ApiException(detail);
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(resp.body);
    } catch (_) {
      NetLog.instance.record(
        category: 'Network',
        level: 'ERROR',
        title: '$kind $title',
        message: tr('响应解析失败'),
        method: 'POST',
        url: _endpoint.toString(),
        status: resp.statusCode,
        ms: sw.elapsedMilliseconds,
      );
      throw ApiException(tr('响应解析失败'));
    }
    final errors = decoded?['errors'];
    if (errors is List && errors.isNotEmpty) {
      NetLog.instance.record(
        category: 'Network',
        level: 'ERROR',
        title: '$kind $title',
        message: errors.first?['message']?.toString() ?? tr('GraphQL 错误'),
        method: 'POST',
        url: _endpoint.toString(),
        status: resp.statusCode,
        ms: sw.elapsedMilliseconds,
      );
      throw ApiException(
        errors.first?['message']?.toString() ?? tr('GraphQL 错误'),
      );
    }
    NetLog.instance.record(
      category: 'Network',
      title: '$kind $title',
      method: 'POST',
      url: _endpoint.toString(),
      status: resp.statusCode,
      ms: sw.elapsedMilliseconds,
    );
    return decoded?['data'];
  }

  Future<String> version() async {
    final data = await query('query { version { version } }');
    return data?['version']?['version']?.toString() ?? '';
  }

  // ---------- Stash 任务（扫描） ----------

  /// 触发扫描：发现并入库新短片与图片。
  /// [paths] 为 null 时扫描全部已配置路径；指定则只扫描该文件夹。
  /// 可选生成选项仅在开启时传入（GraphQL 变量声明同步动态生成），
  /// 避免旧版 Stash schema 缺字段时因"变量未使用/字段不存在"报 422。
  Future<void> metadataScan({
    List<String>? paths,
    bool useFileMetadata = false,
    bool rescan = false,
    bool scanGenerateCovers = false,
    bool scanGeneratePreviews = false,
    bool scanGenerateImagePreviews = false,
    bool scanGeneratePhashes = false,
    bool scanGenerateSpritePreviews = false,
  }) async {
    final vars = <String, dynamic>{};
    final varDecls = <String>[];
    final inputFields = <String>[];
    void addBool(String name, bool v) {
      if (v) {
        vars[name] = true;
        varDecls.add('\$$name: Boolean');
        inputFields.add('$name: \$$name');
      }
    }

    if (paths != null) {
      vars['paths'] = paths;
      varDecls.add('\$paths: [String!]');
      inputFields.add('paths: \$paths');
    }
    addBool('useFileMetadata', useFileMetadata);
    addBool('rescan', rescan);
    addBool('scanGenerateCovers', scanGenerateCovers);
    addBool('scanGeneratePreviews', scanGeneratePreviews);
    addBool('scanGenerateImagePreviews', scanGenerateImagePreviews);
    addBool('scanGeneratePhashes', scanGeneratePhashes);
    addBool('scanGenerateSpritePreviews', scanGenerateSpritePreviews);

    final head = varDecls.isEmpty
        ? 'mutation'
        : 'mutation(${varDecls.join(', ')})';
    final gq = '$head { metadataScan(input: { ${inputFields.join(', ')} }) }';
    await query(gq, vars, const Duration(seconds: 15));
  }

  /// 生成任务：按类别为已有媒体生成封面/视频预览/图片预览/感知哈希/预览缩略图/互动热图。
  /// mutation 名按服务器实际字段传入（0.31+ 为 metadataGenerate，旧版为 generate）。
  /// [sceneIDs] 非空时只对指定短片生成（0.31+ GenerateMetadataInput.sceneIDs）。
  /// 只把勾选为 true 的选项写入 input，避免 0.31.1 中不存在的字段（如
  /// interactiveHeatmaps）导致 HTTP 422。
  Future<void> generate({
    required String mutation,
    bool covers = false,
    bool sprites = false,
    bool previews = false,
    bool imagePreviews = false,
    bool markers = false,
    bool markerImagePreviews = false,
    bool markerScreenshots = false,
    bool transcodes = false,
    bool phashes = false,
    bool imagePhashes = false,
    bool imageThumbnails = false,
    bool interactiveHeatmaps = false,
    bool clipPreviews = false,
    bool overwrite = false,
    List<String> sceneIDs = const [],
  }) async {
    final vars = <String, dynamic>{};
    final varDecls = <String>[];
    final inputFields = <String>[];
    void addBool(String name, bool v) {
      if (v) {
        vars[name] = true;
        varDecls.add('\$$name: Boolean');
        inputFields.add('$name: \$$name');
      }
    }

    addBool('covers', covers);
    addBool('sprites', sprites);
    addBool('previews', previews);
    addBool('imagePreviews', imagePreviews);
    addBool('markers', markers);
    addBool('markerImagePreviews', markerImagePreviews);
    addBool('markerScreenshots', markerScreenshots);
    addBool('transcodes', transcodes);
    addBool('phashes', phashes);
    addBool('imagePhashes', imagePhashes);
    addBool('imageThumbnails', imageThumbnails);
    // 0.31+ 的 GenerateMetadataInput 字段名为 interactiveHeatmapsSpeeds，
    // 旧版 generate 才是 interactiveHeatmaps，按 mutation 名区分。
    addBool(
      mutation == 'metadataGenerate'
          ? 'interactiveHeatmapsSpeeds'
          : 'interactiveHeatmaps',
      interactiveHeatmaps,
    );
    addBool('clipPreviews', clipPreviews);
    addBool('overwrite', overwrite);
    if (sceneIDs.isNotEmpty) {
      vars['sceneIDs'] = sceneIDs;
      varDecls.add('\$sceneIDs: [ID!]!');
      inputFields.add('sceneIDs: \$sceneIDs');
    }
    final head = varDecls.isEmpty
        ? 'mutation'
        : 'mutation(${varDecls.join(', ')})';
    final gq = '$head { $mutation(input: { ${inputFields.join(', ')} }) }';
    await query(gq, vars, const Duration(seconds: 15));
  }

  /// 给指定短片生成封面（0.31+ 按 sceneIDs 定向生成；mutation 名动态探测）。
  Future<void> generateCovers(
    List<String> sceneIds, {
    bool overwrite = false,
    String? mutation,
  }) async {
    final m = mutation ?? (await _detectGenerateMutation());
    await generate(
      mutation: m,
      covers: true,
      sprites: false,
      previews: false,
      imagePreviews: false,
      phashes: false,
      overwrite: overwrite,
      sceneIDs: sceneIds,
    );
  }

  /// 探测当前服务端可用的生成 mutation 名（metadataGenerate 优先，兼容旧版 generate）。
  Future<String> _detectGenerateMutation() async {
    final ms = await mutationFields();
    if (ms.contains('metadataGenerate')) return 'metadataGenerate';
    if (ms.contains('generate')) return 'generate';
    return 'metadataGenerate';
  }

  /// 批量识别（Identify）：按 [sources] 顺序自动匹配短片元数据
  /// （0.31+ mutation 为 metadataIdentify，兼容旧版 identify）。
  /// [sources] 每项形如 {'scraper_id': id} 或 {'stash_box_endpoint': url}；
  /// 顺序即优先级，第一个命中即采用。
  /// 识别开关属于 input.options（不是 input 顶层），按服务端实际字段放置；
  /// Stash 这些开关默认 true，所以 false 也要显式下发。
  Future<void> identifyScenes({
    required List<Map<String, dynamic>> sources,
    bool setCoverImage = true,
    bool setOrganized = true,
    bool skipMultipleMatches = true,
    bool skipSingleNamePerformers = true,
    List<String>? sceneIDs,
    List<String>? paths,
  }) async {
    final ms = await mutationFields();
    final m = ms.contains('metadataIdentify') ? 'metadataIdentify' : 'identify';
    final inFields = await inputFields('IdentifyMetadataInput');
    final optFields = await inputFields('IdentifyMetadataOptionsInput');
    final srcFields = await inputFields('IdentifySourceInput');

    final opts = <String, dynamic>{};
    void addOpt(String name, bool v) {
      if (optFields.contains(name)) opts[name] = v;
    }

    addOpt('setCoverImage', setCoverImage);
    addOpt('setOrganized', setOrganized);
    addOpt('skipMultipleMatches', skipMultipleMatches);
    addOpt('skipSingleNamePerformers', skipSingleNamePerformers);

    final vars = <String, dynamic>{};
    final decls = <String>[];
    final parts = <String>[];

    // 0.31 的 IdentifySourceInput 是 { source: ScraperSourceInput! }，旧版才平铺。
    final wrapSource = srcFields.isEmpty || srcFields.contains('source');
    vars['sources'] = wrapSource
        ? [
            for (final s in sources) {'source': s},
          ]
        : sources;
    decls.add('\$sources: [IdentifySourceInput!]!');
    parts.add('sources: \$sources');

    if (opts.isNotEmpty) {
      if (inFields.isEmpty || inFields.contains('options')) {
        vars['options'] = opts;
        decls.add('\$options: IdentifyMetadataOptionsInput');
        parts.add('options: \$options');
      } else {
        for (final e in opts.entries) {
          vars[e.key] = e.value;
          decls.add('\$${e.key}: Boolean');
          parts.add('${e.key}: \$${e.key}');
        }
      }
    }
    if (sceneIDs != null &&
        sceneIDs.isNotEmpty &&
        (inFields.isEmpty || inFields.contains('sceneIDs'))) {
      vars['sceneIDs'] = sceneIDs;
      decls.add('\$sceneIDs: [ID!]');
      parts.add('sceneIDs: \$sceneIDs');
    }
    if (paths != null &&
        paths.isNotEmpty &&
        (inFields.isEmpty || inFields.contains('paths'))) {
      vars['paths'] = paths;
      decls.add('\$paths: [String!]');
      parts.add('paths: \$paths');
    }
    final gq =
        'mutation(${decls.join(', ')}) { $m(input: { ${parts.join(', ')} }) }';
    await query(gq, vars, const Duration(seconds: 15));
  }

  /// 查找疑似重复短片：按 phash 距离（0~64，越小越严格）+ 时长差（秒）。
  /// 返回重复分组列表，每组为内容相似的多个短片。
  Future<List<List<Scene>>> findDuplicateScenes({
    int distance = 16,
    double durationDiff = 15,
  }) async {
    const gq =
        '''
      query FindDuplicateScenes(\$distance: Int, \$duration_diff: Float) {
        findDuplicateScenes(distance: \$distance, duration_diff: \$duration_diff) {
          $_sceneCardFields
        }
      }''';
    final d = await query(gq, {
      'distance': distance,
      'duration_diff': durationDiff,
    });
    final v = d?['findDuplicateScenes'];
    if (v is! List) return const [];
    return v
        .map(
          (g) =>
              (g as List).where((e) => e != null).map(Scene.fromJson).toList(),
        )
        .toList();
  }

  /// 清理：删除孤儿媒体文件等（dryRun=true 只预览不实际删除）。
  /// mutation 名按服务器实际字段传入（0.31+ 为 metadataClean / metadataCleanGenerated，
  /// 旧版为 clean）。CleanInput.dryRun 为非空字段（Boolean!）。
  Future<void> clean({required String mutation, bool dryRun = false}) async {
    await query(
      'mutation(\$dryRun: Boolean!) { $mutation(input: { dryRun: \$dryRun }) }',
      {'dryRun': dryRun},
      const Duration(seconds: 15),
    );
  }

  /// 自动打标签。mutation 名按服务器实际字段传入
  /// （0.31+ 为 metadataAutoTag，旧版为 autoTag）。
  ///
  /// 注意两版 input 结构不同（曾因类型不匹配返回 422）：
  /// - 0.31+ `AutoTagMetadataInput`：performers/studios/tags 为 `[String!]`，
  ///   传 `["*"]` 表示对该类全部打标签，不传该字段表示跳过；
  /// - 旧版 `AutoTagInput`：对应字段为 Boolean。
  Future<void> autoTag({
    required String mutation,
    bool performers = true,
    bool studios = true,
    bool tags = true,
  }) async {
    if (mutation == 'metadataAutoTag') {
      // 0.31+：字段是 ID 数组，"*" 表示全部；未勾选的类不传该字段。
      final inp = <String, dynamic>{};
      if (performers) inp['performers'] = const ['*'];
      if (studios) inp['studios'] = const ['*'];
      if (tags) inp['tags'] = const ['*'];
      await query(
        'mutation(\$input: AutoTagMetadataInput!) { $mutation(input: \$input) }',
        {'input': inp},
        const Duration(seconds: 15),
      );
    } else {
      // 旧版：字段是 Boolean。
      await query(
        'mutation(\$performers: Boolean, \$studios: Boolean, \$tags: Boolean) '
        '{ $mutation(input: { performers: \$performers, studios: \$studios, '
        'tags: \$tags }) }',
        {'performers': performers, 'studios': studios, 'tags': tags},
        const Duration(seconds: 15),
      );
    }
  }

  /// Stash 的媒体库路径（可扫描范围）：
  /// 1. 0.31+：configuration.general.stashes（配置的媒体库路径，含用户添加的二级目录）；
  /// 2. 0.19~0.30：configuration.general.libraryFolders；
  /// 3. 更老：configuration.general.libraryPath；
  /// 4. 兜底：findFolders（所有含媒体文件的文件夹）。
  Future<List<String>> libraryPaths() async {
    try {
      final d = await query(
        'query { configuration { general { stashes { path } } } }',
      );
      final list = d?['configuration']?['general']?['stashes'];
      if (list is List && list.isNotEmpty) {
        final paths =
            list
                .map((e) => e is Map ? e['path']?.toString() : null)
                .whereType<String>()
                .where((s) => s.isNotEmpty)
                .toSet()
                .toList()
              ..sort();
        if (paths.isNotEmpty) return paths;
      }
    } catch (_) {}
    try {
      final d = await query(
        'query { configuration { general { libraryFolders { path } } } }',
      );
      final list = d?['configuration']?['general']?['libraryFolders'];
      if (list is List) {
        final paths = list
            .map((e) => e is Map ? e['path']?.toString() : null)
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .toList();
        if (paths.isNotEmpty) return paths;
      }
    } catch (_) {}
    try {
      final d = await query(
        'query { configuration { general { libraryPath } } }',
      );
      final p = d?['configuration']?['general']?['libraryPath']?.toString();
      if (p != null && p.isNotEmpty) return [p];
    } catch (_) {}
    try {
      final d = await query('query { findFolders { folders { path } } }');
      final list = d?['findFolders']?['folders'];
      if (list is List && list.isNotEmpty) {
        final paths =
            list
                .map((e) => e is Map ? e['path']?.toString() : null)
                .whereType<String>()
                .where((s) => s.isNotEmpty)
                .toSet()
                .toList()
              ..sort();
        if (paths.isNotEmpty) return paths;
      }
    } catch (_) {}
    return [];
  }

  /// 探测 Mutation 类型支持哪些字段（GraphQL introspection）。
  /// 0.31+ 将 generate/autoTag/clean 改名为 metadataGenerate/metadataAutoTag/metadataClean。
  Future<Set<String>> mutationFields() async {
    try {
      final d = await query(
        'query { __type(name: "Mutation") { fields { name } } }',
      );
      final fs = d?['__type']?['fields'];
      if (fs is List) {
        return fs
            .map((e) => e is Map ? e['name']?.toString() ?? '' : '')
            .where((s) => s.isNotEmpty)
            .toSet();
      }
    } catch (_) {}
    return {};
  }

  /// 探测某个 Input 类型支持哪些字段（用于按版本显示扫描选项等）。
  Future<Set<String>> inputFields(String typeName) async {
    try {
      final d = await query(
        'query { __type(name: "$typeName") { inputFields { name } } }',
      );
      final fs = d?['__type']?['inputFields'];
      if (fs is List) {
        return fs
            .map((e) => e is Map ? e['name']?.toString() ?? '' : '')
            .where((s) => s.isNotEmpty)
            .toSet();
      }
    } catch (_) {}
    return {};
  }

  /// 当前任务队列（Stash 后台任务：id/状态/描述/子任务）。
  Future<List<dynamic>> jobQueue() async {
    final data = await query(
      'query { jobQueue { id status description subTasks } }',
      null,
      const Duration(seconds: 15),
    );
    final list = data?['jobQueue'];
    return list is List ? list : [];
  }

  /// 媒体库统计（StatsResultType）。字段全部必填，新版用 group_count，
  /// 旧版回退 movie_count。
  Future<Map<String, dynamic>> stats() async {
    final d = await query(
      'query { stats { scene_count scenes_size scenes_duration '
      'image_count images_size gallery_count performer_count studio_count '
      'group_count movie_count tag_count total_o_count total_play_duration '
      'total_play_count scenes_played } }',
      null,
      const Duration(seconds: 20),
    );
    final s = d?['stats'];
    return s is Map ? Map<String, dynamic>.from(s) : {};
  }

  /// 已安装插件列表（Plugin）。失败返回空列表。
  Future<List<dynamic>> plugins() async {
    try {
      final d = await query(
        'query { plugins { id name description url version enabled '
        'tasks { name } hooks { name } settings { name display_name type } } }',
        null,
        const Duration(seconds: 15),
      );
      final list = d?['plugins'];
      return list is List ? list : [];
    } catch (_) {
      return [];
    }
  }

  // ---------- 分类全量（编辑表单用） ----------

  Future<List<Studio>> allStudios() async {
    final d = await query('query { allStudios { id name } }');
    return Studio.listFrom(d?['allStudios']);
  }

  Future<List<Performer>> allPerformers() async {
    final d = await query('query { allPerformers { id name } }');
    return Performer.listFrom(d?['allPerformers']);
  }

  Future<List<Tag>> allTags() async {
    final d = await query('query { allTags { id name } }');
    return Tag.listFrom(d?['allTags']);
  }

  /// 按名称精确查找标签（0.31.1 不允许重名，新建前先查重）。
  Future<List<Tag>> findTagsByName(String name) async {
    final q = '''
      query FindTagByName(\$n: String!) {
        findTags(tag_filter: { name: { value: \$n, modifier: EQUALS } },
                 filter: { per_page: 5 }) {
          count tags { id name }
        }
      }''';
    try {
      final d = await query(q, {'n': name});
      return Tag.listFrom(d?['findTags']?['tags']);
    } catch (_) {
      return const [];
    }
  }

  /// 按关键词模糊查标签（搜索用）。
  Future<List<Tag>> findTagsByQ(String term, {int perPage = 50}) async {
    const q = '''
      query FindTags(\$filter: FindFilterType!) {
        findTags(filter: \$filter) { count tags { id name } }
      }''';
    try {
      final d = await query(q, {
        'filter': {'page': 1, 'per_page': perPage, 'q': term.trim()},
      });
      return Tag.listFrom(d?['findTags']?['tags']);
    } catch (_) {
      return const [];
    }
  }

  /// 按名称精确查找工作室（新建前先查重）。
  Future<List<Studio>> findStudiosByName(String name) async {
    final q = '''
      query FindStudioByName(\$n: String!) {
        findStudios(studio_filter: { name: { value: \$n, modifier: EQUALS } },
                    filter: { per_page: 5 }) {
          count studios { id name }
        }
      }''';
    try {
      final d = await query(q, {'n': name});
      return Studio.listFrom(d?['findStudios']?['studios']);
    } catch (_) {
      return const [];
    }
  }

  // ---------- 削刮源 ----------

  Future<List<Scraper>> scrapers(String typeName) async {
    const q = '''
      query ListScrapers(\$types: [ScrapeContentType!]!) {
        listScrapers(types: \$types) { id name scene { supported_scrapes } performer { supported_scrapes } }
      }''';
    final d = await query(q, {
      'types': [typeName],
    });
    final v = d?['listScrapers'];
    if (v is! List) return const [];
    return v.map((e) => Scraper.fromJson(e)).toList();
  }

  /// 服务端已配置的 Stash-box 端点（数组顺序即 stash_box_index）。
  Future<List<StashBoxInfo>> stashBoxes() async {
    const q =
        'query { configuration { general { stashBoxes { name endpoint } } } }';
    final d = await query(q);
    final conf = d?['configuration'];
    final arr = conf?['general']?['stashBoxes'];
    if (arr is! List) return const [];
    return arr.map((e) => StashBoxInfo.fromJson(e)).toList();
  }

  // ---------- 削刮器包（Stash 包系统） ----------

  /// 包对象想要字段：0.31 的 `Package` 只有前四个 + requires，
  /// 更早版本的 InstalledPackage/AvailablePackage 另有 author/synopsis/url。
  static const _pkgWantFields = <String>[
    'package_id',
    'name',
    'version',
    'date',
    'sourceURL',
    'requires',
    'author',
    'synopsis',
    'url',
  ];
  static const _pkgMinFields = ['package_id', 'name', 'version', 'sourceURL'];

  /// 包类型名的探测顺序（0.31 起合并为 Package）。
  static const _pkgInstalledTypes = ['Package', 'InstalledPackage'];
  static const _pkgAvailableTypes = ['Package', 'AvailablePackage'];

  static final Map<String, Map<String, String>> _pkgFieldCache = {};
  static String? _pkgTypeScraper;

  /// 对象类型的字段名 -> 「种类:类型名」（如 SCALAR:String、OBJECT:Package）。
  /// introspection 不可用时返回空 Map。
  Future<Map<String, String>> _typeFields(String typeName) async {
    final cached = _pkgFieldCache[typeName];
    if (cached != null) return cached;
    final out = <String, String>{};
    try {
      final d = await query(
        'query { __type(name: "$typeName") { fields { '
        'name type { kind name ofType { kind name ofType { kind name } } } } } }',
      );
      final fs = d?['__type']?['fields'];
      if (fs is List) {
        for (final e in fs.whereType<Map>()) {
          final n = e['name']?.toString() ?? '';
          if (n.isNotEmpty) out[n] = _unwrapType(e['type']);
        }
      }
    } catch (_) {}
    _pkgFieldCache[typeName] = out;
    return out;
  }

  /// 逐层剥开 NON_NULL / LIST 包装，取最终的「种类:类型名」。
  static String _unwrapType(dynamic t) {
    var cur = t;
    for (var i = 0; i < 4 && cur is Map; i++) {
      final name = cur['name']?.toString() ?? '';
      if (name.isNotEmpty) {
        return '${cur['kind']?.toString() ?? ''}:$name';
      }
      cur = cur['ofType'];
    }
    return '';
  }

  /// PackageType 枚举里代表「削刮器」的那个值。0.31 是 `Scraper`（首字母大写），
  /// 其它版本见过 SCRAPER / SCRAPERS，传错整条查询直接报错。
  Future<String> packageTypeScraper() async {
    final cached = _pkgTypeScraper;
    if (cached != null) return cached;
    var out = 'Scraper';
    try {
      final d = await query(
        'query { __type(name: "PackageType") { enumValues { name } } }',
      );
      final vs = d?['__type']?['enumValues'];
      if (vs is List) {
        final names = vs
            .map((e) => e is Map ? e['name']?.toString() ?? '' : '')
            .where((s) => s.isNotEmpty)
            .toList();
        for (final n in names) {
          if (n.toLowerCase() == 'scraper') {
            out = n;
            break;
          }
        }
        if (out == 'Scraper') {
          for (final n in names) {
            if (n.toLowerCase().startsWith('scraper')) {
              out = n;
              break;
            }
          }
        }
      }
    } catch (_) {}
    _pkgTypeScraper = out;
    return out;
  }

  /// 按服务器实际字段拼包列表的选择集。requires 在 0.31 是 `[Package!]!`
  /// （更早版本是字符串数组），必须按类型种类决定是否下钻。
  Future<String> _pkgSelection(List<String> candidates) async {
    for (final typeName in candidates) {
      final have = await _typeFields(typeName);
      if (have.isEmpty) continue;
      final parts = <String>[];
      for (final f in _pkgWantFields) {
        final ty = have[f];
        if (ty == null || ty.isEmpty) continue;
        if (!ty.startsWith('OBJECT:')) {
          parts.add(f);
          continue;
        }
        final sub = await _typeFields(ty.split(':').last);
        final subFields = <String>[
          'package_id',
          'name',
          'version',
        ].where((n) => sub.containsKey(n)).toList();
        if (subFields.isNotEmpty) {
          parts.add('$f { ${subFields.join(' ')} }');
        }
      }
      if (parts.isNotEmpty) return parts.join(' ');
    }
    return _pkgMinFields.join(' ');
  }

  /// 服务端已配置的削刮器包源（名称 / 索引 URL / 本地目录）。
  /// 老版本没有该字段时返回空列表。
  Future<List<PackageSource>> scraperPackageSources() async {
    try {
      final d = await query(
        'query { configuration { general '
        '{ scraperPackageSources { name url local_path } } } }',
      );
      final arr = d?['configuration']?['general']?['scraperPackageSources'];
      if (arr is! List) return const [];
      return arr.map((e) => PackageSource.fromJson(e)).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 服务器上已安装的削刮器包。
  Future<List<ScraperPkg>> installedPackages() async {
    final sel = await _pkgSelection(_pkgInstalledTypes);
    final type = await packageTypeScraper();
    final d = await query(
      'query InstalledPkgs(\$t: PackageType!) '
      '{ installedPackages(type: \$t) { $sel } }',
      {'t': type},
      const Duration(seconds: 20),
    );
    final list = d?['installedPackages'];
    if (list is! List) return const [];
    return list.map((e) => ScraperPkg.fromJson(e)).toList();
  }

  /// 某个索引源上可安装的包。[source] 必须是完整 index.yml URL ——
  /// 传源配置里的 local_path 会让服务器报 `unsupported protocol scheme`。
  Future<List<ScraperPkg>> availablePackages(String source) async {
    final sel = await _pkgSelection(_pkgAvailableTypes);
    final type = await packageTypeScraper();
    final d = await query(
      'query AvailablePkgs(\$t: PackageType!, \$s: String!) '
      '{ availablePackages(type: \$t, source: \$s) { $sel } }',
      {'t': type, 's': source.trim()},
      const Duration(seconds: 60),
    );
    final list = d?['availablePackages'];
    if (list is! List) return const [];
    return list.map((e) => ScraperPkg.fromJson(e)).toList();
  }

  /// 安装（或重装以更新）削刮器包，返回后台任务 id（可能为空）。
  /// 注意 specs 为空是「什么都不装」，不是「装全部」。
  Future<String> installPackages(List<Map<String, String>> specs) async {
    if (specs.isEmpty) return '';
    final fields = await mutationFields();
    if (!fields.contains('installPackages')) {
      throw ApiException(tr('当前 Stash 版本不支持安装削刮器包'));
    }
    final inp = await inputFields('PackageSpecInput');
    final key = inp.contains('source_url')
        ? 'source_url'
        : (inp.contains('sourceURL') || inp.isEmpty)
        ? 'sourceURL'
        : '';
    final type = await packageTypeScraper();
    final vars = specs
        .map(
          (e) => <String, String>{
            'id': e['id'] ?? '',
            if (key.isNotEmpty && (e['source'] ?? '').isNotEmpty)
              key: e['source']!,
          },
        )
        .where((e) => (e['id'] ?? '').isNotEmpty)
        .toList();
    if (vars.isEmpty) return '';
    final d = await query(
      'mutation InstallPkgs(\$t: PackageType!, \$p: [PackageSpecInput!]!) '
      '{ installPackages(type: \$t, packages: \$p) }',
      {'t': type, 'p': vars},
      const Duration(seconds: 30),
    );
    final v = d?['installPackages'];
    return v is String ? v : '';
  }

  /// 让服务器重新加载削刮器：装完包不必重启容器，新刮削器即进缓存。
  Future<void> reloadScrapers() async {
    final fields = await mutationFields();
    if (!fields.contains('reloadScrapers')) {
      throw ApiException(tr('当前 Stash 版本不支持重新加载削刮器'));
    }
    await query(
      'mutation { reloadScrapers }',
      null,
      const Duration(seconds: 30),
    );
  }

  /// 按 id 找后台任务；队列里查不到该 id 视为已结束（返回 null）。
  /// 老版本 jobQueue 无 progress/error 字段，整条查询失败时退回精简字段。
  Future<Map<String, dynamic>?> findJob(String id) async {
    if (id.isEmpty) return null;
    List<dynamic> list;
    try {
      list = await _jobQueueFull();
    } catch (_) {
      list = await _jobQueueLite();
    }
    for (final e in list.whereType<Map>()) {
      if (e['id']?.toString() == id) return Map<String, dynamic>.from(e);
    }
    return null;
  }

  Future<List<dynamic>> _jobQueueFull() async {
    final data = await query(
      'query { jobQueue { id status progress description error } }',
      null,
      const Duration(seconds: 15),
    );
    final list = data?['jobQueue'];
    return list is List ? list : [];
  }

  Future<List<dynamic>> _jobQueueLite() async {
    try {
      final data = await query(
        'query { jobQueue { id status description } }',
        null,
        const Duration(seconds: 15),
      );
      final list = data?['jobQueue'];
      return list is List ? list : [];
    } catch (_) {
      return [];
    }
  }

  // ---------- 短片查询 ----------

  static const _sceneCardFields = '''
      id title details date created_at rating100 o_counter play_count organized
      urls studio { id name } performers { id name } tags { id name }
      paths { screenshot webp } files { path height width duration }
      captions { language_code caption_type }
  ''';

  Future<FindResult<Scene>> findScenes({
    int page = 1,
    int perPage = 120,
    String? q,
    String sort = 'date',
    String direction = 'DESC',
    Map<String, dynamic>? sceneFilter,
  }) async {
    const gq =
        '''
      query FindScenes(\$filter: FindFilterType!, \$sf: SceneFilterType) {
        findScenes(filter: \$filter, scene_filter: \$sf) {
          count
          scenes { $_sceneCardFields }
        }
      }''';
    final filter = <String, dynamic>{
      'page': page,
      'per_page': perPage,
      'sort': sort,
      'direction': direction,
      if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
    };
    final vars = <String, dynamic>{'filter': filter};
    if (sceneFilter != null && sceneFilter.isNotEmpty) {
      vars['sf'] = sceneFilter;
    }
    final d = await query(gq, vars);
    final fs = d?['findScenes'];
    if (fs == null) return const FindResult<Scene>(count: 0, items: []);
    return FindResult<Scene>(
      count: fs['count'] is int ? fs['count'] as int : 0,
      items: Scene.listFrom(fs['scenes']),
    );
  }

  /// 关键词合并搜索：标题/路径/详情（q）+ 演员名 + 标签名 + 工作室名。
  /// 各路由取全量匹配后按 sort 在客户端排序并本地分页。
  Future<FindResult<Scene>> searchScenes({
    required String term,
    required int page,
    required int perPage,
    String sort = 'date',
    String direction = 'DESC',
    Map<String, dynamic>? sceneFilter,
  }) async {
    final map = <String, Scene>{};

    Future<void> collect(String? q, Map<String, dynamic>? sf) async {
      var p = 1;
      for (;;) {
        final r = await findScenes(
          page: p,
          perPage: 1000,
          q: q,
          sort: sort,
          direction: direction,
          sceneFilter: sf,
        );
        for (final s in r.items) {
          map[s.id] = s;
        }
        if (r.items.isEmpty || p * 1000 >= r.count || p >= 8) break;
        p++;
      }
    }

    // 1) 标题/路径/详情
    await collect(term, sceneFilter);

    // 2) 演员名
    try {
      final ps = await findPerformers(page: 1, perPage: 50, q: term);
      if (ps.items.isNotEmpty) {
        await collect(null, {
          ...?sceneFilter,
          'performers': {
            'value': ps.items.map((e) => e.id).toList(),
            'modifier': 'INCLUDES',
          },
        });
      }
    } catch (_) {}

    // 3) 标签名
    try {
      final ts = await findTagsByQ(term);
      if (ts.isNotEmpty) {
        await collect(null, {
          ...?sceneFilter,
          'tags': {
            'value': ts.map((e) => e.id).toList(),
            'modifier': 'INCLUDES',
          },
        });
      }
    } catch (_) {}

    // 4) 工作室名
    try {
      final ss = await findStudios(page: 1, perPage: 50, q: term);
      if (ss.items.isNotEmpty) {
        await collect(null, {
          ...?sceneFilter,
          'studio_id': ss.items.map((e) => e.id).toList(),
        });
      }
    } catch (_) {}

    final all = map.values.toList();
    _sortScenesClient(all, sort, direction);
    final total = all.length;
    final start = (page - 1) * perPage;
    final items = start >= total
        ? <Scene>[]
        : all.sublist(
            start,
            (start + perPage) > total ? total : start + perPage,
          );
    return FindResult<Scene>(count: total, items: items);
  }

  /// 客户端排序（合并搜索用），空日期/空值永远排最后。
  static void _sortScenesClient(
    List<Scene> list,
    String sort,
    String direction,
  ) {
    int cmp(Scene a, Scene b) {
      switch (sort) {
        case 'title':
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case 'rating':
          return a.rating100.compareTo(b.rating100);
        case 'o_counter':
          return a.oCounter.compareTo(b.oCounter);
        case 'duration':
          return a.duration.compareTo(b.duration);
        case 'created_at':
          return a.createdAt.compareTo(b.createdAt);
        case 'performer_count':
          return a.performers.length.compareTo(b.performers.length);
        case 'tag_count':
          return a.tags.length.compareTo(b.tags.length);
        case 'studio':
          return (a.studio?.name ?? '').compareTo(b.studio?.name ?? '');
        default:
          return a.date.compareTo(b.date);
      }
    }

    list.sort((a, b) {
      final av = _sortKey(a, sort);
      final bv = _sortKey(b, sort);
      final aEmpty = av.isEmpty;
      final bEmpty = bv.isEmpty;
      if (aEmpty && bEmpty) return 0;
      if (aEmpty) return 1; // 空值永远排最后
      if (bEmpty) return -1;
      final c = cmp(a, b);
      return direction == 'DESC' ? -c : c;
    });
  }

  static String _sortKey(Scene s, String sort) {
    switch (sort) {
      case 'title':
        return s.title;
      case 'rating':
        return s.rating100.toString();
      case 'o_counter':
        return s.oCounter.toString();
      case 'play_count':
        return s.playCount.toString();
      case 'duration':
        return s.duration.toString();
      case 'created_at':
        return s.createdAt;
      case 'performer_count':
        return s.performers.length.toString();
      case 'tag_count':
        return s.tags.length.toString();
      case 'studio':
        return s.studio?.name ?? '';
      default:
        return s.date;
    }
  }

  Future<Scene?> findScene(String id) async {
    const q = '''
      query FindScene(\$id: ID!) {
        findScene(id: \$id) {
          id title details date rating100 o_counter play_count organized
          urls studio { id name }
          performers { id name image_path birthdate details }
          tags { id name }
          paths { screenshot webp }
          files { id path size mod_time created_at duration height width }
        }
      }''';
    final d = await query(q, {'id': id});
    final s = d?['findScene'];
    return s == null ? null : Scene.fromJson(s);
  }

  /// 演员完整档案想要的字段（Stash 0.31.1 `Performer`）。
  static const _performerWantFields = <String>[
    'id',
    'name',
    'disambiguation',
    'alias_list',
    'image_path',
    'gender',
    'birthdate',
    'death_date',
    'ethnicity',
    'country',
    'eye_color',
    'hair_color',
    'height_cm',
    'weight',
    'measurements',
    'fake_tits',
    'penis_length',
    'circumcised',
    'career_start',
    'career_end',
    'career_length',
    'tattoos',
    'piercings',
    'urls',
    'details',
    'rating100',
    'favorite',
    'ignore_auto_tag',
    'scene_count',
    'image_count',
    'gallery_count',
    'group_count',
    'o_counter',
    'created_at',
    'updated_at',
  ];

  static Set<String>? _performerFieldCache;

  /// 服务端 Performer 类型实际有的字段；用于裁剪选择集，避免旧版服务器整条查询报错。
  Future<Set<String>> performerFields() async {
    final cached = _performerFieldCache;
    if (cached != null) return cached;
    var out = const <String>{};
    try {
      final d = await query(
        'query { __type(name: "Performer") { fields { name } } }',
      );
      final fs = d?['__type']?['fields'];
      if (fs is List) {
        out = fs
            .map((e) => e is Map ? e['name']?.toString() ?? '' : '')
            .where((s) => s.isNotEmpty)
            .toSet();
      }
    } catch (_) {}
    if (out.isNotEmpty) _performerFieldCache = out;
    return out;
  }

  Future<Performer?> findPerformer(String id) async {
    final have = await performerFields();
    final fields = have.isEmpty
        ? _performerWantFields
        : _performerWantFields.where((f) => have.contains(f)).toList();
    final selection = fields.join(' ');
    final d = await query(
      'query FindPerformer(\$id: ID!) { findPerformer(id: \$id) { $selection tags { id name } } }',
      {'id': id},
    );
    final p = d?['findPerformer'];
    return p == null ? null : Performer.fromJson(p);
  }

  /// findStudio 需要的标量字段；老服务器缺字段时按 introspect 结果裁剪。
  static const _studioWantFields = <String>[
    'id',
    'name',
    'image_path',
    'rating100',
    'scene_count',
    'image_count',
    'performer_count',
    'favorite',
    'details',
    'urls',
    'aliases',
    'ignore_auto_tag',
    'created_at',
    'updated_at',
  ];

  static Set<String>? _studioFieldCache;

  Future<Set<String>> studioFields() async {
    final cached = _studioFieldCache;
    if (cached != null) return cached;
    var out = const <String>{};
    try {
      final d = await query(
        'query { __type(name: "Studio") { fields { name } } }',
      );
      final fs = d?['__type']?['fields'];
      if (fs is List) {
        out = fs
            .map((e) => e is Map ? e['name']?.toString() ?? '' : '')
            .where((s) => s.isNotEmpty)
            .toSet();
      }
    } catch (_) {}
    if (out.isNotEmpty) _studioFieldCache = out;
    return out;
  }

  Future<Studio?> findStudio(String id) async {
    final have = await studioFields();
    final fields = have.isEmpty
        ? _studioWantFields
        : _studioWantFields.where((f) => have.contains(f)).toList();
    final extraTags = have.isEmpty || have.contains('tags')
        ? 'tags { id name }'
        : '';
    final q =
        '''
      query FindStudio(\$id: ID!) {
        findStudio(id: \$id) {
          ${fields.join(' ')}
          parent_studio { id name }
          child_studios { id name image_path }
          $extraTags
        }
      }''';
    final d = await query(q, {'id': id});
    final s = d?['findStudio'];
    return s == null ? null : Studio.fromJson(s);
  }

  Future<Tag?> findTag(String id) async {
    const q = 'query FindTag(\$id: ID!) { findTag(id: \$id) { id name } }';
    final d = await query(q, {'id': id});
    final t = d?['findTag'];
    return t == null ? null : Tag.fromJson(t);
  }

  Future<FindResult<Performer>> findPerformers({
    int page = 1,
    int perPage = 120,
    String? q,
    String sort = 'name',
    String direction = 'ASC',
  }) async {
    const gq = '''
      query FindPerformers(\$filter: FindFilterType!) {
        findPerformers(filter: \$filter) {
          count
          performers { id name disambiguation image_path birthdate country rating100 scene_count favorite tags { id name } }
        }
      }''';
    final filter = <String, dynamic>{
      'page': page,
      'per_page': perPage,
      'sort': sort,
      'direction': direction,
      if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
    };
    final d = await query(gq, {'filter': filter});
    final fp = d?['findPerformers'];
    if (fp == null) return const FindResult<Performer>(count: 0, items: []);
    return FindResult<Performer>(
      count: fp['count'] is int ? fp['count'] as int : 0,
      items: Performer.listFrom(fp['performers']),
    );
  }

  Future<FindResult<Studio>> findStudios({
    int page = 1,
    int perPage = 120,
    String? q,
    String sort = 'name',
    String direction = 'ASC',
    Map<String, dynamic>? studioFilter,
  }) async {
    const gq = '''
      query FindStudios(\$filter: FindFilterType!, \$sf: StudioFilterType) {
        findStudios(filter: \$filter, studio_filter: \$sf) {
          count
          studios { id name image_path rating100 scene_count favorite }
        }
      }''';
    final filter = <String, dynamic>{
      'page': page,
      'per_page': perPage,
      'sort': sort,
      'direction': direction,
      if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
    };
    final vars = <String, dynamic>{'filter': filter};
    if (studioFilter != null && studioFilter.isNotEmpty) {
      vars['sf'] = studioFilter;
    }
    final d = await query(gq, vars);
    final fp = d?['findStudios'];
    if (fp == null) return const FindResult<Studio>(count: 0, items: []);
    return FindResult<Studio>(
      count: fp['count'] is int ? fp['count'] as int : 0,
      items: Studio.listFrom(fp['studios']),
    );
  }

  // ---------- 集合（Groups） ----------

  static const _groupFields = '''
    id name date rating100 duration director synopsis aliases urls
    front_image_path scene_count studio { id name } tags { id name }
  ''';

  /// 集合列表。排序白名单：name / date / rating / duration / scenes_count /
  /// created_at / updated_at（Stash 0.31.1 拒绝 studio 等未支持字段）。
  Future<FindResult<Group>> findGroups({
    int page = 1,
    int perPage = 60,
    String? q,
    String sort = 'name',
    String direction = 'ASC',
  }) async {
    const gq =
        '''
      query FindGroups(\$filter: FindFilterType!) {
        findGroups(filter: \$filter) {
          count
          groups { $_groupFields }
        }
      }''';
    final filter = <String, dynamic>{
      'page': page,
      'per_page': perPage,
      'sort': sort,
      'direction': direction,
      if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
    };
    final d = await query(gq, {'filter': filter});
    final fg = d?['findGroups'];
    if (fg == null) return const FindResult<Group>(count: 0, items: []);
    return FindResult<Group>(
      count: fg['count'] is int ? fg['count'] as int : 0,
      items: Group.listFrom(fg['groups']),
    );
  }

  Future<Group?> findGroup(String id) async {
    const gq =
        '''
      query FindGroup(\$id: ID!) {
        findGroup(id: \$id) { $_groupFields }
      }''';
    final d = await query(gq, {'id': id});
    final g = d?['findGroup'];
    return g == null ? null : Group.fromJson(g);
  }

  /// 新建集合。成员短片不在创建时指定，需从短片侧写入。
  Future<Group> createGroup(String name, [Map<String, dynamic>? extra]) async {
    const m = '''
      mutation GroupCreate(\$input: GroupCreateInput!) {
        groupCreate(input: \$input) { id name }
      }''';
    final d = await query(m, {
      'input': {'name': name, ...?extra},
    });
    final g = d?['groupCreate'];
    if (g == null) throw ApiException(tr('groupCreate 失败'));
    return Group.fromJson(g);
  }

  /// 短片的集合成员关系：scene_id -> { group_id: scene_index }。
  /// 集合成员存在短片侧，写入时必须带上原有集合，否则会被整体覆盖。
  Future<Map<String, Map<String, int?>>> sceneGroups(
    List<String> sceneIds,
  ) async {
    if (sceneIds.isEmpty) return const {};
    const sq = '''
      query SceneGroups(\$ids: [ID!]!) {
        findScenes(ids: \$ids) {
          scenes { id groups { scene_index group { id } } }
        }
      }''';
    final d = await query(sq, {'ids': sceneIds});
    final out = <String, Map<String, int?>>{};
    final scenes = d?['findScenes']?['scenes'];
    if (scenes is! List) return out;
    for (final raw in scenes) {
      if (raw is! Map) continue;
      final sid = raw['id']?.toString();
      if (sid == null) continue;
      final members = <String, int?>{};
      final groups = raw['groups'];
      if (groups is List) {
        for (final g in groups) {
          if (g is! Map) continue;
          final group = g['group'];
          final gid = group is Map ? group['id']?.toString() : null;
          if (gid == null) continue;
          members[gid] = g['scene_index'] is int
              ? g['scene_index'] as int
              : null;
        }
      }
      out[sid] = members;
    }
    return out;
  }

  // ---------- 削刮 ----------

  static const _long = Duration(seconds: 180);

  static const _sceneSelection = '''
    title details date duration urls image
    studio { stored_id name urls image }
    performers { stored_id name disambiguation birthdate details country ethnicity measurements urls tags { stored_id name } }
    tags { stored_id name }''';

  static const _performerSelection = '''
    stored_id name disambiguation aliases birthdate gender country ethnicity hair_color eye_color height weight
    measurements fake_tits tattoos piercings career_start career_end details urls images tags { stored_id name }''';

  Future<List<ScrapedScene>> scrapeSceneFragment(
    Map<String, dynamic> source,
    String sceneId,
  ) async {
    const gq =
        '''
      query ScrapeSingleScene(\$source: ScraperSourceInput!, \$input: ScrapeSingleSceneInput!) {
        scrapeSingleScene(source: \$source, input: \$input) { $_sceneSelection }
      }''';
    final d = await query(gq, {
      'source': source,
      'input': {'scene_id': sceneId},
    }, _long);
    final list = d?['scrapeSingleScene'];
    if (list is! List) return const [];
    return list
        .where((e) => e != null)
        .map((e) => ScrapedScene.fromJson(e))
        .toList();
  }

  Future<List<ScrapedScene>> scrapeSceneByName(
    Map<String, dynamic> source,
    String term,
  ) async {
    const gq =
        '''
      query ScrapeSingleScene(\$source: ScraperSourceInput!, \$input: ScrapeSingleSceneInput!) {
        scrapeSingleScene(source: \$source, input: \$input) { $_sceneSelection }
      }''';
    final d = await query(gq, {
      'source': source,
      'input': {'query': term},
    }, _long);
    final list = d?['scrapeSingleScene'];
    if (list is! List) return const [];
    return list
        .where((e) => e != null)
        .map((e) => ScrapedScene.fromJson(e))
        .toList();
  }

  Future<List<ScrapedScene>> scrapeSceneUrl(String url) async {
    const gq =
        '''
      query ScrapeSceneURL(\$url: String!) {
        scrapeSceneURL(url: \$url) { $_sceneSelection }
      }''';
    final d = await query(gq, {'url': url}, _long);
    final s = d?['scrapeSceneURL'];
    return s == null ? const [] : [ScrapedScene.fromJson(s)];
  }

  /// 本地刮削器片段削刮：0.31.1 的 ScrapeSinglePerformer 对本地 scraper_id
  /// 只支持 performer_input（FRAGMENT）与 query（NAME），不支持 performer_id
  ///（直接返回 ErrNotImplemented）。故调用方先取本地演员数据构造 performer_input。
  Future<List<ScrapedPerformer>> scrapePerformerFragment(
    Map<String, dynamic> source,
    Map<String, dynamic> performerInput,
  ) async {
    const gq =
        '''
      query ScrapeSinglePerformer(\$source: ScraperSourceInput!, \$input: ScrapeSinglePerformerInput!) {
        scrapeSinglePerformer(source: \$source, input: \$input) { $_performerSelection }
      }''';
    final d = await query(gq, {
      'source': source,
      'input': {'performer_input': performerInput},
    }, _long);
    final list = d?['scrapeSinglePerformer'];
    if (list is! List) return const [];
    return list
        .where((e) => e != null)
        .map((e) => ScrapedPerformer.fromJson(e))
        .toList();
  }

  Future<List<ScrapedPerformer>> scrapePerformerByName(
    Map<String, dynamic> source,
    String term,
  ) async {
    const gq =
        '''
      query ScrapeSinglePerformer(\$source: ScraperSourceInput!, \$input: ScrapeSinglePerformerInput!) {
        scrapeSinglePerformer(source: \$source, input: \$input) { $_performerSelection }
      }''';
    final d = await query(gq, {
      'source': source,
      'input': {'query': term},
    }, _long);
    final list = d?['scrapeSinglePerformer'];
    if (list is! List) return const [];
    return list
        .where((e) => e != null)
        .map((e) => ScrapedPerformer.fromJson(e))
        .toList();
  }

  Future<List<ScrapedPerformer>> scrapePerformerUrl(String url) async {
    const gq =
        '''
      query ScrapePerformerURL(\$url: String!) {
        scrapePerformerURL(url: \$url) { $_performerSelection }
      }''';
    final d = await query(gq, {'url': url}, _long);
    final p = d?['scrapePerformerURL'];
    return p == null ? const [] : [ScrapedPerformer.fromJson(p)];
  }

  Future<ScrapedStudio?> scrapeStudioByName(
    Map<String, dynamic> source,
    String term,
  ) async {
    const gq = '''
      query ScrapeSingleStudio(\$source: ScraperSourceInput!, \$input: ScrapeSingleStudioInput!) {
        scrapeSingleStudio(source: \$source, input: \$input) { stored_id name urls image }
      }''';
    final d = await query(gq, {
      'source': source,
      'input': {'query': term},
    }, _long);
    final s = d?['scrapeSingleStudio'];
    return s == null ? null : ScrapedStudio.fromJson(s);
  }

  // ---------- 元数据写回 ----------

  Future<void> updateScene(Map<String, dynamic> input) async {
    const m =
        'mutation UpdateScene(\$input: SceneUpdateInput!) { sceneUpdate(input: \$input) { id } }';
    final d = await query(m, {'input': input});
    if (d?['sceneUpdate'] == null) throw ApiException(tr('sceneUpdate 失败'));
  }

  /// 批量写多部短片。标签/演员/集合用 BulkUpdateIds（SET/ADD/REMOVE），
  /// 其余字段（organized、rating100、studio_id）直接给值。
  Future<void> bulkUpdateScenes(
    List<String> ids,
    Map<String, dynamic> fields, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (ids.isEmpty) return;
    const m =
        'mutation BulkSceneUpdate(\$input: BulkSceneUpdateInput!) '
        '{ bulkSceneUpdate(input: \$input) { id } }';
    // 空结果集时服务端返回 null 且无错误，故不以返回值判成败，只看是否抛出。
    await query(m, {
      'input': {'ids': ids, ...fields},
    }, timeout);
  }

  /// 标记短片已看一次（Stash 0.31 的 sceneAddPlay，省略 times 即按当前时间记一条）。
  /// 返回服务端最新的已看次数。
  Future<int> markScenePlayed(String id) async {
    const m =
        'mutation SceneAddPlay(\$id: ID!) '
        '{ sceneAddPlay(id: \$id) { count } }';
    final d = await query(m, {'id': id});
    final v = d?['sceneAddPlay'];
    if (v is Map && v['count'] is int) return v['count'] as int;
    throw ApiException(tr('sceneAddPlay 失败'));
  }

  /// 清零短片的已看次数（Stash 0.31 的 sceneResetPlayCount）。
  Future<void> resetScenePlayCount(String id) async {
    const m =
        'mutation SceneResetPlayCount(\$id: ID!) '
        '{ sceneResetPlayCount(id: \$id) }';
    final d = await query(m, {'id': id});
    if (d == null || d['sceneResetPlayCount'] == null) {
      throw ApiException(tr('sceneResetPlayCount 失败'));
    }
  }

  /// 清除短片的全部削刮结果：标题改用文件名，简介/日期/链接/工作室/演员/标签清空。
  /// 封面与评分、O 计数属于用户自己的数据，不动。
  /// studio_id 传 null 才表示取消工作室（缺省不传时 Stash 视为「不修改」）。
  Future<void> clearSceneScrape(String id, String title) async {
    await updateScene({
      'id': id,
      'title': title,
      'details': '',
      'date': '',
      'urls': <String>[],
      'studio_id': null,
      'performer_ids': <String>[],
      'tag_ids': <String>[],
    });
  }

  Future<void> updatePerformer(Map<String, dynamic> input) async {
    const m =
        'mutation UpdatePerformer(\$input: PerformerUpdateInput!) { performerUpdate(input: \$input) { id } }';
    final d = await query(m, {'input': input});
    if (d?['performerUpdate'] == null)
      throw ApiException(tr('performerUpdate 失败'));
  }

  Future<void> updateStudio(Map<String, dynamic> input) async {
    const m =
        'mutation UpdateStudio(\$input: StudioUpdateInput!) { studioUpdate(input: \$input) { id } }';
    final d = await query(m, {'input': input});
    if (d?['studioUpdate'] == null) throw ApiException(tr('studioUpdate 失败'));
  }

  Future<String> createPerformer(Map<String, dynamic> input) async {
    const m =
        'mutation CreatePerformer(\$input: PerformerCreateInput!) { performerCreate(input: \$input) { id } }';
    final d = await query(m, {'input': input});
    final v = d?['performerCreate'];
    if (v == null || v['id'] == null)
      throw ApiException(tr('performerCreate 失败'));
    return v['id'].toString();
  }

  Future<String> createTag(String name) async {
    final fields = await mutationFields();
    final m = fields.contains('tagCreate') ? 'tagCreate' : 'createTag';
    final q =
        'mutation CreateTag(\$input: TagCreateInput!) { $m(input: \$input) { id } }';
    final d = await query(q, {
      'input': {'name': name},
    });
    final v = d?[m];
    if (v == null || v['id'] == null)
      throw ApiException(tr('{m} 失败', {'m': m}));
    return v['id'].toString();
  }

  Future<String> createStudio(
    String name, [
    Map<String, dynamic>? extra,
  ]) async {
    final fields = await mutationFields();
    final m = fields.contains('studioCreate') ? 'studioCreate' : 'createStudio';
    final q =
        'mutation CreateStudio(\$input: StudioCreateInput!) { $m(input: \$input) { id } }';
    final d = await query(q, {
      'input': {'name': name, ...?extra},
    });
    final v = d?[m];
    if (v == null || v['id'] == null)
      throw ApiException(tr('{m} 失败', {'m': m}));
    return v['id'].toString();
  }

  /// 删除演员（0.31+ mutation 名为 performerDestroy，兼容旧版 destroyPerformer）。
  Future<void> destroyPerformer(String id) async {
    final fields = await mutationFields();
    final m = fields.contains('performerDestroy')
        ? 'performerDestroy'
        : 'destroyPerformer';
    final q =
        'mutation DestroyPerformer(\$input: PerformerDestroyInput!) { $m(input: \$input) }';
    await query(q, {
      'input': {'id': id},
    });
  }

  /// 删除工作室（0.31+ mutation 名为 studioDestroy，兼容旧版 destroyStudio）。
  Future<void> destroyStudio(String id) async {
    final fields = await mutationFields();
    final m = fields.contains('studioDestroy')
        ? 'studioDestroy'
        : 'destroyStudio';
    final q =
        'mutation DestroyStudio(\$input: StudioDestroyInput!) { $m(input: \$input) }';
    await query(q, {
      'input': {'id': id},
    });
  }

  /// 删除短片（0.31+ mutation 名为 sceneDestroy，兼容旧版 destroyScene）。
  /// [deleteFile] 是否同时删除磁盘文件；[deleteGenerated] 是否删除生成素材。
  Future<void> destroyScene(
    String id, {
    bool deleteFile = false,
    bool deleteGenerated = false,
  }) async {
    final fields = await mutationFields();
    final m = fields.contains('sceneDestroy') ? 'sceneDestroy' : 'destroyScene';
    final q =
        '''
      mutation DestroyScene(\$id: ID!, \$delete_file: Boolean, \$delete_generated: Boolean) {
        $m(input: { id: \$id, delete_file: \$delete_file, delete_generated: \$delete_generated })
      }''';
    await query(q, {
      'id': id,
      'delete_file': deleteFile,
      'delete_generated': deleteGenerated,
    });
  }

  /// 短片合并（服务端原生 sceneMerge）。
  Future<void> mergeScenes(List<String> sourceIds, String destinationId) async {
    const m =
        'mutation SceneMerge(\$input: SceneMergeInput!) { sceneMerge(input: \$input) { id } }';
    final d = await query(m, {
      'input': {
        'source': sourceIds,
        'destination': destinationId,
        'play_history': true,
        'o_history': true,
      },
    });
    if (d?['sceneMerge'] == null) throw ApiException(tr('sceneMerge 失败'));
  }

  /// 演员合并：把 sourceIds 的演员并入 destinationId（源条目删除，
  /// 相关短片/标签等归并到目标）。0.31.1 mutation: performerMerge。
  Future<void> mergePerformers(
    List<String> sourceIds,
    String destinationId,
  ) async {
    const m =
        'mutation PerformerMerge(\$input: PerformerMergeInput!) { performerMerge(input: \$input) { id } }';
    final d = await query(m, {
      'input': {'source': sourceIds, 'destination': destinationId},
    });
    if (d?['performerMerge'] == null)
      throw ApiException(tr('performerMerge 失败'));
  }

  // ---------- 削刮结果写回 ----------

  /// 下载图片转 base64 data URI；失败返回空串（不影响文字字段）。
  Future<String> fetchImageAsBase64(String ref) async {
    if (ref.startsWith('data:')) return ref;
    if (!ref.startsWith('http://') && !ref.startsWith('https://')) return '';
    try {
      final resp = await ApiSession.instance.client
          .get(Uri.parse(ref))
          .timeout(const Duration(seconds: 25));
      if (resp.statusCode < 200 || resp.statusCode > 299) return '';
      final bytes = resp.bodyBytes;
      if (bytes.isEmpty) return '';
      return 'data:image/jpeg;base64,${base64Encode(bytes)}';
    } catch (_) {
      return '';
    }
  }

  /// 外部削刮器通常只给名字、stored_id 为空；库里已有同名实体时必须复用，
  /// 直接 create 会被服务端以「已存在」拒绝（name 有 UNIQUE 约束）。
  /// 返回 null 表示无法解析，调用方跳过该条目而不是让整次写回失败。
  Future<String?> _resolvePerformerId(ScrapedPerformer p) async {
    if (p.storedId.isNotEmpty) return p.storedId;
    final name = p.name.trim();
    if (name.isEmpty) return null;
    final found = await _findPerformerIdByName(name);
    if (found != null) return found;
    try {
      return await createPerformer({'name': name});
    } catch (_) {
      return _findPerformerIdByName(name);
    }
  }

  Future<String?> _findPerformerIdByName(String name) async {
    try {
      final r = await findPerformers(page: 1, perPage: 20, q: name);
      final key = name.toLowerCase();
      for (final p in r.items) {
        if (p.name.trim().toLowerCase() == key) return p.id;
      }
    } catch (_) {}
    return null;
  }

  Future<String?> _resolveTagId(ScrapedTag t) async {
    if (t.storedId.isNotEmpty) return t.storedId;
    final name = t.name.trim();
    if (name.isEmpty) return null;
    final found = await findTagsByName(name);
    if (found.isNotEmpty) return found.first.id;
    try {
      return await createTag(name);
    } catch (_) {
      // 并发创建或名称匹配规则有差异：再查一次，仍查不到就跳过这个标签。
      final again = await findTagsByName(name);
      return again.isEmpty ? null : again.first.id;
    }
  }

  Future<String?> _resolveStudioId(ScrapedStudio s) async {
    if (s.storedId.isNotEmpty) return s.storedId;
    final name = s.name.trim();
    if (name.isEmpty) return null;
    final found = await findStudiosByName(name);
    if (found.isNotEmpty) return found.first.id;
    try {
      return await createStudio(name);
    } catch (_) {
      final again = await findStudiosByName(name);
      return again.isEmpty ? null : again.first.id;
    }
  }

  /// 写回削刮结果：仅写非空字段；库内不存在自动创建；可选图片。
  /// 写回短片削刮结果。[keepOriginalStudio] 为 true 时若本地已有工作室则保留
  /// 原工作室（与演员"默认保留原名"同理），不覆盖 studio_id。
  /// 标签一律取并集：本地已保存的 tag_ids 不会被削刮结果覆盖。
  Future<int> applyScrapedScene(
    ScrapedScene s,
    String targetId,
    bool includeImage, {
    bool keepOriginalStudio = true,
  }) async {
    final input = <String, dynamic>{'id': targetId};
    var changed = 0;
    if (s.title.isNotEmpty) {
      input['title'] = s.title;
      changed++;
    }
    if (s.details.isNotEmpty) {
      input['details'] = s.details;
      changed++;
    }
    if (s.date.isNotEmpty) {
      input['date'] = s.date;
      changed++;
    }
    // 本地现状：工作室保留判断与标签并入都依赖它
    Scene? cur;
    if (s.studio != null || s.tags.isNotEmpty) {
      try {
        cur = await findScene(targetId);
      } catch (_) {
        // 查询失败时按原逻辑写入，不阻塞削刮
      }
    }
    if (s.studio != null) {
      final writeStudio = !(keepOriginalStudio && cur?.studio != null);
      if (writeStudio) {
        final studioId = await _resolveStudioId(s.studio!);
        if (studioId != null) {
          input['studio_id'] = studioId;
          changed++;
        }
      }
    }
    if (s.performers.isNotEmpty) {
      final ids = <String>[];
      for (final p in s.performers) {
        final id = await _resolvePerformerId(p);
        if (id != null) ids.add(id);
      }
      if (ids.isNotEmpty) {
        input['performer_ids'] = ids;
        changed++;
      }
    }
    if (s.tags.isNotEmpty) {
      final ids = <String>{};
      if (cur != null) {
        ids.addAll(cur.tags.map((t) => t.id));
      }
      for (final t in s.tags) {
        final id = await _resolveTagId(t);
        if (id != null) ids.add(id);
      }
      if (ids.isNotEmpty) {
        input['tag_ids'] = ids.toList();
        changed++;
      }
    }
    if (s.urls.isNotEmpty) {
      input['urls'] = s.urls;
      changed++;
    }
    if (includeImage && s.image.isNotEmpty) {
      final b64 = await fetchImageAsBase64(s.image);
      if (b64.isNotEmpty) {
        input['cover_image'] = b64;
        changed++;
      }
    }
    if (changed > 0) await updateScene(input);
    return changed;
  }

  /// 写回演员削刮结果（全部字段）。
  /// 标签一律取并集：本地已保存的 tag_ids 不会被削刮结果覆盖。
  Future<int> applyScrapedPerformer(
    ScrapedPerformer p,
    String targetId,
    bool includeImage, {
    bool keepOriginalName = true,
    bool writeName = true,
  }) async {
    final input = <String, dynamic>{'id': targetId};
    var changed = 0;
    void put(String key, String v) {
      if (v.isNotEmpty) {
        input[key] = v;
        changed++;
      }
    }

    // 本地现状：名字保留判断与标签并入都依赖它
    Performer? local;
    if ((writeName && keepOriginalName) || p.tags.isNotEmpty) {
      try {
        local = await findPerformer(targetId);
      } catch (_) {}
    }

    // writeName=false 用于名字与库中已有演员冲突时跳过名字字段
    // （performers.name 有 UNIQUE 约束，直接写会失败）。
    if (writeName) {
      // 默认保持原名：写回名字时用本地已有名字，不改名；
      // 仅当本地无名字（如新演员）时才用刮削结果的名字。
      var nameToWrite = p.name;
      if (keepOriginalName) {
        final localName = local?.name.trim() ?? '';
        if (localName.isNotEmpty) nameToWrite = localName;
      }
      put('name', nameToWrite);
    }
    put('disambiguation', p.disambiguation);
    // 0.31.1 起别名字段为 alias_list（ScrapedPerformer.aliases 为逗号分隔）
    if (p.aliases.trim().isNotEmpty) {
      final list = p.aliases
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (list.isNotEmpty) {
        input['alias_list'] = list;
        changed++;
      }
    }
    put('birthdate', p.birthdate);
    put('gender', p.gender);
    put('country', p.country);
    put('ethnicity', p.ethnicity);
    put('hair_color', p.hairColor);
    put('eye_color', p.eyeColor);
    put('measurements', p.measurements);
    put('fake_tits', p.fakeTits);
    put('tattoos', p.tattoos);
    put('piercings', p.piercings);
    put('details', p.details);
    final h = int.tryParse(p.height);
    if (h != null && h > 0) {
      // 0.31.1 起字段名为 height_cm（旧版 height 已移除）
      input['height_cm'] = h;
      changed++;
    }
    final w = int.tryParse(p.weight);
    if (w != null && w > 0) {
      input['weight'] = w;
      changed++;
    }
    final careerParts = <String>[];
    if (p.careerStart.isNotEmpty) careerParts.add(p.careerStart);
    if (p.careerEnd.isNotEmpty) careerParts.add(p.careerEnd);
    final career = careerParts.join(' - ');
    if (career.isNotEmpty) {
      input['career_length'] = career;
      changed++;
    }
    if (p.urls.isNotEmpty) {
      input['urls'] = p.urls;
      changed++;
    }
    if (p.tags.isNotEmpty) {
      final ids = <String>{};
      if (local != null) {
        ids.addAll(local.tags.map((t) => t.id));
      }
      for (final t in p.tags) {
        final id = await _resolveTagId(t);
        if (id != null) ids.add(id);
      }
      if (ids.isNotEmpty) {
        input['tag_ids'] = ids.toList();
        changed++;
      }
    }
    if (includeImage && p.images.isNotEmpty) {
      final b64 = await fetchImageAsBase64(p.images.first);
      if (b64.isNotEmpty) {
        input['image'] = b64;
        changed++;
      }
    }
    if (changed > 0) await updatePerformer(input);
    return changed;
  }

  Future<int> applyScrapedStudio(
    ScrapedStudio s,
    String targetId,
    bool includeImage,
  ) async {
    final input = <String, dynamic>{'id': targetId};
    var changed = 0;
    if (s.urls.isNotEmpty) {
      input['urls'] = s.urls;
      changed++;
    }
    if (includeImage && s.image.isNotEmpty) {
      final b64 = await fetchImageAsBase64(s.image);
      if (b64.isNotEmpty) {
        input['image'] = b64;
        changed++;
      }
    }
    if (changed > 0) await updateStudio(input);
    return changed;
  }

  // ---------- 图片鉴权 ----------

  /// Flutter Image.network 支持自定义头，直接带 ApiKey，无需 URL 参数。
  Map<String, String> get imageHeaders =>
      apiKey.isEmpty ? const {} : {'ApiKey': apiKey};

  String imageUrl(String raw) => rewriteImage(raw, baseUrl);

  String coverUrl(Scene s) => imageUrl(s.paths.raw);

  void close() {}
}

/// 供 TypedData 导入使用（base64Encode 需要 Uint8List）。
typedef Bytes = Uint8List;
