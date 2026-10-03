import 'package:flutter/material.dart';

import '../theme/huahuo_v3_theme.dart';
import 'v3_components.dart';
import 'v3_glass_foundations.dart';
import 'v3_text_editing.dart';

@immutable
final class V3ActionSheetItem<T> {
  const V3ActionSheetItem({
    required this.value,
    required this.icon,
    required this.label,
    this.subtitle,
    this.sectionLabel,
    this.selected = false,
    this.enabled = true,
    this.destructive = false,
    this.key,
  });

  final T value;
  final IconData icon;
  final String label;
  final String? subtitle;
  final String? sectionLabel;
  final bool selected;
  final bool enabled;
  final bool destructive;
  final Key? key;
}

Future<T?> showV3ActionSheet<T>({
  required BuildContext context,
  required List<V3ActionSheetItem<T>> items,
  String? title,
  String? message,
  String? cancelLabel,
  Key? listKey,
}) {
  return showV3GlassBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => V3SheetScaffold(
      title: title,
      message: message,
      child: Flexible(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              fit: FlexFit.loose,
              child: ListView.builder(
                key: listKey,
                shrinkWrap: true,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.manual,
                padding: const EdgeInsets.only(bottom: HuahuoSpacing.compact),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final tokens = HuahuoV3Theme.tokensOf(context);
                  final item = items[index];
                  final previousSection = index == 0
                      ? null
                      : items[index - 1].sectionLabel;
                  final showSection =
                      item.sectionLabel != null &&
                      item.sectionLabel != previousSection;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (showSection)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            HuahuoSpacing.page,
                            HuahuoSpacing.sm,
                            HuahuoSpacing.page,
                            HuahuoSpacing.xxs,
                          ),
                          child: Text(
                            item.sectionLabel!,
                            style: HuahuoV3Theme.meta.copyWith(
                              color: tokens.muted,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      _V3ActionSheetRow<T>(key: item.key, item: item),
                    ],
                  );
                },
              ),
            ),
            if (cancelLabel != null) ...[
              const SizedBox(height: HuahuoSpacing.xxs),
              OutlinedButton(
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: Text(cancelLabel),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class V3SheetScaffold extends StatelessWidget {
  const V3SheetScaffold({
    required this.child,
    this.title,
    this.message,
    this.showClose = false,
    this.maxHeightFactor = .72,
    super.key,
  });

  final Widget child;
  final String? title;
  final String? message;
  final bool showClose;
  final double maxHeightFactor;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final mediaQuery = MediaQuery.of(context);
    final baseAvailableHeight =
        mediaQuery.size.height -
        mediaQuery.viewInsets.bottom -
        mediaQuery.padding.bottom;
    final preferredMaxHeight = baseAvailableHeight * maxHeightFactor;
    final safeMaxHeight = baseAvailableHeight - mediaQuery.viewPadding.top;
    final maxHeight = preferredMaxHeight < safeMaxHeight
        ? preferredMaxHeight
        : safeMaxHeight;
    return SafeArea(
      top: false,
      left: true,
      right: true,
      bottom: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: maxHeight.clamp(0.0, mediaQuery.size.height),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            HuahuoSpacing.page,
            HuahuoSpacing.xxs,
            HuahuoSpacing.page,
            HuahuoSpacing.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null || showClose)
                Row(
                  children: [
                    if (title != null)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            0,
                            HuahuoSpacing.compact,
                            HuahuoSpacing.compact,
                            HuahuoSpacing.xxs,
                          ),
                          child: Text(
                            title!,
                            style: HuahuoV3Theme.sectionTitle,
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    if (showClose)
                      V3CloseButton(
                        onPressed: () {
                          FocusManager.instance.primaryFocus?.unfocus();
                          Navigator.of(context).pop();
                        },
                      ),
                  ],
                ),
              if (message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: HuahuoSpacing.compact),
                  child: Text(
                    message!,
                    style: HuahuoV3Theme.body.copyWith(color: tokens.muted),
                  ),
                ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class V3GlassDialogFrame extends StatelessWidget {
  const V3GlassDialogFrame({
    required this.title,
    required this.content,
    required this.actions,
    this.insetPadding,
    this.borderRadius,
    super.key,
  });

  final String title;
  final Widget content;
  final List<Widget> actions;
  final EdgeInsets? insetPadding;
  final double? borderRadius;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final colors = HuahuoV3Theme.tokensOf(context);
    final radius = borderRadius ?? HuahuoRadius.emphasized;
    final unobscuredHeight =
        mediaQuery.size.height -
        mediaQuery.viewInsets.bottom -
        mediaQuery.viewPadding.top -
        mediaQuery.padding.bottom;
    final compactKeyboard =
        mediaQuery.viewInsets.bottom > 0 && unobscuredHeight < 280;
    final resolvedInsetPadding =
        insetPadding ??
        (compactKeyboard
            ? const EdgeInsets.symmetric(
                horizontal: HuahuoSpacing.page,
                vertical: HuahuoSpacing.xxs,
              )
            : const EdgeInsets.symmetric(
                horizontal: HuahuoSpacing.page,
                vertical: HuahuoSpacing.xl,
              ));
    final maxHeight = compactKeyboard
        ? unobscuredHeight - resolvedInsetPadding.vertical
        : mediaQuery.size.height -
              mediaQuery.viewInsets.bottom -
              mediaQuery.padding.vertical -
              (HuahuoSpacing.xl * 2);
    return SafeArea(
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: HuahuoElevation.flat,
        insetPadding: resolvedInsetPadding,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight.clamp(0.0, 640.0)),
          child: V3GlassHomeScope(
            enabled: false,
            child: Material(
              color: colors.surface,
              elevation: HuahuoElevation.floating,
              shadowColor: colors.ink.withValues(alpha: .1),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radius),
                side: BorderSide(color: colors.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compactKeyboard
                      ? HuahuoSpacing.compact
                      : HuahuoSpacing.page,
                  vertical: compactKeyboard
                      ? HuahuoSpacing.compact
                      : HuahuoSpacing.page,
                ),
                child: compactKeyboard
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Flexible(
                            fit: FlexFit.loose,
                            child: SingleChildScrollView(
                              key: const ValueKey(
                                'v3-dialog-compact-content-scroll',
                              ),
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.manual,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    title,
                                    style: HuahuoTypography.sectionTitle,
                                  ),
                                  const SizedBox(height: HuahuoSpacing.xxs),
                                  content,
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: HuahuoSpacing.xxs),
                          Wrap(
                            alignment: WrapAlignment.end,
                            spacing: HuahuoSpacing.compact,
                            runSpacing: HuahuoSpacing.xxs,
                            children: actions,
                          ),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(title, style: HuahuoTypography.sectionTitle),
                          const SizedBox(height: HuahuoSpacing.sm),
                          Flexible(
                            fit: FlexFit.loose,
                            child: SingleChildScrollView(
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.manual,
                              child: content,
                            ),
                          ),
                          const SizedBox(height: HuahuoSpacing.section),
                          Wrap(
                            alignment: WrapAlignment.end,
                            spacing: HuahuoSpacing.compact,
                            runSpacing: HuahuoSpacing.compact,
                            children: actions,
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<String?> showV3TextInputDialog({
  required BuildContext context,
  required String title,
  required String initialValue,
  required String label,
  String confirmLabel = '保存',
  String cancelLabel = '取消',
  int? maxLength,
  String? Function(String value)? validator,
  ValueKey<String>? inputKey,
}) async {
  final route = ModalRoute.of(context);
  if (route != null && !route.isCurrent) return null;
  FocusManager.instance.primaryFocus?.unfocus();
  try {
    return await showDialog<String>(
      context: context,
      builder: (dialogContext) => _V3TextInputDialog(
        title: title,
        initialValue: initialValue,
        label: label,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        maxLength: maxLength,
        validator: validator,
        inputKey: inputKey,
      ),
    );
  } finally {
    FocusManager.instance.primaryFocus?.unfocus();
  }
}

Future<String?> showV3TextInputSheet({
  required BuildContext context,
  required String title,
  required String initialValue,
  required String label,
  String confirmLabel = '保存',
  String cancelLabel = '取消',
  int? maxLength,
  String? Function(String value)? validator,
  ValueKey<String>? inputKey,
  IconData? prefixIcon,
  List<String> suggestions = const <String>[],
}) async {
  try {
    return await showV3GlassBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _V3TextInputSheet(
        title: title,
        initialValue: initialValue,
        label: label,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        maxLength: maxLength,
        validator: validator,
        inputKey: inputKey,
        prefixIcon: prefixIcon,
        suggestions: suggestions,
      ),
    );
  } finally {
    FocusManager.instance.primaryFocus?.unfocus();
  }
}

Future<bool> showV3DestructiveConfirmationSheet({
  required BuildContext context,
  required String title,
  required String message,
  required String itemLabel,
  String? warning,
  String confirmLabel = '删除',
  String cancelLabel = '取消',
  IconData itemIcon = Icons.delete_outline_rounded,
}) async {
  final confirmed = await showV3GlassBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      final colors = HuahuoV3Theme.tokensOf(sheetContext);
      return V3SheetScaffold(
        title: title,
        showClose: true,
        maxHeightFactor: .9,
        child: Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  key: const ValueKey(
                    'v3-destructive-confirmation-body-scroll',
                  ),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.manual,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(message, style: HuahuoV3Theme.meta),
                      const SizedBox(height: HuahuoSpacing.compact),
                      Container(
                        constraints: const BoxConstraints(minHeight: 52),
                        padding: const EdgeInsets.symmetric(
                          horizontal: HuahuoSpacing.compact,
                          vertical: HuahuoSpacing.sm,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: colors.primary),
                          borderRadius: BorderRadius.circular(
                            HuahuoRadius.control,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(itemIcon, size: 18, color: colors.primary),
                            const SizedBox(width: HuahuoSpacing.compact),
                            Expanded(
                              child: Text(
                                itemLabel,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: HuahuoV3Theme.body.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (warning != null) ...[
                        const SizedBox(height: HuahuoSpacing.compact),
                        Text(warning, style: HuahuoV3Theme.meta),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: HuahuoSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(sheetContext).pop(false),
                      child: Text(cancelLabel),
                    ),
                  ),
                  const SizedBox(width: HuahuoSpacing.compact),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: () => Navigator.of(sheetContext).pop(true),
                      child: Text(confirmLabel),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  return confirmed ?? false;
}

class _V3TextInputDialog extends StatefulWidget {
  const _V3TextInputDialog({
    required this.title,
    required this.initialValue,
    required this.label,
    required this.confirmLabel,
    required this.cancelLabel,
    this.maxLength,
    this.validator,
    this.inputKey,
  });

  final String title;
  final String initialValue;
  final String label;
  final String confirmLabel;
  final String cancelLabel;
  final int? maxLength;
  final String? Function(String value)? validator;
  final ValueKey<String>? inputKey;

  @override
  State<_V3TextInputDialog> createState() => _V3TextInputDialogState();
}

class _V3TextInputDialogState extends State<_V3TextInputDialog> {
  late final TextEditingController _controller;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    final error = widget.validator?.call(value);
    if (error != null) {
      setState(() => _errorText = error);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return V3GlassDialogFrame(
      title: widget.title,
      content: TextField(
        key: widget.inputKey,
        controller: _controller,
        contextMenuBuilder: V3TextEditing.buildContextMenu,
        autofocus: true,
        maxLength: widget.maxLength,
        textInputAction: TextInputAction.done,
        onChanged: (_) {
          if (_errorText != null) setState(() => _errorText = null);
        },
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: widget.label,
          errorText: _errorText,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

class _V3TextInputSheet extends StatefulWidget {
  const _V3TextInputSheet({
    required this.title,
    required this.initialValue,
    required this.label,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.suggestions,
    this.maxLength,
    this.validator,
    this.inputKey,
    this.prefixIcon,
  });

  final String title;
  final String initialValue;
  final String label;
  final String confirmLabel;
  final String cancelLabel;
  final int? maxLength;
  final String? Function(String value)? validator;
  final ValueKey<String>? inputKey;
  final IconData? prefixIcon;
  final List<String> suggestions;

  @override
  State<_V3TextInputSheet> createState() => _V3TextInputSheetState();
}

class _V3TextInputSheetState extends State<_V3TextInputSheet> {
  late final TextEditingController _controller;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setValue(String value) {
    _controller
      ..text = value
      ..selection = TextSelection.collapsed(offset: value.length);
    if (_errorText != null) setState(() => _errorText = null);
  }

  void _submit() {
    final value = _controller.text.trim();
    final error = widget.validator?.call(value);
    if (error != null) {
      setState(() => _errorText = error);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final bottomInset = mediaQuery.viewInsets.bottom;
    final keyboardVisible = bottomInset > 0;
    const glassSheetHandleExtent = 20.0;
    final keyboardMaxHeight =
        (mediaQuery.size.height - bottomInset - glassSheetHandleExtent)
            .clamp(0.0, mediaQuery.size.height)
            .toDouble();
    return AnimatedPadding(
      padding: EdgeInsets.only(bottom: bottomInset),
      duration: V3MotionTokens.resolve(context, V3MotionTokens.standard),
      curve: Curves.easeOutCubic,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: keyboardVisible ? keyboardMaxHeight : double.infinity,
        ),
        child: V3SheetScaffold(
          title: widget.title,
          showClose: true,
          maxHeightFactor: keyboardVisible ? 1 : .74,
          child: Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    key: const ValueKey('v3-text-input-sheet-scroll'),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.manual,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(widget.label, style: HuahuoV3Theme.meta),
                        const SizedBox(height: HuahuoSpacing.compact),
                        TextField(
                          key: widget.inputKey,
                          controller: _controller,
                          contextMenuBuilder: V3TextEditing.buildContextMenu,
                          autofocus: true,
                          maxLength: widget.maxLength,
                          textInputAction: TextInputAction.done,
                          onChanged: (_) {
                            if (_errorText != null) {
                              setState(() => _errorText = null);
                            }
                          },
                          onSubmitted: (_) => _submit(),
                          decoration: InputDecoration(
                            prefixIcon: widget.prefixIcon == null
                                ? null
                                : Icon(widget.prefixIcon, size: 19),
                            errorText: _errorText,
                          ),
                        ),
                        if (widget.suggestions.isNotEmpty) ...[
                          const SizedBox(height: HuahuoSpacing.xxs),
                          const Text('推荐命名', style: HuahuoV3Theme.meta),
                          const SizedBox(height: HuahuoSpacing.compact),
                          for (final suggestion in widget.suggestions)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: HuahuoSpacing.xxs,
                              ),
                              child: Material(
                                color: HuahuoV3Theme.tokensOf(
                                  context,
                                ).surfaceMuted,
                                borderRadius: BorderRadius.circular(
                                  HuahuoRadius.control,
                                ),
                                child: InkWell(
                                  key: ValueKey<String>(
                                    'text-input-suggestion-$suggestion',
                                  ),
                                  onTap: () => _setValue(suggestion),
                                  borderRadius: BorderRadius.circular(
                                    HuahuoRadius.control,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: HuahuoSpacing.compact,
                                      vertical: HuahuoSpacing.sm,
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.lightbulb_outline_rounded,
                                          size: 18,
                                        ),
                                        const SizedBox(
                                          width: HuahuoSpacing.compact,
                                        ),
                                        Expanded(child: Text(suggestion)),
                                        const Icon(Icons.add_rounded, size: 19),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: HuahuoSpacing.compact),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(widget.cancelLabel),
                      ),
                    ),
                    const SizedBox(width: HuahuoSpacing.compact),
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        onPressed: _submit,
                        child: Text(widget.confirmLabel),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _V3ActionSheetRow<T> extends StatelessWidget {
  const _V3ActionSheetRow({required this.item, super.key});

  final V3ActionSheetItem<T> item;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final baseColor = item.destructive ? tokens.danger : tokens.ink;
    final color = item.enabled ? baseColor : baseColor.withValues(alpha: .45);
    return Semantics(
      button: true,
      enabled: item.enabled,
      selected: item.selected,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: item.enabled
              ? () => Navigator.of(context).pop(item.value)
              : null,
          borderRadius: BorderRadius.circular(HuahuoRadius.control),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HuahuoSpacing.page,
                vertical: HuahuoSpacing.compact,
              ),
              child: Row(
                children: [
                  Icon(item.icon, size: 20, color: color),
                  const SizedBox(width: HuahuoSpacing.sm),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.label,
                          style: HuahuoV3Theme.body.copyWith(
                            color: color,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (item.subtitle != null) ...[
                          const SizedBox(height: HuahuoSpacing.xxs),
                          Text(
                            item.subtitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: HuahuoV3Theme.meta.copyWith(
                              color: item.enabled
                                  ? tokens.muted
                                  : tokens.muted.withValues(alpha: .55),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (item.selected)
                    Icon(
                      Icons.check_rounded,
                      size: 20,
                      color: item.enabled
                          ? tokens.ink
                          : tokens.muted.withValues(alpha: .55),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
