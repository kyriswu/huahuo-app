import 'package:flutter/material.dart';

import '../../../shared/ui_v3/v3_components.dart';

class V3AcademyPlaceholderPage extends StatelessWidget {
  const V3AcademyPlaceholderPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const _ProductPlaceholderPage(title: '花火商学院', message: '功能尚未开发');
}

class _ProductPlaceholderPage extends StatelessWidget {
  const _ProductPlaceholderPage({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => V3PageScaffold(
    title: title,
    fallbackRoute: '/v3/feed',
    children: [
      V3Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 28),
          child: Center(child: Text(message)),
        ),
      ),
    ],
  );
}
