import json
import time

import pytest

from double_touch import cloud_train
from double_touch.image_train import TrainError


@pytest.fixture(autouse=True)
def storage(tmp_path, monkeypatch):
    monkeypatch.setenv("DOUBLE_TOUCH_LORASET_DIR", str(tmp_path / "antelora"))
    monkeypatch.setenv("GCP_PROJECT_ID", "proj")
    monkeypatch.setenv("GCP_GCS_BUCKET", "bucket")
    monkeypatch.setenv("GCP_VERTEX_TRAIN_IMAGE", "us-central1-docker.pkg.dev/proj/repo/img:latest")
    cloud_train._jobs.clear()
    # Never touch real GCS for uploads in tests; individual tests monkeypatch
    # submission/polling/download themselves.
    monkeypatch.setattr(cloud_train, "_upload_dir", lambda *a, **k: None)
    monkeypatch.setattr(cloud_train, "_upload_dir_single", lambda *a, **k: None)


def _collected(tmp_path, rows=3, antelora="mccay", output="train"):
    folder = tmp_path / "antelora" / antelora / "_collected" / output
    (folder / "images").mkdir(parents=True)
    lines = []
    for i in range(rows):
        (folder / "images" / f"p{i}.png").write_bytes(b"png%d" % i)
        lines.append(json.dumps({"file_name": f"images/p{i}.png", "text": f"caption {i}"}))
    (folder / "metadata.jsonl").write_text("\n".join(lines))
    return folder


def _wait_submitted(run_id):
    for _ in range(200):
        if cloud_train._jobs[run_id].resource_name is not None:
            return
        time.sleep(0.02)
    raise AssertionError("job was never submitted")


def test_build_config_matches_the_requested_settings():
    cfg = cloud_train.build_config(
        run_name="r", data_dir_in_container="/workspace/data",
        output_dir_in_container="/workspace/output", epochs=4, rank=8,
        learning_rate=5e-4, resolution=512, num_images=3, trigger="mccaystyle",
    )
    proc = cfg["config"]["process"][0]
    assert proc["model"]["arch"] == "zimage"
    assert proc["model"]["name_or_path"] == cloud_train.MODEL_NAME_OR_PATH
    assert proc["network"]["linear"] == 8
    assert proc["train"]["steps"] == 12  # epochs * num_images
    assert proc["train"]["lr"] == 5e-4
    assert proc["datasets"][0]["resolution"] == [512]
    assert proc["trigger_word"] == "mccaystyle"


def test_build_config_does_not_quantize_by_default():
    cfg = cloud_train.build_config(
        run_name="r", data_dir_in_container="/d", output_dir_in_container="/o",
        epochs=1, rank=4, learning_rate=1e-4, resolution=256, num_images=1,
    )
    assert "quantize" not in cfg["config"]["process"][0]["model"]
    assert "low_vram" not in cfg["config"]["process"][0]["model"]


def test_build_config_quantize_opt_in():
    cfg = cloud_train.build_config(
        run_name="r", data_dir_in_container="/d", output_dir_in_container="/o",
        epochs=1, rank=4, learning_rate=1e-4, resolution=256, num_images=1,
        quantize=True,
    )
    model = cfg["config"]["process"][0]["model"]
    assert model["quantize"] is True and model["low_vram"] is True


def test_build_config_omits_trigger_word_when_none_given():
    cfg = cloud_train.build_config(
        run_name="r", data_dir_in_container="/d", output_dir_in_container="/o",
        epochs=1, rank=4, learning_rate=1e-4, resolution=256, num_images=1,
    )
    assert "trigger_word" not in cfg["config"]["process"][0]


@pytest.mark.parametrize("kw,msg", [
    ({"epochs": 0}, "epochs"), ({"rank": 0}, "rank"), ({"rank": 999}, "rank"),
    ({"learning_rate": 0}, "learning rate"), ({"resolution": 100}, "resolution"),
    ({"resolution": 770}, "resolution"),
])
def test_bad_settings_are_refused_before_touching_gcp(kw, msg, tmp_path):
    _collected(tmp_path)
    with pytest.raises(TrainError, match=msg):
        cloud_train.start_cloud_train("mccay", **kw)


def test_missing_gcp_env_is_reported_by_name(tmp_path, monkeypatch):
    _collected(tmp_path)
    monkeypatch.delenv("GCP_GCS_BUCKET")
    with pytest.raises(TrainError, match="GCP_GCS_BUCKET"):
        cloud_train.start_cloud_train("mccay")


def test_happy_path_submits_uploads_and_downloads_the_adapter(monkeypatch, tmp_path):
    _collected(tmp_path, rows=3)
    monkeypatch.setattr(cloud_train, "_submit_job", lambda cfg, job: "projects/p/locations/r/customJobs/123")
    monkeypatch.setattr(cloud_train, "_poll_state", lambda cfg, name: ("JOB_STATE_SUCCEEDED", None))

    def fake_download(gcs_prefix, dest):
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(b"adapter-bytes")
        return True

    monkeypatch.setattr(cloud_train, "_download_adapter", fake_download)

    r = cloud_train.start_cloud_train("mccay", epochs=4, rank=8)
    assert r["images"] == 3
    _wait_submitted(r["run_id"])

    st = cloud_train.cloud_train_status(r["run_id"])
    assert st["status"] == "done", st
    assert open(st["adapter"], "rb").read() == b"adapter-bytes"
    assert st["adapter"] == r["adapter"]


def test_a_failed_job_reports_the_vertex_error(monkeypatch, tmp_path):
    _collected(tmp_path)
    monkeypatch.setattr(cloud_train, "_submit_job", lambda cfg, job: "name")
    monkeypatch.setattr(cloud_train, "_poll_state", lambda cfg, name: ("JOB_STATE_FAILED", "out of memory"))
    r = cloud_train.start_cloud_train("mccay")
    _wait_submitted(r["run_id"])
    st = cloud_train.cloud_train_status(r["run_id"])
    assert st["status"] == "failed" and "out of memory" in st["error"]


def test_success_with_no_adapter_found_is_a_failure_not_a_success(monkeypatch, tmp_path):
    _collected(tmp_path)
    monkeypatch.setattr(cloud_train, "_submit_job", lambda cfg, job: "name")
    monkeypatch.setattr(cloud_train, "_poll_state", lambda cfg, name: ("JOB_STATE_SUCCEEDED", None))
    monkeypatch.setattr(cloud_train, "_download_adapter", lambda *a, **k: False)
    r = cloud_train.start_cloud_train("mccay")
    _wait_submitted(r["run_id"])
    st = cloud_train.cloud_train_status(r["run_id"])
    assert st["status"] == "failed" and "no adapter" in st["error"]


def test_cancel_calls_vertex_and_reports_cancelled(monkeypatch, tmp_path):
    _collected(tmp_path)
    monkeypatch.setattr(cloud_train, "_submit_job", lambda cfg, job: "name")
    cancelled = {}
    monkeypatch.setattr(cloud_train, "_cancel_job", lambda cfg, name: cancelled.setdefault("name", name))
    monkeypatch.setattr(cloud_train, "_poll_state", lambda cfg, name: ("JOB_STATE_CANCELLED", None))
    r = cloud_train.start_cloud_train("mccay")
    _wait_submitted(r["run_id"])
    st = cloud_train.cancel_cloud_train(r["run_id"])
    assert cancelled["name"] == "name"
    assert st["status"] == "cancelled"


def test_only_one_cloud_run_at_a_time(monkeypatch, tmp_path):
    _collected(tmp_path)
    monkeypatch.setattr(cloud_train, "_submit_job", lambda cfg, job: "name")
    monkeypatch.setattr(cloud_train, "_poll_state", lambda cfg, name: ("JOB_STATE_RUNNING", None))
    first = cloud_train.start_cloud_train("mccay")
    _wait_submitted(first["run_id"])
    with pytest.raises(TrainError, match="already in progress"):
        cloud_train.start_cloud_train("mccay")


def test_dataset_path_from_the_collect_node_is_used_as_given(monkeypatch, tmp_path):
    folder = _collected(tmp_path, antelora="other", output="v2")
    monkeypatch.setattr(cloud_train, "_submit_job", lambda cfg, job: "name")
    monkeypatch.setattr(cloud_train, "_poll_state", lambda cfg, name: ("JOB_STATE_RUNNING", None))
    r = cloud_train.start_cloud_train(dataset=str(folder), epochs=2, rank=4)
    assert r["images"] == 3
    assert r["run_dir"].endswith("/lora/other/" + cloud_train.default_name(2, 4))
