import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'performer_form.dart';

/// 演员编辑页。
class PerformerEditPage extends StatelessWidget {
  const PerformerEditPage({super.key, required this.performerId});

  final String performerId;

  @override
  Widget build(BuildContext context) => PerformerForm(
        performerId: performerId,
        title: '编辑演员',
        submitLabel: '保存',
        onSubmit: (ctx, input) async {
          await buildApi().updatePerformer(input);
          if (ctx.mounted) Navigator.pop(ctx, true);
        },
      );
}
