import base64
import subprocess
import sys
import time

import pytest

from double_touch import image_gen
from double_touch.image_gen import GenerateError


@pytest.fixture(autouse=True)
def storage(tmp_path, monkeypatch):
    monkeypatch.setenv("DOUBLE_TOUCH_LORASET_DIR", str(tmp_path / "loraset"))


def _fake(monkeypatch, script, seen=None):
    """Run `python -c script <output>` in place of mflux; record the real argv."""
    def popen(cmd, **kw):
        if seen is not None:
            seen["cmd"] = cmd
        out = cmd[cmd.index("--output") + 1]
        return subprocess.Popen([sys.executable, "-c", script, out], **kw)
    monkeypatch.setattr(image_gen, "_popen", popen)


def _wait(run_id):
    for _ in range(100):
        st = image_gen.generate_status(run_id)
        if st["status"] != "running":
            return st
        time.sleep(0.05)
    raise AssertionError("never finished")


OK = (
    "import sys\n"
    "for i in range(1,5):\n"
    "    sys.stdout.write('%d%%|##| %d/4\\r' % (i*25, i)); sys.stdout.flush()\n"
    "open(sys.argv[1],'wb').write(b'\\x89PNG-fake')\n"
)


def test_generate_builds_the_documented_flags_and_returns_the_image(monkeypatch):
    seen = {}
    _fake(monkeypatch, OK, seen)
    r = image_gen.start_generate("a bed", steps=4, width=512, height=512, seed=7,
                                 command="mflux-generate-qwen-2.1")
    st = _wait(r["run_id"])
    cmd = seen["cmd"]
    assert st["status"] == "done" and (st["step"], st["total"]) == (4, 4)
    assert cmd[cmd.index("--steps") + 1] == "4" and cmd[cmd.index("-q") + 1] == "8"
    assert cmd[cmd.index("--seed") + 1] == "7" and "--model" not in cmd and "--lora" not in cmd
    assert image_gen.generate_result(r["run_id"]) == b"\x89PNG-fake"


def test_a_lora_a_model_and_an_init_image_become_flags(monkeypatch, tmp_path):
    lora = tmp_path / "a.safetensors"; lora.write_bytes(b"x")
    seen = {}
    _fake(monkeypatch, OK, seen)
    r = image_gen.start_generate(
        "p", model="someone/other-model", lora=str(lora), lora_scale=0.7, quantize=0,
        image_b64=base64.b64encode(b"png").decode(), image_strength=0.4, command="x")
    _wait(r["run_id"])
    c = seen["cmd"]
    assert c[c.index("--model") + 1] == "someone/other-model" and "-q" not in c
    assert c[c.index("--lora") + 1:c.index("--lora") + 3] == [str(lora), "0.7"]
    assert c[c.index("--image") + 2] == "0.4"


def test_the_default_model_id_is_not_passed(monkeypatch):
    seen = {}
    _fake(monkeypatch, OK, seen)
    _wait(image_gen.start_generate("p", model="Qwen/Qwen-Image-2.1", command="x")["run_id"])
    assert "--model" not in seen["cmd"]


def test_failure_reports_the_exit_code_and_log_tail(monkeypatch):
    _fake(monkeypatch, "import sys; print('Metal out of memory'); sys.exit(2)")
    st = _wait(image_gen.start_generate("p", command="x")["run_id"])
    assert st["status"] == "failed" and "code 2" in st["error"] and "out of memory" in st["error"]


def test_clean_exit_without_an_image_is_a_failure(monkeypatch):
    _fake(monkeypatch, "print('hi')")
    st = _wait(image_gen.start_generate("p", command="x")["run_id"])
    assert st["status"] == "failed" and "wrote no image" in st["error"]


def test_cancel(monkeypatch):
    _fake(monkeypatch, "import time; time.sleep(30)")
    rid = image_gen.start_generate("p", command="x")["run_id"]
    image_gen.cancel_generate(rid)
    assert _wait(rid)["status"] == "cancelled"


def test_unrunnable_requests_say_why(monkeypatch, tmp_path):
    monkeypatch.delenv("DOUBLE_TOUCH_MFLUX_QWEN21", raising=False)
    monkeypatch.setattr(image_gen.shutil, "which", lambda _: None)
    with pytest.raises(GenerateError, match="pip install -U mflux"):
        image_gen.start_generate("p")
    with pytest.raises(GenerateError, match="enter a prompt"):
        image_gen.start_generate(" ", command="x")
    with pytest.raises(GenerateError, match="multiples of 16"):
        image_gen.start_generate("p", width=500, command="x")
    with pytest.raises(GenerateError, match="LoRA not found"):
        image_gen.start_generate("p", lora=str(tmp_path / "no"), command="x")
    with pytest.raises(GenerateError, match="not valid base64"):
        image_gen.start_generate("p", image_b64="!!", command="x")


def test_the_image_is_not_served_before_it_is_done(monkeypatch):
    _fake(monkeypatch, "import time; time.sleep(30)")
    rid = image_gen.start_generate("p", command="x")["run_id"]
    with pytest.raises(GenerateError, match="not ready"):
        image_gen.generate_result(rid)
    with pytest.raises(GenerateError, match="no such generation"):
        image_gen.generate_status("nope")
    image_gen.cancel_generate(rid)


def test_edit_mode_uses_the_edit_command_and_its_flags(monkeypatch):
    seen = {}
    _fake(monkeypatch, OK, seen)
    r = image_gen.start_generate(
        "red shirt", steps=4, width=512, height=512, mode="edit",
        image_b64=base64.b64encode(b"png").decode(), edit_strength=0.5,
        image_strength=0.9, command="mflux-generate-qwen-2.1-edit")
    _wait(r["run_id"])
    cmd = seen["cmd"]
    assert "--image-paths" in cmd and "--image" not in cmd
    assert cmd[cmd.index("--strength") + 1] == "0.5"
    assert "0.9" not in cmd, "img2img strength must not leak into edit mode"


def test_edit_mode_full_strength_sends_no_strength_flag(monkeypatch):
    seen = {}
    _fake(monkeypatch, OK, seen)
    r = image_gen.start_generate(
        "x", steps=4, width=512, height=512, mode="edit",
        image_b64=base64.b64encode(b"png").decode(), command="e")
    _wait(r["run_id"])
    assert "--strength" not in seen["cmd"]


def test_edit_mode_needs_an_image_and_32_multiple_sizes_and_a_valid_strength():
    png = base64.b64encode(b"png").decode()
    with pytest.raises(GenerateError, match="start image"):
        image_gen.start_generate("x", mode="edit", width=512, height=512, command="e")
    with pytest.raises(GenerateError, match="multiples of 32"):
        image_gen.start_generate("x", mode="edit", width=496, height=496,
                                 image_b64=png, command="e")
    with pytest.raises(GenerateError, match="edit strength"):
        image_gen.start_generate("x", mode="edit", width=512, height=512,
                                 image_b64=png, edit_strength=0, command="e")
    with pytest.raises(GenerateError, match="mode must be"):
        image_gen.start_generate("x", mode="bogus", command="e")


def test_the_edit_command_is_found_beside_the_txt2img_one(monkeypatch, tmp_path):
    base = tmp_path / "mflux-generate-qwen-2.1"; base.write_text("")
    beside = tmp_path / "mflux-generate-qwen-2.1-edit"; beside.write_text("")
    monkeypatch.delenv("DOUBLE_TOUCH_MFLUX_QWEN21_EDIT", raising=False)
    monkeypatch.setenv("DOUBLE_TOUCH_MFLUX_QWEN21", str(base))
    monkeypatch.setattr(image_gen.shutil, "which", lambda _n: None)
    assert image_gen.find_edit_command() == str(beside)
    monkeypatch.setenv("DOUBLE_TOUCH_MFLUX_QWEN21_EDIT", "/x/edit")
    assert image_gen.find_edit_command() == "/x/edit"


def test_edit_failures_name_the_edit_command(monkeypatch):
    _fake(monkeypatch, "import sys; sys.exit(3)")
    r = image_gen.start_generate(
        "x", steps=4, width=512, height=512, mode="edit",
        image_b64=base64.b64encode(b"png").decode(), command="e")
    st = _wait(r["run_id"])
    assert st["status"] == "failed" and "mflux-generate-qwen-2.1-edit exited" in st["error"]



def test_z_image_family_uses_its_own_command_and_refuses_edit(monkeypatch, tmp_path):
    lora = tmp_path / "z.safetensors"; lora.write_bytes(b"x")
    seen = {}
    _fake(monkeypatch, OK, seen)
    monkeypatch.setattr(image_gen, "find_zimage_command", lambda: "mflux-generate-z-image-turbo")
    r = image_gen.start_generate("a bed", steps=9, width=512, height=512, lora=str(lora),
                                 family="z-image")
    st = _wait(r["run_id"])
    c = seen["cmd"]
    assert st["status"] == "done" and c[0] == "mflux-generate-z-image-turbo"
    assert c[c.index("--lora") + 1] == str(lora) and "--model" not in c
    with pytest.raises(GenerateError, match="no edit mode"):
        image_gen.start_generate("p", family="z-image", mode="edit", image_b64="eA==")
    with pytest.raises(GenerateError, match="family"):
        image_gen.start_generate("p", family="sdxl")


def test_z_image_command_missing_names_the_right_command(monkeypatch):
    monkeypatch.delenv("DOUBLE_TOUCH_MFLUX_ZIMAGE", raising=False)
    monkeypatch.setattr(image_gen.shutil, "which", lambda _c: None)
    with pytest.raises(GenerateError, match="mflux-generate-z-image-turbo was not found"):
        image_gen.start_generate("p", family="z-image")
