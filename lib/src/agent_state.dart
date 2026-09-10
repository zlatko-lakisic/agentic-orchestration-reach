/// Per-overlay-agent lifecycle state from AO (`type: agent_state`).
library;

/// Sticky per-agent readiness on a Reach session.
///
/// [pulling] is first-class (not a reason under [starting]) and is used only
/// for local Ollama ensure/pull.
enum AgentLifecycleState {
  down,
  starting,
  pulling,
  ready,
  busy,
  stopping,
}

AgentLifecycleState? parseAgentLifecycleState(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'down':
      return AgentLifecycleState.down;
    case 'starting':
      return AgentLifecycleState.starting;
    case 'pulling':
      return AgentLifecycleState.pulling;
    case 'ready':
      return AgentLifecycleState.ready;
    case 'busy':
      return AgentLifecycleState.busy;
    case 'stopping':
      return AgentLifecycleState.stopping;
    default:
      return null;
  }
}

String agentLifecycleStateWire(AgentLifecycleState state) {
  switch (state) {
    case AgentLifecycleState.down:
      return 'down';
    case AgentLifecycleState.starting:
      return 'starting';
    case AgentLifecycleState.pulling:
      return 'pulling';
    case AgentLifecycleState.ready:
      return 'ready';
    case AgentLifecycleState.busy:
      return 'busy';
    case AgentLifecycleState.stopping:
      return 'stopping';
  }
}

/// One `agent_state` frame from the engine.
class AgentStateUpdate {
  AgentStateUpdate({
    required this.agentProviderId,
    required this.state,
    this.reason,
    this.detail,
    this.model,
    this.progress,
    this.questionId,
    this.raw = const {},
  });

  factory AgentStateUpdate.fromJson(Map<String, dynamic> json) {
    final pid = (json['agentProviderId'] ?? json['agent_provider_id'] ?? '')
        .toString()
        .trim();
    final state = parseAgentLifecycleState(json['state']?.toString());
    if (state == null) {
      throw FormatException('unknown agent state: ${json['state']}');
    }
    final progress = json['progress'];
    return AgentStateUpdate(
      agentProviderId: pid,
      state: state,
      reason: json['reason']?.toString(),
      detail: json['detail']?.toString(),
      model: json['model']?.toString(),
      progress: progress is num ? progress.toDouble() : null,
      questionId: (json['questionId'] ?? json['question_id'])?.toString(),
      raw: Map<String, dynamic>.from(json),
    );
  }

  final String agentProviderId;
  final AgentLifecycleState state;
  final String? reason;
  final String? detail;
  final String? model;
  final double? progress;
  final String? questionId;
  final Map<String, dynamic> raw;

  @override
  String toString() =>
      'AgentStateUpdate($agentProviderId → ${agentLifecycleStateWire(state)})';
}
