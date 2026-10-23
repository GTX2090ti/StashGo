import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'studio_form.dart';
import '../l10n/l10n.dart';

/// 编辑工作室页；成功后 pop true，供详情页刷新。
class StudioEditPage extends StatelessWidget {
  const StudioEditPage({super.key, required this.studioId});

  final String studioId;

  @override
  Widget build(BuildContext context) => StudioForm(
        studioId: studioId,
        title: tr('编辑工作室'),
        submitLabel: tr('保存'),
        onSubmit: (ctx, input) async {
          await buildApi().updateStudio(input);
          if (ctx.mounted) {
            showToast(ctx, tr('已保存'));
            Navigator.pop(ctx, true);
          }
        },
      );
}
