import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_long_running_task_notice.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import 'v3_deposit_picker.dart';

class V3MaterialImportRouteSheet extends StatelessWidget {
  const V3MaterialImportRouteSheet({
    required this.title,
    required this.confirmLabel,
    required this.onClose,
    required this.onConfirm,
    required this.child,
    this.confirmEnabled = true,
    super.key,
  });

  final String title;
  final String confirmLabel;
  final VoidCallback onClose;
  final VoidCallback onConfirm;
  final Widget child;
  final bool confirmEnabled;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final height = MediaQuery.sizeOf(context).height;
    final sheetHeight = math.min(694.0, height);
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          height: sheetHeight,
          width: double.infinity,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.canvas,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.line,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  SizedBox(
                    height: 72,
                    child: Stack(
                      children: [
                        Positioned(
                          left: 20,
                          top: 20,
                          child: V3CloseButton(
                            tooltip: '关闭',
                            onPressed: onClose,
                            color: colors.ink,
                          ),
                        ),
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 20),
                            child: Text(
                              title,
                              style: TextStyle(
                                color: colors.ink,
                                fontSize: 19,
                                height: 1.35,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 20,
                          top: 20,
                          child: SizedBox(
                            width: 84,
                            height: 40,
                            child: FilledButton(
                              onPressed: confirmEnabled ? onConfirm : null,
                              style: FilledButton.styleFrom(
                                padding: EdgeInsets.zero,
                                backgroundColor: colors.primary,
                                foregroundColor: colors.onPrimary,
                                disabledBackgroundColor: colors.surfaceMuted,
                                disabledForegroundColor: colors.muted,
                                shape: const StadiumBorder(),
                              ),
                              child: Text(
                                confirmLabel,
                                style: const TextStyle(
                                  fontSize: 14,
                                  height: 1.4,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(child: child),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class V3MaterialImportProgressSurface extends StatelessWidget {
  const V3MaterialImportProgressSurface({
    required this.sourceLabel,
    required this.sourceIcon,
    required this.title,
    required this.message,
    required this.onBack,
    this.canReturnViaNotifications = false,
    this.sourceAccent = const Color(0xffa5682b),
    super.key,
  });

  final String sourceLabel;
  final IconData sourceIcon;
  final String title;
  final String message;
  final VoidCallback onBack;
  final bool canReturnViaNotifications;
  final Color sourceAccent;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        child: ListView(
          children: [
            SizedBox(
              height: 72,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 22),
                  child: V3NavigationBackButton(
                    tooltip: '返回',
                    onPressed: onBack,
                  ),
                ),
              ),
            ),
            Container(
              height: 60,
              margin: const EdgeInsets.symmetric(horizontal: 22),
              padding: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: colors.line),
              ),
              child: Row(
                children: [
                  Icon(sourceIcon, size: 23, color: colors.ink),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Text(
                      sourceLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: HuahuoV3Theme.readableForeground(
                          sourceAccent,
                          background: colors.surfaceMuted,
                          fallback: colors.accent,
                        ),
                        fontSize: 16,
                        height: 1.4,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              key: const ValueKey('material-import-progress-status'),
              constraints: const BoxConstraints(minHeight: 118),
              margin: const EdgeInsets.fromLTRB(22, 16, 22, 0),
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              decoration: BoxDecoration(
                color: colors.canvas,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: colors.line),
                boxShadow: [
                  BoxShadow(
                    color: colors.ink.withValues(alpha: .08),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: colors.ink,
                      fontSize: 18,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 11),
                  Text(
                    message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.muted,
                      fontSize: 13,
                      height: 1.45,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  if (canReturnViaNotifications) ...[
                    const SizedBox(height: 12),
                    V3LongRunningTaskNotice(onReturn: onBack),
                  ],
                ],
              ),
            ),
            Container(
              height: 160,
              margin: const EdgeInsets.fromLTRB(22, 18, 22, 0),
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 18),
              decoration: BoxDecoration(
                color: colors.canvas,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: colors.line),
              ),
              child: const _V3ImportSkeleton(),
            ),
          ],
        ),
      ),
    );
  }
}

class V3LinkImportSheetContent extends StatelessWidget {
  const V3LinkImportSheetContent({
    required this.controller,
    required this.onChanged,
    this.distillToDigitalTwin = false,
    this.onDistillationChanged,
    this.onDistillationHelp,
    this.enabled = true,
    this.errorText,
    super.key,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final bool distillToDigitalTwin;
  final ValueChanged<bool>? onDistillationChanged;
  final VoidCallback? onDistillationHelp;
  final bool enabled;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            key: const ValueKey('link-import-card'),
            constraints: const BoxConstraints(minHeight: 270),
            padding: const EdgeInsets.fromLTRB(16, 17, 16, 16),
            decoration: BoxDecoration(
              color: colors.canvas,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.line),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.surfaceMuted,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.north_east_rounded,
                    size: 20,
                    color: Color(0xffa5682b),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '粘贴链接',
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 17,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '粘贴后由服务器解析内容并生成笔记',
                  style: TextStyle(
                    color: colors.muted,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 32),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 54),
                  child: TextField(
                    key: const ValueKey('link-import-field'),
                    controller: controller,
                    enabled: enabled,
                    contextMenuBuilder: V3TextEditing.buildContextMenu,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.done,
                    autocorrect: false,
                    enableSuggestions: false,
                    onChanged: onChanged,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 15,
                      height: 1.4,
                    ),
                    decoration: InputDecoration(
                      hintText: '粘贴内容链接',
                      errorText: errorText,
                      prefixIcon: const Icon(
                        Icons.north_east_rounded,
                        size: 18,
                        color: Color(0xffa5682b),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                      filled: false,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xffa5682b)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xffa5682b)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                          color: Color(0xffa5682b),
                          width: 1.4,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          V3DigitalTwinDistillationOption(
            optionKey: const ValueKey('link-import-distillation-option'),
            checked: distillToDigitalTwin,
            onChanged: onDistillationChanged,
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: colors.line),
          const SizedBox(height: 24),
          Row(
            children: [
              const Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: Color(0xffa5682b),
              ),
              const SizedBox(width: 10),
              Text(
                '链接导入说明',
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 17,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const _V3ImportInstruction(index: 1, text: '粘贴公开可访问的内容链接后，点击“确定”。'),
          const SizedBox(height: 17),
          const _V3ImportInstruction(index: 2, text: '服务器解析完成后，将自动生成并回传笔记。'),
          const SizedBox(height: 50),
          Row(
            children: [
              const Text(
                '如何粘贴链接并生成笔记？',
                style: TextStyle(
                  color: Color(0xffa5682b),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const Spacer(),
              Icon(Icons.chevron_right_rounded, size: 18, color: colors.muted),
            ],
          ),
          const SizedBox(height: 6),
          V3DigitalTwinDistillationHelpLink(
            helpKey: const ValueKey('link-import-distillation-help'),
            onTap: onDistillationHelp ?? () {},
          ),
        ],
      ),
    );
  }
}

enum V3FileImportKind { document, media }

class V3FileImportSheetContent extends StatelessWidget {
  const V3FileImportSheetContent({
    required this.kind,
    required this.onPick,
    this.distillToDigitalTwin = false,
    this.onDistillationChanged,
    this.onDistillationHelp,
    this.selectedFileName,
    this.errorText,
    super.key,
  });

  final V3FileImportKind kind;
  final VoidCallback onPick;
  final bool distillToDigitalTwin;
  final ValueChanged<bool>? onDistillationChanged;
  final VoidCallback? onDistillationHelp;
  final String? selectedFileName;
  final String? errorText;

  bool get _media => kind == V3FileImportKind.media;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final actionLabel = _media ? '选择录音' : '选择文件';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            key: const ValueKey('file-import-card'),
            constraints: const BoxConstraints(minHeight: 270),
            padding: const EdgeInsets.fromLTRB(16, 17, 16, 16),
            decoration: BoxDecoration(
              color: colors.canvas,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.line),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.surfaceMuted,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _media
                        ? Icons.play_arrow_rounded
                        : Icons.arrow_upward_rounded,
                    size: 22,
                    color: colors.accent,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _media ? '上传录音音频' : '上传本地文件',
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 17,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  _media ? '上传后自动转写，完成后生成结构化笔记' : '选择文件后上传，服务器解析完成后生成笔记',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.muted,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 36),
                Text(
                  _media
                      ? 'MP3、M4A、WAV'
                      : 'PDF、DOCX、PPTX、XLSX、TXT、Markdown、CSV、JSON',
                  style: TextStyle(
                    color: colors.muted,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  height: 48,
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: onPick,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.accent,
                      side: BorderSide(color: colors.accent),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Text(
                      selectedFileName ?? actionLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (errorText != null) ...[
            const SizedBox(height: 8),
            Text(
              errorText!,
              style: TextStyle(color: colors.danger, fontSize: 12),
            ),
          ],
          const SizedBox(height: 16),
          V3DigitalTwinDistillationOption(
            optionKey: ValueKey(
              _media
                  ? 'audio-import-distillation-option'
                  : 'file-import-distillation-option',
            ),
            checked: distillToDigitalTwin,
            onChanged: onDistillationChanged,
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: colors.line),
          const SizedBox(height: 24),
          Row(
            children: [
              const Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: Color(0xffa5682b),
              ),
              const SizedBox(width: 10),
              Text(
                _media ? '录音音频导入说明' : '文件导入说明',
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 17,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _V3ImportInstruction(
            index: 1,
            text: _media
                ? '一次选择一段录音后，点击“确定”。'
                : '每个文件不超过 100 MB，选择后点击“确定”开始上传。',
          ),
          const SizedBox(height: 17),
          _V3ImportInstruction(
            index: 2,
            text: _media ? '上传完成后将自动创建转写任务，并显示识别文字。' : '服务器完成解析后，将自动生成并回传笔记。',
          ),
          const SizedBox(height: 50),
          Row(
            children: [
              Text(
                _media ? '如何上传录音并查看转写？' : '如何上传文件并生成笔记？',
                style: const TextStyle(
                  color: Color(0xffa5682b),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const Spacer(),
              Icon(Icons.chevron_right_rounded, size: 18, color: colors.muted),
            ],
          ),
          const SizedBox(height: 6),
          V3DigitalTwinDistillationHelpLink(
            helpKey: ValueKey(
              _media
                  ? 'audio-import-distillation-help'
                  : 'file-import-distillation-help',
            ),
            onTap: onDistillationHelp ?? () {},
          ),
        ],
      ),
    );
  }
}

enum V3RecordingImportMode { external, internal }

class V3RecordingImportSheetContent extends StatelessWidget {
  const V3RecordingImportSheetContent({
    required this.selected,
    required this.onSelected,
    this.distillToDigitalTwin = false,
    this.onDistillationChanged,
    this.onDistillationHelp,
    super.key,
  });

  final V3RecordingImportMode selected;
  final ValueChanged<V3RecordingImportMode> onSelected;
  final bool distillToDigitalTwin;
  final ValueChanged<bool>? onDistillationChanged;
  final VoidCallback? onDistillationHelp;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '选择录音方式',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.ink,
              fontSize: 18,
              height: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '外录记录现场声音，内录使用设备麦克风',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.muted, fontSize: 13),
          ),
          const SizedBox(height: 24),
          _V3RecordingModeTile(
            title: '外录',
            subtitle: '录制会议、谈话等外部声音',
            selected: selected == V3RecordingImportMode.external,
            onTap: () => onSelected(V3RecordingImportMode.external),
          ),
          const SizedBox(height: 8),
          _V3RecordingModeTile(
            title: '内录',
            subtitle: '使用设备麦克风，离开录音页仍可继续录制',
            selected: selected == V3RecordingImportMode.internal,
            onTap: () => onSelected(V3RecordingImportMode.internal),
          ),
          const SizedBox(height: 16),
          V3DigitalTwinDistillationOption(
            optionKey: const ValueKey('recording-import-distillation-option'),
            checked: distillToDigitalTwin,
            onChanged: onDistillationChanged,
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: colors.line),
          const SizedBox(height: 24),
          Row(
            children: [
              const Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: Color(0xffa5682b),
              ),
              const SizedBox(width: 10),
              Text(
                '录音使用说明',
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const _V3ImportInstruction(index: 1, text: '选择外录或内录后，点击“确定”进入录音。'),
          const SizedBox(height: 17),
          const _V3ImportInstruction(index: 2, text: '录音结束后，服务器将自动转写并生成笔记。'),
          const SizedBox(height: 50),
          Row(
            children: [
              const Text(
                '如何选择外录或内录？',
                style: TextStyle(color: Color(0xffa5682b), fontSize: 13),
              ),
              const Spacer(),
              Icon(Icons.chevron_right_rounded, size: 18, color: colors.muted),
            ],
          ),
          const SizedBox(height: 6),
          V3DigitalTwinDistillationHelpLink(
            helpKey: const ValueKey('recording-import-distillation-help'),
            onTap: onDistillationHelp ?? () {},
          ),
        ],
      ),
    );
  }
}

class _V3RecordingModeTile extends StatelessWidget {
  const _V3RecordingModeTile({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 91,
        padding: const EdgeInsets.symmetric(horizontal: 15),
        decoration: BoxDecoration(
          color: colors.canvas,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? colors.accent : colors.line,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? colors.accent : colors.line,
                  width: 2,
                ),
              ),
              child: selected
                  ? Center(
                      child: SizedBox(
                        width: 10,
                        height: 10,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: colors.ink,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    subtitle,
                    style: TextStyle(color: colors.muted, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _V3ImportInstruction extends StatelessWidget {
  const _V3ImportInstruction({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.surfaceMuted,
            shape: BoxShape.circle,
          ),
          child: Text(
            '$index',
            style: TextStyle(color: colors.accent, fontSize: 12),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: colors.text, fontSize: 13, height: 1.5),
          ),
        ),
      ],
    );
  }
}

class _V3ImportSkeleton extends StatelessWidget {
  const _V3ImportSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    Widget bar(double width, {Color? color}) {
      return Container(
        width: width,
        height: 15,
        decoration: BoxDecoration(
          color: color ?? colors.surfaceMuted,
          borderRadius: BorderRadius.circular(8),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        bar(118, color: Color.lerp(colors.surfaceMuted, colors.line, .22)),
        const SizedBox(height: 13),
        bar(double.infinity, color: colors.line),
        const SizedBox(height: 10),
        bar(double.infinity),
        const SizedBox(height: 10),
        bar(double.infinity),
        const SizedBox(height: 10),
        bar(260, color: Color.lerp(colors.surfaceMuted, colors.line, .22)),
      ],
    );
  }
}
