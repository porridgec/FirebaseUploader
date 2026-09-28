import json
import os
import re
import shlex
import subprocess
import threading
from datetime import datetime
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

CACHE_FILE = os.path.expanduser("~/.firebase_uploader_cache.json")

# ---------- helpers ----------
def run_cmd(args, on_line=None):
    """
    Run command with real-time output (stdout+stderr merged).
    args: list[str]
    """
    print(f"$ {shlex.join(args)}", flush=True)
    try:
        p = subprocess.Popen(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
    except FileNotFoundError:
        raise RuntimeError("找不到 firebase 命令。请先安装：npm i -g firebase-tools，并确保 PATH 可用。")

    out_lines = []
    for line in p.stdout:
        out_lines.append(line)
        if on_line:
            on_line(line)
    code = p.wait()
    return code, "".join(out_lines)

def safe_ui(root, fn):
    root.after(0, fn)

def parse_console_links(text):
    # Grab common URLs printed by firebase-tools
    urls = re.findall(r"https?://\S+", text)
    return urls

# ---------- GUI ----------
class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Firebase App Distribution GUI (CLI wrapper)")
        self.geometry("980x820")
        self.minsize(900, 760)

        self.projects = []   # list of {projectId, displayName, ...}
        self.apps = []       # list of iOS apps
        self.groups = []     # list of group names (string) - depends on CLI output

        self.selected_project = tk.StringVar()
        self.selected_app = tk.StringVar()

        self.ipa_path = tk.StringVar()
        self.dsym_path = tk.StringVar()
        self.release_mark = tk.StringVar()
        self.final_release_notes = tk.StringVar()
        self.uploader = tk.StringVar(value="")

        self.cache = self._load_cache()

        self._build_ui()
        self.release_mark.trace_add("write", self._on_release_mark_changed)
        self.uploader.trace_add("write", self._refresh_final_release_notes)
        self._refresh_final_release_notes()
        self._restore_cached_ui()

    def _refresh_final_release_notes(self, *_args):
        mark = self.release_mark.get().strip()
        uploader_name = self.uploader.get().strip()
        # uploader 为空时不加括号，release notes 只含 mark
        notes = f"{mark} [{uploader_name}]" if uploader_name else mark
        self.final_release_notes.set(notes.strip())

    def _on_release_mark_changed(self, *_args):
        self._refresh_final_release_notes()
        self.cache["last_release_mark"] = self.release_mark.get()
        self._save_cache()

    def _load_cache(self):
        try:
            with open(CACHE_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except Exception:
            return {}

    def _save_cache(self):
        try:
            with open(CACHE_FILE, "w", encoding="utf-8") as f:
                json.dump(self.cache, f, ensure_ascii=False, indent=2)
        except Exception:
            pass

    def _restore_cached_ui(self):
        project_choices = self.cache.get("projects_choices")
        if isinstance(project_choices, list) and project_choices:
            self.project_cb["values"] = project_choices
            last_project = self.cache.get("selected_project")
            if last_project in project_choices:
                self.selected_project.set(last_project)
            else:
                self.project_cb.current(0)

        app_choices = self.cache.get("apps_choices")
        if isinstance(app_choices, list) and app_choices:
            self.app_cb["values"] = app_choices
            last_app = self.cache.get("selected_app")
            if last_app in app_choices:
                self.selected_app.set(last_app)
            else:
                self.app_cb.current(0)

        group_aliases = self.cache.get("groups_aliases")
        group_labels = self.cache.get("groups_labels")
        if isinstance(group_aliases, list) and isinstance(group_labels, list):
            self.groups = group_aliases
            self.groups_list.delete(0, "end")
            for label in group_labels:
                self.groups_list.insert("end", label)
            selected_aliases = self.cache.get("selected_groups")
            if isinstance(selected_aliases, list):
                for idx, alias in enumerate(self.groups):
                    if alias in selected_aliases:
                        self.groups_list.select_set(idx)

        last_release_mark = self.cache.get("last_release_mark")
        if isinstance(last_release_mark, str):
            self.release_mark.set(last_release_mark)

        history = self.cache.get("upload_history")
        if isinstance(history, list):
            self.history_tree.delete(*self.history_tree.get_children())
            for item in history:
                if not isinstance(item, dict):
                    continue
                note = str(item.get("release_note", "")).strip()
                upload_time = str(item.get("upload_time", "")).strip()
                if note or upload_time:
                    self.history_tree.insert("", "end", values=(note, upload_time))

    def _append_upload_history(self, release_note):
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        entry = {
            "release_note": release_note,
            "upload_time": ts,
        }

        history = self.cache.get("upload_history")
        if not isinstance(history, list):
            history = []
        history.insert(0, entry)
        self.cache["upload_history"] = history[:200]
        self._save_cache()

        self.history_tree.insert("", 0, values=(release_note, ts))

    def _save_selected_project(self):
        self.cache["selected_project"] = self.selected_project.get().strip()
        self._save_cache()

    def _save_selected_app(self):
        self.cache["selected_app"] = self.selected_app.get().strip()
        self._save_cache()

    def _save_selected_groups(self):
        idxs = self.groups_list.curselection()
        self.cache["selected_groups"] = [self.groups[i] for i in idxs if i < len(self.groups)]
        self._save_cache()

    def _build_ui(self):
        container = ttk.Frame(self)
        container.pack(fill="both", expand=True)

        self.main_canvas = tk.Canvas(container, highlightthickness=0)
        self.main_canvas.pack(side="left", fill="both", expand=True)

        main_scrollbar = ttk.Scrollbar(container, orient="vertical", command=self.main_canvas.yview)
        main_scrollbar.pack(side="right", fill="y")
        self.main_canvas.configure(yscrollcommand=main_scrollbar.set)

        frm = ttk.Frame(self.main_canvas, padding=10)
        self._main_canvas_window = self.main_canvas.create_window((0, 0), window=frm, anchor="nw")

        frm.bind("<Configure>", self._on_scrollable_frame_configure)
        self.main_canvas.bind("<Configure>", self._on_canvas_configure)
        self.main_canvas.bind("<Enter>", lambda _e: self._bind_mousewheel(True))
        self.main_canvas.bind("<Leave>", lambda _e: self._bind_mousewheel(False))

        # Top actions
        top = ttk.Frame(frm)
        top.pack(fill="x")

        ttk.Button(top, text="检测 firebase 版本", command=self.check_version).pack(side="left")
        ttk.Button(top, text="Firebase 登录 (firebase login)", command=self.firebase_login).pack(side="left", padx=6)
        ttk.Button(top, text="刷新 Projects", command=self.refresh_projects).pack(side="left", padx=6)

        # Project
        proj = ttk.LabelFrame(frm, text="Project")
        proj.pack(fill="x", pady=8)
        self.project_cb = ttk.Combobox(proj, textvariable=self.selected_project, state="readonly")
        self.project_cb.pack(side="left", fill="x", expand=True, padx=6, pady=6)
        self.project_cb.bind("<<ComboboxSelected>>", lambda _e: self._save_selected_project())
        ttk.Button(proj, text="刷新 Apps", command=self.refresh_apps).pack(side="left", padx=6)

        # App
        appf = ttk.LabelFrame(frm, text="iOS App (Firebase App ID)")
        appf.pack(fill="x", pady=8)
        self.app_cb = ttk.Combobox(appf, textvariable=self.selected_app, state="readonly")
        self.app_cb.pack(side="left", fill="x", expand=True, padx=6, pady=6)
        self.app_cb.bind("<<ComboboxSelected>>", lambda _e: self._save_selected_app())
        ttk.Button(appf, text="刷新 Groups", command=self.refresh_groups).pack(side="left", padx=6)

        # Groups
        gf = ttk.LabelFrame(frm, text="Groups (多选)")
        gf.pack(fill="both", pady=8)
        self.groups_list = tk.Listbox(gf, selectmode="multiple", height=7)
        self.groups_list.pack(fill="both", expand=True, padx=6, pady=6)
        self.groups_list.bind("<<ListboxSelect>>", lambda _e: self._save_selected_groups())

        # Files
        ff = ttk.LabelFrame(frm, text="Files")
        ff.pack(fill="x", pady=8)

        row1 = ttk.Frame(ff); row1.pack(fill="x", padx=6, pady=4)
        ttk.Label(row1, text="IPA:").pack(side="left")
        ttk.Entry(row1, textvariable=self.ipa_path).pack(side="left", fill="x", expand=True, padx=6)
        ttk.Button(row1, text="选择...", command=self.pick_ipa).pack(side="left")

        row2 = ttk.Frame(ff); row2.pack(fill="x", padx=6, pady=4)
        ttk.Label(row2, text="dSYM.zip (可选):").pack(side="left")
        ttk.Entry(row2, textvariable=self.dsym_path).pack(side="left", fill="x", expand=True, padx=6)
        ttk.Button(row2, text="选择...", command=self.pick_dsym).pack(side="left")

        # Release mark + final release notes preview
        rn = ttk.LabelFrame(frm, text="Release mark")
        rn.pack(fill="x", pady=8)
        ttk.Entry(rn, textvariable=self.release_mark).pack(fill="x", padx=6, pady=6)

        uploader_row = ttk.Frame(rn)
        uploader_row.pack(fill="x", padx=6, pady=(0, 6))
        ttk.Label(uploader_row, text="Uploader:").pack(side="left")
        ttk.Entry(uploader_row, textvariable=self.uploader).pack(side="left", fill="x", expand=True, padx=6)

        preview_row = ttk.Frame(rn)
        preview_row.pack(fill="x", padx=6, pady=(0, 6))
        ttk.Label(preview_row, text="Release notes 预览:").pack(side="left")
        ttk.Entry(preview_row, textvariable=self.final_release_notes, state="readonly").pack(
            side="left", fill="x", expand=True, padx=6
        )

        # Distribute
        act = ttk.Frame(frm)
        act.pack(fill="x", pady=6)
        ttk.Button(act, text="上传并分发", command=self.distribute).pack(side="left")

        # Upload history
        hf = ttk.LabelFrame(frm, text="Upload History")
        hf.pack(fill="both", expand=True, pady=8)
        self.history_tree = ttk.Treeview(hf, columns=("release_note", "upload_time"), show="headings", height=6)
        self.history_tree.heading("release_note", text="release note")
        self.history_tree.heading("upload_time", text="upload time")
        self.history_tree.column("release_note", width=620, anchor="w")
        self.history_tree.column("upload_time", width=220, anchor="w")
        history_scroll = ttk.Scrollbar(hf, orient="vertical", command=self.history_tree.yview)
        self.history_tree.configure(yscrollcommand=history_scroll.set)
        self.history_tree.pack(side="left", fill="both", expand=True, padx=(6, 0), pady=6)
        history_scroll.pack(side="right", fill="y", padx=(0, 6), pady=6)

        # Log
        lf = ttk.LabelFrame(frm, text="Log")
        lf.pack(fill="both", expand=True, pady=8)
        self.log = tk.Text(lf, height=12)
        self.log.pack(fill="both", expand=True, padx=6, pady=6)

    # ---------- UI helpers ----------
    def _on_scrollable_frame_configure(self, _event):
        self.main_canvas.configure(scrollregion=self.main_canvas.bbox("all"))

    def _on_canvas_configure(self, event):
        self.main_canvas.itemconfigure(self._main_canvas_window, width=event.width)

    def _bind_mousewheel(self, enable):
        if enable:
            self.bind_all("<MouseWheel>", self._on_mousewheel)
        else:
            self.unbind_all("<MouseWheel>")

    def _on_mousewheel(self, event):
        if event.delta == 0:
            return
        direction = -1 if event.delta > 0 else 1
        self.main_canvas.yview_scroll(direction, "units")

    def log_write(self, s):
        self.log.insert("end", s)
        self.log.see("end")

    def log_clear(self):
        self.log.delete("1.0", "end")

    def _run_cmd_ui(self, args, on_line=None):
        # Keep UI log in sync with the actual command executed.
        safe_ui(self, lambda cmd=shlex.join(args): self.log_write(f"\n$ {cmd}\n"))
        return run_cmd(args, on_line=on_line)

    def _run_bg(self, args, title="运行中"):
        """
        Run in background thread, streaming output to log.
        """
        def worker():
            try:
                code, out = self._run_cmd_ui(args, on_line=lambda line: safe_ui(self, lambda: self.log_write(line)))
            except Exception as e:
                err_msg = str(e)
                safe_ui(self, lambda msg=err_msg: messagebox.showerror("错误", msg))
                return
            if code != 0:
                safe_ui(self, lambda: messagebox.showerror("命令失败", f"Exit code: {code}\n请看日志"))
        threading.Thread(target=worker, daemon=True).start()

    # ---------- actions ----------
    def check_version(self):
        self._run_bg(["firebase", "--version"])

    def firebase_login(self):
        # This will open browser and block until finished.
        self._run_bg(["firebase", "login"])

    def refresh_projects(self):
        self.log_clear()
        self.log_write("获取 projects...\n")

        def worker():
            try:
                code, out = self._run_cmd_ui(["firebase", "projects:list", "--json"])
            except Exception as e:
                err_msg = str(e)
                safe_ui(self, lambda msg=err_msg: messagebox.showerror("错误", msg))
                return
            if code != 0:
                safe_ui(self, lambda: messagebox.showerror("失败", out))
                return

            try:
                lines = out.splitlines()
                json_text = "\n".join(lines[2:]) if len(lines) > 2 else out
                data = json.loads(json_text)
                # firebase-tools JSON shape may vary; try common keys
                results = data.get("result") or data.get("projects") or data
                # Expect a list of project objects
                if isinstance(results, dict) and "projects" in results:
                    results = results["projects"]
                if not isinstance(results, list):
                    raise ValueError("无法解析 projects:list 输出（JSON 结构不符合预期）。")
            except Exception as e:
                err_msg = f"{e}\n\n原始输出:\n{out[:2000]}"
                print(err_msg)
                safe_ui(self, lambda msg=err_msg: messagebox.showerror("解析失败", msg))
                return

            self.projects = results
            choices = []
            for p in self.projects:
                pid = p.get("projectId") or p.get("project_id") or p.get("id")
                name = p.get("displayName") or p.get("name") or ""
                if pid:
                    choices.append(f"{pid}  {name}".strip())

            def apply():
                self.project_cb["values"] = choices
                if choices:
                    last_project = self.cache.get("selected_project")
                    if last_project in choices:
                        self.selected_project.set(last_project)
                    else:
                        self.project_cb.current(0)
                    self.cache["projects_choices"] = choices
                    self.cache["selected_project"] = self.selected_project.get().strip()
                    self._save_cache()
            safe_ui(self, apply)

        threading.Thread(target=worker, daemon=True).start()

    def _get_selected_project_id(self):
        val = self.selected_project.get().strip()
        if not val:
            return None
        return val.split()[0]  # projectId is first token

    def refresh_apps(self):
        project_id = self._get_selected_project_id()
        if not project_id:
            messagebox.showwarning("提示", "请先选择 Project。")
            return

        self.log_clear()
        self.log_write(f"获取 apps (project={project_id})...\n")

        def worker():
            try:
                code, out = self._run_cmd_ui(["firebase", "apps:list", "--project", project_id, "--json"])
            except Exception as e:
                err_msg = str(e)
                safe_ui(self, lambda msg=err_msg: messagebox.showerror("错误", msg))
                return
            if code != 0:
                safe_ui(self, lambda: messagebox.showerror("失败", out))
                return

            try:
                lines = out.splitlines()
                json_text = "\n".join(lines[2:]) if len(lines) > 2 else out
                data = json.loads(json_text)
                results = data.get("result") or data.get("apps") or data
                if isinstance(results, dict) and "apps" in results:
                    results = results["apps"]
                if not isinstance(results, list):
                    raise ValueError("无法解析 apps:list 输出（JSON 结构不符合预期）。")
            except Exception as e:
                err_msg = f"{e}\n\n原始输出:\n{out[:2000]}"
                safe_ui(self, lambda msg=err_msg: messagebox.showerror("解析失败", msg))
                return

            # Filter iOS
            ios = []
            for a in results:
                platform = (a.get("platform") or a.get("appPlatform") or "").upper()
                if platform in ("IOS", "APPLE_PLATFORM_IOS"):
                    ios.append(a)

            self.apps = ios
            choices = []
            for a in self.apps:
                app_id = a.get("appId") or a.get("app_id") or a.get("firebaseAppId")
                bundle = a.get("bundleId") or a.get("bundle_id") or ""
                name = a.get("displayName") or a.get("name") or ""
                if app_id:
                    choices.append(f"{app_id}  {bundle}  {name}".strip())

            def apply():
                self.app_cb["values"] = choices
                if choices:
                    last_app = self.cache.get("selected_app")
                    if last_app in choices:
                        self.selected_app.set(last_app)
                    else:
                        self.app_cb.current(0)
                    self.cache["apps_choices"] = choices
                    self.cache["selected_app"] = self.selected_app.get().strip()
                    self._save_cache()
            safe_ui(self, apply)

        threading.Thread(target=worker, daemon=True).start()

    def _get_selected_app_id(self):
        val = self.selected_app.get().strip()
        if not val:
            return None
        return val.split()[0]  # appId is first token

    def refresh_groups(self):
        project_id = self._get_selected_project_id()
        if not project_id:
            messagebox.showwarning("提示", "请先选择 Project。")
            return

        self.log_clear()
        self.log_write(f"获取 groups (project={project_id})...\n")

        def worker():
            try:
                code, out = self._run_cmd_ui(["firebase", "appdistribution:groups:list", "--project", project_id, "--json"])
            except Exception as e:
                err_msg = str(e)
                safe_ui(self, lambda msg=err_msg: messagebox.showerror("错误", msg))
                return
            if code != 0:
                safe_ui(self, lambda: messagebox.showerror("失败", out))
                return

            try:
                lines = out.splitlines()
                json_text = "\n".join(lines[2:]) if len(lines) > 2 else out
                data = json.loads(json_text)
                result = data.get("result") if isinstance(data, dict) else None
                groups_data = result.get("groups") if isinstance(result, dict) else None
                if not isinstance(groups_data, list):
                    raise ValueError("无法解析 groups:list 输出（JSON 结构不符合预期）。")
            except Exception as e:
                err_msg = f"{e}\n\n原始输出:\n{out[:2000]}"
                safe_ui(self, lambda msg=err_msg: messagebox.showerror("解析失败", msg))
                return

            aliases = []
            labels = []
            for g in groups_data:
                if not isinstance(g, dict):
                    continue
                raw_name = g.get("name") or ""
                alias = raw_name.rsplit("/", 1)[-1] if raw_name else ""
                if not alias:
                    continue
                display = g.get("displayName") or alias
                aliases.append(alias)
                labels.append(f"{alias}  {display}".strip())

            self.groups = aliases

            def apply():
                self.groups_list.delete(0, "end")
                for label in labels:
                    self.groups_list.insert("end", label)
                selected_aliases = self.cache.get("selected_groups")
                if isinstance(selected_aliases, list):
                    for idx, alias in enumerate(self.groups):
                        if alias in selected_aliases:
                            self.groups_list.select_set(idx)
                self.cache["groups_aliases"] = self.groups
                self.cache["groups_labels"] = labels
                self._save_selected_groups()
            safe_ui(self, apply)

        threading.Thread(target=worker, daemon=True).start()

    def pick_ipa(self):
        # 默认目录：~/Downloads/ios-build-output 存在才用，否则回退 ~/Downloads
        home = os.path.expanduser("~")
        preferred = os.path.join(home, "Downloads", "ios-build-output")
        initial_dir = preferred if os.path.isdir(preferred) else os.path.join(home, "Downloads")
        path = filedialog.askopenfilename(
            title="选择 IPA",
            initialdir=initial_dir,
            filetypes=[("IPA", "*.ipa"), ("All", "*.*")],
        )
        if path:
            self.ipa_path.set(path)

    def pick_dsym(self):
        path = filedialog.askopenfilename(title="选择 dSYM.zip", filetypes=[("ZIP", "*.zip"), ("All", "*.*")])
        if path:
            self.dsym_path.set(path)

    def distribute(self):
        app_id = self._get_selected_app_id()
        project_id = self._get_selected_project_id()

        if not project_id:
            messagebox.showwarning("提示", "请先选择 Project。")
            return
        if not app_id:
            messagebox.showwarning("提示", "请先选择 iOS App。")
            return
        ipa = self.ipa_path.get().strip()
        if not ipa or not os.path.exists(ipa):
            messagebox.showwarning("提示", "请选择有效的 IPA 文件。")
            return

        notes_with_uploader = self.final_release_notes.get().strip()

        # selected groups
        idxs = self.groups_list.curselection()
        selected_groups = [self.groups[i] for i in idxs]
        if not selected_groups:
            if not messagebox.askyesno("未选择 Groups", "你没有选择任何 group。是否继续（仅上传，不分发）？"):
                return

        args = ["firebase", "appdistribution:distribute", ipa, "--app", app_id]
        if notes_with_uploader:
            args += ["--release-notes", notes_with_uploader]

        dsym = self.dsym_path.get().strip()
        if dsym:
            if not os.path.exists(dsym):
                messagebox.showwarning("提示", "dSYM.zip 路径不存在。")
                return
            args += ["--debug-symbols", dsym]

        if selected_groups:
            # IMPORTANT: join groups by comma; firebase-tools expects comma-separated list for --groups
            args += ["--groups", ",".join(selected_groups)]

        self.log_clear()

        def worker():
            try:
                code, out = self._run_cmd_ui(args, on_line=lambda line: safe_ui(self, lambda: self.log_write(line)))
            except Exception as e:
                err_msg = str(e)
                safe_ui(self, lambda msg=err_msg: messagebox.showerror("错误", msg))
                return

            if code != 0:
                # Special hint for 404 distribute
                if "HTTP Error: 404" in out and ":distribute" in out:
                    hint = (
                        "分发 404 常见原因：\n"
                        "1) group 名称不匹配/不存在（尤其包含空格/显示名 vs 实际名）\n"
                        "2) 账号权限不足（有时表现为 404）\n"
                        "建议：点击“刷新 Groups”重新选择，或先用 testers 分发验证权限。\n"
                    )
                    safe_ui(self, lambda: messagebox.showerror("分发失败(404)", hint))
                else:
                    safe_ui(self, lambda: messagebox.showerror("失败", f"Exit code: {code}\n请看日志"))
                return

            safe_ui(self, lambda notes_text=notes_with_uploader: self._append_upload_history(notes_text))

            urls = parse_console_links(out)
            if urls:
                safe_ui(self, lambda: messagebox.showinfo("成功", "上传/分发成功。\n\n关键链接已在日志中输出（可复制）。"))

        threading.Thread(target=worker, daemon=True).start()


if __name__ == "__main__":
    App().mainloop()