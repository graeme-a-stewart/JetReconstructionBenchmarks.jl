using JSON
using DataFrames
using CSV
using Statistics

if length(ARGS) < 2
    error("Usage: julia merge-thread-scan.jl input1.json [input2.json ...] output.csv")
end

input_files = ARGS[1:end-1]
output_file = ARGS[end]

rows=[]

get_nested(data, keys...; default = missing) = foldl(
    (value, key) -> value isa AbstractDict && haskey(value, key) ? value[key] : default,
    keys;
    init = data,
)

maybe_string(value) = ismissing(value) || isnothing(value) ? missing : String(value)
maybe_float(value) = ismissing(value) || isnothing(value) ? missing : Float64(value)
maybe_int(value) = ismissing(value) || isnothing(value) ? missing : Int(value)

for filename in input_files
    data = JSON.parsefile(filename)
    if !data["success"]
        @warn "Skipping file $filename due to unsuccessful run"
        continue
    end

    threads = Int(data["julia_threads"])
    events_per_second = Float64(data["summary"]["events_per_second_median"])
    algorithm = String(data["algorithm"])
    strategy = String(data["strategy"])
    R = Float64(data["R"])
    p = Float64(data["p"])
    input_file = String(data["input_file"])
    input_event_count = Int(data["input_event_count"])
    measured_events = Int(data["measured_events"])
    nsamples = Int(data["nsamples"])
    repeats = Int(data["repeats"])
    warmup_events = Int(data["warmup_events"])
    julia_version = String(data["julia_version"])
    wall_time_seconds = Float64(data["summary"]["wall_time_seconds_median"])
    time_per_event_seconds = wall_time_seconds / measured_events
    allocated_bytes_total = Float64(data["summary"]["allocated_bytes_total_median"])
    allocated_bytes_per_event = allocated_bytes_total / measured_events
    gc_fraction = Float64(data["summary"]["gc_fraction_median"])
    benchmark_command = maybe_string(get(data, "benchmark_command", missing))
    repo_commit = maybe_string(get_nested(data, "git", "commit"))
    repo_short_commit = maybe_string(get_nested(data, "git", "short_commit"))
    repo_branch = maybe_string(get_nested(data, "git", "branch"))
    repo_dirty = get_nested(data, "git", "is_dirty")
    remote_origin = maybe_string(get_nested(data, "git", "remote_origin"))
    package_commit = maybe_string(get(data, "package_commit", missing))
    jetreconstruction_version = maybe_string(get_nested(data, "packages", "JetReconstruction", "version"))
    jetreconstruction_source = maybe_string(get_nested(data, "packages", "JetReconstruction", "source"))
    cpu_threads = maybe_int(get_nested(data, "hardware", "cpu_threads"))
    cpu_model = maybe_string(get_nested(data, "hardware", "cpu_model"))
    machine = maybe_string(get_nested(data, "hardware", "machine"))
    kernel = maybe_string(get_nested(data, "hardware", "kernel"))
    total_memory_bytes = maybe_int(get_nested(data, "hardware", "total_memory_bytes"))
    julia_project = maybe_string(get_nested(data, "runtime", "julia_project"))
    julia_num_gc_threads = maybe_string(get_nested(data, "runtime", "environment", "JULIA_NUM_GC_THREADS"))
    julia_exclusive = maybe_string(get_nested(data, "runtime", "environment", "JULIA_EXCLUSIVE"))

    push!(rows, (threads=threads, events_per_second=events_per_second, algorithm=algorithm, strategy=strategy, 
    R=R, p=p, input_file=input_file, input_event_count=input_event_count, 
    measured_events=measured_events, nsamples=nsamples, repeats=repeats, 
    warmup_events=warmup_events, julia_version=julia_version,
    wall_time_seconds=wall_time_seconds, time_per_event_seconds=time_per_event_seconds,
    allocated_bytes_total=allocated_bytes_total, allocated_bytes_per_event=allocated_bytes_per_event,
    gc_fraction=gc_fraction, benchmark_command=benchmark_command,
    repo_commit=repo_commit, repo_short_commit=repo_short_commit, repo_branch=repo_branch,
    repo_dirty=repo_dirty, remote_origin=remote_origin,
    package_commit=package_commit, jetreconstruction_version=jetreconstruction_version,
    jetreconstruction_source=jetreconstruction_source,
    cpu_threads=cpu_threads, cpu_model=cpu_model, machine=machine, kernel=kernel,
    total_memory_bytes=total_memory_bytes, julia_project=julia_project,
    julia_num_gc_threads=julia_num_gc_threads, julia_exclusive=julia_exclusive))
end

df = DataFrame(rows)

workload_cols = [:algorithm, :strategy, :R, :p, :input_file]
grouped = combine(
    groupby(df, vcat(workload_cols, [:threads])),
    :events_per_second => median => :events_per_second_median,
    :wall_time_seconds => median => :wall_time_seconds_median,
    :time_per_event_seconds => median => :time_per_event_seconds_median,
    :allocated_bytes_total => median => :allocated_bytes_total_median,
    :allocated_bytes_per_event => median => :allocated_bytes_per_event_median,
    :gc_fraction => median => :gc_fraction_median,
    :input_event_count => first => :input_event_count,
    :measured_events => first => :measured_events,
    :nsamples => first => :nsamples,
    :repeats => first => :repeats,
    :warmup_events => first => :warmup_events,
    :julia_version => first => :julia_version,
    :benchmark_command => first => :benchmark_command,
    :repo_commit => first => :repo_commit,
    :repo_short_commit => first => :repo_short_commit,
    :repo_branch => first => :repo_branch,
    :repo_dirty => first => :repo_dirty,
    :remote_origin => first => :remote_origin,
    :package_commit => first => :package_commit,
    :jetreconstruction_version => first => :jetreconstruction_version,
    :jetreconstruction_source => first => :jetreconstruction_source,
    :cpu_threads => first => :cpu_threads,
    :cpu_model => first => :cpu_model,
    :machine => first => :machine,
    :kernel => first => :kernel,
    :total_memory_bytes => first => :total_memory_bytes,
    :julia_project => first => :julia_project,
    :julia_num_gc_threads => first => :julia_num_gc_threads,
    :julia_exclusive => first => :julia_exclusive,
)

baseline = grouped[
    grouped.threads .== 1,
    vcat(workload_cols, [:events_per_second_median])
]

rename!(
    baseline,
    :events_per_second_median => :baseline_events_per_second_median
)

grouped = leftjoin(grouped, baseline, on = workload_cols)

if any(ismissing, grouped.baseline_events_per_second_median)
    error("Cannot compute speedup: at least one workload has no 1-thread baseline")
end

grouped.speedup_median =
    grouped.events_per_second_median ./ grouped.baseline_events_per_second_median

grouped.efficiency_median =
    grouped.speedup_median ./ grouped.threads

sort!(grouped, vcat(workload_cols, [:threads]))

CSV.write(output_file, grouped)
