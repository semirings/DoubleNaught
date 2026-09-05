"""GPT-style transformer model definition.

Architecture matches GPT-2 medium (117M @ default config):
  12 layers · 768 d_model · 12 heads · 3072 d_ff · 1024 ctx
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import torch
import torch.nn as nn
from torch.utils.checkpoint import checkpoint


@dataclass
class GPTConfig:
    vocab_size: int = 50257
    n_layers: int = 12
    d_model: int = 768
    n_heads: int = 12
    d_ff: int = 3072       # typically 4 * d_model
    dropout: float = 0.1
    max_seq_len: int = 1024
    use_gradient_checkpointing: bool = False

    def __post_init__(self) -> None:
        if self.d_model % self.n_heads != 0:
            raise ValueError(
                f"d_model ({self.d_model}) must be divisible by n_heads ({self.n_heads})"
            )

    def to_dict(self) -> dict:
        return {
            "vocab_size": self.vocab_size,
            "n_layers": self.n_layers,
            "d_model": self.d_model,
            "n_heads": self.n_heads,
            "d_ff": self.d_ff,
            "dropout": self.dropout,
            "max_seq_len": self.max_seq_len,
            "use_gradient_checkpointing": self.use_gradient_checkpointing,
        }


class CausalSelfAttention(nn.Module):
    """Multi-head causal self-attention with scaled dot-product."""

    def __init__(self, cfg: GPTConfig) -> None:
        super().__init__()
        self.n_heads = cfg.n_heads
        self.d_head = cfg.d_model // cfg.n_heads

        self.qkv = nn.Linear(cfg.d_model, 3 * cfg.d_model, bias=False)
        self.out_proj = nn.Linear(cfg.d_model, cfg.d_model, bias=False)
        self.attn_drop = nn.Dropout(cfg.dropout)
        self.resid_drop = nn.Dropout(cfg.dropout)

        # Causal mask — registered as a buffer so it moves with the model.
        self.register_buffer(
            "mask",
            torch.tril(torch.ones(cfg.max_seq_len, cfg.max_seq_len)).view(
                1, 1, cfg.max_seq_len, cfg.max_seq_len
            ),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        B, T, C = x.shape
        qkv = self.qkv(x).split(C, dim=-1)
        q, k, v = (
            t.view(B, T, self.n_heads, self.d_head).transpose(1, 2)
            for t in qkv
        )
        scale = 1.0 / math.sqrt(self.d_head)
        att = (q @ k.transpose(-2, -1)) * scale
        att = att.masked_fill(self.mask[:, :, :T, :T] == 0, float("-inf"))
        att = torch.softmax(att, dim=-1)
        att = self.attn_drop(att)
        y = (att @ v).transpose(1, 2).contiguous().view(B, T, C)
        return self.resid_drop(self.out_proj(y))


class FeedForward(nn.Module):
    """Position-wise feed-forward network (GELU activation, GPT-2 style)."""

    def __init__(self, cfg: GPTConfig) -> None:
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(cfg.d_model, cfg.d_ff),
            nn.GELU(),
            nn.Linear(cfg.d_ff, cfg.d_model),
            nn.Dropout(cfg.dropout),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.net(x)


class TransformerBlock(nn.Module):
    """Pre-norm transformer block: LN → Attn → residual, LN → FFN → residual."""

    def __init__(self, cfg: GPTConfig) -> None:
        super().__init__()
        self.ln1 = nn.LayerNorm(cfg.d_model)
        self.attn = CausalSelfAttention(cfg)
        self.ln2 = nn.LayerNorm(cfg.d_model)
        self.ffn = FeedForward(cfg)
        self._use_ckpt = cfg.use_gradient_checkpointing

    def _inner(self, x: torch.Tensor) -> torch.Tensor:
        x = x + self.attn(self.ln1(x))
        x = x + self.ffn(self.ln2(x))
        return x

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if self._use_ckpt and x.requires_grad:
            return checkpoint(self._inner, x, use_reentrant=False)
        return self._inner(x)


class GPTModel(nn.Module):
    """GPT-style causal language model."""

    def __init__(self, cfg: GPTConfig) -> None:
        super().__init__()
        self.cfg = cfg
        self.tok_emb = nn.Embedding(cfg.vocab_size, cfg.d_model)
        self.pos_emb = nn.Embedding(cfg.max_seq_len, cfg.d_model)
        self.drop = nn.Dropout(cfg.dropout)
        self.blocks = nn.ModuleList(
            [TransformerBlock(cfg) for _ in range(cfg.n_layers)]
        )
        self.ln_f = nn.LayerNorm(cfg.d_model)
        # Tied output projection — shares weights with token embedding.
        self.lm_head = nn.Linear(cfg.d_model, cfg.vocab_size, bias=False)
        self.lm_head.weight = self.tok_emb.weight

        self._init_weights()

    def _init_weights(self) -> None:
        for module in self.modules():
            if isinstance(module, nn.Linear):
                nn.init.normal_(module.weight, mean=0.0, std=0.02)
                if module.bias is not None:
                    nn.init.zeros_(module.bias)
            elif isinstance(module, nn.Embedding):
                nn.init.normal_(module.weight, mean=0.0, std=0.02)

    def forward(
        self,
        idx: torch.Tensor,
        targets: torch.Tensor | None = None,
    ) -> tuple[torch.Tensor, torch.Tensor | None]:
        B, T = idx.shape
        pos = torch.arange(T, device=idx.device)
        x = self.drop(self.tok_emb(idx) + self.pos_emb(pos))
        for block in self.blocks:
            x = block(x)
        logits = self.lm_head(self.ln_f(x))
        loss = None
        if targets is not None:
            loss = nn.functional.cross_entropy(
                logits.view(-1, logits.size(-1)), targets.view(-1)
            )
        return logits, loss

    # ------------------------------------------------------------------
    # Introspection helpers
    # ------------------------------------------------------------------

    def param_count(self) -> int:
        return sum(p.numel() for p in self.parameters())

    def trainable_param_count(self) -> int:
        return sum(p.numel() for p in self.parameters() if p.requires_grad)

    def estimated_memory_mb(self, mixed_precision: bool = True) -> float:
        """Rough VRAM estimate: params + gradients + optimizer state."""
        bytes_per_param = 2 if mixed_precision else 4
        params = self.param_count()
        # params (fp16) + grads (fp32) + Adam state (2× fp32) ≈ 16 bytes/param
        total_bytes = params * (bytes_per_param + 4 + 8)
        return total_bytes / (1024 ** 2)

    def architecture_summary(self) -> dict:
        cfg = self.cfg
        return {
            "vocab_size": cfg.vocab_size,
            "n_layers": cfg.n_layers,
            "d_model": cfg.d_model,
            "n_heads": cfg.n_heads,
            "d_head": cfg.d_model // cfg.n_heads,
            "d_ff": cfg.d_ff,
            "max_seq_len": cfg.max_seq_len,
            "dropout": cfg.dropout,
            "param_count": self.param_count(),
            "param_count_m": round(self.param_count() / 1e6, 1),
            "estimated_vram_fp16_mb": round(self.estimated_memory_mb(True), 0),
            "estimated_vram_fp32_mb": round(self.estimated_memory_mb(False), 0),
        }
