import 'package:flutter/material.dart';

import 'v3_my_assets_page.dart';

class V3FeedSearchPage extends StatelessWidget {
  const V3FeedSearchPage({this.initialQuery = '', super.key});

  final String initialQuery;

  @override
  Widget build(BuildContext context) =>
      V3MyAssetsPage(initialSearch: true, initialQuery: initialQuery);
}
