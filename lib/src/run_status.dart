/// Structured run progress / error updates from AO (`type: "status"` / `error`).
library;

/// One status frame during [SessionBridge.chat] / [SessionBridge.directAgent].
///
/// [message] is user-friendly and safe to stream to the end user as-is.
class ReachRunStatus {
  ReachRunStatus({
    required this.processing,
    required this.phase,
    required this.message,
    this.detail,
    this.agentProviderId,
    this.step,
    this.stepCount,
    this.code,
    this.questionId,
    this.runId,
    this.raw = const {},
  });

  factory ReachRunStatus.fromJson(Map<String, dynamic> json) {
    return ReachRunStatus(
      processing: json['processing'] == true,
      phase: (json['phase'] ?? 'info').toString(),
      message: (json['message'] ?? '').toString(),
      detail: json['detail']?.toString(),
      agentProviderId: json['agentProviderId']?.toString() ??
          json['agent_provider_id']?.toString(),
      step: json['step'] is num ? (json['step'] as num).toInt() : null,
      stepCount: json['stepCount'] is num
          ? (json['stepCount'] as num).toInt()
          : (json['step_count'] is num
              ? (json['step_count'] as num).toInt()
              : null),
      code: json['code']?.toString(),
      questionId: json['question_id']?.toString() ?? json['questionId']?.toString(),
      runId: json['run_id']?.toString() ?? json['runId']?.toString(),
      raw: Map<String, dynamic>.from(json),
    );
  }

  /// True while AO is still working on this request.
  final bool processing;

  /// Stable phase id (`planning`, `warming_agent`, `generating`, `done`, `error`, …).
  final String phase;

  /// User-facing text — stream this to the UI.
  final String message;

  /// Optional technical detail (not required for UX).
  final String? detail;

  final String? agentProviderId;
  final int? step;
  final int? stepCount;

  /// Structured error code when [phase] is `error` (also on [ReachRunException]).
  final String? code;

  final String? questionId;
  final String? runId;
  final Map<String, dynamic> raw;

  bool get isError => phase == 'error' || code != null && !processing;

  @override
  String toString() =>
      'ReachRunStatus(processing=$processing, phase=$phase, message=$message)';
}

/// Thrown when a run ends with `ok: false` or a terminal AO error.
///
/// Catch this to show [message] and branch on [code] without parsing strings.
class ReachRunException implements Exception {
  ReachRunException({
    required this.message,
    this.code,
    this.detail,
    this.questionId,
    this.runId,
    this.phase = 'error',
  });

  factory ReachRunException.fromStatus(ReachRunStatus status) {
    return ReachRunException(
      message: status.message.isNotEmpty ? status.message : 'AO run failed',
      code: status.code,
      detail: status.detail,
      questionId: status.questionId,
      runId: status.runId,
      phase: status.phase,
    );
  }

  final String message;
  final String? code;
  final String? detail;
  final String? questionId;
  final String? runId;
  final String phase;

  /// Always false when thrown — the request is no longer processing.
  bool get processing => false;

  ReachRunStatus toStatus() => ReachRunStatus(
        processing: false,
        phase: phase,
        message: message,
        detail: detail,
        code: code,
        questionId: questionId,
        runId: runId,
      );

  @override
  String toString() =>
      'ReachRunException(code=$code, message=$message, questionId=$questionId)';
}
