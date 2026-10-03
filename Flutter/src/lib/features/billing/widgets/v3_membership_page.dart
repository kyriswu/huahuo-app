import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/legal/legal_document_page.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../application/account_usage_controller.dart';
import '../application/billing_controller.dart';

class V3MembershipPage extends ConsumerStatefulWidget {
  const V3MembershipPage({
    required this.billingController,
    required this.accountUsageController,
    super.key,
  });

  final ChangeNotifierProvider<BillingController> billingController;
  final ChangeNotifierProvider<AccountUsageController> accountUsageController;

  @override
  ConsumerState<V3MembershipPage> createState() => _V3MembershipPageState();
}

class _V3MembershipPageState extends ConsumerState<V3MembershipPage> {
  String? _selectedSKU;
  bool _acceptedAgreements = false;
  String? _acceptedAgreementFingerprint;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() async {
      await Future.wait<void>(<Future<void>>[
        ref.read(widget.billingController).load(),
        ref.read(widget.billingController).loadTransactions(),
        ref.read(widget.accountUsageController).load(),
      ]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(widget.billingController);
    final accountUsage = ref.watch(widget.accountUsageController);
    final state = controller.state;
    final selected = _selectedProduct(state.products);
    final agreementFingerprint = _agreementFingerprint(state.agreements);
    final agreementsAccepted =
        _acceptedAgreements &&
        _acceptedAgreementFingerprint == agreementFingerprint;
    const background = Color(0xFF070817);
    const surface = Color(0xFF121424);
    const text = Color(0xFFF7F7FA);
    const muted = Color(0xFFA9ACB9);
    const gold = Color(0xFFE3B763);
    const line = Color(0xFF292C3C);
    final canPurchase =
        agreementsAccepted &&
        selected != null &&
        controller.canPurchase(selected) &&
        !state.busy;
    return Theme(
      data: HuahuoV3Theme.fromTokens(
        brightness: Brightness.dark,
        tokens: HuahuoV3Theme.darkTokens.copyWith(
          canvas: background,
          surface: surface,
          surfaceMuted: surface,
          ink: text,
          text: text,
          muted: muted,
          primary: gold,
          accent: gold,
          onPrimary: background,
          line: line,
        ),
      ),
      child: Scaffold(
        backgroundColor: background,
        body: SafeArea(
          child: Stack(
            children: [
              SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 154),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 56,
                      child: Row(
                        children: [
                          V3NavigationBackButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                          const Expanded(
                            child: Text(
                              '无限花火会员',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: text,
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Builder(
                            builder: (themedContext) => TextButton(
                              key: const ValueKey('billing-transaction-entry'),
                              onPressed: () =>
                                  _showTransactions(themedContext, controller),
                              child: const Text(
                                '会员记录',
                                style: TextStyle(color: muted, fontSize: 12),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 34),
                    const Text(
                      '让每一次创作，\n都有更强的 AI 支持',
                      style: TextStyle(
                        color: text,
                        fontSize: 30,
                        height: 1.22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      accountUsage.loading
                          ? '正在读取会员状态'
                          : _accountMembershipLabel(
                              accountUsage.membership?.levelCode,
                              accountUsage.membership?.status,
                            ),
                      key: const ValueKey('account-membership-status'),
                      style: const TextStyle(color: muted, fontSize: 13),
                    ),
                    if (accountUsage.membership?.expiresAt != null)
                      Text(
                        '有效期至 ${_dateLabel(accountUsage.membership!.expiresAt!)}',
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                    const SizedBox(height: 32),
                    const Text(
                      '选择会员方案',
                      style: TextStyle(
                        color: text,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (state.products.isEmpty)
                      Container(
                        height: 138,
                        width: double.infinity,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: line),
                        ),
                        child: state.busy
                            ? const CircularProgressIndicator(strokeWidth: 2)
                            : const Text(
                                '会员商品暂不可用',
                                style: TextStyle(color: muted),
                              ),
                      )
                    else
                      SizedBox(
                        height: 156,
                        child: ListView.separated(
                          key: const ValueKey('billing-product-list'),
                          scrollDirection: Axis.horizontal,
                          itemCount: state.products.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 10),
                          itemBuilder: (context, index) {
                            final product = state.products[index];
                            return _BillingProductCard(
                              product: product,
                              selected: selected?.sku == product.sku,
                              onTap: () =>
                                  setState(() => _selectedSKU = product.sku),
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 34),
                    const Text(
                      '三个 Agent，覆盖完整创作链路',
                      style: TextStyle(
                        color: text,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const _MembershipAgentGrid(),
                    const SizedBox(height: 30),
                    const Text(
                      '会员权益',
                      style: TextStyle(
                        color: text,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const _MembershipPerk(
                      icon: Icons.auto_awesome_outlined,
                      title: '更充足的 AI 创作额度',
                      subtitle: '对话、分析与内容生成连续可用',
                    ),
                    const _MembershipPerk(
                      icon: Icons.cloud_outlined,
                      title: '更大的工作区',
                      subtitle: '安全保存录音、笔记与创作资产',
                    ),
                    const _MembershipPerk(
                      icon: Icons.speed_rounded,
                      title: '优先处理',
                      subtitle: '高峰时段也能更快进入创作',
                    ),
                    if (state.errorCode != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        _errorLabel(state.errorCode!),
                        key: const ValueKey('billing-error'),
                        style: const TextStyle(
                          color: Color(0xFFFF8A8A),
                          fontSize: 13,
                        ),
                      ),
                    ],
                    if (state.status == BillingStatus.pending) ...[
                      const SizedBox(height: 14),
                      Container(
                        key: const ValueKey('billing-order-pending'),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: surface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: line),
                        ),
                        child: Row(
                          children: [
                            const Expanded(child: Text('订单正在等待服务端确认')),
                            TextButton(
                              key: const ValueKey('billing-order-retry'),
                              onPressed: controller.retryPendingOrder,
                              child: const Text('重新查询'),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (controller.platform == BillingPlatform.ios) ...[
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              key: const ValueKey('billing-restore-button'),
                              onPressed: state.busy
                                  ? null
                                  : controller.restoreIOSPurchases,
                              icon: const Icon(Icons.restore_rounded, size: 17),
                              label: const Text('恢复购买'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              key: const ValueKey('billing-manage-button'),
                              onPressed: _openSubscriptionManagement,
                              icon: const Icon(
                                Icons.open_in_new_rounded,
                                size: 17,
                              ),
                              label: const Text('管理订阅'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _MembershipPurchaseBar(
                  agreements: state.agreements,
                  agreementsReady: controller.agreementsReady,
                  accepted: agreementsAccepted,
                  enabled: canPurchase,
                  busy: state.busy,
                  label: _purchaseLabel(controller.platform, selected),
                  onAgreementChanged: (value) => setState(() {
                    _acceptedAgreements = value;
                    _acceptedAgreementFingerprint = value
                        ? agreementFingerprint
                        : null;
                  }),
                  onAgreementTap: _showAgreement,
                  onPurchase: () {
                    if (selected != null) _purchase(controller, selected);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showTransactions(
    BuildContext context,
    BillingController controller,
  ) {
    return showV3GlassBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * .72,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const V3SectionTitle('会员记录'),
                  const SizedBox(height: 10),
                  _BillingTransactionSection(controller: controller),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  BillingProduct? _selectedProduct(List<BillingProduct> products) {
    if (products.isEmpty) return null;
    return products.cast<BillingProduct?>().firstWhere(
      (item) => item?.sku == _selectedSKU,
      orElse: () => products.first,
    );
  }

  Future<void> _purchase(
    BillingController controller,
    BillingProduct product,
  ) async {
    if (controller.platform == BillingPlatform.ios) {
      await controller.purchaseIOS(product);
      return;
    }
    final provider = await showV3GlassBottomSheet<BillingProvider>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (product.availableProviders.contains(BillingProvider.wechat))
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline_rounded),
                title: const Text('微信支付'),
                onTap: () =>
                    Navigator.pop(sheetContext, BillingProvider.wechat),
              ),
            if (product.availableProviders.contains(BillingProvider.alipay))
              ListTile(
                leading: const Icon(Icons.account_balance_wallet_outlined),
                title: const Text('支付宝'),
                onTap: () =>
                    Navigator.pop(sheetContext, BillingProvider.alipay),
              ),
          ],
        ),
      ),
    );
    if (provider != null) {
      await controller.purchaseAndroid(product: product, provider: provider);
    }
  }

  Future<void> _showAgreement(BillingAgreement agreement) async {
    if (agreement.type == 'privacy') {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) =>
              const LegalDocumentPage(kind: LegalDocumentKind.privacyPolicy),
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => V3GlassDialog(
        title: _agreementLabel(agreement.type),
        message: '版本 ${agreement.version}',
        primaryLabel: '查看全文',
        onPrimary: () {
          Navigator.pop(dialogContext);
          launchUrl(agreement.url, mode: LaunchMode.externalApplication);
        },
      ),
    );
  }

  Future<void> _openSubscriptionManagement() => launchUrl(
    Uri.parse('https://apps.apple.com/account/subscriptions'),
    mode: LaunchMode.externalApplication,
  );
}

class _MembershipPurchaseBar extends StatelessWidget {
  const _MembershipPurchaseBar({
    required this.agreements,
    required this.agreementsReady,
    required this.accepted,
    required this.enabled,
    required this.busy,
    required this.label,
    required this.onAgreementChanged,
    required this.onAgreementTap,
    required this.onPurchase,
  });

  final List<BillingAgreement> agreements;
  final bool agreementsReady;
  final bool accepted;
  final bool enabled;
  final bool busy;
  final String label;
  final ValueChanged<bool> onAgreementChanged;
  final ValueChanged<BillingAgreement> onAgreementTap;
  final VoidCallback onPurchase;

  @override
  Widget build(BuildContext context) {
    const muted = Color(0xFFA9ACB9);
    const gold = Color(0xFFE3B763);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      decoration: const BoxDecoration(
        color: Color(0xFF0C0D1B),
        border: Border(top: BorderSide(color: Color(0xFF292C3C))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox.square(
                dimension: 28,
                child: Checkbox(
                  key: const ValueKey('billing-agreement-checkbox'),
                  value: accepted,
                  activeColor: gold,
                  checkColor: const Color(0xFF111322),
                  side: const BorderSide(color: muted),
                  onChanged: busy || !agreementsReady
                      ? null
                      : (value) => onAgreementChanged(value ?? false),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Wrap(
                    children: [
                      const Text(
                        '已阅读并同意 ',
                        style: TextStyle(color: muted, fontSize: 11),
                      ),
                      if (!agreementsReady)
                        const Text(
                          '必需协议暂不完整',
                          style: TextStyle(
                            color: Color(0xFFFF8A8A),
                            fontSize: 11,
                          ),
                        ),
                      for (
                        var index = 0;
                        index < agreements.length;
                        index++
                      ) ...[
                        if (index > 0)
                          const Text(
                            '、',
                            style: TextStyle(color: muted, fontSize: 11),
                          ),
                        GestureDetector(
                          onTap: () => onAgreementTap(agreements[index]),
                          child: Text(
                            '《${_agreementLabel(agreements[index].type)}》',
                            style: const TextStyle(color: gold, fontSize: 11),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.icon(
              key: const ValueKey('billing-purchase-button'),
              onPressed: enabled ? onPurchase : null,
              style: FilledButton.styleFrom(
                backgroundColor: gold,
                foregroundColor: const Color(0xFF151207),
                disabledBackgroundColor: const Color(0xFF30313D),
                disabledForegroundColor: muted,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              icon: Icon(
                busy ? Icons.hourglass_top_rounded : Icons.workspace_premium,
                size: 19,
              ),
              label: Text(
                busy ? '处理中' : label,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MembershipAgentGrid extends StatelessWidget {
  const _MembershipAgentGrid();

  @override
  Widget build(BuildContext context) {
    const items = <(IconData, String, String)>[
      (Icons.person_outline_rounded, '个人 IP', '定位与内容方向'),
      (Icons.trending_up_rounded, '获客营销', '选题与转化建议'),
      (Icons.insights_outlined, '视频分析', '拆解与优化表达'),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 10.0;
        final width = (constraints.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final item in items)
              Container(
                width: width,
                height: 76,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF121424),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF292C3C)),
                ),
                child: Row(
                  children: [
                    Icon(item.$1, color: const Color(0xFFE3B763), size: 22),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            item.$2,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            item.$3,
                            style: const TextStyle(
                              color: Color(0xFFA9ACB9),
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MembershipPerk extends StatelessWidget {
  const _MembershipPerk({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 68),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Color(0xFF292C3C))),
    ),
    child: Row(
      children: [
        Icon(icon, color: const Color(0xFFE3B763), size: 21),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: const TextStyle(color: Color(0xFFA9ACB9), fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _BillingTransactionSection extends StatelessWidget {
  const _BillingTransactionSection({required this.controller});

  final BillingController controller;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final status = controller.transactionStatus;
    final items = controller.transactions;
    if ((status == BillingTransactionStatus.idle ||
            status == BillingTransactionStatus.loading) &&
        items.isEmpty) {
      return const SizedBox(
        key: ValueKey('billing-transactions-loading'),
        height: 96,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (items.isEmpty &&
        (status == BillingTransactionStatus.failed ||
            status == BillingTransactionStatus.unavailable)) {
      return Padding(
        key: const ValueKey('billing-transactions-error'),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _errorLabel(
                controller.transactionErrorCode ??
                    'BILLING_TRANSACTIONS_LOAD_FAILED',
              ),
              style: TextStyle(color: colors.danger),
            ),
            const SizedBox(height: 8),
            V3OutlineButton(
              key: const ValueKey('billing-transactions-retry'),
              label: '重试',
              icon: Icons.refresh_rounded,
              onPressed: controller.retryTransactions,
            ),
          ],
        ),
      );
    }
    if (status == BillingTransactionStatus.empty ||
        (status == BillingTransactionStatus.ready && items.isEmpty)) {
      return SizedBox(
        key: const ValueKey('billing-transactions-empty'),
        height: 88,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('暂无交易记录', style: TextStyle(color: colors.muted)),
        ),
      );
    }
    return Column(
      key: const ValueKey('billing-transactions-list'),
      children: [
        V3GroupedList(
          variant: V3CardVariant.flat,
          radius: 0,
          dividerIndent: 45,
          children: [
            for (var index = 0; index < items.length; index++)
              V3GroupedListTile(
                key: ValueKey('billing-transaction-row-$index'),
                minHeight: 60,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: Icon(Icons.receipt_long_rounded, color: colors.accent),
                title: Text(_skuLabel(items[index].sku)),
                trailing: Text(
                  _transactionStatusLabel(items[index].status),
                  style: TextStyle(color: colors.muted, fontSize: 12.5),
                ),
              ),
          ],
        ),
        if (controller.transactionErrorCode != null) ...[
          const SizedBox(height: 8),
          Text(
            _errorLabel(controller.transactionErrorCode!),
            style: TextStyle(color: colors.danger, fontSize: 12.5),
          ),
        ],
        if (controller.hasMoreTransactions) ...[
          const SizedBox(height: 8),
          V3OutlineButton(
            key: const ValueKey('billing-transactions-load-more'),
            label: status == BillingTransactionStatus.loadingMore
                ? '加载中…'
                : '查看更多',
            icon: Icons.expand_more_rounded,
            enabled: status != BillingTransactionStatus.loadingMore,
            onPressed: controller.loadMoreTransactions,
          ),
        ],
      ],
    );
  }
}

class _BillingProductCard extends StatelessWidget {
  const _BillingProductCard({
    required this.product,
    required this.selected,
    required this.onTap,
  });

  final BillingProduct product;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      child: Material(
        color: selected ? const Color(0xFF242235) : const Color(0xFF121424),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? const Color(0xFFE3B763) : const Color(0xFF292C3C),
            width: selected ? 1.4 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        product.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (selected)
                      const Icon(
                        Icons.check_circle_rounded,
                        color: Color(0xFFE3B763),
                        size: 18,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  product.displayPrice ?? '价格暂不可用',
                  maxLines: 1,
                  style: TextStyle(
                    color: product.displayPrice == null
                        ? const Color(0xFFA9ACB9)
                        : const Color(0xFFE3B763),
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  product.benefits.isEmpty
                      ? '查看会员权益'
                      : _benefitLabel(product.benefits.first),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFA9ACB9),
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
                if (!product.enabled)
                  const Text(
                    '当前不可购买',
                    style: TextStyle(color: Color(0xFFFF8A8A), fontSize: 10),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _accountMembershipLabel(String? levelCode, String? membershipStatus) {
  if (levelCode == null || membershipStatus == null) {
    return '会员状态暂不可用';
  }
  final level = switch (levelCode) {
    'pilot_paid' => '试点会员',
    'max' => 'MAX',
    'pro' => 'PRO',
    'free' => '免费用户',
    _ => '会员',
  };
  final status = switch (membershipStatus) {
    'pending' => '待生效',
    'active' => '已生效',
    'grace_period' => '宽限期',
    'cancelled' => '已取消续费',
    'expired' => '已过期',
    'refunded' => '已退款',
    'revoked' => '已撤销',
    _ => '状态未知',
  };
  return '$level · $status';
}

String _dateLabel(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

String _purchaseLabel(BillingPlatform platform, BillingProduct? product) {
  final action = platform == BillingPlatform.ios ? '立即订阅' : '立即购买';
  final price = product?.displayPrice;
  return price == null ? action : '$action $price';
}

String _agreementLabel(String type) => switch (type) {
  'membership_service' => '会员服务协议',
  'purchase_refund' => '购买与退款说明',
  'privacy' => '隐私政策',
  'auto_renew' => '自动续费协议',
  _ => '会员协议',
};

String _agreementFingerprint(List<BillingAgreement> agreements) {
  final values =
      agreements
          .map((agreement) => '${agreement.type}:${agreement.version}')
          .toList(growable: false)
        ..sort();
  return values.join('|');
}

String _benefitLabel(String value) => switch (value) {
  'chat_2_daily' => 'AI 聊一聊 2 次/天',
  'chat_50_daily' => 'AI 聊一聊 50 次/天',
  'asr_500_monthly' => '录音转写 10 分钟/条 · 500 分钟/月',
  'asr_1500_monthly' => '录音转写 30 分钟/条 · 1500 分钟/月',
  'storage_20_gib' => '存储空间 20 GB',
  'storage_500_gib' => '存储空间 500 GB',
  _ => value,
};

String _skuLabel(String sku) => switch (sku) {
  'pro_30d' => 'PRO 30天',
  'pro_365d' => 'PRO 365天',
  'max_365d' => 'MAX 365天',
  _ => '会员商品',
};

String _transactionStatusLabel(String status) => switch (status) {
  'created' => '已创建',
  'provider_pending' => '待支付',
  'paid' => '已支付',
  'granting' => '权益发放中',
  'succeeded' => '已完成',
  'cancelled' => '已取消',
  'closed' => '已关闭',
  'failed' => '失败',
  'refunded' => '已退款',
  'active' => '已生效',
  'grace_period' => '宽限期',
  'expired' => '已过期',
  'revoked' => '已撤销',
  _ => '处理中',
};

String _errorLabel(String code) => switch (code) {
  'BILLING_AUTH_REQUIRED' => '请登录后查看会员与交易信息',
  'BILLING_CATALOG_UNAVAILABLE' => '会员商品加载失败，请重试',
  'BILLING_AGREEMENTS_UNAVAILABLE' => '会员协议暂不完整，无法购买',
  'BILLING_PRODUCT_NOT_FOUND' => '未找到该会员商品',
  'BILLING_PRODUCT_DISABLED' => '该会员商品暂停销售',
  'BILLING_MEMBERSHIP_LOAD_FAILED' => '会员状态加载失败',
  'BILLING_PROVIDER_UNAVAILABLE' => '支付渠道尚未配置，请稍后再试',
  'BILLING_PAYMENT_APP_UNAVAILABLE' => '未检测到对应支付应用',
  'BILLING_STORE_PRODUCT_UNAVAILABLE' => 'App Store 商品或价格暂不可用',
  'BILLING_ORDER_CREATE_FAILED' => '订单创建失败，可重试',
  'BILLING_ORDER_CONFIRM_FAILED' => '订单确认失败，可重试',
  'BILLING_PENDING_ORDER_STORE_FAILED' => '订单恢复信息保存失败',
  'BILLING_ORDER_NOT_FOUND' => '未找到该订单',
  'BILLING_ORDER_STATE_CONFLICT' => '订单状态已变更，请刷新',
  'BILLING_ORDER_RESPONSE_MISMATCH' => '订单信息校验失败',
  'BILLING_ORDER_MEMBERSHIP_INVALID' => '会员权益校验失败',
  'BILLING_ORDER_CANCELLED' => '订单已取消',
  'BILLING_ORDER_CLOSED' => '订单已关闭',
  'BILLING_ORDER_FAILED' => '订单支付失败',
  'BILLING_ORDER_REFUNDED' => '订单已退款',
  'BILLING_PURCHASE_INVALID' => '购买凭证校验失败',
  'BILLING_PURCHASE_FAILED' => '购买失败，请稍后再试',
  'BILLING_PURCHASE_PENDING' => '购买正在验证中',
  'BILLING_PURCHASE_ENTITLEMENT_INVALID' => '购买权益校验失败',
  'BILLING_TRANSACTION_ACCOUNT_MISMATCH' => '该购买已绑定其他账号',
  'BILLING_PROVIDER_RESPONSE_INVALID' => '支付平台响应异常，可重试',
  'IDEMPOTENCY_KEY_CONFLICT' => '购买请求已变更，请重新发起',
  'BILLING_STORE_COMPLETE_FAILED' => 'App Store 交易确认待重试',
  'BILLING_RESTORE_FAILED' => '恢复购买失败，请稍后再试',
  'BILLING_TRANSACTIONS_LOAD_FAILED' => '交易记录加载失败',
  'BILLING_TRANSACTION_CURSOR_INVALID' => '交易记录分页状态异常',
  'API_RESPONSE_INVALID' => '服务端返回的支付数据无法校验',
  _ => '支付状态更新失败（$code）',
};
