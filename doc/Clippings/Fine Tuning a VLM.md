---
title: "Fine Tuning a VLM"
source: "https://gemini.google.com/app/f189cd8c159ec209?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=bkws&utm_source=sem&utm_medium=paid-media&utm_campaign=bkws&pt=9008&mt=8&ct=p-growth-sem-bkws&gclsrc=aw.ds&gad_source=1&gad_campaignid=20108148196&gbraid=0AAAAApk5BhkcKFCPAYK4hSZxm1eNlnQRi&gclid=Cj0KCQjwp7jOBhDGARIsABe7C4dAOBtocrZYoO-EqkPkC2PT6WFLBTUb2tjLVD4B-V25UjwRpyXoj50aAmCzEALw_wcB"
author:
published:
created: 2026-08-13
description: "Gemini conversation with 22 messages"
tags:
  - "clippings"
---
Here is a comprehensive, structured summary and technical breakdown of the fine-tuning narrative you provided.

# Executive Summary & Core Philosophy

Fine-tuning Small Language Models (SLMs) and Vision-Language Models (VLMs) offers massive upsides: **cheap execution, easy deployment, low memory overhead, and no need for massive GPU clusters**. However, going from a raw dataset to a production-ready model requires careful experimentation.

The central theme of the session is **building a model for a specific task** (identifying car manufacturers/makers from images using a Stanford Cars dataset subset with 49 classes).

### The Golden Rule of Fine-Tuning

> **"A fine-tuned model is only as good as the dataset you use to fine-tune it."**
> 
> Hyperparameters, learning rates, and LoRA rank matter—but the quality, accuracy, and diversity of your dataset will make or break the model.

# 1\. Key Technical Concepts & Prerequisites

### A. Evaluation Loop (Build First, Tune Second)

- **Never drive blind:** Before touching prompts or fine-tuning, construct an **evaluation loop/script**.
- **Model-Agnostic Design:** The script should take any model or configuration, run a test dataset, and return an explicit accuracy metric.
- **Baseline Performance:** You must establish a baseline before fine-tuning. Sometimes a fine-tuned model performs *worse* than the base model; without an evaluation loop, you won't know.

### B. Structured Output Generation

- Classification requires strict outputs (e.g., returning only valid car brands like `"Audi"`, `"Tesla"`, or `"Ford"`—never non-existent labels).
- Structured output generation constrains the VLM's generation logits/tokens to strictly match allowed schema/class lists.

### C. Dataset Quality & Hazards

- **Label Accuracy:** Mislabeled training samples severely degrade model performance.
- **Class Imbalance:** In the video's dataset, Chevrolet represents ~11.6% of samples while Rolls-Royce represents ~1.4%. Underrepresented classes are significantly harder for models to classify.
- **Distribution Coverage:** If the model encounters a brand in production that wasn't represented in training, it will fail. The dataset must cover the operational domain.

# 2\. Infrastructure & Tooling Setup

| Layer | Tool Used | Purpose / Benefit |
| --- | --- | --- |
| **Package Management** | `uv` (by Astral) | Replaces `poetry`/`pip`. Ultra-fast virtualenv creation, package installation, and dependency locking. |
| **Project Packaging** | `uv init --lib` | Packaging the codebase as a Python library solves import path issues cleanly. |
| **Serverless GPU Compute** | **Modal** (`modal.com`) | On-demand GPU provisioning. Avoids maintaining raw Dockerfiles, renting persistent boxes (e.g., RunPod/Vast.ai), or paying idle costs. |
| **Experiment Tracking** | **Weights & Biases (W&B)** | Logs hyperparameters, metrics, loss curves, and artifact versions across multiple runs. |
| **Persistent Storage** | Modal Volumes | Persists fine-tuned model weights and outputs after serverless GPU containers shut down. |

# 3\. Model Fine-Tuning Workflow & Lifecycle

The speaker outlines an iterative 6-step lifecycle for adapting VLMs:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        VLM FINE-TUNING LIFECYCLE                        │
└─────────────────────────────────────────────────────────────────────────┘

  1. Establish Baseline     ──> Run base VLM through your evaluation loop
  2. Prompt & Structure     ──> Test system prompts & structured output constraints
  3. Serverless GPU Setup   ──> Configure Modal app environment & volumes
  4. Parameter Separation   ──> Isolate hyperparameters into dedicated configs
  5. Fine-Tune (LoRA/QLoRA) ──> Train VLM on serverless GPUs; track via W&B
  6. Error Analysis         ──> Dissect failure modes & fix dataset errors
```

### Error Analysis & Post-Mortem

When predictions fail (e.g., the model consistently confuses *Ford* with *Chevrolet*), perform a post-mortem:

1. Is it a data labeling error?
2. Are there too few training examples for those classes?
3. Add targeted examples to sharpen decision boundaries between confused classes, then re-tune.

# 4\. Summary of Code Architecture Shown

- **`make evaluate`**: Runs the Modal CLI entry point (`modal run source/car_maker_identification/evaluate.py --config-file-name <config>`).
- **Modal App Decorators**:
	- `@app.local_entry_point`: Runs locally on your machine to orchestrate runs and parse CLI flags.
		- `@app.function(...)`: Decorates remote functions to spin up serverless GPUs (NVIDIA), attached Modal volumes for model weights, and custom Debian Linux containers with PyTorch dependencies.
- **Model Choices Evaluated**: Testing Liquid AI's LFM2-VL series (450M, 1.6B, and 3B parameter variants).