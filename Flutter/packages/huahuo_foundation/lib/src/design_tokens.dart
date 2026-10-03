import 'package:flutter/material.dart';

abstract final class HuahuoColors {
  static const canvas = Color(0xFFFAFAFB);
  static const surface = Color(0xFFFFFFFF);
  static const sidebar = Color(0xFFF6F6F7);
  static const surfaceMuted = Color(0xFFF1F1F3);
  static const line = Color(0xFFE8E8EB);
  static const lineStrong = Color(0xFFD9D9DE);
  static const text = Color(0xFF27272A);
  static const textSecondary = Color(0xFF73737B);
  static const textFaint = Color(0xFFA4A4AB);
  static const accent = Color(0xFF5B6880);
  static const accentHover = Color(0xFF4D596F);
  static const accentMuted = Color(0xFFECEEF3);
  static const success = Color(0xFF38765B);
  static const danger = Color(0xFFB34B4B);
  static const shadow = Color(0x1209090B);
}

abstract final class HuahuoDarkColors {
  static const canvas = Color(0xFF18181A);
  static const surface = Color(0xFF1C1C1F);
  static const sidebar = Color(0xFF202023);
  static const surfaceMuted = Color(0xFF252529);
  static const line = Color(0xFF313136);
  static const lineStrong = Color(0xFF3B3B41);
  static const text = Color(0xFFE8E8EA);
  static const textSecondary = Color(0xFFA1A1A8);
  static const textFaint = Color(0xFF74747C);
  static const accent = Color(0xFFA9B3C5);
  static const accentMuted = Color(0xFF2A2E35);
}

abstract final class HuahuoSpacing {
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
}

abstract final class HuahuoRadii {
  static const navigation = 7.0;
  static const control = 8.0;
  static const panel = 10.0;
  static const floating = 14.0;
}

abstract final class HuahuoDesktopMetrics {
  static const activityBar = 52.0;
  static const sidebarExpanded = 248.0;
  static const sidebarCollapsed = 0.0;
  static const contextPanel = 284.0;
  static const chatPanel = 360.0;
  static const collapsedChatRail = 46.0;
  static const tabBarHeight = 36.0;
  static const topBarHeight = 52.0;
  static const editorMaxWidth = 820.0;
  static const chatMaxWidth = 900.0;
  static const chatRailBreakpoint = 940.0;
  static const contextSplitBreakpoint = 1700.0;
}

abstract final class HuahuoTypography {
  static const primaryFamily = 'NotoSansSC';
  static const fallbacks = <String>[
    'PingFang SC',
    'Microsoft YaHei',
    'Noto Sans CJK SC',
    'Segoe UI',
    'Roboto',
  ];
}
