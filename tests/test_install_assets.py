"""打包资产契约测试：安装脚本、PyInstaller spec、hook 模板与 README。

seam 是交付物本身的可解析内容：EXE 用户拿到的 zip 由 build.spec 的 datas
决定，安装行为由 install.sh / install.bat 里的 ps1 调用参数决定，README 是
支持矩阵与升级说明的唯一出口。这里只做纯文件断言，不执行安装、不碰真实
计划任务与注册表。
"""
import ast
import json
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

HOOK_EVENTS = {
    "SessionStart": "session-start",
    "UserPromptSubmit": "prompt",
    "PostToolUse": "tool",
    "Notification": "notify",
    "Stop": "stop",
    "SessionEnd": "end",
}


def _analysis_datas():
    tree = ast.parse((REPO / "build.spec").read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and getattr(node.func, "id", "") == "Analysis":
            for kw in node.keywords:
                if kw.arg == "datas":
                    return ast.literal_eval(kw.value)
    raise AssertionError("build.spec 缺少 Analysis(datas=...)")


def _datas_by_dest():
    bundled = {}
    for src, dest in _analysis_datas():
        bundled[src.replace("\\", "/")] = dest.replace("\\", "/")
    return bundled


def _powershell_lines(path):
    lines = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.lower().startswith("rem ") or line.startswith("::"):
            continue
        if re.search(r"powershell(\.exe)?\b", line, re.IGNORECASE):
            lines.append(line)
    return lines


def _install_sh():
    return (REPO / "install.sh").read_text(encoding="utf-8")


def test_build_spec_bundles_resolver_and_hooks():
    bundled = _datas_by_dest()
    # 四类运行时资源：解析脚本、探针、hook 入口目录、hook 模板
    assert bundled.get("resolve.ps1") == "."
    assert bundled.get("probe.ps1") == "."
    assert bundled.get("hooks") == "hooks"
    assert bundled.get(".codebuddy-hooks.json") == "."
    assert (REPO / "resolve.ps1").is_file()
    assert (REPO / "probe.ps1").is_file()
    assert (REPO / "hooks" / "traffic-light.sh").is_file()


def test_build_spec_bundles_install_entrypoints_for_exe_users():
    bundled = _datas_by_dest()
    # 解压即用：EXE 用户需要安装入口与合并脚本，缺一个都装不上
    for name in ("install.bat", "install.sh", "merge-hooks.ps1"):
        assert name in bundled, f"build.spec datas 缺少 {name}"
        assert (REPO / name).is_file()


def test_install_sh_every_powershell_call_bypasses_execution_policy():
    lines = _powershell_lines(REPO / "install.sh")
    assert lines, "install.sh 里没有 powershell 调用"
    for line in lines:
        assert "-NoProfile" in line, line
        assert re.search(r"-ExecutionPolicy\s+Bypass", line, re.IGNORECASE), line


def test_install_bat_every_powershell_call_bypasses_execution_policy():
    lines = _powershell_lines(REPO / "install.bat")
    assert lines, "install.bat 里没有 powershell 调用"
    for line in lines:
        assert "-NoProfile" in line, line
        assert re.search(r"-ExecutionPolicy\s+Bypass", line, re.IGNORECASE), line


def test_install_sh_runs_gc_once_after_install():
    text = _install_sh()
    gc_calls = [
        line
        for line in text.splitlines()
        if "resolve.ps1" in line and "-GcOnly" in line
    ]
    assert len(gc_calls) == 1, gc_calls
    call = gc_calls[0]
    assert "powershell" in call
    assert "-NoProfile" in call
    assert re.search(r"-ExecutionPolicy\s+Bypass", call, re.IGNORECASE)
    # GC 必须在合并 hooks 成功之后跑，失败时不误删旧资产
    assert text.index("merge-hooks.ps1") < text.index("-GcOnly")


def test_no_legacy_project_level_entrypoint():
    # 破坏式升级：项目级入口 bind.sh 与 resolve.ps1 的 -Project 参数都不保留
    assert not (REPO / "bind.sh").exists()
    resolver = (REPO / "resolve.ps1").read_text(encoding="utf-8")
    assert "bind.sh" not in resolver
    assert "[string]$Project" not in resolver
    release = (REPO / "RELEASE.md").read_text(encoding="utf-8")
    assert "bind.sh" not in release
    assert "--project" not in release


def test_install_sh_has_no_project_level_key():
    text = _install_sh()
    assert "--project" not in text
    assert "<YOUR_PROJECT>" not in text
    assert "traffic-light-$" not in text
    assert "ProjectName" not in text


def test_hook_template_wires_six_events_to_single_entrypoint():
    hooks = json.loads((REPO / ".codebuddy-hooks.json").read_text(encoding="utf-8"))["hooks"]
    assert set(hooks) == set(HOOK_EVENTS)
    for event, subcommand in HOOK_EVENTS.items():
        commands = [
            h["command"]
            for group in hooks[event]
            for h in group.get("hooks", [])
            if h.get("type") == "command"
        ]
        assert len(commands) == 1, (event, commands)
        command = commands[0]
        assert "TRAFFIC_LIGHT_DIR/hooks/traffic-light.sh " + subcommand in command
        assert "bash --noprofile --norc" in command
        assert "<YOUR_PROJECT>" not in command
    assert hooks["Notification"][0]["matcher"] == "permission_prompt"


def test_merge_hooks_only_substitutes_traffic_light_dir():
    text = (REPO / "merge-hooks.ps1").read_text(encoding="utf-8")
    assert "<YOUR_PROJECT>" not in text
    assert "auto-bind.sh" not in text
    assert "auto-stop.sh" not in text
    assert "$ProjectName" not in text
    assert "TRAFFIC_LIGHT_DIR" in text


def test_readme_documents_support_matrix_and_degradation():
    text = (REPO / "README.md").read_text(encoding="utf-8")
    assert "支持矩阵" in text
    for terminal in ("Windows Terminal", "conhost", "mintty", "VSCode"):
        assert terminal in text, terminal
    assert "✅" in text and "❌" in text
    assert re.search(r"❌[^\n]*\?|❌[^\n]*降级", text), "不支持终端要写 ? 降级"
    assert "降级灯" in text


def test_readme_documents_upgrade_and_window_behaviour():
    text = (REPO / "README.md").read_text(encoding="utf-8")
    for phrase in ("破坏式", "自动清理", "不抢焦点", "最小化", "/clear"):
        assert phrase in text, phrase


def test_readme_has_no_removed_project_feature():
    text = (REPO / "README.md").read_text(encoding="utf-8")
    for stale in ("--project", "auto-bind.sh", "auto-stop.sh", "<YOUR_PROJECT>"):
        assert stale not in text, stale
