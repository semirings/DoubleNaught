
`using SparseArrays
using LinearAlgebra

# 1. Define your Rule Engine Struct
struct OntologyGuardrailEngine
    # Dictionary mapping entity/attribute names to integer indices
    vocab::Dict{String, Int}
    
    # Adjacency matrix for mandatory co-occurrences (If X, must have Y)
    # R[i, j] = 1 means entity i requires entity j
    requirement_matrix::SparseMatrixCSC{Float64, Int}
    
    # Symmetric adjacency matrix for disjointness rules (X cannot co-occur with Y)
    # D[i, j] = 1 means entity i and entity j are mutually exclusive
    disjoint_matrix::SparseMatrixCSC{Float64, Int}
end

"""
    validate_prompt(engine::OntologyGuardrailEngine, candidate_tokens::Vector{String})

Validates a candidate prompt vector against the system's ontology rules using sparse matrix operations.
Returns a tuple: (is_valid::Bool, violations::Vector{String})
"""
function validate_prompt(engine::OntologyGuardrailEngine, candidate_tokens::Vector{String})
    violations = String[]
    
    # Map candidate string tokens to a binary sparse vector v based on vocabulary indices
    n = length(engine.vocab)
    v_indices = [engine.vocab[token] for token in candidate_tokens if haskey(engine.vocab, token)]
    
    if isempty(v_indices)
        return true, violations
    end
    
    # Create sparse binary vector representing the requested prompt state
    v = sparsevec(v_indices, ones(length(v_indices)), n)
    
    # --- Check 1: Disjointness / Mutually Exclusive Violation Check ---
    # Formula: v^T * D * v > 0 indicates a forbidden co-occurrence
    # (Using logical/algebraic semiring where multiplication is AND and addition is OR)
    disjoint_score = dot(v, engine.disjoint_matrix * v)
    
    if disjoint_score > 0.0
        push!(violations, "Disjointness violation detected: Mutually exclusive narrative or visual elements requested.")
        # Optional: You can inspect non-zero coordinates of (v' * D * v) to pinpoint exact failing pairs
    end
    
    # --- Check 2: Requirement / Dependency Violation Check ---
    # Formula: Check if required prerequisite elements are missing
    # If element i is present (v[i] == 1), its dependencies must also evaluate to 1.
    # We can check this via matrix multiplication against the requirement rules.
    
    is_valid = isempty(violations)
    return is_valid, violations
end

# ==========================================
# Example Usage & Setup
# ==========================================

# 1. Mocking your vocabulary extracted from your LinkML/Ontology
vocab = Dict(
    "Character_Bob" => 1,
    "Setting_Bridge" => 2,
    "RestrictedZone_Alpha" => 3,
    "ShotType_Wide" => 4,
    "ShotType_Macro" => 5  # Mutually exclusive with Wide
)

# 2. Build Disjointness Matrix (Symmetric)
# E.g., ShotType_Wide (4) and ShotType_Macro (5) cannot co-occur
# E.g., Character_Bob (1) and RestrictedZone_Alpha (3) cannot co-occur
rows = [4, 1]
cols = [5, 3]
vals = [1.0, 1.0]
D = sparse(rows, cols, vals, 5, 5)
D = D + D' # Ensure symmetry

# 3. Initialize the Engine
engine = OntologyGuardrailEngine(vocab, spzeros(5, 5), D)

# 4. Test Case 1: Valid Prompt Tokens
valid_tokens = ["Character_Bob", "Setting_Bridge", "ShotType_Wide"]
valid, errors = validate_prompt(engine, valid_tokens)
println("Test 1 (Valid): Passed? $valid | Errors: $errors")

# 5. Test Case 2: Invalid Prompt Tokens (Triggering Disjointness: Wide + Macro)
invalid_tokens = ["Character_Bob", "ShotType_Wide", "ShotType_Macro"]
valid, errors = validate_prompt(engine, invalid_tokens)
println("Test 2 (Invalid): Passed? $valid | Errors: $errors")`