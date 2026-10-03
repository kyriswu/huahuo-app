import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../markdown/v3_markdown.dart';
import '../theme/huahuo_v3_theme.dart';
import '../ui_v3/v3_components.dart';

enum LegalDocumentKind { userAgreement, privacyPolicy }

extension LegalDocumentKindX on LegalDocumentKind {
  String get title => switch (this) {
    LegalDocumentKind.userAgreement => '无限花火用户服务协议',
    LegalDocumentKind.privacyPolicy => '无限花火隐私政策',
  };

  String get route => switch (this) {
    LegalDocumentKind.userAgreement => '/legal/user-agreement',
    LegalDocumentKind.privacyPolicy => '/legal/privacy-policy',
  };

  String get assetPath => switch (this) {
    LegalDocumentKind.userAgreement => 'assets/legal/user_service_agreement.md',
    LegalDocumentKind.privacyPolicy => 'assets/legal/privacy_policy.md',
  };

  String get version => '2026-08-20';
}

class LegalDocumentPage extends StatefulWidget {
  const LegalDocumentPage({required this.kind, super.key});

  final LegalDocumentKind kind;

  @override
  State<LegalDocumentPage> createState() => _LegalDocumentPageState();
}

class _LegalDocumentPageState extends State<LegalDocumentPage> {
  late Future<String> _document;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant LegalDocumentPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind) _reload();
  }

  void _reload() {
    _document = rootBundle.loadString(widget.kind.assetPath);
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3PageScaffold(
      title: widget.kind.title,
      subtitle: '版本 ${widget.kind.version}',
      fallbackRoute: '/auth',
      children: [
        FutureBuilder<String>(
          future: _document,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(child: CircularProgressIndicator.adaptive()),
              );
            }
            final source = snapshot.data?.trim();
            if (snapshot.hasError || source == null || source.isEmpty) {
              return Padding(
                padding: const EdgeInsets.only(top: 64),
                child: Column(
                  children: [
                    Text('协议暂时无法读取', style: TextStyle(color: colors.muted)),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: () => setState(_reload),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重新加载'),
                    ),
                  ],
                ),
              );
            }
            return V3AssistantReplyMarkdown(
              key: ValueKey<String>('legal-document-${widget.kind.name}'),
              source: source,
            );
          },
        ),
      ],
    );
  }
}
