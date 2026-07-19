"""
Core connect/prepare/launch logic for the EveJS multiplayer client.

Ports the essential behavior of tools/PlayerConnect/Connect.ps1 so friends can
point at a host (server.json), refresh CA trust, patch start.ini, and launch
exefile.exe with the correct proxy / ResFiles environment.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable

LogFn = Callable[[str, str], None]  # (level, message) level: info|ok|warn|error


REQUIRED_BUILD = "3396210"
DEFAULT_CRYPTO = "Placebo"


def _log(log: LogFn | None, level: str, message: str) -> None:
    if log:
        log(level, message)


@dataclass
class ServerInfo:
    host: str
    token: str
    game_port: int = 26000
    image_port: int = 26001
    proxy_port: int = 26002
    xmpp_port: int = 5222
    proxy_url: str = ""
    image_server_url: str = ""
    crypto_pack: str = DEFAULT_CRYPTO
    required_build: str = REQUIRED_BUILD

    def __post_init__(self) -> None:
        self.host = str(self.host or "").strip()
        self.token = str(self.token or "").strip()
        if not self.proxy_url:
            self.proxy_url = f"http://{self.host}:{self.proxy_port}/"
        if not self.proxy_url.endswith("/"):
            self.proxy_url += "/"
        if not self.image_server_url:
            self.image_server_url = f"http://{self.host}:{self.image_port}/"
        if not self.crypto_pack:
            self.crypto_pack = DEFAULT_CRYPTO
        if not self.required_build:
            self.required_build = REQUIRED_BUILD

    @classmethod
    def from_dict(cls, data: dict) -> "ServerInfo":
        return cls(
            host=str(data.get("host") or ""),
            token=str(data.get("token") or ""),
            game_port=int(data.get("gamePort") or data.get("game_port") or 26000),
            image_port=int(data.get("imagePort") or data.get("image_port") or 26001),
            proxy_port=int(data.get("proxyPort") or data.get("proxy_port") or 26002),
            xmpp_port=int(data.get("xmppPort") or data.get("xmpp_port") or 5222),
            proxy_url=str(data.get("proxyUrl") or data.get("proxy_url") or ""),
            image_server_url=str(
                data.get("imageServerUrl") or data.get("image_server_url") or ""
            ),
            crypto_pack=str(data.get("cryptoPack") or data.get("crypto_pack") or DEFAULT_CRYPTO),
            required_build=str(
                data.get("requiredBuild") or data.get("required_build") or REQUIRED_BUILD
            ),
        )

    def to_server_json(self) -> dict:
        return {
            "service": "evejs-playerconnect",
            "host": self.host,
            "gamePort": self.game_port,
            "imagePort": self.image_port,
            "proxyPort": self.proxy_port,
            "xmppPort": self.xmpp_port,
            "token": self.token,
            "proxyUrl": self.proxy_url,
            "imageServerUrl": self.image_server_url,
            "cryptoPack": self.crypto_pack,
            "requiredBuild": self.required_build,
        }


@dataclass
class LocalState:
    client_path: str = ""
    last_host: str = ""
    prepared_at: str = ""
    extra: dict = field(default_factory=dict)

    @classmethod
    def load(cls, path: Path) -> "LocalState":
        if not path.is_file():
            return cls()
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return cls()
        return cls(
            client_path=str(raw.get("clientPath") or raw.get("client_path") or ""),
            last_host=str(raw.get("lastHost") or raw.get("last_host") or ""),
            prepared_at=str(raw.get("preparedAt") or raw.get("prepared_at") or ""),
            extra={
                k: v
                for k, v in raw.items()
                if k
                not in {
                    "clientPath",
                    "client_path",
                    "lastHost",
                    "last_host",
                    "preparedAt",
                    "prepared_at",
                }
            },
        )

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "clientPath": self.client_path,
            "lastHost": self.last_host,
            "preparedAt": self.prepared_at,
            **self.extra,
        }
        path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def app_base_dir() -> Path:
    """Directory that holds server.json / ca.pem (bundle or frozen exe dir)."""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    # Prefer player-connect-bundle if present next to repo or under _local.
    here = Path(__file__).resolve().parent.parent
    candidates = [
        here / "_local" / "player-connect-bundle",
        here / "player-connect-bundle",
        Path.cwd() / "_local" / "player-connect-bundle",
        Path.cwd(),
        here,
    ]
    for c in candidates:
        if (c / "server.json").is_file():
            return c
    return here / "_local" / "player-connect-bundle"


def load_server_info(bundle_dir: Path | None = None) -> ServerInfo:
    root = bundle_dir or app_base_dir()
    path = root / "server.json"
    if not path.is_file():
        raise FileNotFoundError(f"server.json not found: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    info = ServerInfo.from_dict(data)
    if not info.host:
        raise ValueError("server.json missing host")
    if not info.token:
        raise ValueError("server.json missing token")
    return info


def save_server_info(info: ServerInfo, bundle_dir: Path | None = None) -> Path:
    root = bundle_dir or app_base_dir()
    root.mkdir(parents=True, exist_ok=True)
    path = root / "server.json"
    path.write_text(
        json.dumps(info.to_server_json(), indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return path


def find_client_exe(tq_path: Path) -> Path:
    for rel in ("bin64/exefile.exe", "bin/exefile.exe"):
        candidate = tq_path / rel
        if candidate.is_file():
            return candidate
    raise FileNotFoundError(f"exefile.exe not found under {tq_path}")


def resolve_resource_cache(tq_path: Path) -> tuple[Path, Path, Path]:
    cache_root = tq_path.resolve().parent
    res_files = cache_root / "ResFiles"
    index = cache_root / "index_tranquility.txt"
    if not res_files.is_dir():
        raise FileNotFoundError(
            f"ResFiles missing next to tq: {res_files}\n"
            "Copy the full EVE shared cache, not only the tq folder."
        )
    if not index.is_file():
        raise FileNotFoundError(f"index_tranquility.txt missing: {index}")
    return cache_root, res_files, index


def read_ini_value(ini_path: Path, keys: Iterable[str]) -> str | None:
    if not ini_path.is_file():
        return None
    key_set = {k.lower() for k in keys}
    for line in ini_path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"^\s*([A-Za-z0-9_]+)\s*=\s*(.+?)\s*$", line)
        if not m:
            continue
        if m.group(1).lower() in key_set:
            return m.group(2).strip()
    return None


def patch_start_ini(ini_path: Path, server_host: str, crypto_pack: str = DEFAULT_CRYPTO) -> None:
    if not ini_path.is_file():
        raise FileNotFoundError(f"start.ini not found: {ini_path}")
    backup = ini_path.with_suffix(ini_path.suffix + ".playerconnect.bak")
    if not backup.is_file():
        shutil.copy2(ini_path, backup)

    lines = ini_path.read_text(encoding="utf-8", errors="replace").splitlines()
    server_keys = {"server", "serverip"}
    crypto_keys = {"cryptopack"}
    saw_server = False
    saw_crypto = False
    out: list[str] = []

    for line in lines:
        m = re.match(r"^\s*([A-Za-z0-9_]+)\s*=", line)
        if m:
            key = m.group(1).lower()
            if key in server_keys:
                if not saw_server:
                    out.append(f"server = {server_host}")
                    saw_server = True
                continue
            if key in crypto_keys:
                if not saw_crypto:
                    out.append(f"cryptoPack = {crypto_pack}")
                    saw_crypto = True
                continue
        out.append(line)

    if not saw_server:
        out.append(f"server = {server_host}")
    if not saw_crypto:
        out.append(f"cryptoPack = {crypto_pack}")

    ini_path.write_text("\n".join(out) + "\n", encoding="utf-8")


def tcp_open(host: str, port: int, timeout: float = 2.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def http_get_json(url: str, timeout: float = 8.0) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": "EveJS-ClientLauncher/0.1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode("utf-8", errors="replace")
    return json.loads(body)


def http_download(url: str, dest: Path, timeout: float = 20.0) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": "EveJS-ClientLauncher/0.1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = resp.read()
    dest.write_bytes(data)


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest().lower()


def health_check(server: ServerInfo, log: LogFn | None = None) -> dict | None:
    url = (
        f"{server.proxy_url}playerconnect/health?"
        f"token={urllib.parse.quote(server.token)}"
    )
    try:
        data = http_get_json(url)
        _log(log, "ok", f"PlayerConnect health OK (host={data.get('host')})")
        return data
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError, OSError) as exc:
        _log(log, "warn", f"PlayerConnect health failed: {exc}")
        return None


def ensure_ca_file(
    server: ServerInfo,
    ca_path: Path,
    log: LogFn | None = None,
) -> Path:
    health = health_check(server, log=None)
    expected = ""
    if health and health.get("caSha256"):
        expected = str(health["caSha256"]).lower()

    local = file_sha256(ca_path) if ca_path.is_file() else ""
    need = True
    if local and expected and local == expected:
        need = False
        _log(log, "ok", f"ca.pem matches host fingerprint ({local[:12]}...)")

    if need:
        url = (
            f"{server.proxy_url}playerconnect/ca.pem?"
            f"token={urllib.parse.quote(server.token)}"
        )
        _log(log, "info", f"Downloading live ca.pem from {server.host}...")
        try:
            http_download(url, ca_path)
            local = file_sha256(ca_path)
            _log(log, "ok", f"Downloaded ca.pem ({local[:12]}...)")
        except Exception as exc:  # noqa: BLE001
            if ca_path.is_file():
                _log(log, "warn", f"CA download failed, keeping existing file: {exc}")
            else:
                raise RuntimeError(
                    f"Could not download ca.pem from {url}. Is the host running? {exc}"
                ) from exc

    if not ca_path.is_file():
        raise FileNotFoundError(f"ca.pem missing: {ca_path}")
    return ca_path


def _pem_blocks(text: str) -> list[str]:
    return re.findall(
        r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----",
        text,
    )


def _is_evejs_cert_block(block: str) -> bool:
    upper = block.upper()
    # Subject strings appear in PEM only after decode; use openssl-less heuristic:
    # fingerprint helper when cryptography available, else keyword after base64 decode attempt.
    try:
        import base64

        b64 = re.sub(
            r"-----BEGIN CERTIFICATE-----|-----END CERTIFICATE-----|\s",
            "",
            block,
        )
        der = base64.b64decode(b64)
        # ASN.1 printable: look for organization / CN bytes
        if b"EvEJS Local" in der or b"eve.js Public Gateway" in der:
            return True
    except Exception:  # noqa: BLE001
        pass
    return "EVEJS" in upper  # unlikely in raw b64; kept as fallback


def strip_old_evejs_from_pem(content: str) -> str:
    kept: list[str] = []
    for block in _pem_blocks(content):
        if _is_evejs_cert_block(block):
            continue
        kept.append(block)
    # Preserve non-cert text roughly by rejoining certs only (cacert is cert-only).
    if not kept and "BEGIN CERTIFICATE" not in content:
        return content
    return "\n".join(kept) + ("\n" if kept else "")


def install_ca_windows_root(ca_path: Path, log: LogFn | None = None) -> None:
    """Import CA into CurrentUser Root via certutil (no admin required)."""
    if sys.platform != "win32":
        _log(log, "warn", "Non-Windows: skip certutil Root install")
        return
    # certutil accepts PEM for -addstore in modern Windows.
    try:
        proc = subprocess.run(
            ["certutil", "-user", "-addstore", "Root", str(ca_path)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        if proc.returncode == 0 or "already in store" in out.lower() or "成功" in out:
            _log(log, "ok", "Installed / verified EveJS CA in CurrentUser\\Root")
        else:
            _log(log, "warn", f"certutil returned {proc.returncode}: {out.strip()[:200]}")
    except FileNotFoundError:
        _log(log, "warn", "certutil not found; install CA manually if TLS fails")


def find_cacert_paths(tq_path: Path) -> list[Path]:
    candidates: list[Path] = []
    fixed = [
        tq_path / "bin64" / "cacert.pem",
        tq_path / "bin64" / "packages" / "certifi" / "cacert.pem",
        tq_path / "bin" / "cacert.pem",
        tq_path / "bin" / "packages" / "certifi" / "cacert.pem",
    ]
    for p in fixed:
        if p.is_file():
            candidates.append(p.resolve())
    scan_roots = [tq_path]
    try:
        scan_roots.append(tq_path.resolve().parent)
    except OSError:
        pass
    seen = {str(p).lower() for p in candidates}
    for root in scan_roots:
        if not root.is_dir():
            continue
        try:
            for p in root.rglob("cacert.pem"):
                key = str(p.resolve()).lower()
                if key not in seen and p.is_file():
                    candidates.append(p.resolve())
                    seen.add(key)
        except OSError:
            continue
    return candidates


def inject_ca_into_client(
    ca_path: Path,
    tq_path: Path,
    bundle_dir: Path,
    log: LogFn | None = None,
) -> Path:
    """Inject EveJS CA into client cacert bundles; return combined trust file path."""
    ca_raw = ca_path.read_text(encoding="utf-8", errors="replace").strip()
    paths = find_cacert_paths(tq_path)
    if not paths:
        _log(
            log,
            "warn",
            f"No cacert.pem under {tq_path}. Chat/gateway TLS may fail inside exefile.",
        )
    updated = 0
    primary: Path | None = None
    for path in paths:
        try:
            raw = path.read_text(encoding="utf-8", errors="replace")
            cleaned = strip_old_evejs_from_pem(raw)
            # Also remove exact previous EveJS PEM if still present after heuristic
            if ca_raw in cleaned:
                path.write_text(cleaned if cleaned.endswith("\n") else cleaned + "\n", encoding="utf-8")
                _log(log, "info", f"CA already present in {path}")
            else:
                new_text = cleaned.rstrip() + "\n\n" + ca_raw + "\n"
                path.write_text(new_text, encoding="utf-8")
                _log(log, "ok", f"Installed EveJS CA into {path}")
            updated += 1
            if primary is None:
                primary = path
        except OSError as exc:
            _log(log, "warn", f"Could not update {path}: {exc}")

    combined = bundle_dir / "combined-ca-bundle.pem"
    try:
        if primary and primary.is_file():
            base = strip_old_evejs_from_pem(
                primary.read_text(encoding="utf-8", errors="replace")
            )
        else:
            base = ""
        if ca_raw not in base:
            base = base.rstrip() + "\n\n" + ca_raw + "\n"
        combined.write_text(base if base.endswith("\n") else base + "\n", encoding="utf-8")
        _log(log, "ok", f"Wrote combined CA bundle: {combined}")
    except OSError:
        combined = ca_path
        _log(log, "warn", "Could not write combined CA bundle; using ca.pem only")

    _log(log, "info", f"cacert.pem files updated/verified: {updated}")
    install_ca_windows_root(ca_path, log=log)
    return combined


def maybe_patch_blue_dll(tq_path: Path, bundle_dir: Path, log: LogFn | None = None) -> None:
    blue = tq_path / "bin64" / "blue.dll"
    if not blue.is_file():
        _log(log, "warn", f"blue.dll not found at {blue}")
        return
    patcher = bundle_dir / "tools" / "blue_dll_patch.ps1"
    # Also try repo tools path when running from source
    if not patcher.is_file():
        repo_patcher = (
            Path(__file__).resolve().parent.parent
            / "tools"
            / "ClientSETUP"
            / "blue_dll_patch.ps1"
        )
        if repo_patcher.is_file():
            patcher = repo_patcher
    if not patcher.is_file():
        _log(log, "warn", "blue_dll_patch.ps1 not found; skip auto patch")
        return

    def run_ps(args: list[str]) -> tuple[int, str]:
        cmd = [
            "powershell",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(patcher),
            *args,
        ]
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        return proc.returncode, (proc.stdout or "") + (proc.stderr or "")

    code, out = run_ps(["--status", "--input", str(blue)])
    if "state=already_patched" in out:
        _log(log, "ok", "blue.dll already patched")
        return
    if "state=patchable_original" in out:
        _log(log, "info", "Patching blue.dll for EveJS...")
        code2, out2 = run_ps(["--input", str(blue), "--in-place"])
        if code2 == 0:
            _log(log, "ok", "blue.dll patched")
        else:
            _log(log, "warn", f"blue.dll patch failed: {out2[:300]}")
        return
    _log(log, "warn", f"Could not auto-patch blue.dll (exit={code})")


def build_launch_env(
    server: ServerInfo,
    res_files: Path,
    trust_bundle: Path,
) -> dict[str, str]:
    env = os.environ.copy()
    proxy = server.proxy_url.rstrip("/")
    env["http_proxy"] = proxy
    env["https_proxy"] = proxy
    env["HTTP_PROXY"] = proxy
    env["HTTPS_PROXY"] = proxy
    env["all_proxy"] = proxy
    env["ALL_PROXY"] = proxy
    no_proxy = f"127.0.0.1,localhost,::1,{server.host}"
    env["no_proxy"] = no_proxy
    env["NO_PROXY"] = no_proxy
    env["EVEJS_NO_PROXY"] = no_proxy
    env["EVE_CLIENT_SENTRY_DSN"] = ""
    env["LD_OFFLINE"] = "true"
    env["LAUNCHDARKLY_OFFLINE"] = "true"
    env["LAUNCHDARKLY_SEND_EVENTS"] = "false"
    env["LD_SEND_EVENTS"] = "false"
    env["EO_REMOTEFILECACHEFOLDER"] = str(res_files)
    if trust_bundle.is_file():
        ca = str(trust_bundle)
        env["SSL_CERT_FILE"] = ca
        env["REQUESTS_CA_BUNDLE"] = ca
        env["CURL_CA_BUNDLE"] = ca
        env["NODE_EXTRA_CA_CERTS"] = ca
    env["SSL_CERT_DIR"] = ""
    return env


def prepare_and_launch(
    server: ServerInfo,
    tq_path: Path,
    bundle_dir: Path | None = None,
    *,
    skip_launch: bool = False,
    force_setup: bool = False,
    log: LogFn | None = None,
) -> int:
    root = bundle_dir or app_base_dir()
    root.mkdir(parents=True, exist_ok=True)
    state_path = root / "player-local.json"
    ca_path = root / "ca.pem"
    state = LocalState.load(state_path)

    tq_path = tq_path.resolve()
    if not tq_path.is_dir():
        raise FileNotFoundError(f"Client tq path not found: {tq_path}")

    client_exe = find_client_exe(tq_path)
    start_ini = tq_path / "start.ini"
    _log(log, "info", f"Server:  {server.host}:{server.game_port}")
    _log(log, "info", f"Proxy:   {server.proxy_url}")
    _log(log, "info", f"Client:  {client_exe}")

    cache_root, res_files, _index = resolve_resource_cache(tq_path)
    _log(log, "info", f"ResFiles:{res_files}")

    build = read_ini_value(start_ini, ["build"])
    if build and build != server.required_build:
        _log(
            log,
            "warn",
            f"Client build is '{build}' (expected {server.required_build}). Login may fail.",
        )

    needs_setup = force_setup
    cur_server = read_ini_value(start_ini, ["server", "serverip"])
    cur_crypto = read_ini_value(start_ini, ["cryptoPack", "cryptopack"])
    if cur_server != server.host or cur_crypto != server.crypto_pack:
        needs_setup = True
    if not state.client_path or Path(state.client_path).resolve() != tq_path:
        needs_setup = True

    _log(log, "info", "Checking server reachability...")
    health_check(server, log=log)
    if tcp_open(server.host, server.game_port):
        _log(log, "ok", f"Game port {server.host}:{server.game_port} is open")
    else:
        _log(log, "error", f"Cannot reach game port {server.host}:{server.game_port}")
        raise ConnectionError(
            f"Cannot reach game port {server.host}:{server.game_port}. "
            "Is Server.bat running on the host?"
        )

    ensure_ca_file(server, ca_path, log=log)
    _log(log, "info", "Ensuring EveJS CA trust (chat + public gateway)...")
    trust = inject_ca_into_client(ca_path, tq_path, root, log=log)

    if needs_setup:
        _log(log, "info", "Preparing client for this server...")
        patch_start_ini(start_ini, server.host, server.crypto_pack)
        maybe_patch_blue_dll(tq_path, root, log=log)
        from datetime import datetime, timezone

        state.client_path = str(tq_path)
        state.last_host = server.host
        state.prepared_at = datetime.now(timezone.utc).isoformat()
        state.save(state_path)
        _log(log, "ok", "Client prepared")
    else:
        _log(log, "ok", "Client already pointed at this server")

    if skip_launch:
        _log(log, "ok", "Setup complete (skip launch).")
        return 0

    env = build_launch_env(server, res_files, trust)
    _log(log, "info", "Launching EVE client...")
    _log(log, "info", f"  Host:   {server.host}")
    _log(log, "info", f"  Proxy:  {server.proxy_url}")
    _log(log, "info", f"  Client: {client_exe}")

    proc = subprocess.Popen(
        [str(client_exe)],
        cwd=str(client_exe.parent),
        env=env,
    )
    code = proc.wait()
    _log(log, "info", f"Client exited with code {code}")
    return int(code or 0)
