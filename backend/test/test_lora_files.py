import json
import struct

import pytest

from double_touch.lora_files import LoraFileError, inspect_lora


def _write(path, tensors, metadata=None):
    """A real safetensors layout: u64 header length, JSON header, then data.

    Each tensor is declared with its shape; the data is zero-length filler since
    the inspector only ever reads the header.
    """
    header = {name: {"dtype": "F16", "shape": shape, "data_offsets": [0, 0]}
              for name, shape in tensors.items()}
    if metadata:
        header["__metadata__"] = metadata
    blob = json.dumps(header).encode()
    path.write_bytes(struct.pack("<Q", len(blob)) + blob)
    return str(path)


def _qwen21(prefix="diffusion_model.", blocks=2, rank=16):
    t = {}
    for b in range(blocks):
        base = f"{prefix}transformer_blocks.{b}."
        for n in ("attn.to_q", "attn.to_k", "attn.to_v", "attn.to_out.0"):
            t[f"{base}{n}.lora_A.weight"] = [rank, 3072]
            t[f"{base}{n}.lora_B.weight"] = [3072, rank]
        t[f"{base}img_mlp.gate_up.lora_A.weight"] = [rank, 3072]
        t[f"{base}img_mlp.gate_up.lora_B.weight"] = [16384, rank]
        t[f"{base}img_mlp.out.lora_A.weight"] = [rank, 8192]
        t[f"{base}img_mlp.out.lora_B.weight"] = [3072, rank]
    return t


@pytest.mark.parametrize("prefix", ["diffusion_model.", "transformer.", ""])
def test_a_qwen_image_2_1_lora_fits_under_any_accepted_prefix(tmp_path, prefix):
    r = inspect_lora(_write(tmp_path / "a.safetensors", _qwen21(prefix)))
    assert r["compatible"] == "yes" and r["rank"] == 16
    assert r["family"] == "qwen-image-2.1"
    assert r["name"] == "a.safetensors" and r["matched"] > 0


def test_the_default_adapter_suffix_and_unfused_mlp_also_fit(tmp_path):
    t = {}
    for n in ("attn.to_q", "attn.to_k", "attn.to_v", "attn.to_out.0",
              "img_mlp.proj", "img_mlp.gate_layer", "img_mlp.out"):
        t[f"transformer_blocks.0.{n}.lora_A.default.weight"] = [8, 64]
        t[f"transformer_blocks.0.{n}.lora_B.default.weight"] = [64, 8]
    assert inspect_lora(_write(tmp_path / "a.safetensors", t))["compatible"] == "yes"


def test_a_lora_for_the_older_qwen_image_is_only_partial(tmp_path):
    t = {}
    for n in ("attn.to_q", "attn.to_k", "attn.to_v", "attn.to_out.0"):
        t[f"transformer_blocks.0.{n}.lora_A.weight"] = [8, 64]
        t[f"transformer_blocks.0.{n}.lora_B.weight"] = [64, 8]
    t["transformer_blocks.0.img_mlp.net.0.proj.lora_A.weight"] = [8, 64]
    t["transformer_blocks.0.img_mlp.net.0.proj.lora_B.weight"] = [256, 8]
    r = inspect_lora(_write(tmp_path / "old.safetensors", t))
    assert r["compatible"] == "partial" and "older Qwen-Image" in r["message"]
    assert r["family"] == "qwen-image"


@pytest.mark.parametrize("key,family", [
    ("lora_unet_double_blocks_0_img_attn_qkv.lora_down.weight", "flux1"),
    ("diffusion_model.double_blocks.0.img_attn.qkv.lora_A.weight", "flux1"),
    ("lora_te1_text_model_encoder_layers_0_mlp_fc1.lora_down.weight", "sdxl"),
    ("lora_te_text_model_encoder_layers_0_mlp_fc1.lora_down.weight", "sd15"),
    ("lora_unet_down_blocks_0_attentions_0_proj_in.lora_down.weight", "sd"),
    ("unet.down_blocks.0.attentions.0.to_q.lora_A.weight", "sd"),
    ("transformer.single_transformer_blocks.0.attn.to_q.lora_A.weight", "flux-or-zimage"),
    ("lora_unet_something_new.lora_down.weight", "kohya"),
    ("some.layer.lora_A.weight", "unknown"),
])
def test_loras_for_other_models_are_refused_and_named(tmp_path, key, family):
    r = inspect_lora(_write(tmp_path / "x.safetensors", {key: [8, 64]}))
    assert r["compatible"] == "no" and r["family"] == family
    assert "Qwen-Image-2.1" in r["message"]


def test_a_file_with_no_lora_tensors_is_refused(tmp_path):
    r = inspect_lora(_write(tmp_path / "m.safetensors", {"model.layers.0.weight": [4, 4]}))
    assert r["compatible"] == "no" and "no LoRA tensors" in r["message"]


def test_metadata_is_not_counted_as_a_tensor_and_base_model_is_reported(tmp_path):
    r = inspect_lora(_write(tmp_path / "a.safetensors", _qwen21(blocks=1),
                            metadata={"ss_base_model_version": "qwen_image_2.1"}))
    assert r["base_model"] == "qwen_image_2.1"
    assert r["tensors"] == len(_qwen21(blocks=1))


def test_unreadable_files_say_why(tmp_path):
    with pytest.raises(LoraFileError, match="not found"):
        inspect_lora(str(tmp_path / "nope.safetensors"))
    other = tmp_path / "a.bin"; other.write_bytes(b"x" * 20)
    with pytest.raises(LoraFileError, match="ends in .safetensors"):
        inspect_lora(str(other))
    short = tmp_path / "s.safetensors"; short.write_bytes(b"abc")
    with pytest.raises(LoraFileError, match="too short"):
        inspect_lora(str(short))
    trunc = tmp_path / "t.safetensors"; trunc.write_bytes(struct.pack("<Q", 500) + b"{}")
    with pytest.raises(LoraFileError, match="truncated"):
        inspect_lora(str(trunc))
    huge = tmp_path / "h.safetensors"; huge.write_bytes(struct.pack("<Q", 10**12) + b"{}")
    with pytest.raises(LoraFileError, match="implausibly large"):
        inspect_lora(str(huge))
    junk = tmp_path / "j.safetensors"; junk.write_bytes(struct.pack("<Q", 4) + b"nope")
    with pytest.raises(LoraFileError, match="cannot read"):
        inspect_lora(str(junk))


def test_the_trained_captioner_adapter_is_not_mistaken_for_an_image_lora(tmp_path):
    t = {"language_model.model.layers.27.self_attn.q_proj.lora_a": [8, 1536],
         "language_model.model.layers.27.self_attn.q_proj.lora_b": [1536, 8]}
    r = inspect_lora(_write(tmp_path / "adapters.safetensors", t))
    assert r["compatible"] == "no"
