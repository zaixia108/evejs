"""customtkinter GUI for EveJS multiplayer client launcher."""

from __future__ import annotations

import queue
import threading
import traceback
from pathlib import Path
from tkinter import filedialog, messagebox

import customtkinter as ctk

from evejs_client.engine import (
    LocalState,
    ServerInfo,
    app_base_dir,
    health_check,
    load_server_info,
    prepare_and_launch,
    save_server_info,
    tcp_open,
)

ctk.set_appearance_mode("dark")
ctk.set_default_color_theme("blue")


class ClientLauncherApp(ctk.CTk):
    def __init__(self) -> None:
        super().__init__()
        self.title("EveJS Client Launcher")
        self.geometry("720x620")
        self.minsize(640, 560)

        self.bundle_dir = app_base_dir()
        self.bundle_dir.mkdir(parents=True, exist_ok=True)
        self.state_path = self.bundle_dir / "player-local.json"
        self._worker: threading.Thread | None = None
        self._log_queue: queue.Queue[tuple[str, str]] = queue.Queue()

        self._build_ui()
        self._load_initial()
        self.after(100, self._drain_log_queue)

    def _build_ui(self) -> None:
        pad = {"padx": 16, "pady": 6}

        header = ctk.CTkFrame(self, fg_color="transparent")
        header.pack(fill="x", **pad)
        ctk.CTkLabel(
            header,
            text="EveJS 联机客户端",
            font=ctk.CTkFont(size=22, weight="bold"),
        ).pack(anchor="w")
        ctk.CTkLabel(
            header,
            text="连接好友主机 · 安装证书 · 启动 EVE 客户端",
            text_color=("gray40", "gray70"),
            font=ctk.CTkFont(size=13),
        ).pack(anchor="w")

        form = ctk.CTkFrame(self)
        form.pack(fill="x", padx=16, pady=8)
        form.grid_columnconfigure(1, weight=1)

        def row(r: int, label: str, widget) -> None:
            ctk.CTkLabel(form, text=label, width=100, anchor="w").grid(
                row=r, column=0, sticky="w", padx=12, pady=8
            )
            widget.grid(row=r, column=1, sticky="ew", padx=12, pady=8)

        self.host_var = ctk.StringVar(value="192.168.28.65")
        self.token_var = ctk.StringVar(value="test")
        self.game_port_var = ctk.StringVar(value="26000")
        self.proxy_port_var = ctk.StringVar(value="26002")
        self.client_path_var = ctk.StringVar(value="")

        row(0, "主机 IP", ctk.CTkEntry(form, textvariable=self.host_var))
        row(1, "Token", ctk.CTkEntry(form, textvariable=self.token_var, show="*"))
        ports = ctk.CTkFrame(form, fg_color="transparent")
        ports.grid_columnconfigure((0, 1, 2, 3), weight=1)
        ctk.CTkLabel(ports, text="游戏端口").grid(row=0, column=0, sticky="w")
        ctk.CTkEntry(ports, textvariable=self.game_port_var, width=80).grid(
            row=0, column=1, sticky="w", padx=(4, 16)
        )
        ctk.CTkLabel(ports, text="代理端口").grid(row=0, column=2, sticky="w")
        ctk.CTkEntry(ports, textvariable=self.proxy_port_var, width=80).grid(
            row=0, column=3, sticky="w", padx=4
        )
        row(2, "端口", ports)

        client_row = ctk.CTkFrame(form, fg_color="transparent")
        client_row.grid_columnconfigure(0, weight=1)
        ctk.CTkEntry(client_row, textvariable=self.client_path_var).grid(
            row=0, column=0, sticky="ew"
        )
        ctk.CTkButton(
            client_row, text="浏览…", width=80, command=self._browse_client
        ).grid(row=0, column=1, padx=(8, 0))
        row(3, "EVE tq 目录", client_row)

        ctk.CTkLabel(
            form,
            text=f"数据目录: {self.bundle_dir}",
            text_color=("gray40", "gray60"),
            font=ctk.CTkFont(size=11),
            anchor="w",
        ).grid(row=4, column=0, columnspan=2, sticky="ew", padx=12, pady=(0, 8))

        actions = ctk.CTkFrame(self, fg_color="transparent")
        actions.pack(fill="x", padx=16, pady=4)
        self.btn_test = ctk.CTkButton(
            actions, text="测试连接", width=120, command=self._on_test
        )
        self.btn_test.pack(side="left", padx=(0, 8))
        self.btn_prepare = ctk.CTkButton(
            actions,
            text="仅准备（不启动）",
            width=140,
            fg_color=("gray50", "gray30"),
            command=self._on_prepare,
        )
        self.btn_prepare.pack(side="left", padx=8)
        self.btn_play = ctk.CTkButton(
            actions,
            text="连接并启动游戏",
            width=160,
            font=ctk.CTkFont(weight="bold"),
            command=self._on_play,
        )
        self.btn_play.pack(side="right")

        log_frame = ctk.CTkFrame(self)
        log_frame.pack(fill="both", expand=True, padx=16, pady=(8, 16))
        ctk.CTkLabel(log_frame, text="日志", anchor="w").pack(
            fill="x", padx=12, pady=(8, 0)
        )
        self.log_box = ctk.CTkTextbox(log_frame, height=220, font=ctk.CTkFont(family="Consolas", size=12))
        self.log_box.pack(fill="both", expand=True, padx=12, pady=8)
        self.log_box.configure(state="disabled")

        self.status_var = ctk.StringVar(value="就绪")
        ctk.CTkLabel(self, textvariable=self.status_var, anchor="w").pack(
            fill="x", padx=16, pady=(0, 10)
        )

    def _load_initial(self) -> None:
        try:
            if (self.bundle_dir / "server.json").is_file():
                info = load_server_info(self.bundle_dir)
                self.host_var.set(info.host)
                self.token_var.set(info.token)
                self.game_port_var.set(str(info.game_port))
                self.proxy_port_var.set(str(info.proxy_port))
                self._append_log("ok", f"已加载 server.json → {info.host}")
            else:
                self._append_log("warn", f"未找到 server.json，将使用表单写入: {self.bundle_dir}")
        except Exception as exc:  # noqa: BLE001
            self._append_log("error", f"读取 server.json 失败: {exc}")

        state = LocalState.load(self.state_path)
        if state.client_path:
            self.client_path_var.set(state.client_path)

    def _browse_client(self) -> None:
        path = filedialog.askdirectory(title="选择 EVE 客户端 tq 目录")
        if path:
            self.client_path_var.set(path)

    def _append_log(self, level: str, message: str) -> None:
        prefix = {"info": "  ", "ok": "OK", "warn": "!!", "error": "XX"}.get(level, "  ")
        line = f"[{prefix}] {message}\n"
        self.log_box.configure(state="normal")
        self.log_box.insert("end", line)
        self.log_box.see("end")
        self.log_box.configure(state="disabled")

    def _queue_log(self, level: str, message: str) -> None:
        self._log_queue.put((level, message))

    def _drain_log_queue(self) -> None:
        try:
            while True:
                level, message = self._log_queue.get_nowait()
                self._append_log(level, message)
        except queue.Empty:
            pass
        self.after(100, self._drain_log_queue)

    def _set_busy(self, busy: bool, status: str = "") -> None:
        state = "disabled" if busy else "normal"
        for btn in (self.btn_test, self.btn_prepare, self.btn_play):
            btn.configure(state=state)
        if status:
            self.status_var.set(status)

    def _server_from_form(self) -> ServerInfo:
        host = self.host_var.get().strip()
        token = self.token_var.get().strip()
        if not host:
            raise ValueError("请填写主机 IP / 主机名")
        if not token:
            raise ValueError("请填写 PlayerConnect Token")
        game_port = int(self.game_port_var.get().strip() or "26000")
        proxy_port = int(self.proxy_port_var.get().strip() or "26002")
        return ServerInfo(
            host=host,
            token=token,
            game_port=game_port,
            proxy_port=proxy_port,
            proxy_url=f"http://{host}:{proxy_port}/",
            image_server_url=f"http://{host}:26001/",
        )

    def _client_path(self) -> Path:
        raw = self.client_path_var.get().strip()
        if not raw:
            raise ValueError("请选择 EVE 客户端 tq 目录")
        path = Path(raw)
        if not path.is_dir():
            raise ValueError(f"目录不存在: {path}")
        return path

    def _persist_form(self, server: ServerInfo) -> None:
        save_server_info(server, self.bundle_dir)
        state = LocalState.load(self.state_path)
        state.client_path = self.client_path_var.get().strip()
        state.last_host = server.host
        state.save(self.state_path)

    def _on_test(self) -> None:
        if self._worker and self._worker.is_alive():
            return

        def work() -> None:
            try:
                server = self._server_from_form()
                self._queue_log("info", f"测试 {server.host} …")
                health = health_check(server, log=self._queue_log)
                game_ok = tcp_open(server.host, server.game_port)
                if game_ok:
                    self._queue_log("ok", f"游戏端口 {server.game_port} 可达")
                else:
                    self._queue_log("error", f"游戏端口 {server.game_port} 不可达")
                if health and game_ok:
                    self.after(0, lambda: self.status_var.set("连接正常"))
                    self.after(
                        0,
                        lambda: messagebox.showinfo(
                            "测试连接",
                            f"主机在线\n"
                            f"host={health.get('host')}\n"
                            f"xmpp={health.get('xmppHost')}\n"
                            f"gamePortOpen={health.get('gamePortOpen')}",
                        ),
                    )
                else:
                    self.after(0, lambda: self.status_var.set("连接异常"))
            except Exception as exc:  # noqa: BLE001
                self._queue_log("error", str(exc))
                self.after(0, lambda: messagebox.showerror("测试失败", str(exc)))
            finally:
                self.after(0, lambda: self._set_busy(False))

        self._set_busy(True, "测试中…")
        self._worker = threading.Thread(target=work, daemon=True)
        self._worker.start()

    def _run_prepare_launch(self, *, skip_launch: bool) -> None:
        if self._worker and self._worker.is_alive():
            return

        def work() -> None:
            try:
                server = self._server_from_form()
                tq = self._client_path()
                self._persist_form(server)
                self._queue_log("info", "写入 server.json / player-local.json")
                code = prepare_and_launch(
                    server,
                    tq,
                    self.bundle_dir,
                    skip_launch=skip_launch,
                    force_setup=False,
                    log=self._queue_log,
                )
                if skip_launch:
                    self.after(0, lambda: self.status_var.set("准备完成"))
                    self.after(
                        0,
                        lambda: messagebox.showinfo("完成", "客户端已准备好，可再点「连接并启动游戏」。"),
                    )
                else:
                    self.after(0, lambda: self.status_var.set(f"游戏已退出 ({code})"))
            except Exception as exc:  # noqa: BLE001
                tb = traceback.format_exc()
                self._queue_log("error", str(exc))
                self._queue_log("info", tb)
                self.after(0, lambda: self.status_var.set("失败"))
                self.after(0, lambda: messagebox.showerror("失败", str(exc)))
            finally:
                self.after(0, lambda: self._set_busy(False))

        self._set_busy(True, "准备中…" if skip_launch else "启动中…")
        self._worker = threading.Thread(target=work, daemon=True)
        self._worker.start()

    def _on_prepare(self) -> None:
        self._run_prepare_launch(skip_launch=True)

    def _on_play(self) -> None:
        self._run_prepare_launch(skip_launch=False)


def run_app() -> None:
    app = ClientLauncherApp()
    app.mainloop()
