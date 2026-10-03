import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:huahuo_foundation/huahuo_foundation.dart';

import 'v3_components.dart';

class V3CenteredInput extends StatefulWidget {
  const V3CenteredInput({
    required this.builder,
    this.minHeight = 44,
    this.focusNode,
    this.enabled = true,
    super.key,
  }) : assert(minHeight >= 0);

  final Widget Function(FocusNode focusNode) builder;
  final double minHeight;
  final FocusNode? focusNode;
  final bool enabled;

  @override
  State<V3CenteredInput> createState() => _V3CenteredInputState();
}

class _V3CenteredInputState extends State<V3CenteredInput> {
  FocusNode? _ownedFocusNode;

  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownedFocusNode ??= FocusNode());

  @override
  void dispose() {
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(minHeight: widget.minHeight),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.enabled ? _focusNode.requestFocus : null,
      child: Center(heightFactor: 1, child: widget.builder(_focusNode)),
    ),
  );
}

class V3SearchTextField extends StatelessWidget {
  const V3SearchTextField({
    required this.fieldKey,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.enabled = true,
    this.style,
    this.hintStyle,
    super.key,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final ValueChanged<String> onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final bool enabled;
  final TextStyle? style;
  final TextStyle? hintStyle;

  @override
  Widget build(BuildContext context) => V3CenteredInput(
    focusNode: focusNode,
    enabled: enabled,
    builder: (inputFocus) => TextField(
      key: fieldKey,
      controller: controller,
      focusNode: inputFocus,
      autofocus: autofocus,
      enabled: enabled,
      contextMenuBuilder: V3TextEditing.buildContextMenu,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      textInputAction: TextInputAction.search,
      textAlignVertical: TextAlignVertical.center,
      style: style,
      decoration: V3TextEditing.inlineDecoration.copyWith(
        hintText: hintText,
        hintStyle: hintStyle,
      ),
    ),
  );
}

abstract final class V3TextEditing {
  static const inlineDecoration = InputDecoration(
    hintStyle: TextStyle(),
    isCollapsed: true,
    constraints: BoxConstraints(),
    filled: false,
    contentPadding: EdgeInsets.zero,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
  );

  static const _plainTextClipboardChannel = MethodChannel(
    'huahuoai/plain_text_clipboard',
  );

  static const String copyLabel = HuahuoTextEditing.copyLabel;
  static const String copySucceededMessage = '已复制';
  static const String copyFailedMessage = '复制失败，请重试';

  static bool canCopy(String text) => text.isNotEmpty;

  static Future<String?> readPlainText() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final value = await _plainTextClipboardChannel.invokeMethod<Object?>(
        'readPlainText',
      );
      return value is String ? value : null;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  static Future<bool> copy(BuildContext context, String text) async {
    if (!canCopy(text)) return false;
    try {
      await HuahuoTextEditing.writePlainText(text);
    } on Object {
      if (context.mounted) showV3Snack(context, copyFailedMessage);
      return false;
    }
    if (context.mounted) showV3Snack(context, copySucceededMessage);
    return true;
  }

  static Widget buildContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) => HuahuoTextEditing.buildEditableContextMenu(context, editableTextState);

  static Widget buildSelectionContextMenu(
    BuildContext context,
    SelectableRegionState selectableRegionState,
  ) => HuahuoTextEditing.buildSelectableContextMenu(
    context,
    selectableRegionState,
  );

  static Widget buildRawContextMenu(
    BuildContext context, {
    required TextSelectionToolbarAnchors anchors,
    required Iterable<ContextMenuButtonItem> buttonItems,
    bool useTextFieldTapRegion = false,
  }) => HuahuoTextEditing.buildRawContextMenu(
    context,
    anchors: anchors,
    buttonItems: buttonItems,
    useTextFieldTapRegion: useTextFieldTapRegion,
  );

  static List<ContextMenuButtonItem> localizeButtonItems(
    BuildContext context,
    Iterable<ContextMenuButtonItem> items,
  ) => HuahuoTextEditing.localizeButtonItems(context, items);

  static String buttonLabel(BuildContext context, ContextMenuButtonItem item) =>
      HuahuoTextEditing.buttonLabel(context, item);
}
