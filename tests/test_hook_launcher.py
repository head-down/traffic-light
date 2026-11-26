"""hook_launcher：hook 必须由 GUI 子系统宿主无窗口拉起。"""
import os

from core import hook_launcher


def test_run_hook_spawns_bash_without_a_console(monkeypatch, tmp_path):
    captured = {}

    class _Result:
        returncode = 7

    def fake_run(cmd, **kwargs):
        captured["cmd"] = cmd
        captured.update(kwargs)
        return _Result()

    monkeypatch.setattr(hook_launcher.subprocess, "run", fake_run)
    script = str(tmp_path / "traffic-light.sh")

    code = hook_launcher.run_hook(["prompt"], hooks_path=script)

    assert code == 7
    assert captured["cmd"][1:] == ["--noprofile", "--norc", script, "prompt"]
    assert captured["creationflags"] == hook_launcher.CREATE_NO_WINDOW
    assert captured["env"]["LC_ALL"] == "C.UTF-8"


def test_run_hook_without_event_does_nothing(monkeypatch):
    def boom(*args, **kwargs):
        raise AssertionError("不应启动任何进程")

    monkeypatch.setattr(hook_launcher.subprocess, "run", boom)
    assert hook_launcher.run_hook([]) == 0


def test_hooks_dir_points_at_the_repo_hooks(monkeypatch):
    monkeypatch.setattr(hook_launcher.sys, "frozen", False, raising=False)
    assert os.path.basename(hook_launcher.hooks_dir()) == "hooks"
    assert os.path.isfile(os.path.join(hook_launcher.hooks_dir(),
                                       hook_launcher.HOOK_SCRIPT))
