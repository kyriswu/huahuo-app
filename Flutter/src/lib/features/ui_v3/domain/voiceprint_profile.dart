import 'package:flutter/foundation.dart';

@immutable
final class VoiceprintProfile {
  const VoiceprintProfile({
    required this.id,
    required this.name,
    required this.enrolledAt,
    required this.updatedAt,
    required this.isDemo,
  });

  final String id;
  final String name;
  final DateTime enrolledAt;
  final DateTime updatedAt;
  final bool isDemo;

  VoiceprintProfile copyWith({
    String? name,
    DateTime? enrolledAt,
    DateTime? updatedAt,
    bool? isDemo,
  }) {
    return VoiceprintProfile(
      id: id,
      name: name ?? this.name,
      enrolledAt: enrolledAt ?? this.enrolledAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDemo: isDemo ?? this.isDemo,
    );
  }
}
