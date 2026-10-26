import 'package:flutter/material.dart';

import '../api/filter_options_cache.dart';
import '../widgets/common.dart';
import 'studio_form.dart';
import '../l10n/l10n.dart';

/// 手动添加工作室页；成功后 pop 新工作室 id，供来源页刷新。
class StudioCreatePage extends StatelessWidget {
  const StudioCreatePage({super.key});

  @override
  Widget build(BuildContext context) => StudioForm(
        title: tr('添加工作室'),
        submitLabel: tr('创建'),
        onSubmit: (ctx, input) async {
          final id = await buildApi().createStudio(
                (input['name'] ?? '').toString(),
                {...input}..remove('name'),
              );
          // 工作室列表变了，让筛选/选择面板下次重新拉取
          FilterOptionsCache.invalidate();
          if (ctx.mounted) Navigator.pop(ctx, id);
        },
      );
}
