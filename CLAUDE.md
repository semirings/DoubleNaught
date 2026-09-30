# DoubleNaught (DN) — Project Context for Claude Code

Associative Array (AA) semantics, invariants, the D4M.jl/GraphBLAS dependency
mandate, and the backend-only algebra rule are all covered by the
`associative-arrays` skill (`.claude/skills/associative-arrays/SKILL.md`) —
it auto-invokes on AA/D4M-related work, so nothing here needs to duplicate it.
The authoritative source is `aa-spec.pdf` at the project root; AA-related
registry code lives in `aa_binary_normalizer.py` and related nodes.
