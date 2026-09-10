import 'package:ao_reach/ao_reach.dart';
import 'package:test/test.dart';

void main() {
  test('AgentLifecycleState.pulling is first-class on the wire', () {
    final update = AgentStateUpdate.fromJson({
      'type': 'agent_state',
      'agentProviderId': 'client.campaign_director',
      'state': 'pulling',
      'model': 'qwen3.5:9b',
      'progress': 0.42,
    });
    expect(update.state, AgentLifecycleState.pulling);
    expect(agentLifecycleStateWire(update.state), 'pulling');
    expect(update.model, 'qwen3.5:9b');
    expect(update.progress, closeTo(0.42, 1e-9));
  });

  test('parseAgentLifecycleState covers full enum', () {
    expect(parseAgentLifecycleState('down'), AgentLifecycleState.down);
    expect(parseAgentLifecycleState('starting'), AgentLifecycleState.starting);
    expect(parseAgentLifecycleState('pulling'), AgentLifecycleState.pulling);
    expect(parseAgentLifecycleState('ready'), AgentLifecycleState.ready);
    expect(parseAgentLifecycleState('busy'), AgentLifecycleState.busy);
    expect(parseAgentLifecycleState('stopping'), AgentLifecycleState.stopping);
    expect(parseAgentLifecycleState('nope'), isNull);
  });
}
