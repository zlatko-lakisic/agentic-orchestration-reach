"""mTLS material load/persist for Reach ↔ AO."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass
class ReachMtlsConfig:
    client_cert_pem: str | None = None
    client_key_pem: str | None = None
    ca_pem: str | None = None
    material_dir: str | None = None

    @property
    def has_inline_material(self) -> bool:
        return bool(
            (self.client_cert_pem or "").strip()
            and (self.client_key_pem or "").strip()
            and (self.ca_pem or "").strip()
        )

    @property
    def has_material_dir(self) -> bool:
        return bool((self.material_dir or "").strip())

    @property
    def is_configured(self) -> bool:
        return self.has_inline_material or self.has_material_dir


@dataclass
class ReachMtlsMaterial:
    client_cert_pem: str
    client_key_pem: str
    ca_pem: str
    dir: str | None = None
    subject: str | None = None
    expires_at: float | None = None

    def to_config(self) -> ReachMtlsConfig:
        return ReachMtlsConfig(
            client_cert_pem=self.client_cert_pem,
            client_key_pem=self.client_key_pem,
            ca_pem=self.ca_pem,
            material_dir=self.dir,
        )


def assert_reach_mtls_uses_tls(base_url: str) -> None:
    if not base_url.lower().startswith("https://"):
        raise ValueError(f"mTLS requires https base URL, got: {base_url}")


def material_present(material_dir: str) -> bool:
    root = Path(material_dir)
    return all((root / name).is_file() for name in ("cert.pem", "key.pem", "ca.pem"))


def load_reach_mtls_material(config: ReachMtlsConfig) -> ReachMtlsMaterial:
    if config.has_inline_material:
        return ReachMtlsMaterial(
            client_cert_pem=config.client_cert_pem.strip(),  # type: ignore[union-attr]
            client_key_pem=config.client_key_pem.strip(),  # type: ignore[union-attr]
            ca_pem=config.ca_pem.strip(),  # type: ignore[union-attr]
            dir=(config.material_dir or "").strip() or None,
        )
    directory = (config.material_dir or "").strip()
    if not directory:
        raise RuntimeError("ReachMtlsConfig requires PEMs or materialDir")
    root = Path(directory)
    for name in ("cert.pem", "key.pem", "ca.pem"):
        path = root / name
        if not path.is_file():
            raise RuntimeError(f"mTLS material missing: {path}")
    meta_path = root / "meta.json"
    subject = None
    expires_at = None
    if meta_path.is_file():
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            subject = meta.get("subject") or meta.get("client_name")
            exp = meta.get("expires_at")
            if isinstance(exp, (int, float)):
                expires_at = float(exp)
        except (OSError, json.JSONDecodeError, TypeError):
            pass
    return ReachMtlsMaterial(
        client_cert_pem=(root / "cert.pem").read_text(encoding="utf-8"),
        client_key_pem=(root / "key.pem").read_text(encoding="utf-8"),
        ca_pem=(root / "ca.pem").read_text(encoding="utf-8"),
        dir=directory,
        subject=subject,
        expires_at=expires_at,
    )


def persist_reach_mtls_material(
    *,
    dir: str,
    client_cert_pem: str,
    client_key_pem: str,
    ca_pem: str,
    subject: str | None = None,
    expires_at: float | None = None,
) -> ReachMtlsMaterial:
    root = Path(dir)
    root.mkdir(parents=True, exist_ok=True)
    (root / "cert.pem").write_text(client_cert_pem, encoding="utf-8")
    (root / "key.pem").write_text(client_key_pem, encoding="utf-8")
    (root / "ca.pem").write_text(ca_pem, encoding="utf-8")
    meta = {
        "subject": subject,
        "expires_at": expires_at,
        "client_name": subject,
    }
    (root / "meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    return ReachMtlsMaterial(
        client_cert_pem=client_cert_pem,
        client_key_pem=client_key_pem,
        ca_pem=ca_pem,
        dir=dir,
        subject=subject,
        expires_at=expires_at,
    )


def clear_reach_mtls_material(material_dir: str) -> None:
    root = Path(material_dir)
    for name in ("cert.pem", "key.pem", "ca.pem", "meta.json"):
        path = root / name
        if path.is_file():
            path.unlink()
