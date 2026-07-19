"""customtkinter GUI — EveJS multiplayer server launcher (DDNS / FRP)."""

from __future__ import annotations

import queue
import threading
import traceback
from pathlib import Path
from tkinter import filedialog, messagebox

import customtkinter as ctk

from evejs_server.engine import (
    LauncherState,
    ProcessHandle,
    detect_lan_ip,
    prepare_host,
    repo_root,
    start_evejs_server,
    start_frpc,
    write_frpc_toml,
    write_frps_example,
)

ctk.set_appearance_mode("dark")
ctk.set_default_color_theme("dark-blue")


class ServerLauncherApp(ctk.CTk):
    def __init__(self) -> None:
        super().__init__()
        self.title("EveJS Server Launcher")
        self.geometry("860x720")
        self.minsize(780, 640)

        self.root = repo_root()
        self.state_path = self.root / "_local" / "server-launcher.json"
        self.frp_dir = self.root / "_local" / "frp"
        # Do not name this `self.state` — CTk uses self.state(...) for window state.
        self.launcher_state = LauncherState.load(self.state_path)

        self._server: ProcessHandle | None = None
        self._frpc: ProcessHandle | None = None
        self._worker: threading.Thread | None = None
        self._log_queue: queue.Queue[tuple[str, str]] = queue.Queue()

        self._build_ui()
        self._apply_state_to_form()
        self._on_mode_change()
        self.after(100, self._drain_log)
        self.protocol("WM_DELETE_WINDOW", self._on_close)

    def _build_ui(self) -> None:
        pad = {"padx": 16, "pady": 4}

        header = ctk.CTkFrame(self, fg_color="transparent")
        header.pack(fill="x", **pad)
        ctk.CTkLabel(
            header,
            text="EveJS 联机服务器启动器",
            font=ctk.CTkFont(size=22, weight="bold"),
        ).pack(anchor="w")
        ctk.CTkLabel(
            header,
            text=f"项目目录: {self.root}",
            text_color=("gray40", "gray65"),
            font=ctk.CTkFont(size=12),
        ).pack(anchor="w")

        # Mode
        mode_frame = ctk.CTkFrame(self)
        mode_frame.pack(fill="x", padx=16, pady=8)
        ctk.CTkLabel(
            mode_frame, text="联网方案", font=ctk.CTkFont(weight="bold")
        ).pack(anchor="w", padx=12, pady=(10, 4))
        self.mode_var = ctk.StringVar(value=self.launcher_state.mode or "ddns")
        self.mode_seg = ctk.CTkSegmentedButton(
            mode_frame,
            values=["公网 IP + DDNS", "无公网 IP + FRP"],
            command=self._on_mode_seg,
        )
        self.mode_seg.pack(fill="x", padx=12, pady=(0, 10))
        if self.launcher_state.mode == "frp":
            self.mode_seg.set("无公网 IP + FRP")
        else:
            self.mode_seg.set("公网 IP + DDNS")

        # Common form
        self.common_frame = ctk.CTkFrame(self)
        common = self.common_frame
        common.pack(fill="x", padx=16, pady=4)
        common.grid_columnconfigure(1, weight=1)

        self.advertise_var = ctk.StringVar()
        self.token_var = ctk.StringVar()
        self.fw_var = ctk.BooleanVar(value=True)

        ctk.CTkLabel(common, text="对外地址", width=110, anchor="w").grid(
            row=0, column=0, sticky="w", padx=12, pady=8
        )
        ctk.CTkEntry(
            common,
            textvariable=self.advertise_var,
            placeholder_text="DDNS 域名 / VPS 域名或公网 IP",
        ).grid(row=0, column=1, sticky="ew", padx=12, pady=8)
        ctk.CTkButton(
            common, text="填入局域网 IP", width=110, command=self._fill_lan
        ).grid(row=0, column=2, padx=(0, 12))

        ctk.CTkLabel(common, text="联机 Token", width=110, anchor="w").grid(
            row=1, column=0, sticky="w", padx=12, pady=8
        )
        ctk.CTkEntry(common, textvariable=self.token_var, show="*").grid(
            row=1, column=1, columnspan=2, sticky="ew", padx=12, pady=8
        )

        self.fw_check = ctk.CTkCheckBox(
            common,
            text="尝试添加 Windows 防火墙入站规则（需管理员）",
            variable=self.fw_var,
        )
        self.fw_check.grid(row=2, column=0, columnspan=3, sticky="w", padx=12, pady=(0, 10))

        self.hint_label = ctk.CTkLabel(
            common,
            text="",
            wraplength=780,
            justify="left",
            text_color=("gray30", "gray70"),
            font=ctk.CTkFont(size=12),
        )
        self.hint_label.grid(row=3, column=0, columnspan=3, sticky="ew", padx=12, pady=(0, 10))

        # FRP panel
        self.frp_frame = ctk.CTkFrame(self)
        self.frp_frame.pack(fill="x", padx=16, pady=4)
        self.frp_frame.grid_columnconfigure(1, weight=1)
        ctk.CTkLabel(
            self.frp_frame, text="FRP 客户端设置", font=ctk.CTkFont(weight="bold")
        ).grid(row=0, column=0, columnspan=3, sticky="w", padx=12, pady=(10, 4))

        self.frp_server_var = ctk.StringVar()
        self.frp_port_var = ctk.StringVar(value="7000")
        self.frp_token_var = ctk.StringVar()
        self.frpc_path_var = ctk.StringVar()
        self.auto_frpc_var = ctk.BooleanVar(value=True)
        self.r_game = ctk.StringVar(value="26000")
        self.r_image = ctk.StringVar(value="26001")
        self.r_proxy = ctk.StringVar(value="26002")
        self.r_xmpp = ctk.StringVar(value="5222")

        def fr(r: int, label: str, widget) -> None:
            ctk.CTkLabel(self.frp_frame, text=label, width=110, anchor="w").grid(
                row=r, column=0, sticky="w", padx=12, pady=6
            )
            widget.grid(row=r, column=1, columnspan=2, sticky="ew", padx=12, pady=6)

        fr(1, "VPS 地址", ctk.CTkEntry(self.frp_frame, textvariable=self.frp_server_var))
        ports_row = ctk.CTkFrame(self.frp_frame, fg_color="transparent")
        ctk.CTkLabel(ports_row, text="frps 端口").pack(side="left")
        ctk.CTkEntry(ports_row, textvariable=self.frp_port_var, width=80).pack(
            side="left", padx=6
        )
        ctk.CTkLabel(ports_row, text="鉴权 token").pack(side="left", padx=(12, 0))
        ctk.CTkEntry(ports_row, textvariable=self.frp_token_var, show="*", width=160).pack(
            side="left", padx=6
        )
        fr(2, "连接参数", ports_row)

        frpc_row = ctk.CTkFrame(self.frp_frame, fg_color="transparent")
        frpc_row.grid_columnconfigure(0, weight=1)
        ctk.CTkEntry(frpc_row, textvariable=self.frpc_path_var).grid(
            row=0, column=0, sticky="ew"
        )
        ctk.CTkButton(frpc_row, text="浏览 frpc…", width=100, command=self._browse_frpc).grid(
            row=0, column=1, padx=(8, 0)
        )
        fr(3, "frpc 程序", frpc_row)

        rem = ctk.CTkFrame(self.frp_frame, fg_color="transparent")
        for i, (lab, var) in enumerate(
            [
                ("远程游戏", self.r_game),
                ("图片", self.r_image),
                ("代理", self.r_proxy),
                ("聊天", self.r_xmpp),
            ]
        ):
            ctk.CTkLabel(rem, text=lab).grid(row=0, column=i * 2, padx=(0, 4))
            ctk.CTkEntry(rem, textvariable=var, width=70).grid(row=0, column=i * 2 + 1, padx=(0, 10))
        fr(4, "VPS 远程端口", rem)

        ctk.CTkCheckBox(
            self.frp_frame,
            text="启动服务器时自动启动 frpc",
            variable=self.auto_frpc_var,
        ).grid(row=5, column=0, columnspan=3, sticky="w", padx=12, pady=(0, 10))

        # Actions
        actions = ctk.CTkFrame(self, fg_color="transparent")
        actions.pack(fill="x", padx=16, pady=8)
        self.btn_cfg = ctk.CTkButton(
            actions, text="仅写入配置 / 导出联机包", width=180, command=self._on_configure
        )
        self.btn_cfg.pack(side="left", padx=(0, 8))
        self.btn_gen_frp = ctk.CTkButton(
            actions,
            text="生成 FRP 配置文件",
            width=140,
            fg_color=("gray50", "gray35"),
            command=self._on_gen_frp,
        )
        self.btn_gen_frp.pack(side="left", padx=8)
        self.btn_stop = ctk.CTkButton(
            actions,
            text="停止",
            width=90,
            fg_color=("#8B3A3A", "#6B2A2A"),
            command=self._on_stop,
            state="disabled",
        )
        self.btn_stop.pack(side="right", padx=(8, 0))
        self.btn_start = ctk.CTkButton(
            actions,
            text="配置并启动服务器",
            width=160,
            font=ctk.CTkFont(weight="bold"),
            command=self._on_start,
        )
        self.btn_start.pack(side="right")

        # Log
        log_frame = ctk.CTkFrame(self)
        log_frame.pack(fill="both", expand=True, padx=16, pady=(4, 12))
        ctk.CTkLabel(log_frame, text="日志", anchor="w").pack(fill="x", padx=12, pady=(8, 0))
        self.log_box = ctk.CTkTextbox(
            log_frame, font=ctk.CTkFont(family="Consolas", size=12)
        )
        self.log_box.pack(fill="both", expand=True, padx=12, pady=8)
        self.log_box.configure(state="disabled")

        self.status_var = ctk.StringVar(value="就绪")
        ctk.CTkLabel(self, textvariable=self.status_var, anchor="w").pack(
            fill="x", padx=16, pady=(0, 10)
        )

    def _on_mode_seg(self, value: str) -> None:
        self.mode_var.set("frp" if "FRP" in value else "ddns")
        self._on_mode_change()

    def _on_mode_change(self) -> None:
        mode = self.mode_var.get()
        # Re-pack FRP block between common form and action buttons.
        self.frp_frame.pack_forget()
        if mode == "frp":
            self.frp_frame.pack(fill="x", padx=16, pady=4, after=self.common_frame)
            self.fw_check.configure(state="disabled")
            self.hint_label.configure(
                text=(
                    "无公网 IP：在 VPS 上运行 frps，本机运行 frpc 映射 26000/26001/26002/5222。\n"
                    "「对外地址」填朋友要连接的地址（通常是 VPS 域名或公网 IP），"
                    "会写入 EveJS 配置与联机包。"
                )
            )
            self.btn_gen_frp.configure(state="normal")
        else:
            self.fw_check.configure(state="normal")
            self.hint_label.configure(
                text=(
                    "有公网 IP：配置 DDNS 指向你家公网 IP，路由器端口转发 "
                    "26000、26001、26002、5222 → 本机。\n"
                    "「对外地址」填 DDNS 域名（或公网 IP）。可点「填入局域网 IP」做内网测试。"
                )
            )
            self.btn_gen_frp.configure(state="disabled")

    def _apply_state_to_form(self) -> None:
        s = self.launcher_state
        self.advertise_var.set(s.advertise_host)
        self.token_var.set(s.player_token or "test")
        self.fw_var.set(bool(s.open_firewall))
        self.frp_server_var.set(s.frp_server_addr)
        self.frp_port_var.set(str(s.frp_server_port or 7000))
        self.frp_token_var.set(s.frp_auth_token)
        self.frpc_path_var.set(s.frpc_path)
        self.auto_frpc_var.set(bool(s.auto_start_frpc))
        self.r_game.set(str(s.frp_remote_game or 26000))
        self.r_image.set(str(s.frp_remote_image or 26001))
        self.r_proxy.set(str(s.frp_remote_proxy or 26002))
        self.r_xmpp.set(str(s.frp_remote_xmpp or 5222))

    def _collect_state(self) -> LauncherState:
        mode = "frp" if "FRP" in self.mode_seg.get() else "ddns"
        return LauncherState(
            mode=mode,
            advertise_host=self.advertise_var.get().strip(),
            player_token=self.token_var.get().strip(),
            open_firewall=bool(self.fw_var.get()),
            frp_server_addr=self.frp_server_var.get().strip(),
            frp_server_port=int(self.frp_port_var.get().strip() or "7000"),
            frp_auth_token=self.frp_token_var.get().strip(),
            frpc_path=self.frpc_path_var.get().strip(),
            frp_remote_game=int(self.r_game.get().strip() or "26000"),
            frp_remote_image=int(self.r_image.get().strip() or "26001"),
            frp_remote_proxy=int(self.r_proxy.get().strip() or "26002"),
            frp_remote_xmpp=int(self.r_xmpp.get().strip() or "5222"),
            auto_start_frpc=bool(self.auto_frpc_var.get()),
        )

    def _fill_lan(self) -> None:
        ip = detect_lan_ip()
        self.advertise_var.set(ip)
        self._append("ok", f"局域网 IP: {ip}")

    def _browse_frpc(self) -> None:
        path = filedialog.askopenfilename(
            title="选择 frpc.exe",
            filetypes=[("frpc", "frpc.exe"), ("All", "*.*")],
        )
        if path:
            self.frpc_path_var.set(path)

    def _append(self, level: str, msg: str) -> None:
        prefix = {"info": "  ", "ok": "OK", "warn": "!!", "error": "XX"}.get(level, "  ")
        self.log_box.configure(state="normal")
        self.log_box.insert("end", f"[{prefix}] {msg}\n")
        self.log_box.see("end")
        self.log_box.configure(state="disabled")

    def _qlog(self, level: str, msg: str) -> None:
        self._log_queue.put((level, msg))

    def _drain_log(self) -> None:
        try:
            while True:
                level, msg = self._log_queue.get_nowait()
                self._append(level, msg)
        except queue.Empty:
            pass
        # process liveness
        if self._server and not self._server.running:
            self._qlog("warn", "EveJS server process exited")
            self._server = None
            self.after(0, self._refresh_buttons)
        if self._frpc and not self._frpc.running:
            self._qlog("warn", "frpc process exited")
            self._frpc = None
            self.after(0, self._refresh_buttons)
        self.after(120, self._drain_log)

    def _set_busy(self, busy: bool, status: str = "") -> None:
        st = "disabled" if busy else "normal"
        self.btn_cfg.configure(state=st)
        self.btn_start.configure(state=st)
        if status:
            self.status_var.set(status)
        self._refresh_buttons()

    def _refresh_buttons(self) -> None:
        running = bool(
            (self._server and self._server.running)
            or (self._frpc and self._frpc.running)
        )
        self.btn_stop.configure(state="normal" if running else "disabled")
        if running:
            parts = []
            if self._server and self._server.running:
                parts.append(f"server pid={self._server.proc.pid}")
            if self._frpc and self._frpc.running:
                parts.append(f"frpc pid={self._frpc.proc.pid}")
            self.status_var.set("运行中: " + ", ".join(parts))

    def _on_gen_frp(self) -> None:
        try:
            st = self._collect_state()
            st.save(self.state_path)
            cfg = write_frpc_toml(
                self.frp_dir / "frpc.toml",
                server_addr=st.frp_server_addr or "YOUR_VPS_IP",
                server_port=st.frp_server_port,
                auth_token=st.frp_auth_token,
                remote_game=st.frp_remote_game,
                remote_image=st.frp_remote_image,
                remote_proxy=st.frp_remote_proxy,
                remote_xmpp=st.frp_remote_xmpp,
            )
            ex = write_frps_example(
                self.frp_dir / "frps.example.toml",
                bind_port=st.frp_server_port,
                auth_token=st.frp_auth_token,
            )
            self._append("ok", f"已生成 {cfg}")
            self._append("ok", f"VPS 示例 {ex}")
            messagebox.showinfo(
                "FRP 配置",
                f"已写入:\n{cfg}\n{ex}\n\n"
                "把 frps.example.toml 拷到 VPS 改名运行 frps；\n"
                "本机用 frpc -c frpc.toml（或点「配置并启动」自动拉起）。",
            )
        except Exception as exc:  # noqa: BLE001
            messagebox.showerror("失败", str(exc))

    def _on_configure(self) -> None:
        if self._worker and self._worker.is_alive():
            return

        def work() -> None:
            try:
                st = self._collect_state()
                st.save(self.state_path)
                summary = prepare_host(st, log=self._qlog)
                host = summary.get("host", st.advertise_host)
                bundle = summary.get("bundleRoot", "")
                self.after(
                    0,
                    lambda: messagebox.showinfo(
                        "配置完成",
                        f"advertise host: {host}\n"
                        f"联机包: {bundle}\n\n"
                        "把 _local\\player-connect-bundle 发给朋友即可。",
                    ),
                )
                self.after(0, lambda: self.status_var.set("配置已写入"))
            except Exception as exc:  # noqa: BLE001
                self._qlog("error", str(exc))
                self._qlog("info", traceback.format_exc())
                self.after(0, lambda: messagebox.showerror("配置失败", str(exc)))
            finally:
                self.after(0, lambda: self._set_busy(False))

        self._set_busy(True, "配置中…")
        self._worker = threading.Thread(target=work, daemon=True)
        self._worker.start()

    def _on_start(self) -> None:
        if self._worker and self._worker.is_alive():
            return
        if self._server and self._server.running:
            messagebox.showwarning("已在运行", "服务器进程已在运行，请先停止。")
            return

        def work() -> None:
            try:
                st = self._collect_state()
                if st.mode == "ddns" and not st.advertise_host.strip():
                    # auto LAN for convenience
                    st.advertise_host = "auto"
                if st.mode == "frp":
                    if not st.advertise_host.strip():
                        st.advertise_host = st.frp_server_addr.strip()
                    if not st.advertise_host:
                        raise ValueError("请填写对外地址（VPS 域名或公网 IP）")
                    if st.auto_start_frpc and not st.frpc_path:
                        raise ValueError("请选择 frpc.exe 路径，或取消「自动启动 frpc」")
                    if st.auto_start_frpc and not st.frp_server_addr:
                        raise ValueError("请填写 VPS 地址（frps serverAddr）")

                st.save(self.state_path)
                prepare_host(st, log=self._qlog)

                if st.mode == "frp" and st.auto_start_frpc:
                    cfg = self.frp_dir / "frpc.toml"
                    write_frpc_toml(
                        cfg,
                        server_addr=st.frp_server_addr,
                        server_port=st.frp_server_port,
                        auth_token=st.frp_auth_token,
                        remote_game=st.frp_remote_game,
                        remote_image=st.frp_remote_image,
                        remote_proxy=st.frp_remote_proxy,
                        remote_xmpp=st.frp_remote_xmpp,
                    )
                    self._frpc = start_frpc(Path(st.frpc_path), cfg, log=self._qlog)

                self._server = start_evejs_server(log=self._qlog)
                self._qlog(
                    "ok",
                    "服务器已启动。联机包目录: "
                    f"{self.root / '_local' / 'player-connect-bundle'}",
                )
                self.after(0, self._refresh_buttons)
            except Exception as exc:  # noqa: BLE001
                self._qlog("error", str(exc))
                self._qlog("info", traceback.format_exc())
                self.after(0, lambda: messagebox.showerror("启动失败", str(exc)))
                self._stop_all()
            finally:
                self.after(0, lambda: self._set_busy(False))

        self._set_busy(True, "启动中…")
        self._worker = threading.Thread(target=work, daemon=True)
        self._worker.start()

    def _stop_all(self) -> None:
        if self._frpc:
            try:
                self._frpc.stop()
                self._qlog("ok", "frpc stopped")
            except Exception as exc:  # noqa: BLE001
                self._qlog("warn", f"stop frpc: {exc}")
            self._frpc = None
        if self._server:
            try:
                self._server.stop()
                self._qlog("ok", "EveJS server stopped")
            except Exception as exc:  # noqa: BLE001
                self._qlog("warn", f"stop server: {exc}")
            self._server = None

    def _on_stop(self) -> None:
        self._stop_all()
        self.status_var.set("已停止")
        self._refresh_buttons()

    def _on_close(self) -> None:
        if (self._server and self._server.running) or (
            self._frpc and self._frpc.running
        ):
            if not messagebox.askyesno("退出", "服务器仍在运行，是否停止并退出？"):
                return
            self._stop_all()
        self.destroy()


def run_app() -> None:
    app = ServerLauncherApp()
    app.mainloop()
