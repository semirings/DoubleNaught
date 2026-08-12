"""
    DnDefs

Shared definition-finding for the DoubleNaught Julia tooling: what counts as a
definition, what it is called, which lines it spans, and which docstring is
attached to it.

Both `extract_ast.jl` and `patch_docstrings.jl` use this. They **must** agree: the
patcher locates its target by the `(symbol_name, line_range)` the extractor
emitted, so two copies of this logic drifting apart would make the patcher
silently miss symbols rather than fail loudly.

Parsing uses JuliaSyntax — the registered package when installed, else the copy
that ships inside Base (Julia ≥ 1.10).
"""
module DnDefs

export Definition, each_definition, parse_source, escape_docstring, kindname

const JS = try
    @eval using JuliaSyntax
    JuliaSyntax
catch
    isdefined(Base, :JuliaSyntax) ? Base.JuliaSyntax :
    error("no JuliaSyntax available: install JuliaSyntax.jl or use Julia ≥ 1.10")
end

"""Kind of `n` as a plain string, e.g. `"function"`.

Compared as a string rather than with `K"function"`: `@K_str` would have to
resolve against whichever module [JS] turned out to be, at macro-expansion time,
and the string form is stable across JuliaSyntax versions.
"""
kindname(n) = string(JS.kind(n))

"""Node kinds whose children are more code, and so worth descending into."""
const CONTAINERS = Set([
    "toplevel", "block", "module", "baremodule",
    "if", "elseif", "else", "let", "begin", "try", "finally",
    # A struct body can hold inner constructors, which are real definitions.
    "struct",
])

"""One function or macro definition found in a source file."""
struct Definition
    "The `function` / `macro` node."
    node::Any
    "The attached docstring's **literal** node, or `nothing`. Splicing target."
    doc_literal::Any
    "The attached docstring's text, or `\"\"`."
    docstring::String
    "`\"add_one\"`, `\"Base.show\"`, `\"@shout\"`, `\"(::M)\"` …"
    name::String
    "`\"function\"` or `\"macro\"`."
    kind::String
    first_line::Int
    last_line::Int
end

"""`"12:28"` — the form the extracted index carries and the patcher matches on."""
line_range(d::Definition) = string(d.first_line, ":", d.last_line)

"""Parse `source`, tolerating syntax errors.

`ignore_errors` keeps the definitions around a broken one instead of losing the
whole file to a single syntax error.
"""
parse_source(source::AbstractString; filename::AbstractString = "none") =
    JS.parseall(JS.SyntaxNode, source; filename = filename, ignore_errors = true)

"""Extract the defined name from a definition's signature node.

Descends the shapes a signature can take, all confirmed against the parser rather
than assumed:

    f(x) = …                → call → Identifier   → "f"
    Base.show(io) = …       → call → .            → "Base.show"
    +(a, b) = …             → call → Identifier    → "+"
    h(x::T) where {T} = …   → where → call        → "h"
    f(x)::Int = …           → :: → call           → "f"
    (::M)(x) = …            → call → ::           → "(::M)"

Returns the signature's own text when the shape is something not covered, so an
odd definition is recorded rather than aborting the file.
"""
function signature_name(sig)
    JS.is_leaf(sig) && return JS.sourcetext(sig)
    k = kindname(sig)
    kids = JS.children(sig)
    isempty(kids) && return JS.sourcetext(sig)

    if k == "where" || k == "::"
        head = kids[1]
        # `f(x)::Int` unwraps to the call; a bare `(::M)` is a callable object.
        return JS.is_leaf(head) || kindname(head) != "call" ?
            "(" * JS.sourcetext(sig) * ")" : signature_name(head)
    elseif k == "call" || k == "curly"
        head = kids[1]
        return kindname(head) == "::" ? "(" * JS.sourcetext(head) * ")" :
            JS.sourcetext(head)
    end
    return JS.sourcetext(sig)
end

"""The 1-based `(start, stop)` source lines spanned by `n`."""
function line_span(n)
    first_line = JS.source_location(n)[1]
    last_line = try
        JS.source_location(n.source, JS.last_byte(n))[1]
    catch
        first_line
    end
    return (first_line, last_line)
end

"""The text of a docstring literal node, without its delimiters.

A plain literal converts through `Expr` to a `String`. An interpolated docstring
does not, so it falls back to the raw source with the fence trimmed — better to
carry the template than to drop the documentation.
"""
function docstring_text(n)
    literal = try
        Expr(n)
    catch
        nothing
    end
    literal isa String && return literal

    text = JS.sourcetext(n)
    for fence in ("\"\"\"", "\"")
        if startswith(text, fence) && endswith(text, fence) &&
           length(text) >= 2 * length(fence)
            inner = text[nextind(text, 0, length(fence) + 1):prevind(text, lastindex(text) + 1, length(fence))]
            return String(strip(inner))
        end
    end
    return text
end

"""Name for a definition node, with a macro's leading `@`."""
function definition_name(node, is_macro::Bool)
    kids = JS.children(node)
    name = isempty(kids) ? "" : signature_name(kids[1])
    if is_macro && !isempty(name) && !startswith(name, "@")
        name = "@" * name
    end
    return name
end

"""Every function and macro definition under `node`, in source order.

`doc` nodes contribute their text to the definition they wrap, and their literal
node is carried along so a caller can splice over it.

Definition **bodies are not descended into**: a closure inside a function already
appears verbatim in that function's source, and treating it as its own top-level
definition would duplicate the same text under a misleading name. `quote` blocks
are skipped for the same reason — definitions inside a macro's template are code
being generated, not code that exists.
"""
function each_definition(node; found = Definition[], doc_literal = nothing,
                         docstring::String = "")
    JS.is_leaf(node) && return found
    k = kindname(node)

    if k == "function" || k == "macro"
        is_macro = k == "macro"
        first_line, last_line = line_span(node)
        push!(found, Definition(
            node, doc_literal, docstring,
            definition_name(node, is_macro),
            is_macro ? "macro" : "function",
            first_line, last_line,
        ))
        return found
    end

    if k == "doc"
        kids = JS.children(node)
        length(kids) >= 2 || return found
        text = try
            docstring_text(kids[1])
        catch
            ""
        end
        each_definition(kids[2]; found = found, doc_literal = kids[1], docstring = text)
        return found
    end

    if k in CONTAINERS
        for child in JS.children(node)
            each_definition(child; found = found)
        end
    end
    return found
end

"""Escape `text` for embedding in a `\"\"\"` … `\"\"\"` block.

Three substitutions, and they are the *only* three needed — verified by
round-tripping every awkward case (interpolation, LaTeX backslashes, an embedded
fence, trailing quotes) back through the parser:

* `\\` → `\\\\`  — otherwise it escapes the next character
* `\$`  → `\\\$`  — otherwise it interpolates
* `\"\"\"` → escaped quotes — otherwise it closes the block early

A trailing `\"` needs no special handling because the emitted block always puts a
newline before the closing fence.

**Not** `raw\"\"\"`: the parser treats a raw string literal above a definition as a
`macrocall`, not a `doc`, so the documentation would be silently lost.
"""
function escape_docstring(text::AbstractString)
    escaped = replace(text, "\\" => "\\\\")
    escaped = replace(escaped, "\$" => "\\\$")
    return replace(escaped, "\"\"\"" => "\\\"\\\"\\\"")
end

end # module DnDefs
