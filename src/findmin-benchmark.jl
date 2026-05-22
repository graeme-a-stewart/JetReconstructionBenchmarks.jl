#! /usr/bin/env julia
#
# Test various strategies for finding the minimum value in an
# array of random numbers.
#
# This is a proxy for the jet reconstruction problem, where we
# require each iteration to search for the lowest dij value.

using ArgParse
using Chairmarks
using Random
using LoopVectorization
using Statistics
using Printf
using SIMD
using Infiltrator

# Jet numerical types that we allow to be set on the CLI
const numtypes = Dict(
    "Float16" => Float16,
    "Float32" => Float32,
    "Float64" => Float64
)

function fast_findmin(dij::DenseVector{T}, n) where {T}
    best = 1
    @inbounds dij_min = dij[1]
    @turbo for here in 2:n
        dij_here = dij[here]
        newmin = dij_here < dij_min
        best = newmin ? here : best
        dij_min = newmin ? dij_here : dij_min
    end
    return dij_min, best
end

function basic_findmin(dij::DenseVector{T}, n) where {T}
    best = 1
    @inbounds dij_min = dij[1]
    @inbounds @simd for here in 2:n
        dij_here = dij[here]
        newmin = dij_here < dij_min
        best = ifelse(newmin, here, best)
        dij_min = ifelse(newmin, dij_here, dij_min)
    end
    return dij_min, best
end

function julia_findmin(dij::DenseVector{T}, n) where {T}
    return findmin(@view dij[1:n])
end

# function naive_findmin(dij::DenseVector{T}, n) where T
#     u = view(dij, 1:n)
#     x = @fastmath foldl(min, u)
#     i = findfirst(==(x), u)::Int
#     x, i
# end

function naive_findmin(dij::DenseVector{T}, n) where {T}
    x = @fastmath foldl(min, @view dij[1:n])
    i = findfirst(==(x), dij)::Int
    return x, i
end

function naive_findmin_reduce(dij::DenseVector{T}, n) where {T}
    x = @fastmath reduce(min, @view dij[1:n])
    i = findfirst(==(x), dij)::Int
    return x, i
end

function naive_findmin_minimum(dij::DenseVector{T}, n) where {T}
    x = @fastmath minimum(@view dij[1:n])
    i = findfirst(==(x), dij)::Int
    return x, i
end

function fast_findmin_simd(dij::DenseVector{T}, n) where {T}
    laneIndices = SIMD.Vec{8, Int}((1, 2, 3, 4, 5, 6, 7, 8))
    minvals = SIMD.Vec{8, T}(Inf)
    min_indices = SIMD.Vec{8, Int}(0)

    n_batches, remainder = divrem(n, 8)
    lane = VecRange{8}(0)
    i = 1
    @inbounds @fastmath for _ in 1:n_batches
        dijs = dij[lane + i]
        predicate = dijs < minvals
        minvals = vifelse(predicate, dijs, minvals)
        min_indices = vifelse(predicate, laneIndices, min_indices)

        i += 8
        laneIndices += 8
    end

    min_value = SIMD.minimum(minvals)
    # min_index = findfirst(==(min_value), minvals)::Int
    min_index = @inbounds min_value == minvals[1] ? min_indices[1] : min_value == minvals[2] ? min_indices[2] :
        min_value == minvals[3] ? min_indices[3] : min_value == minvals[4] ? min_indices[4] :
        min_value == minvals[5] ? min_indices[5] : min_value == minvals[6] ? min_indices[6] :
        min_value == minvals[7] ? min_indices[7] : min_indices[8]

    @inbounds @fastmath for _ in 1:remainder
        xi = dij[i]
        pred = dij[i] < min_value
        min_value = ifelse(pred, xi, min_value)
        min_index = ifelse(pred, i, min_index)
        i += 1
    end
    return min_value, min_index
end

function run_descent(v::DenseVector{N}, f::T; perturb = 0) where {N <: AbstractFloat, T}
    # Ensure we do something with the calculation to prevent the
    # compiler from optimizing everything away!
    sum = 0.0
    for n in length(v):-1:2
        val, index = f(v, n)
        sum += val
        # After we found the minimum, it should not be the minimum in the next
        # iteration
        v[index] += N(1.0)
        # If one wants to further perturb the array, do it like this, which is a
        # proxy for changing values as the algorithm progresses.
        for _ in 1:min(perturb, n)
            v[rand(1:n)] = rand(N)
        end
    end
    return sum
end

function report(f, v)
    bm = @be run_descent(v, f; perturb = 5)
    print("$(String(Symbol(f))) min: ", minimum(bm).time * 1.0e6, " μs; ")
    return println("mean: ", mean(bm).time * 1.0e6, " μs")
end

function parse_command_line(args)
    s = ArgParseSettings(autofix_names = true)
    @add_arg_table! s begin
        "-n", "--length"
        help = "Starting size of the array"
        arg_type = Int
        default = 450

        "--numtype"
        help = """Numerical type to use for the reconstruction. Supported values are 
            $(join(keys(numtypes), ", ")). The default is Float64"""

        "-f", "--functions"
        help = "Filter test functions (default it run all)"
        nargs = '*'

    end
    return parse_args(args, s; as_symbols = true)
end

function main(ARGS)
    args = parse_command_line(ARGS)

    # Were we passed a (valid) numerical type?
    Numtype = Float64
    if !isnothing(args[:numtype])
        if haskey(numtypes, args[:numtype])
            Numtype = numtypes[args[:numtype]]
        else
            @error "Numerical type argument $(args[:numtype]) is invalid"
            exit(1)
        end
    end

    # Setup the random array
    v = rand(Numtype, args[:length])

    # Run the benchmark
    println("Running the benchmark for an array of length $(length(v)) of $Numtype")

    for test_func in (fast_findmin, basic_findmin, julia_findmin, naive_findmin, naive_findmin_reduce, naive_findmin_minimum, fast_findmin_simd)
        if length(args[:functions]) == 0 || string(nameof(test_func)) in args[:functions]
            report(test_func, v)
        end
    end
end

main(ARGS)
