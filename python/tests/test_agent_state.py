"""Agent lifecycle state parsing tests."""

from __future__ import annotations

import pytest

from ao_reach.agent_state import AgentLifecycleState, AgentStateUpdate


@pytest.mark.unit
def test_pulling_is_first_class_state() -> None:
    update = AgentStateUpdate.from_json(
        {
            "type": "agent_state",
            "agentProviderId": "client.campaign_director",
            "state": "pulling",
            "model": "qwen3.5:9b",
            "progress": 0.5,
        }
    )
    assert update.state is AgentLifecycleState.PULLING
    assert update.state.value == "pulling"
    assert update.model == "qwen3.5:9b"
    assert update.progress == pytest.approx(0.5)


@pytest.mark.unit
def test_unknown_state_rejected() -> None:
    with pytest.raises(ValueError):
        AgentStateUpdate.from_json({"agentProviderId": "a", "state": "warming"})
