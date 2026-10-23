import 'package:flutter/material.dart';

import 'groups_page.dart';
import 'performer_list_page.dart';
import 'studio_list_page.dart';
import 'tags_page.dart';
import '../l10n/l10n.dart';

/// 资料库：标签 / 演员 / 工作室 / 集合 合并到一个页面（对齐 Stash web 打包 app）。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, this.embedded = false});

  /// true 时由 HomePage 提供 Scaffold/AppBar，本页只出内容。
  final bool embedded;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = Column(children: [
      TabBar(
        controller: _tab,
        labelColor: theme.colorScheme.primary,
        unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
        indicatorColor: theme.colorScheme.primary,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        tabs:  [
          Tab(text: tr('标签')),
          Tab(text: tr('演员')),
          Tab(text: tr('工作室')),
          Tab(text: tr('集合')),
        ],
      ),
      Expanded(
        child: TabBarView(
          controller: _tab,
          children: const [
            TagsPage(embedded: true),
            PerformerListPage(embedded: true),
            StudioListPage(embedded: true),
            GroupsPage(embedded: true),
          ],
        ),
      ),
    ]);

    if (widget.embedded) return Scaffold(body: body);
    return Scaffold(appBar: AppBar(title:  Text(tr('资料库'))), body: body);
  }
}
