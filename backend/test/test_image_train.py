import json
import subprocess
import sys
import time

import pytest

from double_touch import image_train
from double_touch.image_train import TrainError


@pytest.fixture(autouse=True)
def storage(tmp_path, monkeypatch):
    monkeypatch.setenv("DOUBLE_TOUCH_LORASET_DIR", str(tmp_path / "loraset"))
    image_train._jobs.clear()


def _collected(tmp_path, rows=3, loraset="mccay", output="train"):
    folder = tmp_path / "loraset" / loraset / "_collected" / output
    (folder / "images").mkdir(parents=True)
    lines = []
    for i in range(rows):
        (folder / "images" / f"p{i}.png").write_bytes(b"png%d" % i)
        lines.append(json.dumps({"file_name": f"images/p{i}.png", "text": f"caption {i}"}))
    (folder / "metadata.jsonl").write_text("\n".join(lines))
    return folder


# A stand-in for mflux-train: reads the config, "trains", writes a checkpoint zip.
FAKE = r"""
import json, sys, zipfile, pathlib
cfg = json.load(open(sys.argv[2]))
out = pathlib.Path(cfg["checkpoint"]["output_path"]) / "checkpoints"
out.mkdir(parents=True)
for n in (6, 12):
    sys.stdout.write('%d%%|##| %d/12\r' % (n * 100 // 12, n)); sys.stdout.flush()
    with zipfile.ZipFile(out / ("%07d_checkpoint.zip" % n), "w") as z:
        z.writestr("%07d_adapter.safetensors" % n, b"adapter-%d" % n)
"""


def _fake(monkeypatch, script=FAKE, seen=None):
    def popen(cmd, **kw):
        if seen is not None:
            seen["cmd"] = cmd
        return subprocess.Popen([sys.executable, "-c", script, *cmd[1:]], **kw)
    monkeypatch.setattr(image_train, "_popen", popen)


def _wait(run_id):
    for _ in range(200):
        st = image_train.train_status(run_id)
        if st["status"] != "running":
            return st
        time.sleep(0.05)
    raise AssertionError("never finished")


def test_prepare_writes_image_text_pairs_and_a_valid_config(tmp_path):
    folder = _collected(tmp_path, rows=2)
    run = tmp_path / "run"
    run.mkdir()
    cfg_path = image_train.prepare(
        image_train.read_captions(folder), run, epochs=8, rank=16,
        learning_rate=1e-4, resolution=768, trigger="mccaystyle")
    data = run / "data"
    assert sorted(p.name for p in data.glob("*.png")) == ["p0.png", "p1.png"]
    assert (data / "p0.txt").read_text() == "mccaystyle, caption 0"
    assert (data / "preview.txt").read_text() == "mccaystyle, caption 0"
    cfg = json.loads(cfg_path.read_text())
    assert cfg["model"] == "z-image-turbo" and cfg["steps"] == 9
    assert cfg["data"] == str(data) and cfg["max_resolution"] == 768
    assert cfg["training_loop"]["num_epochs"] == 8
    assert cfg["training_loop"]["timestep_high"] <= cfg["steps"]
    assert cfg["checkpoint"]["output_path"] == str(run / "train")
    targets = cfg["lora_layers"]["targets"]
    assert len(targets) == 9 and all(t["rank"] == 16 for t in targets)
    assert cfg["monitoring"]["generate_image_frequency"] == cfg["checkpoint"]["save_frequency"]


def test_training_runs_the_command_and_exports_the_newest_adapter(monkeypatch, tmp_path):
    _collected(tmp_path, rows=3)
    seen = {}
    _fake(monkeypatch, seen=seen)
    r = image_train.start_train("mccay", epochs=4, rank=8, command="mflux-train")
    assert r["images"] == 3 and r["total"] == 12
    assert seen["cmd"][1] == "--config" and seen["cmd"][2].endswith("train.json")
    st = _wait(r["run_id"])
    assert st["status"] == "done", st
    assert st["step"] == 12 and st["iteration"] == 12 and st["checkpoints"] == 2
    adapter = tmp_path / "lora" / "mccay" / "z-image-r8-e4" / "z-image-r8-e4.safetensors"
    assert st["adapter"] == str(adapter) and adapter.read_bytes() == b"adapter-12"


def test_a_failed_trainer_reports_its_last_lines(monkeypatch, tmp_path):
    _collected(tmp_path)
    _fake(monkeypatch, "import sys\nprint('boom: out of memory')\nsys.exit(3)\n")
    st = _wait(image_train.start_train("mccay", command="x")["run_id"])
    assert st["status"] == "failed" and "code 3" in st["error"] and "out of memory" in st["error"]


def test_clean_exit_without_a_checkpoint_is_a_failure_not_a_success(monkeypatch, tmp_path):
    _collected(tmp_path)
    _fake(monkeypatch, "print('nothing saved')\n")
    st = _wait(image_train.start_train("mccay", command="x")["run_id"])
    assert st["status"] == "failed" and "no checkpoint" in st["error"]


def test_only_one_run_at_a_time_and_a_rerun_gets_a_new_folder(monkeypatch, tmp_path):
    _collected(tmp_path)
    _fake(monkeypatch, "import time\ntime.sleep(5)\n")
    first = image_train.start_train("mccay", command="x")
    with pytest.raises(TrainError, match="already training"):
        image_train.start_train("mccay", command="x")
    image_train.cancel_train(first["run_id"])
    assert _wait(first["run_id"])["status"] == "cancelled"
    _fake(monkeypatch)
    again = image_train.start_train("mccay", command="x")
    assert again["run_dir"] != first["run_dir"]
    _wait(again["run_id"])


def test_export_now_takes_a_checkpoint_while_running(monkeypatch, tmp_path):
    _collected(tmp_path)
    script = FAKE + "\nimport time\ntime.sleep(5)\n"
    _fake(monkeypatch, script)
    r = image_train.start_train("mccay", command="x")
    for _ in range(100):
        if image_train.train_status(r["run_id"])["checkpoints"] == 2:
            break
        time.sleep(0.05)
    st = image_train.export_now(r["run_id"])
    assert st["iteration"] == 12 and open(st["adapter"], "rb").read() == b"adapter-12"
    image_train.cancel_train(r["run_id"])
    _wait(r["run_id"])


@pytest.mark.parametrize("kw,msg", [
    ({"epochs": 0}, "epochs"), ({"rank": 0}, "rank"), ({"rank": 999}, "rank"),
    ({"learning_rate": 0}, "learning rate"), ({"resolution": 100}, "resolution"),
    ({"resolution": 770}, "resolution"), ({"quantize": 5}, "quantize"),
])
def test_bad_settings_are_refused(kw, msg, tmp_path):
    _collected(tmp_path)
    with pytest.raises(TrainError, match=msg):
        image_train.start_train("mccay", command="x", **kw)


def test_missing_or_empty_collection_and_missing_command(tmp_path, monkeypatch):
    with pytest.raises(TrainError, match="Collect Loraset"):
        image_train.start_train("mccay", command="x")
    folder = _collected(tmp_path, rows=0)
    with pytest.raises(TrainError, match="no captioned images"):
        image_train.start_train("mccay", command="x")
    _collected(tmp_path, rows=1, output="other")
    monkeypatch.delenv("DOUBLE_TOUCH_MFLUX_TRAIN", raising=False)
    monkeypatch.setattr(image_train.shutil, "which", lambda _c: None)
    with pytest.raises(TrainError, match="mflux-train was not found"):
        image_train.start_train("mccay", output="other")


def test_rows_with_missing_images_or_blank_captions_are_dropped(tmp_path):
    folder = _collected(tmp_path, rows=2)
    with open(folder / "metadata.jsonl", "a") as f:
        f.write("\n" + json.dumps({"file_name": "images/gone.png", "text": "x"}))
        f.write("\n" + json.dumps({"file_name": "images/p0.png", "text": "  "}))
    assert [t for _, t in image_train.read_captions(folder)] == ["caption 0", "caption 1"]


def test_dataset_path_from_the_collect_node_is_used_as_given(monkeypatch, tmp_path):
    folder = _collected(tmp_path, loraset="other", output="v2")
    _fake(monkeypatch)
    r = image_train.start_train(dataset=str(folder), epochs=2, rank=4, command="x")
    assert r["images"] == 3
    assert r["run_dir"].endswith("/lora/other/z-image-r4-e2")
    assert _wait(r["run_id"])["status"] == "done"
