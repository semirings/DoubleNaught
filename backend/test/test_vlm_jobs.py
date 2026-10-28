import subprocess
import sys
import time
from pathlib import Path

import pytest

from double_touch import vlm_jobs
from double_touch.vlm_jobs import VlmError


@pytest.fixture
def collected(tmp_path, monkeypatch):
    monkeypatch.setenv("DOUBLE_TOUCH_LORASET_DIR", str(tmp_path / "antelora"))
    folder = tmp_path / "antelora" / "mccay" / "_collected" / "train"
    folder.mkdir(parents=True)
    (folder / "train.jsonl").write_text("{}\n")
    return folder


def _fake_trainer(monkeypatch, script):
    """Spawn `python -c script` instead of mlx_vlm; the real adapter path is argv[-?]."""
    def popen(cmd, **kw):
        out = cmd[cmd.index("--output-path") + 1]
        return subprocess.Popen([sys.executable, "-c", script, out], **kw)
    monkeypatch.setattr(vlm_jobs, "_popen", popen)


def _wait(run_id):
    for _ in range(100):
        st = vlm_jobs.train_status(run_id)
        if st["status"] != "running":
            return st
        time.sleep(0.05)
    raise AssertionError("job never finished")


OK = (
    "import sys,time\n"
    "for i in (1,2,3):\n"
    "    sys.stdout.write('Training:  %d%%|###| %d/3\\r' % (i*33, i)); sys.stdout.flush()\n"
    "open(sys.argv[1],'wb').write(b'w')\n"
)


def test_train_reports_progress_and_the_adapter(collected, monkeypatch):
    _fake_trainer(monkeypatch, OK)
    started = vlm_jobs.start_train(str(collected), require_installed=False)
    st = _wait(started["run_id"])
    assert st["status"] == "done" and (st["step"], st["total"]) == (3, 3)
    assert Path(st["adapter"]).is_file()
    assert "lora/mccay/" in st["adapter"].replace("\\", "/")


def test_train_failure_carries_the_tail_of_the_log(collected, monkeypatch):
    _fake_trainer(monkeypatch, "import sys; print('out of memory'); sys.exit(3)")
    st = _wait(vlm_jobs.start_train(str(collected), require_installed=False)["run_id"])
    assert st["status"] == "failed" and "code 3" in st["error"] and "out of memory" in st["error"]


def test_train_exiting_cleanly_without_an_adapter_is_a_failure(collected, monkeypatch):
    _fake_trainer(monkeypatch, "print('hi')")
    st = _wait(vlm_jobs.start_train(str(collected), require_installed=False)["run_id"])
    assert st["status"] == "failed" and "no adapter" in st["error"]


def test_cancel(collected, monkeypatch):
    _fake_trainer(monkeypatch, "import time; time.sleep(30)")
    rid = vlm_jobs.start_train(str(collected), require_installed=False)["run_id"]
    vlm_jobs.cancel_train(rid)
    assert _wait(rid)["status"] == "cancelled"


def test_train_refuses_unready_requests(collected, tmp_path):
    with pytest.raises(VlmError, match="train.jsonl"):
        vlm_jobs.start_train(str(tmp_path), require_installed=False)
    with pytest.raises(VlmError, match="at least 1"):
        vlm_jobs.start_train(str(collected), epochs=0, require_installed=False)
    with pytest.raises(VlmError, match="base model"):
        vlm_jobs.start_train(str(collected), model=" ", require_installed=False)


def test_caption_builds_the_command_and_returns_the_text(tmp_path, monkeypatch):
    img = tmp_path / "a.png"; img.write_bytes(b"x")
    ad = tmp_path / "adapters.safetensors"; ad.write_bytes(b"x")
    seen = {}
    def run(cmd, **kw):
        seen["cmd"] = cmd
        return subprocess.CompletedProcess(cmd, 0, stdout="  A dream bed.\n", stderr="")
    monkeypatch.setattr(vlm_jobs, "_run", run)
    text = vlm_jobs.caption_image(str(img), adapter=str(ad), require_installed=False)
    assert text == "A dream bed."
    assert seen["cmd"][seen["cmd"].index("--adapter-path") + 1] == str(ad)
    plain = vlm_jobs.caption_image(str(img), require_installed=False)
    assert "--adapter-path" not in seen["cmd"] and plain == "A dream bed."


def test_caption_errors_are_readable(tmp_path, monkeypatch):
    with pytest.raises(VlmError, match="image not found"):
        vlm_jobs.caption_image(str(tmp_path / "no.png"), require_installed=False)
    img = tmp_path / "a.png"; img.write_bytes(b"x")
    with pytest.raises(VlmError, match="adapter not found"):
        vlm_jobs.caption_image(str(img), adapter=str(tmp_path / "no"), require_installed=False)
    monkeypatch.setattr(vlm_jobs, "_run", lambda c, **k: subprocess.CompletedProcess(c, 1, "", "boom\nTraceback: bad"))
    with pytest.raises(VlmError, match="Traceback: bad"):
        vlm_jobs.caption_image(str(img), require_installed=False)
