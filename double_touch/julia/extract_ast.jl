#!/usr/bin/env julia
#
# extract_ast.jl — index every function and macro definition in a Julia codebase
# and emit the result as an Apache Arrow table.
#
#   julia --startup-file=no extract_ast.jl <source-dir> [out.arrow]
#
# With no output path (or `-`) the Arrow bytes go to stdout. Progress and errors
# always go to stderr, so stdout stays a clean binary stream.
#
# The table has exactly seven String columns, in this order:
#
#   symbol_name · kind · file_path · line_range · docstring · raw_code ·
#   better_docstring
#
# `better_docstring` is emitted empty: it is the slot a downstream teacher node
# fills in.
#
# Parsing uses JuliaSyntax — the registered package when it is installed, else the
# copy that ships inside Base (Julia ≥ 1.10). Both expose the same API surface
# this script needs.
#
# A file that fails to parse does not stop the walk. The parser runs with
# `ignore_errors=true`, so a file with one truncated definition still yields the
# definitions around it, and anything that throws is recorded and skipped.

const JS = try
    @eval using JuliaSyntax
    JuliaSyntax
catch
    isdefined(Base, :JuliaSyntax) ? Base.JuliaSyntax :
    error("no JuliaSyntax available: install JuliaSyntax.jl or use Julia ≥ 1.10")
end

using Arrow

# The seven columns, in emission order. Named here so the Python side and this
# script cannot drift apart silently.
const COLUMNS = (
    :symbol_name,
    :kind,
    :file_path,
    :line_range,
    :docstring,
    :raw_code,
    :better_docstring,
)

# Directory names skipped outright, on top of every dotted directory (`.git`,
# `.build`, …). `deps` holds build artefacts and vendored C sources; indexing it
# yields noise, not API.
const SKIP_DIRS = Set(["deps", "node_modules", "target"])

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

"""Extract the defined name from a definition's signature node.

Descends the shapes a signature can take, all of which were confirmed against
the parser rather than assumed:

    f(x) = …                → call → Identifier          → "f"
    Base.show(io) = …       → call → .                    → "Base.show"
    +(a, b) = …             → call → Identifier           → "+"
    h(x::T) where {T} = …   → where → call                → "h"
    f(x)::Int = …           → :: → call                   → "f"
    (::M)(x) = …            → call → ::                   → "(::M)"

Returns `""` when the shape is something not covered, so an odd definition is
recorded with an empty name rather than aborting the file.
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
        # A callable-object definition has no name of its own; show its type.
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

"""The text of a docstring node, without its delimiters.

A plain literal converts through `Expr` to a `String`. An interpolated docstring
does not, so it falls back to the raw source with the quotes trimmed — better to
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
        if startswith(text, fence) && endswith(text, fence) && length(text) >= 2 * length(fence)
            return String(strip(text[nextind(text, 0, length(fence) + 1):prevind(text, lastindex(text) + 1, length(fence))]))
        end
    end
    return text
end

"""Append a row for definition `node` to `rows`."""
function record!(rows, node, relative_path, docstring)
    is_macro = kindname(node) == "macro"
    kids = JS.children(node)
    name = isempty(kids) ? "" : signature_name(kids[1])
    if is_macro && !isempty(name) && !startswith(name, "@")
        name = "@" * name
    end
    first_line, last_line = line_span(node)

    push!(rows, (
        symbol_name = name,
        kind = is_macro ? "macro" : "function",
        file_path = relative_path,
        line_range = string(first_line, ":", last_line),
        docstring = docstring,
        raw_code = JS.sourcetext(node),
        better_docstring = "",
    ))
    return nothing
end

"""Walk `node`, recording every function and macro definition found.

`docstring` is the documentation attached by an enclosing `K"doc"` node, passed
down one level so the definition it wraps can claim it.

Definition **bodies are not descended into**: a closure inside a function already
appears verbatim in that function's `raw_code`, and emitting it as its own row
would duplicate the same source under a name that is not top-level. `quote`
blocks are skipped for the same reason — the function definitions inside a macro's
template are code being generated, not code that exists.
"""
function walk!(rows, node, relative_path; docstring::String = "")
    JS.is_leaf(node) && return nothing
    k = kindname(node)

    if k == "function" || k == "macro"
        record!(rows, node, relative_path, docstring)
        return nothing
    end

    if k == "doc"
        kids = JS.children(node)
        length(kids) >= 2 || return nothing
        text = try
            docstring_text(kids[1])
        catch
            ""
        end
        walk!(rows, kids[2], relative_path; docstring = text)
        return nothing
    end

    if k in CONTAINERS
        for child in JS.children(node)
            walk!(rows, child, relative_path)
        end
    end
    return nothing
end

"""Parse one file and append its definitions to `rows`.

Returns `nothing` on success, or a message describing why the file was skipped.
Never throws: one unreadable or unparsable file must not end the walk.
"""
function index_file!(rows, path, root)
    relative_path = relpath(path, root)
    source = try
        read(path, String)
    catch err
        return "$relative_path: unreadable ($(typeof(err)))"
    end

    tree = try
        # `ignore_errors` keeps the definitions around a broken one, instead of
        # losing the whole file to a single syntax error.
        JS.parseall(JS.SyntaxNode, source; filename = relative_path, ignore_errors = true)
    catch err
        return "$relative_path: parse failed ($(typeof(err)))"
    end

    before = length(rows)
    try
        walk!(rows, tree, relative_path)
    catch err
        # Keep whatever was recorded before the failure.
        return "$relative_path: traversal failed after $(length(rows) - before) rows ($(typeof(err)))"
    end
    return nothing
end

"""Every `.jl` file under `root`, skipping dotted and excluded directories."""
function julia_files(root)
    found = String[]
    for (dir, subdirs, files) in walkdir(root)
        # Prune in place so `walkdir` does not descend at all.
        filter!(d -> !startswith(d, ".") && !(d in SKIP_DIRS), subdirs)
        for f in files
            endswith(f, ".jl") && push!(found, joinpath(dir, f))
        end
    end
    return sort!(found)
end

"""Index `root` and return `(columns, errors, file_count)`."""
function extract(root)
    isdir(root) || error("not a directory: $root")
    rows = NamedTuple[]
    errors = String[]
    files = julia_files(root)
    for path in files
        message = index_file!(rows, path, root)
        message === nothing || push!(errors, message)
    end

    # Column-major, and typed: Arrow needs vectors, and an empty index still has
    # to carry the full schema.
    columns = NamedTuple{COLUMNS}(
        Tuple(String[getproperty(r, c) for r in rows] for c in COLUMNS)
    )
    return columns, errors, length(files)
end

function main(args)
    if isempty(args)
        println(stderr, "usage: extract_ast.jl <source-dir> [out.arrow|-]")
        return 2
    end

    root = abspath(expanduser(args[1]))
    destination = length(args) >= 2 ? args[2] : "-"

    columns, errors, file_count = extract(root)
    rowcount = length(columns.symbol_name)

    # Diagnostics ride inside the artifact as Arrow schema metadata, so the
    # reader gets them structurally instead of scraping stderr — and the run
    # still produces exactly one file, in one format.
    metadata = [
        "dn_schema" => "ast_index_v1",
        "dn_root" => root,
        "dn_files_scanned" => string(file_count),
        "dn_definition_count" => string(rowcount),
        "dn_error_count" => string(length(errors)),
        "dn_errors" => join(errors, "\n"),
        "dn_julia_version" => string(VERSION),
    ]

    if destination == "-"
        Arrow.write(stdout, columns; metadata = metadata)
    else
        Arrow.write(destination, columns; metadata = metadata)
    end

    println(stderr, "extract_ast: $rowcount definitions from $file_count files under $root")
    for message in errors
        println(stderr, "extract_ast: skipped $message")
    end
    return 0
end

# Runs both as a script and when `include`d with ARGS already set (how the Python
# wrapper invokes it, since the exec framework passes arguments that way).
# `(@__FILE__)` must be parenthesised: a bare macro call swallows the rest of the
# line as its arguments.
if abspath(PROGRAM_FILE) == (@__FILE__) || !isempty(ARGS)
    exit(main(ARGS))
end
