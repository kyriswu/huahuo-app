import 'package:flutter/material.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../application/account_usage_controller.dart';
import '../domain/account_usage_models.dart';

class AccountUsagePanel extends StatelessWidget {
  const AccountUsagePanel({required this.controller, super.key});

  final AccountUsageController controller;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final membership = controller.membership;
    final summary = controller.creditSummary;
    final preferMembership =
        controller.creditErrorCode != null &&
        controller.membershipErrorCode == null;
    final monthly = preferMembership
        ? membership?.monthlyCredit
        : summary?.monthlyCredit ?? membership?.monthlyCredit;
    final permanent = preferMembership
        ? membership?.permanentCredit
        : summary?.permanentCredit ?? membership?.permanentCredit;
    final admission = preferMembership
        ? membership?.runAdmission
        : summary?.runAdmission ?? membership?.runAdmission;
    final uncovered = preferMembership
        ? membership?.outstandingUncoveredCredits
        : summary?.outstandingUncoveredCredits ??
              membership?.outstandingUncoveredCredits;
    final storage = controller.storageUsage;
    final quotas = controller.quotaBalances ?? const <MobileQuotaBalance>[];
    final asr = quotas.where((balance) => balance.quotaType == 'asr_seconds');
    final transcription = asr.isEmpty ? null : asr.first;
    final otherMeters = quotas.where(
      (balance) =>
          balance.quotaType == 'generation' || balance.quotaType == 'token',
    );
    return Column(
      key: const ValueKey('account-usage-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '用量与空间',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            TextButton.icon(
              key: const ValueKey('account-usage-refresh'),
              onPressed: controller.loading ? null : controller.load,
              icon: controller.loading
                  ? const SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded, size: 18),
              label: Text(controller.loading ? '同步中' : '刷新'),
            ),
          ],
        ),
        if (controller.updatedAt != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              '最近同步 ${_dateTime(controller.updatedAt!)} · 用量以服务端结算为准',
              style: TextStyle(color: colors.muted, fontSize: 11, height: 1.5),
            ),
          ),
        _UsageCard(
          title: 'AI 算力额度',
          icon: Icons.auto_awesome_outlined,
          children: [
            if (monthly == null || permanent == null)
              _Unavailable(loading: controller.loading, label: '额度暂不可用')
            else ...[
              _ValueRow(
                '可用总额度',
                '${_number(monthly.availableCredits + permanent.availableCredits)} 点',
                prominent: true,
              ),
              _ValueRow(
                '本月可用 / 总额',
                '${_number(monthly.availableCredits)} / ${_optionalNumber(monthly.quotaCredits)} 点',
              ),
              _ValueRow('永久可用', '${_number(permanent.availableCredits)} 点'),
              if (monthly.quotaCredits != null &&
                  monthly.settledCredits != null)
                _UsageProgress(
                  used: monthly.settledCredits!,
                  limit: monthly.quotaCredits!,
                  label: '本月已结算',
                ),
              _Details(
                title: '额度明细',
                children: [
                  _ValueRow(
                    '本月已结算',
                    '${_optionalNumber(monthly.settledCredits)} 点',
                  ),
                  _ValueRow('本月预留', '${_number(monthly.reservedCredits)} 点'),
                  _ValueRow('永久预留', '${_number(permanent.reservedCredits)} 点'),
                  _ValueRow('待补足额度', '${_optionalNumber(uncovered)} 点'),
                  _ValueRow('运行权限', switch (admission) {
                    'allowed' => '正常',
                    'blocked_uncovered_credit' => '待补足额度后恢复',
                    _ => '暂不可用',
                  }),
                  _Period(start: monthly.periodStart, end: monthly.periodEnd),
                  if (monthly.expiresAt != null)
                    _ValueRow(
                      '本月额度到期',
                      _dateTime(monthly.expiresAt!, utc: true),
                    ),
                  const _Hint('预留额度是处理中任务的占用，不等于已消耗；永久额度不随月度周期清零。'),
                  if (controller.creditLots.isNotEmpty)
                    _Details(
                      title: '永久额度来源记录',
                      children: [
                        for (final lot in controller.creditLots)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _ValueRow(
                                  _origin(lot.originKind),
                                  _dateTime(lot.createdAt),
                                ),
                                _ValueRow(
                                  '发放 / 可用 / 预留',
                                  '${_number(lot.originalCredits)} / ${_number(lot.availableCredits)} / ${_number(lot.reservedCredits)} 点',
                                ),
                              ],
                            ),
                          ),
                        if (controller.hasMoreCredits)
                          TextButton(
                            onPressed:
                                controller.loading ||
                                    controller.loadingMoreCredits
                                ? null
                                : controller.loadMoreCredits,
                            child: Text(
                              controller.loadingMoreCredits
                                  ? '加载中'
                                  : '查看更多来源记录',
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ],
            if (controller.creditErrorCode != null ||
                controller.membershipErrorCode != null)
              const _Hint('部分额度信息未能更新；保留可用数据，请刷新重试。'),
          ],
        ),
        const SizedBox(height: 10),
        _UsageCard(
          title: '云空间',
          icon: Icons.cloud_outlined,
          children: [
            if (storage == null)
              _Unavailable(loading: controller.loading, label: '云空间暂不可用')
            else ...[
              _ValueRow(
                '已用 / 总容量',
                '${_bytes(storage.userLogicalTotalBytes)} / ${_bytes(storage.limitBytes)}',
                prominent: true,
              ),
              _UsageProgress(
                used: storage.userLogicalTotalBytes,
                limit: storage.limitBytes,
                label: '空间使用率',
              ),
              _ValueRow('剩余空间', _bytes(storage.remainingBytes)),
              if (storage.userLogicalTotalBytes > storage.limitBytes)
                const _Hint('云空间已超出容量，请清理不需要的内容。'),
              if (storage.measurementStatus == 'partial')
                const _Hint('部分文件尚未完成计量，当前已用量可能偏低。'),
              _Details(
                title: '空间明细',
                children: [
                  const _Hint('上方为账号全部工作区的总用量；以下分类仅属于当前工作区。'),
                  _ValueRow(
                    '当前工作区合计',
                    _optionalBytes(storage.logicalTotalBytes),
                  ),
                  _ValueRow(
                    '笔记正文',
                    _optionalBytes(storage.currentContentBytes),
                  ),
                  _ValueRow(
                    '保留的历史版本',
                    _optionalBytes(storage.retainedHistoryBytes),
                  ),
                  _ValueRow('录音等资源文件', _optionalBytes(storage.resourceBytes)),
                  _ValueRow(
                    '其他工作区文件',
                    _optionalBytes(storage.formalProjectionBytes),
                  ),
                  _ValueRow(
                    '文件数量上限',
                    storage.fileCountLimit == null
                        ? '不设数量上限'
                        : '${_number(storage.fileCountLimit!)} 个',
                  ),
                  _ValueRow(
                    '计量状态',
                    storage.measurementStatus == 'complete' ? '计量完整' : '部分计量',
                  ),
                  if (storage.unmeasuredObjectCount != null)
                    _ValueRow(
                      '账号待计量对象',
                      '${_number(storage.unmeasuredObjectCount!)} 个',
                    ),
                  if (storage.calculatedAt != null)
                    _ValueRow('服务端统计时间', _dateTime(storage.calculatedAt!)),
                  const _Hint('容量使用二进制单位：1 GiB = 1024 MiB。'),
                ],
              ),
            ],
            if (controller.storageErrorCode != null && storage != null)
              const _Hint('云空间更新失败，当前为上次数据，请刷新重试。'),
          ],
        ),
        const SizedBox(height: 10),
        _UsageCard(
          title: '语音转写',
          icon: Icons.graphic_eq_rounded,
          children: [
            if (transcription == null)
              _Unavailable(loading: controller.loading, label: '转写用量暂不可用')
            else ...[
              _ValueRow(
                '本期已用时长',
                _duration(transcription.used),
                prominent: true,
              ),
              _ValueRow('可用时长', _duration(transcription.remaining)),
              _UsageProgress(
                used: transcription.used,
                limit: transcription.effectiveLimit,
                label: '转写使用率',
              ),
              _Details(
                title: '转写明细',
                children: [
                  ..._meterDetails(transcription),
                  const _Hint('包含已由服务端结算的实时转写和文件转写；不是本机录音总时长，也不是累计历史时长。'),
                ],
              ),
            ],
            if (controller.quotaErrorCode != null && transcription != null)
              const _Hint('转写用量更新失败，当前为上次数据，请刷新重试。'),
          ],
        ),
        if (otherMeters.isNotEmpty) ...[
          const SizedBox(height: 10),
          _UsageCard(
            title: '其他服务计量',
            icon: Icons.data_usage_rounded,
            children: [
              _Details(
                title: '查看生成次数与 Token 计量',
                children: [
                  const _Hint('这是服务端独立计量项，不与上方 AI 算力相加，也不换算成算力额度。'),
                  for (final meter in otherMeters) ...[
                    _ValueRow(
                      meter.quotaType == 'generation' ? '服务生成次数' : 'Token 计量',
                      '已用 ${_meterAmount(meter, meter.used)}',
                    ),
                    ..._meterDetails(meter),
                    const SizedBox(height: 8),
                  ],
                  if (controller.quotaErrorCode != null)
                    const _Hint('计量更新失败，当前为上次数据。'),
                ],
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _UsageCard extends StatelessWidget {
  const _UsageCard({
    required this.title,
    required this.icon,
    required this.children,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => V3Card(
    glass: false,
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, size: 19, color: HuahuoV3Theme.tokensOf(context).muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    ),
  );
}

class _ValueRow extends StatelessWidget {
  const _ValueRow(this.label, this.value, {this.prominent = false});
  final String label;
  final String value;
  final bool prominent;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final caption = Text(
          label,
          style: TextStyle(
            color: HuahuoV3Theme.tokensOf(context).muted,
            fontSize: 12,
          ),
        );
        final content = Text(
          value,
          style: TextStyle(
            fontSize: prominent ? 16 : 12,
            fontWeight: prominent ? FontWeight.w600 : FontWeight.w400,
          ),
        );
        if (constraints.maxWidth < 300 ||
            MediaQuery.textScalerOf(context).scale(12) > 17) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [caption, const SizedBox(height: 3), content],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 2, child: caption),
            const SizedBox(width: 12),
            Flexible(
              flex: 3,
              child: Align(alignment: Alignment.centerRight, child: content),
            ),
          ],
        );
      },
    ),
  );
}

class _UsageProgress extends StatelessWidget {
  const _UsageProgress({
    required this.used,
    required this.limit,
    required this.label,
  });
  final num used;
  final num limit;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ratio = limit > 0 ? used / limit : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ValueRow(
          label,
          ratio == null ? '无可用配额' : '${(ratio * 100).toStringAsFixed(1)}%',
        ),
        LinearProgressIndicator(
          value: ratio?.clamp(0, 1).toDouble() ?? (used > 0 ? 1 : 0),
          minHeight: 5,
          borderRadius: BorderRadius.circular(4),
          color: used > limit ? HuahuoV3Theme.tokensOf(context).danger : null,
        ),
        const SizedBox(height: 6),
      ],
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    childrenPadding: EdgeInsets.zero,
    shape: const Border(),
    collapsedShape: const Border(),
    title: Text(title, style: const TextStyle(fontSize: 12)),
    children: [
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ],
  );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Text(
      text,
      style: TextStyle(
        color: HuahuoV3Theme.tokensOf(context).muted,
        fontSize: 11,
        height: 1.5,
      ),
    ),
  );
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.loading, required this.label});
  final bool loading;
  final String label;

  @override
  Widget build(BuildContext context) =>
      _Hint(loading ? '正在读取服务端用量…' : '$label，请点击上方刷新重试。');
}

class _Period extends StatelessWidget {
  const _Period({required this.start, required this.end});
  final DateTime? start;
  final DateTime? end;

  @override
  Widget build(BuildContext context) => _Hint(
    start == null || end == null
        ? '统计周期暂未提供'
        : '统计周期 ${_dateTime(start!, utc: true)} 至 ${_dateTime(end!, utc: true)}（结束时刻不含在内）',
  );
}

List<Widget> _meterDetails(MobileQuotaBalance balance) => [
  _ValueRow('基础配额', _meterAmount(balance, balance.limit)),
  _ValueRow('配额调整', _meterAmount(balance, balance.adjusted)),
  _ValueRow('当前总配额', _meterAmount(balance, balance.effectiveLimit)),
  _ValueRow('已预留', _meterAmount(balance, balance.reserved)),
  _ValueRow('可用余额', _meterAmount(balance, balance.remaining)),
  _ValueRow('超额待补足', _meterAmount(balance, balance.uncovered)),
  _Period(start: balance.periodStart, end: balance.periodEnd),
];

String _meterAmount(MobileQuotaBalance balance, num amount) =>
    switch (balance.quotaType) {
      'asr_seconds' => _duration(amount),
      'generation' => '${_number(amount)} 次',
      _ => '${_number(amount)} Token',
    };

String _number(num value) {
  final text = value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(2);
  final parts = text.split('.');
  final whole = parts.first.replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
    (match) => '${match[1]},',
  );
  return parts.length == 1 ? whole : '$whole.${parts.last}';
}

String _optionalNumber(num? value) => value == null ? '—' : _number(value);
String _optionalBytes(int? value) => value == null ? '暂不可用' : _bytes(value);

String _bytes(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${_number(value / 1024)} KiB';
  if (value < 1024 * 1024 * 1024) {
    return '${_number(value / (1024 * 1024))} MiB';
  }
  return '${_number(value / (1024 * 1024 * 1024))} GiB';
}

String _duration(num seconds) {
  final absolute = seconds.abs();
  final hours = absolute ~/ 3600;
  final minutes = (absolute % 3600) ~/ 60;
  final remainder = absolute % 60;
  final parts = [
    if (hours > 0) '$hours 小时',
    if (minutes > 0) '$minutes 分',
    if (remainder > 0 || (hours == 0 && minutes == 0))
      '${_number(remainder)} 秒',
  ];
  return '${seconds < 0 ? '−' : ''}${parts.join(' ')}';
}

String _dateTime(DateTime value, {bool utc = false}) {
  final date = utc ? value.toUtc() : value.toLocal();
  String padded(int value) => value.toString().padLeft(2, '0');
  return '${date.year}/${padded(date.month)}/${padded(date.day)} ${padded(date.hour)}:${padded(date.minute)}${utc ? ' UTC' : ''}';
}

String _origin(String value) => switch (value) {
  'admin_grant' => '额度发放',
  'admin_adjustment' => '额度调整',
  'migration' => '历史额度迁入',
  'future_catalog' => '商品权益',
  _ => '额度入账',
};
