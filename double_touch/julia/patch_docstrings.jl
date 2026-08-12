#!/usr/bin/env julia
#
# patch_docstrings.jl — write generated docstrings from a 7-column Arrow index
# back into the Julia sources they describe.
#
#   julia --startup-file=no patch_docstrings.jl <index.arrow|-> [summary.arrow|-] \
#         [--root=DIR] [--dry-run]
#
# Reads the index emitted by `extract_ast.jl` and enriched by a teacher node: for
# every row whose `better_docstring` is non-empty, the docstring above that
# definition is replaced, or inserted if the definition had none.
#
# Emits a summary Arrow table — `file_path`, `symbols_patched`, `status` — where
# status is `UPDATED`, `NO_CHANGE` or `ERROR`.
#
# ## Byte-for-byte preservation
#
# The AST is used to *locate*, never to re-print. Patching is a byte splice: the
# file is rebuilt as `bytes before … new docstring … bytes after`, so every byte
# of code, comment, blank line and indentation outside the spliced range survives
# unchanged. Reprinting a parsed tree would reformat the file, which is exactly
# what must not happen.
#
# ## All-or-nothing per file
#
# If any row targeting a file cannot be located — a stale index, a file edited
# since extraction — that file is left **completely untouched** and reported as
# ERROR. A half-patched source is worse than an unpatched one, and the fix is to
# re-extract, so partial application would only hide the staleness.
#
# Writes go through a temporary file in the same directory, `chmod`-ed to match the
# original, then renamed over it: a crash mid-write cannot leave a truncated
# source file.

include(joinpath(@__DIR__, "defs.jl"))
using .DnDefs

using Arrow

const JS = DnDefs.JS

# Columns required on the way in — the extractor's schema, unchanged.
const REQUIRED_COLUMNS = (
    :symbol_name, :kind, :file_path, :line_range,
    :docstring, :raw_code, :better_docstring,
)

const STATUS_UPDATED = "UPDATED"
const STATUS_NO_CHANGE = "NO_CHANGE"
const STATUS_ERROR = "ERROR"

"""One pending byte-level edit: replace `first_byte:last_byte` with `text`.

`last_byte < first_byte` denotes a pure insertion at `first_byte`.
"""
struct Splice
    first_byte::Int
    last_byte::Int
    text::String
end

"""The indentation (spaces/tabs) preceding byte `at` on its own line."""
function indentation_at(bytes::Vector{UInt8}, at::Int)
    start = at - 1
    while start >= 1 && bytes[start] != UInt8('\n')
        start -= 1
    end
    indent = IOBuffer()
    index = start + 1
    while index < at && (bytes[index] == UInt8(' ') || bytes[index] == UInt8('\t'))
        write(indent, bytes[index])
        index += 1
    end
    return String(take!(indent))
end

"""A `\"\"\"` docstring block for `text`, every line after the first indented by
`indent`, and using `newline` for line endings.

The first line is not indented: the splice point already sits after the existing
indentation, so prefixing it would double it.
"""
function docstring_block(text::AbstractString, indent::AbstractString, newline::AbstractString)
    body = DnDefs.escape_docstring(rstrip(text))
    lines = split(body, '\n')
    out = IOBuffer()
    write(out, "\"\"\"", newline)
    for line in lines
        # Keep blank lines genuinely blank rather than trailing whitespace.
        write(out, isempty(strip(line)) ? "" : indent * line, newline)
    end
    write(out, indent, "\"\"\"")
    return String(take!(out))
end

"""Plan the edit for one row against a located definition, or `nothing` when the
docstring is already what was asked for."""
function plan_splice(definition, better::AbstractString, bytes::Vector{UInt8},
                     newline::AbstractString)
    if definition.doc_literal !== nothing
        existing = definition.docstring
        rstrip(existing) == rstrip(better) && return nothing
        literal = definition.doc_literal
        indent = indentation_at(bytes, JS.first_byte(literal))
        return Splice(
            JS.first_byte(literal),
            JS.last_byte(literal),
            docstring_block(better, indent, newline),
        )
    end

    at = JS.first_byte(definition.node)
    indent = indentation_at(bytes, at)
    # Insert the block, then a newline and the definition's own indentation so the
    # signature keeps the column it started in.
    return Splice(at, at - 1, docstring_block(better, indent, newline) * newline * indent)
end

"""Apply `splices` to `bytes`, returning the patched bytes.

Descending order matters: a later edit must not shift the offsets of an earlier
one.
"""
function apply_splices(bytes::Vector{UInt8}, splices::Vector{Splice})
    ordered = sort(splices; by = s -> s.first_byte, rev = true)
    out = copy(bytes)
    for splice in ordered
        # Where the tail resumes: past the replaced range, or right at the
        # insertion point when nothing is being replaced. Computed as an integer
        # rather than branching between two `@view`s — a bare macro call would
        # swallow the ternary's `:` as an argument.
        resume = splice.last_byte >= splice.first_byte ?
            splice.last_byte + 1 : splice.first_byte
        buffer = IOBuffer()
        write(buffer, @view out[1:(splice.first_byte - 1)])
        write(buffer, splice.text)
        write(buffer, @view out[resume:end])
        out = take!(buffer)
    end
    return out
end

"""Replace `path`'s contents with `bytes`, atomically and preserving its mode."""
function write_atomically(path::AbstractString, bytes::Vector{UInt8})
    directory = dirname(abspath(path))
    temporary = tempname(directory; cleanup = false)
    try
        open(temporary, "w") do io
            write(io, bytes)
        end
        # Keep the original's permission bits: the rename would otherwise hand the
        # file the temp file's mode.
        try
            chmod(temporary, filemode(path))
        catch
        end
        mv(temporary, path; force = true)
    catch err
        rm(temporary; force = true)
        rethrow(err)
    end
    return nothing
end

"""Patch one file. Returns `(status, patched_count, messages)`."""
function patch_file(path::AbstractString, rows, dry_run::Bool)
    messages = String[]

    source = try
        read(path, String)
    catch err
        return STATUS_ERROR, 0, ["$path: unreadable ($(typeof(err)))"]
    end

    tree = try
        DnDefs.parse_source(source; filename = path)
    catch err
        return STATUS_ERROR, 0, ["$path: parse failed ($(typeof(err)))"]
    end

    definitions = try
        DnDefs.each_definition(tree)
    catch err
        return STATUS_ERROR, 0, ["$path: traversal failed ($(typeof(err)))"]
    end

    # Keyed exactly as the extractor emitted it, so a stale index misses rather
    # than mis-targets.
    by_key = Dict{Tuple{String,String},Any}()
    for definition in definitions
        by_key[(definition.name, DnDefs.line_range(definition))] = definition
    end

    bytes = Vector{UInt8}(source)
    newline = occursin("\r\n", source) ? "\r\n" : "\n"
    splices = Splice[]

    for row in rows
        better = row.better_docstring
        isempty(strip(better)) && continue

        key = (row.symbol_name, row.line_range)
        definition = get(by_key, key, nothing)
        if definition === nothing
            push!(messages,
                "$path: no definition matching $(row.symbol_name) at $(row.line_range) " *
                "— index is stale, re-extract")
            continue
        end
        if definition.kind != row.kind
            push!(messages,
                "$path: $(row.symbol_name) at $(row.line_range) is a $(definition.kind), " *
                "index says $(row.kind)")
            continue
        end

        splice = plan_splice(definition, better, bytes, newline)
        splice === nothing || push!(splices, splice)
    end

    # All-or-nothing: a single unlocatable row leaves the file alone.
    isempty(messages) || return STATUS_ERROR, 0, messages
    isempty(splices) && return STATUS_NO_CHANGE, 0, messages

    patched = try
        apply_splices(bytes, splices)
    catch err
        return STATUS_ERROR, 0, ["$path: splice failed ($(typeof(err)))"]
    end

    if !dry_run
        try
            write_atomically(path, patched)
        catch err
            return STATUS_ERROR, 0, ["$path: write failed ($(typeof(err)))"]
        end
    end
    return STATUS_UPDATED, length(splices), messages
end

"""Read the index table from `source` — a path, or `-` for stdin bytes."""
read_index(source::AbstractString) =
    source == "-" ? Arrow.Table(read(stdin)) : Arrow.Table(source)

"""Rows as NamedTuples of Strings, grouped by `file_path` in first-seen order."""
function grouped_rows(table)
    columns = Arrow.names(table)
    for required in REQUIRED_COLUMNS
        required in columns ||
            error("input table is missing the '$required' column; expected the " *
                  "7-column index from extract_ast.jl")
    end

    order = String[]
    groups = Dict{String,Vector{NamedTuple}}()
    count = length(getproperty(table, :file_path))
    for index in 1:count
        row = (
            symbol_name = String(table.symbol_name[index]),
            kind = String(table.kind[index]),
            file_path = String(table.file_path[index]),
            line_range = String(table.line_range[index]),
            better_docstring = String(table.better_docstring[index]),
        )
        if !haskey(groups, row.file_path)
            groups[row.file_path] = NamedTuple[]
            push!(order, row.file_path)
        end
        push!(groups[row.file_path], row)
    end
    return order, groups
end

function main(args)
    positional = String[]
    dry_run = false
    root_override = ""
    for argument in args
        if argument == "--dry-run"
            dry_run = true
        elseif startswith(argument, "--root=")
            root_override = argument[length("--root=") + 1:end]
        else
            push!(positional, argument)
        end
    end

    if isempty(positional)
        println(stderr,
            "usage: patch_docstrings.jl <index.arrow|-> [summary.arrow|-] " *
            "[--root=DIR] [--dry-run]")
        return 2
    end

    table = read_index(positional[1])
    destination = length(positional) >= 2 ? positional[2] : "-"

    # `file_path` in the index is relative to the root it was extracted from, so
    # that root has to come along: explicit flag first, else the index's own
    # `dn_root` metadata, else the working directory.
    metadata = Arrow.getmetadata(table)
    root = if !isempty(root_override)
        root_override
    elseif metadata !== nothing
        get(metadata, "dn_root", "")
    else
        ""
    end

    order, groups = grouped_rows(table)

    files = String[]
    counts = Int64[]
    statuses = String[]
    messages = String[]

    for relative in order
        path = isabspath(relative) ? relative :
            (isempty(root) ? abspath(relative) : joinpath(root, relative))
        status, patched, notes = patch_file(path, groups[relative], dry_run)
        push!(files, relative)
        push!(counts, patched)
        push!(statuses, status)
        append!(messages, notes)
    end

    summary = (file_path = files, symbols_patched = counts, status = statuses)
    summary_metadata = [
        "dn_schema" => "patch_summary_v1",
        "dn_root" => string(root),
        "dn_dry_run" => string(dry_run),
        "dn_files_updated" => string(count(==(STATUS_UPDATED), statuses)),
        "dn_symbols_patched" => string(sum(counts; init = 0)),
        "dn_error_count" => string(count(==(STATUS_ERROR), statuses)),
        "dn_errors" => join(messages, "\n"),
        "dn_julia_version" => string(VERSION),
    ]

    if destination == "-"
        Arrow.write(stdout, summary; metadata = summary_metadata)
    else
        Arrow.write(destination, summary; metadata = summary_metadata)
    end

    prefix = dry_run ? "patch_docstrings (dry run)" : "patch_docstrings"
    println(stderr,
        "$prefix: $(sum(counts; init = 0)) docstrings across " *
        "$(count(==(STATUS_UPDATED), statuses)) files " *
        "($(count(==(STATUS_ERROR), statuses)) errors)")
    for message in messages
        println(stderr, "$prefix: $message")
    end
    return 0
end

# Runs both as a script and when `include`d with ARGS already set (how the Python
# wrapper invokes it). `(@__FILE__)` must be parenthesised: a bare macro call
# swallows the rest of the line as its arguments.
if abspath(PROGRAM_FILE) == (@__FILE__) || !isempty(ARGS)
    exit(main(ARGS))
end
