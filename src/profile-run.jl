#! /usr/bin/env julia
"""
Profile the same event-level jet-reconstruction workload for pp N2Tiled,
pp N2Plain, and electron-positron N2Plain algorithms.

The runner supports unprofiled control measurements plus Julia CPU, wall-time,
and allocation profiling. Warmup, compilation checks, and measurements all use
the same scheduler and event-processing function.
"""

using ArgParse
using Dates
using JSON
using Logging
using Pkg
using Profile
using Serialization
using SHA
using Statistics

using LorentzVectorHEP
using JetReconstruction

include("threading-utils.jl")
using .BenchmarkSchedulers: run_scheduled!, validate_julia_schedule

# Parsing for enum types used by ArgParse.
function ArgParse.parse_item(opt::Type{E}, value::AbstractString) where {E <: Enum}
    instances_of_enum = instances(E)
    parsed = findfirst(instance -> Symbol(instance) == Symbol(value), instances_of_enum)

    isnothing(parsed) && throw(ArgumentError("Invalid value for enum $opt: $value"))
    return instances_of_enum[parsed]
end

function validate_profile_mode(mode::AbstractString)
    resolved = Symbol(mode == "walltime" ? "wall" : mode)
    resolved in (:none, :cpu, :wall, :alloc) || throw(ArgumentError(
        "Invalid profile mode '$mode'. Valid values: none, cpu, wall, alloc",
    ))

    if resolved == :wall && VERSION < v"1.12"
        throw(ArgumentError("Wall-time profiling requires Julia 1.12 or later"))
    end

    return resolved
end

function validate_execution_mode(mode::AbstractString)
    resolved = Symbol(mode)
    resolved in (:owning, :workspace) || throw(ArgumentError(
        "Invalid execution mode '$mode'. Valid values: owning, workspace",
    ))
    return resolved
end

function require_positive(name::AbstractString, value::Real)
    value > 0 || throw(ArgumentError("$name must be positive, got $value"))
    return value
end

function ensure_output_parent(path::AbstractString)
    parent = dirname(abspath(path))
    mkpath(parent)
    return path
end

function write_json_result(path::AbstractString, result)
    ensure_output_parent(path)
    open(path, "w") do io
        JSON.print(io, result, 4)
        println(io)
    end
    return path
end

abstract type AbstractProfileContext end

struct OwningProfileContext <: AbstractProfileContext end

struct WorkspaceProfileContext{W, O, R, I} <: AbstractProfileContext
    workspace::W
    output::O
    reconstruct::R
    inclusive::I
end

function build_worker_contexts(make_context::F, nworkers::Int) where {F}
    first_context = make_context()
    contexts = Vector{typeof(first_context)}(undef, nworkers)
    contexts[1] = first_context
    for worker in 2:nworkers
        contexts[worker] = make_context()
    end
    return contexts
end

function require_jetreconstruction_api(name::Symbol)
    isdefined(JetReconstruction, name) || throw(ArgumentError(
        "--execution-mode workspace requires JetReconstruction.$name; " *
        "use a JetReconstruction version containing the reusable workspace API",
    ))
    return getfield(JetReconstruction, name)
end

function workspace_family(
    algorithm::JetAlgorithm.Algorithm,
    strategy::RecoStrategy.Strategy,
)
    if JetReconstruction.is_ee(algorithm)
        return :n2plain
    elseif strategy == RecoStrategy.N2Tiled
        return :n2tiled
    elseif strategy == RecoStrategy.N2Plain
        return :n2plain
    end

    throw(ArgumentError(
        "Workspace execution requires an explicit N2Plain or N2Tiled strategy " *
        "for pp algorithms",
    ))
end

function build_contexts(
    execution_mode::Symbol,
    algorithm::JetAlgorithm.Algorithm,
    strategy::RecoStrategy.Strategy,
    jet_type::Type,
)
    execution_mode == :owning && return (OwningProfileContext(),)

    family = workspace_family(algorithm, strategy)
    nworkers = Threads.nthreads()
    inclusive = require_jetreconstruction_api(:inclusive_jets!)

    if family == :n2tiled
        constructor = require_jetreconstruction_api(:N2TiledWorkspace)
        reconstruct = require_jetreconstruction_api(:with_n2tiled_reconstruction)
        return build_worker_contexts(nworkers) do
            WorkspaceProfileContext(
                constructor(),
                LorentzVector{Float64}[],
                reconstruct,
                inclusive,
            )
        end
    else
        constructor = require_jetreconstruction_api(:N2PlainWorkspace)
        reconstruct = require_jetreconstruction_api(:with_n2plain_reconstruction)
        return build_worker_contexts(nworkers) do
            WorkspaceProfileContext(
                constructor(jet_type),
                LorentzVector{Float64}[],
                reconstruct,
                inclusive,
            )
        end
    end
end

function process_event!(
    ::OwningProfileContext,
    event;
    ptmin,
    distance,
    p,
    algorithm,
    strategy,
)
    clusterseq = jet_reconstruct(
        event;
        algorithm = algorithm,
        R = distance,
        p = p,
        strategy = strategy,
        preprocess = nothing,
    )
    inclusive_jets(clusterseq; ptmin = ptmin)
    return nothing
end

function process_event!(
    context::WorkspaceProfileContext,
    event;
    ptmin,
    distance,
    p,
    algorithm,
    strategy,
)
    reconstruct = context.reconstruct
    inclusive = context.inclusive
    reconstruct(
        context.workspace,
        event;
        algorithm = algorithm,
        R = distance,
        p = p,
        preprocess = nothing,
    ) do clusterseq
        inclusive(context.output, clusterseq; ptmin = ptmin)
        return nothing
    end

    return nothing
end

context_for_worker(contexts::Tuple{C}, ::Int) where {C} = contexts[1]
context_for_worker(contexts::AbstractVector, worker::Int) = contexts[worker]

function run_reconstruction_batch!(
    contexts,
    events::AbstractVector{V};
    ptmin::Float64,
    distance::Float64,
    p::Real,
    algorithm::JetAlgorithm.Algorithm,
    strategy::RecoStrategy.Strategy,
    event_visits::Int,
    schedule::Symbol,
    chunk_size::Int,
) where {
    T <: JetReconstruction.FourMomentum,
    V <: AbstractVector{T},
}
    n_events = length(events)
    n_events > 0 || throw(ArgumentError("No input events were loaded"))
    event_visits > 0 || throw(ArgumentError("event_visits must be positive"))

    if length(contexts) > 1 && schedule != :chunked_atomic
        throw(ArgumentError(
            "Workspace execution requires --julia-scheduler chunked_atomic",
        ))
    end

    run_scheduled!(
        event_visits,
        schedule;
        chunk_size = chunk_size,
        nworkers = Threads.nthreads(),
    ) do event_counter, worker
        context = context_for_worker(contexts, worker)
        event_idx = mod1(event_counter, n_events)
        process_event!(
            context,
            events[event_idx];
            ptmin = ptmin,
            distance = distance,
            p = p,
            algorithm = algorithm,
            strategy = strategy,
        )
    end

    return nothing
end

function prewarm_contexts!(
    contexts,
    events;
    warmup_events,
    ptmin,
    distance,
    p,
    algorithm,
    strategy,
)
    events_to_visit = min(warmup_events, length(events))

    # Every reusable context must see the warmup set before measurement. This
    # avoids assigning cold workspace storage to workers that claimed no event
    # during a short parallel warmup.
    for context in contexts
        for event_idx in 1:events_to_visit
            process_event!(
                context,
                events[event_idx];
                ptmin = ptmin,
                distance = distance,
                p = p,
                algorithm = algorithm,
                strategy = strategy,
            )
        end
    end

    return nothing
end

function configure_profiler!(
    mode::Symbol;
    profile_delay::Float64,
    profile_buffer::Int,
)
    if mode == :cpu || mode == :wall
        Profile.clear()
        Profile.init(n = profile_buffer, delay = profile_delay)
    elseif mode == :alloc
        Profile.Allocs.clear()
    end
    return nothing
end

function prime_profiler!(f::F, ::Val{:none}, ::Float64) where {F}
    return nothing
end

function prime_profiler!(f::F, ::Val{:cpu}, ::Float64) where {F}
    Profile.@profile f()
    Profile.clear()
    return nothing
end

@static if VERSION >= v"1.12"
    function prime_profiler!(f::F, ::Val{:wall}, ::Float64) where {F}
        Profile.@profile_walltime f()
        Profile.clear()
        return nothing
    end
else
    function prime_profiler!(::F, ::Val{:wall}, ::Float64) where {F}
        throw(ArgumentError("Wall-time profiling requires Julia 1.12 or later"))
    end
end

function prime_profiler!(f::F, ::Val{:alloc}, sample_rate::Float64) where {F}
    Profile.Allocs.start(; sample_rate = sample_rate)
    try
        f()
    finally
        Profile.Allocs.stop()
    end
    Profile.Allocs.clear()
    return nothing
end

function measure_profiled(f::F, ::Val{:none}, ::Float64) where {F}
    return @timed f()
end

function measure_profiled(f::F, ::Val{:cpu}, ::Float64) where {F}
    return @timed Profile.@profile f()
end

@static if VERSION >= v"1.12"
    function measure_profiled(f::F, ::Val{:wall}, ::Float64) where {F}
        return @timed Profile.@profile_walltime f()
    end
else
    function measure_profiled(::F, ::Val{:wall}, ::Float64) where {F}
        throw(ArgumentError("Wall-time profiling requires Julia 1.12 or later"))
    end
end

function measure_profiled(f::F, ::Val{:alloc}, sample_rate::Float64) where {F}
    Profile.Allocs.start(; sample_rate = sample_rate)
    try
        return @timed f()
    finally
        Profile.Allocs.stop()
    end
end

function save_sampling_profile(output_prefix::AbstractString, mode::Symbol)
    ensure_output_parent(output_prefix)
    profile_data, line_info = Profile.retrieve()

    flat_path = output_prefix * "-flat.txt"
    tree_path = output_prefix * "-tree.txt"
    raw_path = output_prefix * "-profile.jls"
    metadata_path = output_prefix * "-profile-metadata.json"

    open(flat_path, "w") do io
        Profile.print(
            IOContext(io, :displaysize => (24, 500)),
            profile_data,
            line_info;
            format = :flat,
            C = true,
            sortedby = :overhead,
            mincount = 1,
        )
    end

    grouping = mode == :wall ? [:thread, :task] : :thread
    open(tree_path, "w") do io
        Profile.print(
            IOContext(io, :displaysize => (24, 500)),
            profile_data,
            line_info;
            format = :tree,
            C = true,
            groupby = grouping,
            noisefloor = 0.0,
            mincount = 1,
        )
    end

    serialize(raw_path, (profile_data, line_info))
    metadata = Dict(
        "profile_mode" => String(mode),
        "profile_data_entries" => length(profile_data),
        "profile_settings" => string(Profile.init()),
        "flat_report" => flat_path,
        "tree_report" => tree_path,
        "raw_profile" => raw_path,
    )
    write_json_result(metadata_path, metadata)

    return Dict(
        "flat_report" => flat_path,
        "tree_report" => tree_path,
        "raw_profile" => raw_path,
        "metadata" => metadata_path,
    )
end

function save_allocation_profile(output_prefix::AbstractString, sample_rate::Float64)
    ensure_output_parent(output_prefix)
    allocation_results = Profile.Allocs.fetch()
    allocations = allocation_results.allocs

    raw_path = output_prefix * "-alloc-profile.jls"
    text_path = output_prefix * "-alloc-report.txt"
    metadata_path = output_prefix * "-alloc-metadata.json"
    sampled_bytes = sum((Int(allocation.size) for allocation in allocations); init = 0)

    serialize(raw_path, allocation_results)
    open(text_path, "w") do io
        wide_io = IOContext(io, :displaysize => (24, 500))
        println(wide_io, "allocation_sample_rate = ", sample_rate)
        println(wide_io, "sampled_allocation_count = ", length(allocations))
        println(wide_io, "sampled_bytes = ", sampled_bytes)
        println(wide_io)
        if isempty(allocations)
            println(wide_io, "No allocation samples were collected.")
        else
            Profile.Allocs.print(wide_io, allocation_results; mincount = 1)
        end
    end

    metadata = Dict(
        "allocation_sample_rate" => sample_rate,
        "sampled_allocation_count" => length(allocations),
        "sampled_bytes" => sampled_bytes,
        "raw_profile" => raw_path,
        "text_report" => text_path,
    )
    write_json_result(metadata_path, metadata)

    return Dict(
        "raw_profile" => raw_path,
        "text_report" => text_path,
        "metadata" => metadata_path,
    )
end

function timed_field(timed, field::Symbol, default)
    return hasproperty(timed, field) ? getproperty(timed, field) : default
end

function summarize_samples(
    samples::Vector{Dict{String, Any}},
    reference_events_per_second::Union{Float64, Nothing},
)
    event_rates = Float64[sample["events_per_second"] for sample in samples]
    wall_times = Float64[sample["wall_time_seconds"] for sample in samples]
    event_counts = Int[sample["measured_events"] for sample in samples]
    bytes_per_event =
        Float64[sample["allocated_bytes_per_event"] for sample in samples]
    gc_per_event =
        Float64[sample["gc_time_seconds_per_event"] for sample in samples]

    total_events = sum(event_counts)
    total_wall_time = sum(wall_times)
    aggregate_rate = total_events / total_wall_time

    summary = Dict{String, Any}(
        "aggregate_events_per_second" => aggregate_rate,
        "total_measured_events" => total_events,
        "total_wall_time_seconds" => total_wall_time,
        "median_events_per_second" => median(event_rates),
        "mean_events_per_second" => mean(event_rates),
        "minimum_events_per_second" => minimum(event_rates),
        "maximum_events_per_second" => maximum(event_rates),
        "events_per_second_cv" =>
            length(event_rates) > 1 ? std(event_rates) / mean(event_rates) : 0.0,
        "median_allocated_bytes_per_event" => median(bytes_per_event),
        "median_gc_time_seconds_per_event" => median(gc_per_event),
    )

    if !isnothing(reference_events_per_second)
        summary["reference_events_per_second"] = reference_events_per_second
        summary["measurement_overhead_fraction"] =
            1.0 - aggregate_rate / reference_events_per_second
    end

    return summary
end

function try_readchomp(command::Cmd)
    try
        return readchomp(pipeline(command; stderr = devnull))
    catch
        return nothing
    end
end

function git_metadata(repo_root)
    if !(repo_root isa AbstractString && isdir(repo_root))
        return Dict("repo_root" => repo_root, "commit" => nothing, "is_dirty" => nothing)
    end

    status = try_readchomp(`git -C $repo_root status --porcelain`)
    return Dict(
        "repo_root" => try_readchomp(`git -C $repo_root rev-parse --show-toplevel`),
        "commit" => try_readchomp(`git -C $repo_root rev-parse HEAD`),
        "branch" => try_readchomp(`git -C $repo_root branch --show-current`),
        "is_dirty" => isnothing(status) ? nothing : !isempty(status),
        "remote_origin" => try_readchomp(`git -C $repo_root remote get-url origin`),
    )
end

function package_metadata(package_name::AbstractString)
    for (_, package_info) in Pkg.dependencies()
        package_info.name == package_name || continue
        return Dict(
            "name" => package_name,
            "version" => isnothing(package_info.version) ? nothing : string(package_info.version),
            "source" => package_info.source,
            "is_tracking_path" => package_info.is_tracking_path,
            "is_tracking_repo" => package_info.is_tracking_repo,
            "git" => git_metadata(package_info.source),
        )
    end
    return Dict("name" => package_name, "version" => nothing, "source" => nothing)
end

function parse_command_line(args)
    settings = ArgParseSettings(autofix_names = true)

    @add_arg_table! settings begin
        "--ptmin"
        help = "Minimum transverse momentum for inclusive jets (GeV)"
        arg_type = Float64
        default = 5.0

        "--distance", "-R"
        help = "Distance parameter passed to jet reconstruction"
        arg_type = Float64
        default = 0.4

        "--algorithm", "-A"
        help = "Algorithm: $(join(JetReconstruction.AllJetRecoAlgorithms, ", "))"
        arg_type = JetAlgorithm.Algorithm
        default = JetAlgorithm.AntiKt

        "--power", "-p"
        help = "Optional generalized-kt power"
        arg_type = Float64

        "--strategy", "-S"
        help = "Strategy: $(join(JetReconstruction.AllJetRecoStrategies, ", "))"
        arg_type = RecoStrategy.Strategy
        default = RecoStrategy.Best

        "--nsamples", "-m"
        help = "Number of measurements; profiled modes require one"
        arg_type = Int
        default = 5

        "--repeats"
        help = "Complete input passes per measurement"
        arg_type = Int
        default = 1

        "--warmup-events"
        help = "Events used to warm the exact execution path"
        arg_type = Int
        default = 10

        "--max-events"
        help = "Use only the first N events; zero means all"
        arg_type = Int
        default = 0

        "--gcoff"
        help = "Disable GC during each measured region"
        action = :store_true

        "--gc-log"
        help = "Log GC events during each measured region"
        action = :store_true

        "--julia-scheduler"
        help = "Scheduler: default, dynamic, static, greedy, chunked_atomic"
        arg_type = String
        default = "default"

        "--chunk-size"
        help = "Atomic chunk size for chunked_atomic scheduling (default: 8)"
        arg_type = Int
        default = 8

        "--execution-mode"
        help = "Reconstruction storage: owning or workspace"
        arg_type = String
        default = "owning"

        "--profile-mode"
        help = "Profiler: none, cpu, wall, or alloc"
        arg_type = String
        default = "none"

        "--profile-output"
        help = "Output prefix for profile artifacts"
        arg_type = String
        default = ""

        "--profile-delay"
        help = "CPU/wall sampling delay in seconds"
        arg_type = Float64
        default = 0.001

        "--profile-buffer"
        help = "Sampling-profile instruction-pointer capacity per thread"
        arg_type = Int
        default = 1_000_000

        "--allocation-sample-rate"
        help = "Allocation-profiler sample rate in (0, 1]"
        arg_type = Float64
        default = 0.001

        "--reference-events-per-second"
        help = "Matched control throughput used to estimate profiling overhead"
        arg_type = Float64

        "--info"
        help = "Print info-level messages"
        action = :store_true

        "--debug"
        help = "Print debug-level messages"
        action = :store_true

        "--output", "-o"
        help = "Optional JSON result file; otherwise write JSON to stdout"
        arg_type = String

        "file"
        help = "HepMC3 event file to process"
        required = true
    end

    return parse_args(args, settings; as_symbols = true)
end

function main()
    args = parse_command_line(ARGS)

    logger = if args[:debug]
        ConsoleLogger(stderr, Logging.Debug)
    elseif args[:info]
        ConsoleLogger(stderr, Logging.Info)
    else
        ConsoleLogger(stderr, Logging.Warn)
    end
    global_logger(logger)

    profile_mode = validate_profile_mode(args[:profile_mode])
    execution_mode = validate_execution_mode(args[:execution_mode])
    schedule = validate_julia_schedule(
        args[:julia_scheduler];
        allow_chunked_atomic = true,
    )

    require_positive("--nsamples", args[:nsamples])
    require_positive("--repeats", args[:repeats])
    require_positive("--warmup-events", args[:warmup_events])
    require_positive("--chunk-size", args[:chunk_size])
    require_positive("--profile-delay", args[:profile_delay])
    require_positive("--profile-buffer", args[:profile_buffer])

    0 < args[:allocation_sample_rate] <= 1 || throw(ArgumentError(
        "--allocation-sample-rate must be in (0, 1]",
    ))
    args[:max_events] >= 0 || throw(ArgumentError("--max-events cannot be negative"))

    if profile_mode != :none
        args[:nsamples] == 1 || throw(ArgumentError(
            "Use --nsamples 1 for cpu, wall, and alloc profiling",
        ))
        isempty(args[:profile_output]) && throw(ArgumentError(
            "--profile-output is required for profiled modes",
        ))
    end

    profile_mode == :alloc && args[:gcoff] && throw(ArgumentError(
        "Do not combine allocation profiling with --gcoff",
    ))
    args[:gc_log] && args[:gcoff] && throw(ArgumentError(
        "Do not combine --gc-log with --gcoff",
    ))
    execution_mode == :workspace && schedule != :chunked_atomic && throw(ArgumentError(
        "Workspace execution requires --julia-scheduler chunked_atomic",
    ))

    jet_type = JetReconstruction.is_ee(args[:algorithm]) ? EEJet : PseudoJet
    events = read_final_state_particles(args[:file], jet_type)
    if args[:max_events] > 0
        events = events[1:min(args[:max_events], length(events))]
    end
    isempty(events) && throw(ArgumentError("No input events were loaded"))

    resolved_p = JetReconstruction.get_algorithm_power(
        p = args[:power],
        algorithm = args[:algorithm],
    )
    contexts = build_contexts(
        execution_mode,
        args[:algorithm],
        args[:strategy],
        jet_type,
    )
    warmup_events = min(args[:warmup_events], length(events))

    @info "Profiling configuration" algorithm = args[:algorithm] strategy = args[:strategy] schedule execution_mode profile_mode threads = Threads.nthreads()

    prewarm_contexts!(
        contexts,
        events;
        warmup_events = warmup_events,
        ptmin = args[:ptmin],
        distance = args[:distance],
        p = resolved_p,
        algorithm = args[:algorithm],
        strategy = args[:strategy],
    )

    function run_region(event_visits)
        return run_reconstruction_batch!(
            contexts,
            events;
            ptmin = args[:ptmin],
            distance = args[:distance],
            p = resolved_p,
            algorithm = args[:algorithm],
            strategy = args[:strategy],
            event_visits = event_visits,
            schedule = schedule,
            chunk_size = args[:chunk_size],
        )
    end

    # Warm the selected scheduler as well as the reconstruction kernel.
    run_region(warmup_events)
    compile_probe = @timed run_region(warmup_events)
    compile_seconds = timed_field(compile_probe, :compile_time, 0.0)
    recompile_seconds = timed_field(compile_probe, :recompile_time, 0.0)
    if compile_seconds > 0.001 || recompile_seconds > 0.001
        @warn "Post-warmup compilation remains" compile_seconds recompile_seconds
    end

    measured_events = length(events) * args[:repeats]
    configure_profiler!(
        profile_mode;
        profile_delay = args[:profile_delay],
        profile_buffer = args[:profile_buffer],
    )
    prime_profiler!(
        () -> run_region(warmup_events),
        Val(profile_mode),
        args[:allocation_sample_rate],
    )

    samples = Dict{String, Any}[]
    for sample_index in 1:args[:nsamples]
        GC.gc()
        timed = try
            args[:gcoff] && GC.enable(false)
            args[:gc_log] && GC.enable_logging(true)

            measure_profiled(
                () -> run_region(measured_events),
                Val(profile_mode),
                args[:allocation_sample_rate],
            )
        finally
            args[:gc_log] && GC.enable_logging(false)
            if args[:gcoff]
                GC.enable(true)
                GC.gc()
            end
        end

        wall_time = timed.time
        push!(
            samples,
            Dict(
                "sample_index" => sample_index,
                "measured_events" => measured_events,
                "wall_time_seconds" => wall_time,
                "events_per_second" => measured_events / wall_time,
                "time_per_event_seconds" => wall_time / measured_events,
                "allocated_bytes_total" => timed.bytes,
                "allocated_bytes_per_event" => timed.bytes / measured_events,
                "gc_time_seconds" => timed.gctime,
                "gc_time_seconds_per_event" => timed.gctime / measured_events,
                "gc_fraction_of_wall" => wall_time == 0 ? 0.0 : timed.gctime / wall_time,
                "compile_time_seconds" => timed_field(timed, :compile_time, 0.0),
                "recompile_time_seconds" => timed_field(timed, :recompile_time, 0.0),
                "lock_conflicts" => timed_field(timed, :lock_conflicts, 0),
            ),
        )
    end

    profile_artifacts = if profile_mode == :cpu || profile_mode == :wall
        save_sampling_profile(args[:profile_output], profile_mode)
    elseif profile_mode == :alloc
        save_allocation_profile(args[:profile_output], args[:allocation_sample_rate])
    else
        Dict{String, Any}()
    end

    reference_rate = get(args, :reference_events_per_second, nothing)
    summary = summarize_samples(samples, reference_rate)
    result = Dict(
        "success" => true,
        "timestamp" => string(now()),
        "algorithm" => string(Symbol(args[:algorithm])),
        "strategy" => string(Symbol(args[:strategy])),
        "R" => args[:distance],
        "p" => resolved_p,
        "ptmin" => args[:ptmin],
        "execution_mode" => String(execution_mode),
        "workspace_family" => execution_mode == :workspace ? String(workspace_family(args[:algorithm], args[:strategy])) : nothing,
        "julia_scheduler" => String(schedule),
        "chunk_size" => schedule == :chunked_atomic ? args[:chunk_size] : nothing,
        "profile_mode" => String(profile_mode),
        "profile_output" => isempty(args[:profile_output]) ? nothing : args[:profile_output],
        "profile_delay_seconds" => args[:profile_delay],
        "profile_buffer_entries_per_thread" => args[:profile_buffer],
        "allocation_sample_rate" => args[:allocation_sample_rate],
        "gcoff" => args[:gcoff],
        "gc_logging" => args[:gc_log],
        "input_file" => abspath(args[:file]),
        "input_sha256" => bytes2hex(open(SHA.sha256, args[:file])),
        "input_event_count" => length(events),
        "measured_events_per_sample" => measured_events,
        "nsamples" => args[:nsamples],
        "repeats" => args[:repeats],
        "warmup_events" => warmup_events,
        "julia_version" => string(VERSION),
        "julia_threads" => Threads.nthreads(),
        "julia_gc_threads" => isdefined(Threads, :ngcthreads) ? Threads.ngcthreads() : nothing,
        "machine" => Sys.MACHINE,
        "cpu_threads" => Sys.CPU_THREADS,
        "process_id" => getpid(),
        "compile_probe" => Dict(
            "wall_time_seconds" => compile_probe.time,
            "compile_time_seconds" => compile_seconds,
            "recompile_time_seconds" => recompile_seconds,
        ),
        "samples" => samples,
        "summary" => summary,
        "profile_artifacts" => profile_artifacts,
        "benchmark_repository" => git_metadata(pwd()),
        "jetreconstruction" => package_metadata("JetReconstruction"),
    )

    output_path = get(args, :output, nothing)
    if isnothing(output_path) || isempty(output_path)
        JSON.print(stdout, result, 4)
        println()
    else
        write_json_result(output_path, result)
        println("Completed profiling run")
        println("Algorithm/strategy: ", result["algorithm"], "/", result["strategy"])
        println("Scheduler: ", result["julia_scheduler"])
        println("Profile mode: ", result["profile_mode"])
        println("Median events/s: ", result["summary"]["median_events_per_second"])
        println("JSON result: ", output_path)
    end

    return nothing
end

main()
