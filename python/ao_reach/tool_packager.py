"""Build wheel+manifest zip bundles for AO custom-tool sandbox upload."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .custom_tool_contract import CustomToolContractError, CustomToolManifest, validate_manifest_dict


@dataclass(frozen=True)
class CustomToolBundle:
    """In-memory zip bundle (manifest.json + wheel)."""

    manifest: CustomToolManifest
    zip_bytes: bytes
    wheel_sha256: str
    zip_sha256: str


def build_wheel(project_dir: Path, *, out_dir: Path | None = None) -> Path:
    """Build a wheel from a PEP 517 project directory."""
    project_dir = project_dir.resolve()
    if not (project_dir / "pyproject.toml").is_file():
        raise CustomToolContractError(f"no pyproject.toml in {project_dir}")

    dest = out_dir or Path(tempfile.mkdtemp(prefix="ao-reach-wheel-"))
    dest.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        [sys.executable, "-m", "pip", "wheel", str(project_dir), "--no-deps", "-w", str(dest)],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise CustomToolContractError(
            f"pip wheel failed for {project_dir}:\n{proc.stdout}\n{proc.stderr}"
        )
    wheels = sorted(dest.glob("*.whl"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not wheels:
        raise CustomToolContractError(f"pip wheel produced no .whl in {dest}")
    return wheels[0]


def build_bundle_zip(*, manifest: dict[str, Any], wheel_path: Path) -> bytes:
    """Create a zip containing ``manifest.json`` and the referenced wheel."""
    validate_manifest_dict(manifest)
    parsed = CustomToolManifest.from_json(manifest)
    wheel_path = wheel_path.resolve()
    if not wheel_path.is_file():
        raise CustomToolContractError(f"wheel not found: {wheel_path}")
    if wheel_path.name != parsed.wheel:
        raise CustomToolContractError(
            f"wheel filename {wheel_path.name!r} does not match manifest.wheel {parsed.wheel!r}"
        )

    buf = tempfile.SpooledTemporaryFile(max_size=16 * 1024 * 1024)
    with zipfile.ZipFile(buf, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("manifest.json", json.dumps(parsed.to_json(), indent=2) + "\n")
        zf.write(wheel_path, arcname=wheel_path.name)
    buf.seek(0)
    return buf.read()


def package_custom_tool(
    *,
    manifest: dict[str, Any] | None = None,
    manifest_path: Path | None = None,
    wheel_path: Path | None = None,
    project_dir: Path | None = None,
) -> CustomToolBundle:
    """Resolve manifest + wheel and return a validated bundle."""
    data: dict[str, Any]
    if manifest is not None:
        data = dict(manifest)
    elif manifest_path is not None:
        raw = json.loads(manifest_path.read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            raise CustomToolContractError("manifest file must contain a JSON object")
        data = raw
    else:
        raise CustomToolContractError("manifest or manifest_path is required")

    wheel: Path | None = wheel_path
    if wheel is None and project_dir is not None:
        wheel = build_wheel(Path(project_dir))
    if wheel is None:
        wheel_name = str(data.get("wheel") or "").strip()
        if manifest_path is not None and wheel_name:
            candidate = manifest_path.parent / wheel_name
            if candidate.is_file():
                wheel = candidate
    if wheel is None:
        raise CustomToolContractError("wheel_path or project_dir is required")

    zip_bytes = build_bundle_zip(manifest=data, wheel_path=wheel)
    parsed = CustomToolManifest.from_json(data)
    wheel_hash = hashlib.sha256(wheel.read_bytes()).hexdigest()
    zip_hash = hashlib.sha256(zip_bytes).hexdigest()
    return CustomToolBundle(
        manifest=parsed,
        zip_bytes=zip_bytes,
        wheel_sha256=wheel_hash,
        zip_sha256=zip_hash,
    )
