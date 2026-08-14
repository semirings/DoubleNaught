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
# fills in, and `patch_docstrings.jl` reads back.
#
# A file that fails to parse does not stop the walk. Parsing runs with
# `ignore_errors=true`, so a file with one truncated definition still yields the
# definitions around it, and anything that throws is recorded and skipped.
#
# What counts as a definition, and what it is called, lives in `defs.jl` — shared
# with the patcher, which locates its targets by the very `(symbol_name,
# line_range)` pairs emitted here.

include(joinpath(@__DIR__, "defs.jl"))
using .DnDefs

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
# `.build`, …). `deps` holds build artefacts and vendored sources; indexing it
# yields noise, not API.
const SKIP_DIRS = Set(["deps", "node_modules", "target"])

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
        DnDefs.parse_source(source; filename = relative_path)
    catch err
        return "$relative_path: parse failed ($(typeof(err)))"
    end

    before = length(rows)
    try
        for definition in DnDefs.each_definition(tree)
            push!(rows, (
                symbol_name = definition.name,
                kind = definition.kind,
                file_path = relative_path,
                line_range = DnDefs.line_range(definition),
                docstring = definition.docstring,
                raw_code = DnDefs.JS.sourcetext(definition.node),
                better_docstring = "",
            ))
        end
    catch err
        # Keep whatever was recorded before the failure.
        return "$relative_path: traversal failed after $(length(rows) - before) rows ($(typeof(err)))"
    end
    return nothing
end

"""Every `.jl` file under `root`, skipping dotted and excluded directories.

`root` may also be a single `.jl` file, which indexes just that file — the canvas
hands over the file a `Load File` node opened, not the tree around it.
"""
function julia_files(root)
    isfile(root) && return endswith(root, ".jl") ? [root] : String[]
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

"""Index `root` — a directory tree or a single `.jl` file.

Returns `(columns, errors, file_count)`. `file_path` is relative to the directory:
for a single file that is its own parent, so the column holds the bare filename.
"""
function extract(root)
    isdir(root) || isfile(root) || error("no such file or directory: $root")
    base = isdir(root) ? root : dirname(root)
    rows = NamedTuple[]
    errors = String[]
    files = julia_files(root)
    for path in files
        message = index_file!(rows, path, base)
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
    #
    # `dn_root` matters beyond diagnostics: `file_path` is relative to it, so the
    # patcher needs it to find the files again.
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
#
# `(@__FILE__)` must be parenthesised: a bare macro call swallows the rest of the
# line as its arguments.
if abspath(PROGRAM_FILE) == (@__FILE__) || !isempty(ARGS)
    exit(main(ARGS))
end
