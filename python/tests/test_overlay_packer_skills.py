"""A skill with no injectable body must not be named on the agent.

The engine validates every skill an agent references and rejects the whole request
with `missing 'content' mapping`. The packer used to name such a skill while skipping
its (empty) body, so one unfinished skill file took the entire agent offline.
"""

from __future__ import annotations

from pathlib import Path

import yaml

from ao_reach.overlay_packer import OverlayPacker


def _overlay(tmp_path: Path, *, skills: dict[str, dict], referenced: list[str]) -> Path:
    agents_dir = tmp_path / "agent_providers"
    skills_dir = tmp_path / "agent_skills"
    agents_dir.mkdir()
    skills_dir.mkdir()
    (agents_dir / "director.yaml").write_text(
        yaml.dump({"id": "director", "type": "ollama", "skills": referenced, "backstory": "base"}),
        encoding="utf-8",
    )
    for name, body in skills.items():
        (skills_dir / f"{name}.yaml").write_text(yaml.dump(body), encoding="utf-8")
    return tmp_path


def test_a_bodyless_skill_is_not_referenced(tmp_path: Path) -> None:
    root = _overlay(
        tmp_path,
        skills={"facts": {"id": "ui_facts", "inject": {"heading": "## Facts"}}},
        referenced=["ui_facts"],
    )

    agent = OverlayPacker().pack(root).agents[0]

    assert agent["skills"] == []
    assert agent["backstory"] == "base"


def test_the_skip_is_logged(tmp_path: Path, caplog) -> None:
    root = _overlay(
        tmp_path,
        skills={"facts": {"id": "ui_facts", "inject": {"heading": "## Facts"}}},
        referenced=["ui_facts"],
    )

    with caplog.at_level("WARNING"):
        OverlayPacker().pack(root)

    assert "ui_facts" in caplog.text


def test_a_skill_with_a_body_is_still_referenced_and_injected(tmp_path: Path) -> None:
    root = _overlay(
        tmp_path,
        skills={
            "doctrine": {
                "id": "doctrine",
                "content": {"text": "ignored", "body": "hold the line"},
                "inject": {"heading": "## Doctrine"},
            }
        },
        referenced=["doctrine"],
    )

    agent = OverlayPacker().pack(root).agents[0]

    assert agent["skills"] == ["client.doctrine"]
    assert "## Doctrine" in agent["backstory"]
    assert "hold the line" in agent["backstory"]


def test_one_empty_skill_does_not_take_the_good_ones_with_it(tmp_path: Path) -> None:
    """The failure mode that mattered: a whole agent lost for one unfinished file."""
    root = _overlay(
        tmp_path,
        skills={
            "facts": {"id": "ui_facts", "inject": {"heading": "## Facts"}},
            "doctrine": {
                "id": "doctrine",
                "content": {"body": "hold the line"},
                "inject": {"heading": "## Doctrine"},
            },
        },
        referenced=["ui_facts", "doctrine"],
    )

    agent = OverlayPacker().pack(root).agents[0]

    assert agent["skills"] == ["client.doctrine"]
    assert "hold the line" in agent["backstory"]


def test_the_skill_itself_is_still_registered(tmp_path: Path) -> None:
    """Dropping the reference is not the same as hiding the file; it still packs."""
    root = _overlay(
        tmp_path,
        skills={"facts": {"id": "ui_facts", "inject": {"heading": "## Facts"}}},
        referenced=["ui_facts"],
    )

    pack = OverlayPacker().pack(root)

    assert pack.skill_ids == ["client.ui_facts"]
