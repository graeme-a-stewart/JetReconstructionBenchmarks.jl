#! /usr/bin/env julia
"""
Run jet reconstruction over a standard set of input files, with
varying initial particle densities
"""

using ArgParse
using Logging
using JSON
using CSV
using DataFrames
using EnumX
using CodecZlib

using LorentzVectorHEP
using JetReconstruction

# Backends for the jet reconstruction
@enumx T=Backend Backends Julia FastJet
const AllBackends = [String(Symbol(x)) for x in instances(Backends.Backend)]

# Parsing for Enum types
function ArgParse.parse_item(opt::Type{E}, s::AbstractString) where {E <: Enum}
    insts = instances(E)
    p = findfirst(x -> Symbol(x) == Symbol(s), insts)
    if isnothing(p)
        throw(ErrorException("Invalid value for enum $opt: $s"))
    end
    return insts[p]
end

function hepmc3gunzip(input_file::AbstractString)
    unpacked_file = replace(input_file, ".gz" => "")
    if !isfile(unpacked_file)
        @info "Unpacking $(input_file) to $(unpacked_file)"
        in = GzipDecompressorStream(open(input_file))
        out = open(unpacked_file, "w")
        write(out, in)
        close(in)
        close(out)
    end
    unpacked_file
end

function julia_jet_process_avg_time(events::Vector{Vector{PseudoJet}};
                                    ptmin::Float64 = 5.0,
                                    distance::Float64 = 0.4,
                                    p::Union{Real, Nothing} = nothing,
                                    algorithm::JetAlgorithm.Algorithm = JetAlgorithm.AntiKt,
                                    strategy::RecoStrategy.Strategy,
                                    nsamples::Integer = 1,
                                    repeats::Int = 1)
    @info "Will process $(size(events)[1]) events"

    # Set consistent algorithm and power
    (p, algorithm) = JetReconstruction.get_algorithm_power_consistency(p = p,
                                                                       algorithm = algorithm)

    n_events = length(events)

    # Warmup code if we are doing a multi-sample timing run
    if nsamples > 1
        @info "Doing initial warm-up run"
        for event in events
            _ = inclusive_jets(jet_reconstruct(event, R = distance, p = p,
                                               strategy = strategy); ptmin = ptmin)
        end
    end

    # Threading?
    threads = Threads.nthreads()
    if threads > 1
        @info "Will use $threads threads"
    end

    # Now setup timers and run the loop
    cummulative_time = 0.0
    cummulative_time2 = 0.0
    lowest_time = typemax(Float64)
    finaljets = Vector{Vector{PseudoJet}}(undef, threads)
    fj = Vector{Vector{FinalJet}}(undef, threads)

    for irun in 1:nsamples
        t_start = time_ns()
        Threads.@threads for event_counter ∈ 1:n_events * repeats
            event_idx = mod1(event_counter, n_events)
            my_t = Threads.threadid()
            inclusive_jets(jet_reconstruct(events[event_idx], R = distance, p = p,
                                           strategy = strategy), ptmin = ptmin)
        end
        t_stop = time_ns()
        dt_μs = convert(Float64, t_stop - t_start) * 1.e-3
        if nsamples > 1
            @info "$(irun)/$(nsamples) $(dt_μs)"
        end
        cummulative_time += dt_μs
        cummulative_time2 += dt_μs^2
        lowest_time = dt_μs < lowest_time ? dt_μs : lowest_time
    end

    mean = cummulative_time / nsamples
    cummulative_time2 /= nsamples
    if nsamples > 1
        sigma = sqrt(nsamples / (nsamples - 1) * (cummulative_time2 - mean^2))
    else
        sigma = 0.0
    end
    mean /= n_events * repeats
    sigma /= n_events * repeats
    lowest_time /= n_events * repeats
    # Why also record the lowest time? 
    # 
    # The argument is that on a "busy" machine, the run time of an application is
    # always TrueRunTime+Overheads, where Overheads is a nuisance parameter that
    # adds jitter, depending on the other things the machine is doing. Therefore
    # the minimum value is (a) more stable and (b) reflects better the intrinsic
    # code performance.
    lowest_time
end

function fastjet_jet_process_avg_time(input_file::AbstractString;
                                      ptmin::Float64 = 5.0,
                                      distance::Float64 = 0.4,
                                      p::Union{Real, Nothing} = nothing,
                                      algorithm::JetAlgorithm.Algorithm = JetAlgorithm.AntiKt,
                                      strategy::RecoStrategy.Strategy,
                                      nsamples::Integer = 1)

    # FastJet reader cannot handle gzipped files
    if endswith(input_file, ".gz")
        input_file = hepmc3gunzip(input_file)
    end

    # Set consistent algorithm and power
    (p, algorithm) = JetReconstruction.get_algorithm_power_consistency(p = p,
                                                                       algorithm = algorithm)

    # @warn "FastJet timing not implemented yet"
    fj_bin = joinpath(@__DIR__, "..", "fastjet", "build", "fastjet-finder")
    fj_args = String[]
    push!(fj_args, "-p", string(p))
    push!(fj_args, "-s", string(strategy))
    push!(fj_args, "-R", string(distance))
    push!(fj_args, "--ptmin", string(ptmin))

    push!(fj_args, "-n", string(nsamples))
    @info "Fastjet command: $fj_bin $fj_args $input_file"
    fj_output = read(`$fj_bin $fj_args $input_file`, String)
    tryparse(Float64, match(r"Lowest time per event ([\d\.]+) us", fj_output)[1])
end

function parse_command_line(args)
    s = ArgParseSettings(autofix_names = true)
    @add_arg_table! s begin
        "--ptmin"
        help = "Minimum p_t for final jets (GeV)"
        arg_type = Float64
        default = 5.0

        "--distance", "-R"
        help = "Distance parameter for jet merging"
        arg_type = Float64
        default = 0.4

        "--algorithm", "-A"
        help = """Algorithm to use for jet reconstruction: $(join(JetReconstruction.AllJetRecoAlgorithms, ", "))"""
        arg_type = JetAlgorithm.Algorithm
        default = JetAlgorithm.AntiKt

        "--power", "-p"
        help = """Power value for jet reconstruction"""
        arg_type = Float64

        "--strategy", "-S"
        help = """Strategy for the algorithm, valid values: $(join(JetReconstruction.AllJetRecoStrategies, ", "))"""
        arg_type = RecoStrategy.Strategy
        default = RecoStrategy.Best

        "--nsamples", "-m"
        help = "Number of measurement points to acquire."
        arg_type = Int
        default = 16

        "--nsamples-override"
        help = "Override for sample number for specific event files"
        nargs = '+'

        "--repeats"
        help = "Run over whole event sample this number of times"
        arg_type = Int
        default = 1

        "--backend"
        help = """Backend to use for the jet reconstruction: $(join(AllBackends, ", "))"""
        arg_type = Backends.Backend
        default = Backends.Julia

        "--info"
        help = "Print info level log messages"
        action = :store_true

        "--debug"
        help = "Print debug level log messages"
        action = :store_true

        "--results"
        help = "Write results in CSV format to this directory/file. If a directory is given, a file named 'BACKEND-ALGORITHM-STRATEGY-RADIUS.csv' will be created."

        "files"
        help = "HepMC3 event files in to process or CSV file listing event files"
        required = true
        nargs = '+'
    end
    return parse_args(args, s; as_symbols = true)
end

function main()
    args = parse_command_line(ARGS)
    if args[:debug]
        logger = ConsoleLogger(stdout, Logging.Debug)
    elseif args[:info]
        logger = ConsoleLogger(stdout, Logging.Info)
    else
        logger = ConsoleLogger(stdout, Logging.Warn)
    end
    global_logger(logger)

    # If we have a CSV file, open it and read
    if endswith(args[:files][1], ".csv")
        if length(args[:files]) > 1
            println("When CSV input is given, only one file can be used")
            exit(1)
        end
        hepmc3_files_df = CSV.read(args[:files][1], DataFrame)
        input_file_path = dirname(args[:files][1])
        input_files = hepmc3_files_df[:, :File]
        input_files_full = map(fname -> joinpath(input_file_path, fname), input_files)
        hepmc3_files_df[:, :File_path] = input_files_full
    else
        # It's just a plain list of files
        input_files_full = args[:files]
        hepmc3_files_df = DataFrame("File_path" => input_files_full)
        hepmc3_files_df[:, :File] = map(basename, hepmc3_files_df[:, :File_path])
        hepmc3_files_df[:, :mean_particles] .= -1
    end

    event_timing = Float64[]
    n_samples = Int[]
    for event_file in hepmc3_files_df[:, :File_path]
        if event_file in args[:nsamples_override]
            samples = tryparse(Int, args[:nsamples_override][1])
            @info "Overriding samples for $(event_file) to $samples"
        else
            samples = args[:nsamples]
        end
        push!(n_samples, samples)

        if args[:backend] == Backends.Julia
            # Try to read events into the correct type!
            if JetReconstruction.is_ee(args[:algorithm])
                JetType = EEjet
            else
                JetType = PseudoJet
            end
            events::Vector{Vector{JetType}} = read_final_state_particles(event_file; T = JetType)
            time_per_event = julia_jet_process_avg_time(events, ptmin = args[:ptmin],
                                                        distance = args[:distance],
                                                        algorithm = args[:algorithm],
                                                        p = args[:power],
                                                        strategy = args[:strategy],
                                                        nsamples = samples, repeats = args[:repeats])
        elseif args[:backend] == Backends.FastJet
            time_per_event = fastjet_jet_process_avg_time(event_file, ptmin = args[:ptmin],
                                                          distance = args[:distance],
                                                          algorithm = args[:algorithm],
                                                          p = args[:power],
                                                          strategy = args[:strategy],
                                                          nsamples = samples)
        end

        push!(event_timing, time_per_event)
    end
    hepmc3_files_df[:, :n_samples] = n_samples
    hepmc3_files_df[:, :time_per_event] = event_timing
    println(hepmc3_files_df)

    # Write out the results
    if !isnothing(args[:results])
        if isdir(args[:results])
            results_file = joinpath(args[:results],
                                    "$(args[:backend])_$(args[:algorithm])_" *
                                    "$(args[:strategy])_R$(args[:distance])_P$(args[:power]).csv")
        else
            results_file = args[:results]
        end
        @info "Writing results to $(results_file)"
        CSV.write(results_file, hepmc3_files_df)
    end

    nothing
end

main()
