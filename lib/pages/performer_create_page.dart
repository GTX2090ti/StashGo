import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'performer_form.dart';
import '../l10n/l10n.dart';

/// 手动添加演员页；成功后 pop 新演员 id，供来源页自动勾选。
class PerformerCreatePage extends StatelessWidget {
  const PerformerCreatePage({super.key});

  @override
  Widget build(BuildContext context) => PerformerForm(
        title: tr('添加演员'),
        submitLabel: tr('创建'),
        onSubmit: (ctx, input) async {
          final id = await buildApi().createPerformer(input);
          if (ctx.mounted) Navigator.pop(ctx, id);
        },
      );
}
