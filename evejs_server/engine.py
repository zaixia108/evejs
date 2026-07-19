"""
Server host engine: multiplayer config, DB/deps, npm server process, FRP client.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Callable

LogFn = Callable[[str, str], None]


def repo_root() -> Path:
    if getattr(sys, "frozen", False):
        # Frozen exe should live in the EveJS repo root (or next to it).
        here = Path(sys.executable).resolve().parent
        if (here / "server" / "index.js").is_file():
            return here
        if (here.parent / "server" / "index.js").is_file():
            return here.parent
        return here
    return Path(__file__).resolve().parent.parent


def _log(log: LogFn | None, level: str, msg: str) -> None:
    if log:
        log(level, msg)


@dataclass
class LauncherState:
    mode: str = "ddns"  # ddns | frp
    advertise_host: str = ""
    player_token: str = "test"
    open_firewall: bool = True
    # FRP
    frp_server_addr: str = ""
    frp_server_port: int = 7000
    frp_auth_token: str = ""
    frpc_path: str = ""
    frp_remote_game: int = 26000
    frp_remote_image: int = 26001
    frp_remote_proxy: int = 26002
    frp_remote_xmpp: int = 5222
    auto_start_frpc: bool = True

    @classmethod
    def load(cls, path: Path) -> "LauncherState":
        if not path.is_file():
            return cls()
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return cls()
        known = {f.name for f in cls.__dataclass_fields__.values()}  # type: ignore[attr-defined]
        kwargs = {k: v for k, v in data.items() if k in known}
        return cls(**kwargs)

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(asdict(self), indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )


def detect_lan_ip() -> str:
    # UDP trick: no packets sent, just choose outbound interface.
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        if ip and not ip.startswith("127."):
            return ip
    except OSError:
        pass
    try:
        hostname = socket.gethostname()
        for info in socket.getaddrinfo(hostname, None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127."):
                return ip
    except OSError:
        pass
    return "127.0.0.1"


def which_node() -> str | None:
    return shutil.which("node")


def which_npm() -> str | None:
    return shutil.which("npm") or shutil.which("npm.cmd")


def configure_multiplayer(
    advertise_host: str,
    token: str | None = None,
    *,
    open_firewall: bool = False,
    log: LogFn | None = None,
) -> dict:
    root = repo_root()
    script = root / "tools" / "PlayerConnect" / "configure-multiplayer-host.js"
    if not script.is_file():
        raise FileNotFoundError(f"Missing {script}")
    node = which_node()
    if not node:
        raise RuntimeError("Node.js not found on PATH. Install LTS from https://nodejs.org")

    host = (advertise_host or "auto").strip() or "auto"
    cmd = [node, str(script), "--host", host, "--json"]
    if token and token.strip():
        cmd.extend(["--token", token.strip()])

    _log(log, "info", f"Configuring multiplayer advertise host={host} ...")
    proc = subprocess.run(
        cmd,
        cwd=str(root),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(f"configure-multiplayer-host failed: {err[:500]}")

    # stdout may contain WARN on stderr only; parse last JSON object
    text = (proc.stdout or "").strip()
    if not text:
        raise RuntimeError("configure-multiplayer-host returned empty output")
    # Find JSON starting at first {
    start = text.find("{")
    if start < 0:
        raise RuntimeError(f"Unexpected configure output: {text[:300]}")
    summary = json.loads(text[start:])
    _log(log, "ok", f"Multiplayer config applied → {summary.get('host')}")
    if summary.get("bundleRoot"):
        _log(log, "ok", f"Friend bundle: {summary['bundleRoot']}")

    if open_firewall and sys.platform == "win32":
        try_open_firewall_ports(log=log)

    return summary


def try_open_firewall_ports(
    ports: tuple[int, ...] = (26000, 26001, 26002, 5222),
    log: LogFn | None = None,
) -> None:
    """Best-effort inbound TCP rules (needs elevation for success)."""
    if sys.platform != "win32":
        return
    names = {
        26000: "EveJS Game TCP",
        26001: "EveJS Image HTTP",
        26002: "EveJS Proxy HTTP",
        5222: "EveJS XMPP Chat",
    }
    for port in ports:
        name = names.get(port, f"EveJS Port {port}")
        # Skip if exists
        check = subprocess.run(
            ["netsh", "advfirewall", "firewall", "show", "rule", f"name={name}"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        if check.returncode == 0 and "Enabled" in (check.stdout or ""):
            _log(log, "info", f"Firewall rule exists: {name}")
            continue
        add = subprocess.run(
            [
                "netsh",
                "advfirewall",
                "firewall",
                "add",
                "rule",
                f"name={name}",
                "dir=in",
                "action=allow",
                "protocol=TCP",
                f"localport={port}",
                "profile=any",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        if add.returncode == 0:
            _log(log, "ok", f"Added firewall rule: {name} (TCP {port})")
        else:
            _log(
                log,
                "warn",
                f"Could not add firewall rule {name} (run as Administrator?). "
                f"{(add.stderr or add.stdout or '')[:120]}",
            )


def ensure_server_dependencies(log: LogFn | None = None) -> None:
    root = repo_root()
    marker = root / "server" / "node_modules" / "express" / "package.json"
    if marker.is_file():
        _log(log, "ok", "Server npm dependencies present")
        return
    npm = which_npm()
    if not npm:
        raise RuntimeError("npm not found on PATH")
    _log(log, "info", "Running npm ci in server/ ...")
    proc = subprocess.run(
        [npm, "ci"],
        cwd=str(root / "server"),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"npm ci failed: {(proc.stderr or proc.stdout or '')[:400]}")
    _log(log, "ok", "npm ci completed")


def ensure_local_database(log: LogFn | None = None) -> None:
    root = repo_root()
    local_db = root / "_local" / "gameStore"
    manifest = local_db / "manifest.json"
    if manifest.is_file():
        _log(log, "ok", f"Local database ready: {local_db}")
        return
    creator = root / "tools" / "DatabaseCreator" / "CreateDatabase.bat"
    if not creator.is_file():
        raise FileNotFoundError(
            f"Database missing and creator not found: {creator}"
        )
    _log(log, "info", "Creating local database (first run, may take a while)...")
    proc = subprocess.run(
        ["cmd", "/c", str(creator)],
        cwd=str(root),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"CreateDatabase failed ({proc.returncode}): "
            f"{(proc.stderr or proc.stdout or '')[-400:]}"
        )
    _log(log, "ok", "Local database created")


def migrate_legacy_if_needed(log: LogFn | None = None) -> None:
    root = repo_root()
    script = root / "server" / "src" / "gameStore" / "migrateLegacyNewDatabase.js"
    node = which_node()
    if not script.is_file() or not node:
        return
    subprocess.run(
        [node, str(script)],
        cwd=str(root),
        capture_output=True,
        check=False,
    )


def write_frpc_toml(
    path: Path,
    *,
    server_addr: str,
    server_port: int,
    auth_token: str,
    remote_game: int = 26000,
    remote_image: int = 26001,
    remote_proxy: int = 26002,
    remote_xmpp: int = 5222,
    local_ip: str = "127.0.0.1",
) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    # frp v0.52+ TOML style
    content = f"""# Generated by EveJS Server Launcher — do not hand-edit unless you know FRP.
# Friends connect to: {server_addr} (advertise host must match this endpoint)
#
# transport.tcpMux = false is REQUIRED for EveJS:
# CONNECT + TLS (public-gateway) often ECONNRESETs when FRP multiplexes
# many streams on one TCP connection (HTTP ok, TLS-after-CONNECT fails).

serverAddr = "{server_addr}"
serverPort = {int(server_port)}

# Disable stream mux between frpc and frps (more connections, far more reliable).
transport.tcpMux = false

"""
    if auth_token.strip():
        content += f'auth.method = "token"\nauth.token = "{auth_token.strip()}"\n\n'

    proxies = [
        ("evejs-game", 26000, remote_game),
        ("evejs-image", 26001, remote_image),
        ("evejs-proxy", 26002, remote_proxy),
        ("evejs-xmpp", 5222, remote_xmpp),
    ]
    for name, local_port, remote_port in proxies:
        content += f"""[[proxies]]
name = "{name}"
type = "tcp"
localIP = "{local_ip}"
localPort = {local_port}
remotePort = {remote_port}

"""
    path.write_text(content, encoding="utf-8")
    return path


def write_frps_example(path: Path, bind_port: int = 7000, auth_token: str = "") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    token_block = ""
    if auth_token.strip():
        token_block = f'\nauth.method = "token"\nauth.token = "{auth_token.strip()}"\n'
    path.write_text(
        f"""# Example frps.toml for your VPS (copy to the VPS, do not run on the game host)
bindPort = {int(bind_port)}
{token_block}
# Match frpc: disable stream mux (EveJS CONNECT+TLS is unreliable with mux on).
transport.tcpMux = false

# Optional dashboard:
# webServer.addr = "0.0.0.0"
# webServer.port = 7500
# webServer.user = "admin"
# webServer.password = "change-me"
""",
        encoding="utf-8",
    )
    return path


class ProcessHandle:
    """Handle for a child process, optionally running in its own console window."""

    def __init__(self, name: str, proc: subprocess.Popen) -> None:
        self.name = name
        self.proc = proc

    @property
    def running(self) -> bool:
        return self.proc.poll() is None

    def stop(self, timeout: float = 8.0) -> None:
        if not self.running:
            return
        pid = self.proc.pid
        if sys.platform == "win32":
            # Kill the whole tree (npm -> node, etc.) that lives in the new console.
            subprocess.run(
                ["taskkill", "/PID", str(pid), "/T", "/F"],
                capture_output=True,
                check=False,
            )
            try:
                self.proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                pass
            return
        self.proc.terminate()
        try:
            self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=3)


def _windows_new_console_flags() -> int:
    # Own console window; do NOT pipe stdout (piping freezes during large preload logs).
    flags = subprocess.CREATE_NEW_CONSOLE  # type: ignore[attr-defined]
    return int(flags)


def start_evejs_server(log: LogFn | None = None) -> ProcessHandle:
    root = repo_root()
    server_dir = root / "server"
    if not (server_dir / "index.js").is_file():
        raise FileNotFoundError(f"server/index.js not found under {root}")
    npm = which_npm()
    if not npm:
        raise RuntimeError("npm not found on PATH")

    env = os.environ.copy()
    # Must stay 1 for multiplayer/domain/FRP: otherwise CONNECT to
    # public-gateway dials real CCP and TLS fails with connection reset.
    env["EVEJS_PROXY_LOCAL_INTERCEPT"] = "1"
    env["EVEJS_PROXY_GATEWAY_MODE"] = env.get("EVEJS_PROXY_GATEWAY_MODE") or "local"
    env["EVEJS_GAMESTORE_DATA_DIR"] = str(root / "_local" / "gameStore" / "data")
    (root / "server" / "logs" / "node-reports").mkdir(parents=True, exist_ok=True)

    _log(log, "info", "Starting EveJS server in a new console window...")
    _log(log, "info", "EVEJS_PROXY_LOCAL_INTERCEPT=1 (local public-gateway TLS)")

    if sys.platform == "win32":
        # New CMD window, keep open on exit (/k) so user can read crash logs.
        # Matching Server.bat: cd server && npm start with env vars set.
        data_dir = env["EVEJS_GAMESTORE_DATA_DIR"]
        # Use cmd /k so the window stays after errors; title for taskbar.
        inner = (
            f'title EveJS Server & '
            f'cd /d "{server_dir}" & '
            f"set EVEJS_PROXY_LOCAL_INTERCEPT=1 & "
            f"set EVEJS_PROXY_GATEWAY_MODE=local & "
            f'set EVEJS_GAMESTORE_DATA_DIR={data_dir} & '
            f"npm start"
        )
        proc = subprocess.Popen(
            ["cmd.exe", "/k", inner],
            cwd=str(server_dir),
            env=env,
            creationflags=_windows_new_console_flags(),
            close_fds=True,
        )
    else:
        proc = subprocess.Popen(
            [npm, "start"],
            cwd=str(server_dir),
            env=env,
            start_new_session=True,
        )

    time.sleep(0.8)
    if proc.poll() is not None:
        raise RuntimeError(f"Server window exited immediately with code {proc.returncode}")
    _log(log, "ok", f"EveJS server console started (pid={proc.pid})")
    _log(log, "info", "Watch the separate black CMD window for preload / ready logs.")
    return ProcessHandle("evejs", proc)


def start_frpc(
    frpc_path: Path,
    config_path: Path,
    log: LogFn | None = None,
) -> ProcessHandle:
    if not frpc_path.is_file():
        raise FileNotFoundError(f"frpc not found: {frpc_path}")
    if not config_path.is_file():
        raise FileNotFoundError(f"frpc config not found: {config_path}")

    _log(log, "info", f"Starting frpc in a new console: {frpc_path}")

    if sys.platform == "win32":
        inner = (
            f'title EveJS frpc & '
            f'cd /d "{config_path.parent}" & '
            f'"{frpc_path}" -c "{config_path}"'
        )
        proc = subprocess.Popen(
            ["cmd.exe", "/k", inner],
            cwd=str(config_path.parent),
            creationflags=_windows_new_console_flags(),
            close_fds=True,
        )
    else:
        proc = subprocess.Popen(
            [str(frpc_path), "-c", str(config_path)],
            cwd=str(config_path.parent),
            start_new_session=True,
        )

    time.sleep(0.5)
    if proc.poll() is not None:
        raise RuntimeError(f"frpc exited immediately with code {proc.returncode}")
    _log(log, "ok", f"frpc console started (pid={proc.pid})")
    return ProcessHandle("frpc", proc)


def prepare_host(
    state: LauncherState,
    log: LogFn | None = None,
) -> dict:
    """Configure multiplayer + DB + deps. Returns configure summary."""
    if state.mode == "ddns":
        host = state.advertise_host.strip() or "auto"
        _log(log, "info", "Mode: 公网 IP + DDNS / 端口转发")
        _log(
            log,
            "info",
            "请在路由器把 26000/26001/26002/5222 转发到本机，DDNS 指到公网 IP。",
        )
    elif state.mode == "frp":
        host = state.advertise_host.strip()
        if not host:
            # Friends connect via VPS — default advertise to frp server addr
            host = state.frp_server_addr.strip()
        if not host:
            raise ValueError("FRP 模式请填写「对外域名/IP」(朋友连接地址，一般是 VPS)")
        _log(log, "info", "Mode: 无公网 IP + FRP")
        _log(log, "info", f"Friends will use advertise host: {host}")
    else:
        raise ValueError(f"Unknown mode: {state.mode}")

    migrate_legacy_if_needed(log=log)
    ensure_local_database(log=log)
    ensure_server_dependencies(log=log)

    summary = configure_multiplayer(
        host,
        token=state.player_token or None,
        open_firewall=state.open_firewall and state.mode == "ddns",
        log=log,
    )

    # Always write FRP templates under _local/frp for convenience
    frp_dir = repo_root() / "_local" / "frp"
    write_frpc_toml(
        frp_dir / "frpc.toml",
        server_addr=state.frp_server_addr.strip() or "YOUR_VPS_IP",
        server_port=int(state.frp_server_port or 7000),
        auth_token=state.frp_auth_token,
        remote_game=int(state.frp_remote_game or 26000),
        remote_image=int(state.frp_remote_image or 26001),
        remote_proxy=int(state.frp_remote_proxy or 26002),
        remote_xmpp=int(state.frp_remote_xmpp or 5222),
    )
    write_frps_example(
        frp_dir / "frps.example.toml",
        bind_port=int(state.frp_server_port or 7000),
        auth_token=state.frp_auth_token,
    )
    _log(log, "info", f"FRP configs written under {frp_dir}")
    return summary
