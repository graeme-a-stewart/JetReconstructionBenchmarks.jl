using JSON
using DataFrames
using CSV
using Statistics

show_help = any(arg -> arg in ("-h", "--help"), ARGS)
if length(ARGS) < 2 || show_help
    println("Usage: julia merge-thread-scan.jl input1.json/input1.csv [input2 ...] output.csv")
    println()
    println("Inputs can be JSON files from thread-run.jl or CSV files from benchmark.jl.")
    exit(show_help ? 0 : 1)
end

input_files = ARGS[1:end-1]
output_file = ARGS[end]

const ROW_COLUMNS = (
    :source_file,
    :source_format,
    :code,
    :code_version,
    :backend,
    :backend_version,
    :threads,
    :schedule,
    :events_per_second,
    :algorithm,
    :strategy,
    :R,
    :p,
    :input_file,
    :input_event_count,
    :measured_events,
    :nsamples,
    :repeats,
    :gcoff,
    :warmup_events,
    :julia_version,
    :wall_time_seconds,
    :time_per_event_seconds,
    :allocated_bytes_total,
    :allocated_bytes_per_event,
    :gc_fraction,
    :benchmark_command,
    :repo_commit,
    :repo_short_commit,
    :repo_branch,
    :repo_dirty,
    :remote_origin,
    :package_commit,
    :jetreconstruction_version,
    :jetreconstruction_source,
    :cpu_threads,
    :cpu_model,
    :machine,
    :kernel,
    :total_memory_bytes,
    :julia_project,
    :julia_num_gc_threads,
    :julia_exclusive,
)

get_nested(data, keys...; default = missing) = foldl(
    (value, key) -> value isa AbstractDict && haskey(value, key) ? value[key] : default,
    keys;
    init = data,
)

is_missing_like(value) = ismissing(value) || isnothing(value)

function maybe_string(value)
    is_missing_like(value) && return missing
    return string(value)
end

function string_or(value, default::AbstractString)
    is_missing_like(value) && return default
    text = string(value)
    return isempty(text) ? default : text
end

function effective_schedule(data)
   if haskey(data, "julia_scheduler")
        return string_or(get(data, "julia_scheduler", missing), "julia_threads_default")
    end

    if haskey(data, "schedule")
        return string_or(get(data, "schedule", missing), "dynamic")
    end

    code = string_or(get(data, "code", missing), "JetReconstruction")
    backend = string_or(get(data, "backend", missing), "Julia")

    if code == "Fastjet" || backend == "C++"
        return "dynamic"
    end

    return "julia_threads_default"
end


function maybe_float(value)
    is_missing_like(value) && return missing
    return Float64(value)
end

function maybe_int(value)
    is_missing_like(value) && return missing
    return Int(value)
end

function maybe_bool(value)
    is_missing_like(value) && return missing
    return Bool(value)
end

function positive_or_missing(value)
    parsed = maybe_float(value)
    if ismissing(parsed)
        return missing
    end
    if parsed <= 0
        error("time_per_event must be positive, got $(parsed)")
    end
    return parsed
end

function divide_or_missing(numerator, denominator)
    if is_missing_like(numerator) || is_missing_like(denominator)
        return missing
    end
    denominator == 0 && return missing
    return Float64(numerator) / Float64(denominator)
end

function median_skipmissing(values)
    numeric = Float64[]
    for value in values
        is_missing_like(value) || push!(numeric, Float64(value))
    end
    return isempty(numeric) ? missing : median(numeric)
end

function first_skipmissing(values)
    for value in values
        is_missing_like(value) || return value
    end
    return missing
end

function require_columns(df::DataFrame, columns::Vector{Symbol}, filename::AbstractString)
    missing_columns = setdiff(columns, propertynames(df))
    if !isempty(missing_columns)
        error("$(filename) is missing required column(s): $(join(string.(missing_columns), ", "))")
    end
end

function row_tuple(; kwargs...)
    values = Dict{Symbol, Any}(kwargs)
    return NamedTuple{ROW_COLUMNS}(Tuple(get(values, col, missing) for col in ROW_COLUMNS))
end

function schedule_label(code, schedule)
    if is_missing_like(schedule) || isempty(string(schedule))
        return string(code) == "Fastjet" ? "dynamic" : "julia_threads_default"
    end
    return string(schedule)
end

function benchmark_backend_default(code)
    code_text = string(code)
    if code_text == "JetReconstruction"
        return "Julia"
    elseif code_text == "Fastjet" || code_text == "CJetReconstruction"
        return "C++"
    elseif code_text == "AkTPython" || code_text == "AkTNumPy"
        return "Python"
    end
    return "unknown"
end

function parse_json_file!(rows, filename::AbstractString)
    data = JSON.parsefile(filename)
    if !Bool(data["success"])
        @warn "Skipping file due to unsuccessful run" filename
        return
    end

    measured_events = maybe_int(get(data, "measured_events", missing))
    wall_time_seconds = maybe_float(get_nested(data, "summary", "wall_time_seconds_median"))
    time_per_event_seconds = maybe_float(get_nested(data, "summary", "time_per_event_seconds_median"))
    if ismissing(time_per_event_seconds)
        time_per_event_seconds = divide_or_missing(wall_time_seconds, measured_events)
    end

    allocated_bytes_total = maybe_float(get_nested(data, "summary", "allocated_bytes_total_median"))
    allocated_bytes_per_event = divide_or_missing(allocated_bytes_total, measured_events)

    julia_version = string_or(get(data, "julia_version", missing), "unknown")
    jetreconstruction_version = maybe_string(get_nested(data, "packages", "JetReconstruction", "version"))

    push!(rows, row_tuple(
        source_file = filename,
        source_format = "json",
        code = string_or(get(data, "code", missing), "JetReconstruction"),
        code_version = string_or(get(data, "code_version", missing), ismissing(jetreconstruction_version) ? "unknown" : jetreconstruction_version),
        backend = string_or(get(data, "backend", missing), "Julia"),
        backend_version = string_or(get(data, "backend_version", missing), julia_version),
        threads = maybe_int(get(data, "threads", get(data, "julia_threads", missing))),
        schedule = effective_schedule(data),
        events_per_second = maybe_float(get_nested(data, "summary", "events_per_second_median")),
        algorithm = string_or(get(data, "algorithm", missing), "unknown"),
        strategy = string_or(get(data, "strategy", missing), "unknown"),
        R = maybe_float(get(data, "R", missing)),
        p = maybe_float(get(data, "p", missing)),
        input_file = string_or(get(data, "input_file", missing), "unknown"),
        input_event_count = maybe_int(get(data, "input_event_count", missing)),
        measured_events = measured_events,
        nsamples = maybe_int(get(data, "nsamples", missing)),
        repeats = maybe_int(get(data, "repeats", missing)),
        gcoff = maybe_bool(get(data, "gcoff", false)),
        warmup_events = maybe_int(get(data, "warmup_events", missing)),
        julia_version = julia_version,
        wall_time_seconds = wall_time_seconds,
        time_per_event_seconds = time_per_event_seconds,
        allocated_bytes_total = allocated_bytes_total,
        allocated_bytes_per_event = allocated_bytes_per_event,
        gc_fraction = maybe_float(get_nested(data, "summary", "gc_fraction_median")),
        benchmark_command = maybe_string(get(data, "benchmark_command", missing)),
        repo_commit = maybe_string(get_nested(data, "git", "commit")),
        repo_short_commit = maybe_string(get_nested(data, "git", "short_commit")),
        repo_branch = maybe_string(get_nested(data, "git", "branch")),
        repo_dirty = maybe_bool(get_nested(data, "git", "is_dirty")),
        remote_origin = maybe_string(get_nested(data, "git", "remote_origin")),
        package_commit = maybe_string(get(data, "package_commit", missing)),
        jetreconstruction_version = jetreconstruction_version,
        jetreconstruction_source = maybe_string(get_nested(data, "packages", "JetReconstruction", "source")),
        cpu_threads = maybe_int(get_nested(data, "hardware", "cpu_threads")),
        cpu_model = maybe_string(get_nested(data, "hardware", "cpu_model")),
        machine = maybe_string(get_nested(data, "hardware", "machine")),
        kernel = maybe_string(get_nested(data, "hardware", "kernel")),
        total_memory_bytes = maybe_int(get_nested(data, "hardware", "total_memory_bytes")),
        julia_project = maybe_string(get_nested(data, "runtime", "julia_project")),
        julia_num_gc_threads = maybe_string(get_nested(data, "runtime", "environment", "JULIA_NUM_GC_THREADS")),
        julia_exclusive = maybe_string(get_nested(data, "runtime", "environment", "JULIA_EXCLUSIVE")),
    ))
end

function column_value(row, column::Symbol, default = missing)
    return hasproperty(row, column) ? getproperty(row, column) : default
end

function parse_csv_file!(rows, filename::AbstractString)
    df = CSV.read(filename, DataFrame)
    require_columns(df, [:time_per_event, :code, :algorithm, :strategy, :radius, :power, :threads], filename)

    for row in eachrow(df)
        time_per_event_us = positive_or_missing(row.time_per_event)
        time_per_event_seconds = time_per_event_us * 1e-6
        code = string_or(row.code, "unknown")
        backend = string_or(column_value(row, :backend), benchmark_backend_default(code))
        input_file = if hasproperty(row, :File_path)
            string_or(row.File_path, "unknown")
        elseif hasproperty(row, :input_file)
            string_or(row.input_file, "unknown")
        elseif hasproperty(row, :File)
            string_or(row.File, "unknown")
        else
            error("$(filename) is missing an input file column; expected File_path, input_file, or File")
        end

        push!(rows, row_tuple(
            source_file = filename,
            source_format = "csv",
            code = code,
            code_version = string_or(column_value(row, :code_version), "unknown"),
            backend = backend,
            backend_version = string_or(column_value(row, :backend_version), "unknown"),
            threads = maybe_int(row.threads),
            schedule = schedule_label(code, column_value(row, :schedule)),
            events_per_second = 1.0 / time_per_event_seconds,
            algorithm = string_or(row.algorithm, "unknown"),
            strategy = string_or(row.strategy, "unknown"),
            R = maybe_float(row.radius),
            p = maybe_float(row.power),
            input_file = input_file,
            input_event_count = missing,
            measured_events = missing,
            nsamples = maybe_int(column_value(row, :n_samples)),
            repeats = missing,
            gcoff = missing,
            warmup_events = missing,
            julia_version = string_or(column_value(row, :backend_version), "unknown"),
            wall_time_seconds = missing,
            time_per_event_seconds = time_per_event_seconds,
            allocated_bytes_total = missing,
            allocated_bytes_per_event = missing,
            gc_fraction = missing,
        ))
    end
end

rows = NamedTuple{ROW_COLUMNS}[]

for filename in input_files
    if filename == output_file
        @warn "Skipping output file listed as input" filename
        continue
    end

    ext = lowercase(splitext(filename)[2])
    if ext == ".json"
        parse_json_file!(rows, filename)
    elseif ext == ".csv"
        parse_csv_file!(rows, filename)
    else
        error("Unsupported input extension for $(filename); expected .json or .csv")
    end
end

isempty(rows) && error("No successful input rows to merge")

df = DataFrame(rows)

workload_cols = [:code, :code_version, :backend, :backend_version, :algorithm, :strategy, :R, :p, :input_file, :gcoff, :schedule]
group_cols = vcat(workload_cols, [:threads])

grouped = combine(
    groupby(df, group_cols),
    :events_per_second => median_skipmissing => :events_per_second_median,
    :wall_time_seconds => median_skipmissing => :wall_time_seconds_median,
    :time_per_event_seconds => median_skipmissing => :time_per_event_seconds_median,
    :allocated_bytes_total => median_skipmissing => :allocated_bytes_total_median,
    :allocated_bytes_per_event => median_skipmissing => :allocated_bytes_per_event_median,
    :gc_fraction => median_skipmissing => :gc_fraction_median,
    :input_event_count => first_skipmissing => :input_event_count,
    :measured_events => first_skipmissing => :measured_events,
    :nsamples => first_skipmissing => :nsamples,
    :repeats => first_skipmissing => :repeats,
    :gcoff => first_skipmissing => :gcoff,
    :warmup_events => first_skipmissing => :warmup_events,
    :julia_version => first_skipmissing => :julia_version,
    :benchmark_command => first_skipmissing => :benchmark_command,
    :repo_commit => first_skipmissing => :repo_commit,
    :repo_short_commit => first_skipmissing => :repo_short_commit,
    :repo_branch => first_skipmissing => :repo_branch,
    :repo_dirty => first_skipmissing => :repo_dirty,
    :remote_origin => first_skipmissing => :remote_origin,
    :package_commit => first_skipmissing => :package_commit,
    :jetreconstruction_version => first_skipmissing => :jetreconstruction_version,
    :jetreconstruction_source => first_skipmissing => :jetreconstruction_source,
    :cpu_threads => first_skipmissing => :cpu_threads,
    :cpu_model => first_skipmissing => :cpu_model,
    :machine => first_skipmissing => :machine,
    :kernel => first_skipmissing => :kernel,
    :total_memory_bytes => first_skipmissing => :total_memory_bytes,
    :julia_project => first_skipmissing => :julia_project,
    :julia_num_gc_threads => first_skipmissing => :julia_num_gc_threads,
    :julia_exclusive => first_skipmissing => :julia_exclusive,
    nrow => :raw_rows,
)

baseline_rows = grouped[
    grouped.threads .== 1,
    vcat(workload_cols, [:events_per_second_median])
]

nrow(baseline_rows) == 0 && error("Cannot compute speedup: no 1-thread baseline rows found")

baseline = combine(
    groupby(baseline_rows, workload_cols),
    :events_per_second_median => median_skipmissing => :baseline_events_per_second_median,
)

grouped = leftjoin(grouped, baseline, on = workload_cols, matchmissing = :equal)

if any(ismissing, grouped.baseline_events_per_second_median)
    error("Cannot compute speedup: at least one workload has no 1-thread baseline")
end

grouped.speedup_median =
    grouped.events_per_second_median ./ grouped.baseline_events_per_second_median

grouped.efficiency_median =
    grouped.speedup_median ./ grouped.threads

sort!(grouped, vcat(workload_cols, [:threads]))

parent = dirname(output_file)
if !isempty(parent) && parent != "."
    mkpath(parent)
end

CSV.write(output_file, grouped)
