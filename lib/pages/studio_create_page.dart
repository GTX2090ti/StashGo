import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'studio_form.dart';

/// 手动添加工作室页；成功后 pop 新工作室 id，供来源页刷新。
class StudioCreatePage extends StatelessWidget {
  const StudioCreatePage({super.key});

  @override
  Widget build(BuildContext context) => StudioForm(
        title: '添加工作室',
        submitLabel: '创建',
        onSubmit: (ctx, input) async {
          final id = await buildApi().createStudio(
                (input['name'] ?? '').toString(),
                {...input}..remove('name'),
              );
          if (ctx.mounted) Navigator.pop(ctx, id);
        },
      );
}
