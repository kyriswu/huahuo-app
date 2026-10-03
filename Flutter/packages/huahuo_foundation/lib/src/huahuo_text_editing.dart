import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract final class HuahuoTextEditing {
  static const String copyLabel = '复制';

  static Future<void> writePlainText(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  static Widget buildEditableContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) => AdaptiveTextSelectionToolbar.buttonItems(
    anchors: editableTextState.contextMenuAnchors,
    buttonItems: localizeButtonItems(
      context,
      editableTextState.contextMenuButtonItems,
    ),
  );

  static Widget buildSelectableContextMenu(
    BuildContext context,
    SelectableRegionState selectableRegionState,
  ) => AdaptiveTextSelectionToolbar.buttonItems(
    anchors: selectableRegionState.contextMenuAnchors,
    buttonItems: localizeButtonItems(
      context,
      selectableRegionState.contextMenuButtonItems,
    ),
  );

  static Widget buildRawContextMenu(
    BuildContext context, {
    required TextSelectionToolbarAnchors anchors,
    required Iterable<ContextMenuButtonItem> buttonItems,
    bool useTextFieldTapRegion = false,
  }) {
    final toolbar = AdaptiveTextSelectionToolbar.buttonItems(
      anchors: anchors,
      buttonItems: localizeButtonItems(context, buttonItems),
    );
    return useTextFieldTapRegion ? TextFieldTapRegion(child: toolbar) : toolbar;
  }

  static List<ContextMenuButtonItem> localizeButtonItems(
    BuildContext context,
    Iterable<ContextMenuButtonItem> items,
  ) => items
      .map((item) => item.copyWith(label: buttonLabel(context, item)))
      .toList(growable: false);

  static String buttonLabel(BuildContext context, ContextMenuButtonItem item) =>
      switch (item.type) {
        ContextMenuButtonType.cut => '剪切',
        ContextMenuButtonType.copy => copyLabel,
        ContextMenuButtonType.paste => '粘贴',
        ContextMenuButtonType.selectAll => '全选',
        ContextMenuButtonType.delete => '删除',
        ContextMenuButtonType.lookUp => '查询',
        ContextMenuButtonType.searchWeb => '网页搜索',
        ContextMenuButtonType.share => '分享',
        ContextMenuButtonType.liveTextInput => '扫描文本',
        ContextMenuButtonType.custom =>
          item.label ??
              AdaptiveTextSelectionToolbar.getButtonLabel(context, item),
      };
}
