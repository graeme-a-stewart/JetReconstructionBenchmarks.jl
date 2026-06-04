# Thread Scaling Benchmarks

This document describes the thread-scaling workflow for
`JetReconstruction.jl` event-level benchmarks. It is intended to be run from
the root of this repository.

The workflow is:

```text
src/thread-run.jl
    one benchmark run for one workload and one Julia thread count

src/thread-scan-json.sh
    a small driver that runs thread-run.jl for several thread counts

src/merge-thread-scan.jl
    merge the JSON files and compute speedup and parallel efficiency

src/plot-thread-scan.jl
    plot speedup, efficiency, or throughput from the merged CSV
```

For most use cases, use the JSON workflow:

```text
thread-scan-json.sh -> JSON files -> merge-thread-scan.jl -> summary CSV -> plot-thread-scan.jl
```

The older `src/thread-scan.sh` script is kept as a simple CSV smoke test, but it
does not record the same metadata and is not recommended for systematic runs.

## Setup

Clone the repository, then work from the repository root:

```sh
git clone https://github.com/graeme-a-stewart/JetReconstructionBenchmarks.jl.git
cd JetReconstructionBenchmarks.jl
```

Instantiate the Julia project:

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

Check that the dependencies used by this workflow load:

```sh
julia --project=. -e 'using ArgParse, CSV, DataFrames, JSON, Plots, Statistics, JetReconstruction; println("OK")'
```

The workflow uses packages already listed in `Project.toml`, notably
`ArgParse`, `CSV`, `DataFrames`, `JSON`, `Plots`, `Statistics`, and
`JetReconstruction`.

The examples below use `jq` to inspect JSON files. `jq` is optional; it is not
required by the Julia scripts.

## Input Files

The repository contains compressed HepMC3 input files under `data/`. Useful
starting points are:

```text
data/events-pp-0.5TeV-5GeV.hepmc3.gz     small pp input
data/events-pp-8TeV-20GeV.hepmc3.gz      medium pp input
data/events-pp-30TeV-50GeV.hepmc3.gz     high pp input
data/events-ee-Z.hepmc3.gz               e+e- input
```

For pp studies, common first workloads are:

```text
AntiKt  N2Plain
AntiKt  N2Tiled
CA      N2Plain
CA      N2Tiled
Kt      N2Plain
Kt      N2Tiled
```

For e+e- studies, start with:

```text
Durham  N2Plain
```

Use a thread list that includes one thread:

```text
1 2 4 8
```

The one-thread result is required for speedup and efficiency.

## Single Run

`src/thread-run.jl` runs one workload with the Julia thread count selected by
`julia --threads`.

Example:

```sh
julia --threads=1 --project=. src/thread-run.jl \
  -A AntiKt \
  -S N2Plain \
  -R 0.4 \
  --repeats 1 \
  --nsamples 5 \
  --warmup-events 10 \
  --output results/thread-scaling/example/AntiKt-N2Plain-small-t1.json \
  data/events-pp-0.5TeV-5GeV.hepmc3.gz
```

The JSON output contains:

- run parameters: algorithm, strategy, radius, input file, repeats, samples
- timing fields: wall time, events/s, time per event
- allocation and GC fields
- raw per-sample measurements under `samples`
- summary statistics under `summary`
- reproducibility metadata: Julia version, hardware, Git commit, package source

The top-level timing values use the fastest sample, following the historical
benchmark convention. For scaling plots and merged summaries, use the median
fields in `summary`; `merge-thread-scan.jl` does this automatically.

If `jq` is available, inspect a result with:

```sh
jq '{success, algorithm, strategy, julia_threads, measured_events, summary}' \
  results/thread-scaling/example/AntiKt-N2Plain-small-t1.json
```

## Thread Sweep

Use `src/thread-scan-json.sh` to run the same workload for several thread
counts. It writes one JSON file per thread count.

Usage:

```sh
./src/thread-scan-json.sh OUTDIR ALGORITHM STRATEGY INPUT_FILE LABEL THREADS NSAMPLES REPEATS WARMUP_EVENTS RADIUS
```

Arguments:

```text
OUTDIR          output directory for JSON files
ALGORITHM       AntiKt, CA, Kt, Durham, ...
STRATEGY        N2Plain or N2Tiled
INPUT_FILE      HepMC3 input file
LABEL           short label used in filenames, e.g. small, medium, high
THREADS         quoted list of thread counts, e.g. "1 2 4 8"
NSAMPLES        timed samples per thread count
REPEATS         number of full event-sample repeats per timed sample
WARMUP_EVENTS   number of events processed before timing starts
RADIUS          radius parameter, typically 0.4 for pp workloads
```

Example:

```sh
./src/thread-scan-json.sh \
  results/thread-scaling/small/AntiKt-N2Plain \
  AntiKt \
  N2Plain \
  data/events-pp-0.5TeV-5GeV.hepmc3.gz \
  small \
  "1 2 4 8" \
  5 \
  1 \
  10 \
  0.4
```

Expected files:

```text
results/thread-scaling/small/AntiKt-N2Plain/AntiKt-N2Plain-small-t1.json
results/thread-scaling/small/AntiKt-N2Plain/AntiKt-N2Plain-small-t2.json
results/thread-scaling/small/AntiKt-N2Plain/AntiKt-N2Plain-small-t4.json
results/thread-scaling/small/AntiKt-N2Plain/AntiKt-N2Plain-small-t8.json
```

Check the run:

```sh
jq -r '[input_filename, .success, .algorithm, .strategy, .julia_threads, .summary.events_per_second_median] | @tsv' \
  results/thread-scaling/small/AntiKt-N2Plain/*.json
```

Every row should have `success` equal to `true`.

## Example Workload Matrix

The commands below run a small pp strategy comparison:

```sh
mkdir -p results/thread-scaling/small

./src/thread-scan-json.sh results/thread-scaling/small/AntiKt-N2Plain AntiKt N2Plain data/events-pp-0.5TeV-5GeV.hepmc3.gz small "1 2 4 8" 5 1 10 0.4
./src/thread-scan-json.sh results/thread-scaling/small/AntiKt-N2Tiled AntiKt N2Tiled data/events-pp-0.5TeV-5GeV.hepmc3.gz small "1 2 4 8" 5 1 10 0.4
./src/thread-scan-json.sh results/thread-scaling/small/CA-N2Plain CA N2Plain data/events-pp-0.5TeV-5GeV.hepmc3.gz small "1 2 4 8" 5 1 10 0.4
./src/thread-scan-json.sh results/thread-scaling/small/CA-N2Tiled CA N2Tiled data/events-pp-0.5TeV-5GeV.hepmc3.gz small "1 2 4 8" 5 1 10 0.4
./src/thread-scan-json.sh results/thread-scaling/small/Kt-N2Plain Kt N2Plain data/events-pp-0.5TeV-5GeV.hepmc3.gz small "1 2 4 8" 5 1 10 0.4
./src/thread-scan-json.sh results/thread-scaling/small/Kt-N2Tiled Kt N2Tiled data/events-pp-0.5TeV-5GeV.hepmc3.gz small "1 2 4 8" 5 1 10 0.4
```

For medium or high multiplicity, use the same commands with a different input
file and label:

```text
medium: data/events-pp-8TeV-20GeV.hepmc3.gz
high:   data/events-pp-30TeV-50GeV.hepmc3.gz
```

For a Durham e+e- scan:

```sh
./src/thread-scan-json.sh \
  results/thread-scaling/ee/Durham-N2Plain \
  Durham \
  N2Plain \
  data/events-ee-Z.hepmc3.gz \
  eeZ \
  "1 2 4 8" \
  5 \
  1 \
  10 \
  0.4
```

## Merge Results

After a scan, merge the JSON files into a summary CSV:

```sh
julia --project=. src/merge-thread-scan.jl \
  results/thread-scaling/small/*/*.json \
  results/thread-scaling/small/summary.csv
```

The output contains one row for each workload and thread count.

Important columns:

```text
algorithm
strategy
R
p
input_file
threads
events_per_second_median
baseline_events_per_second_median
speedup_median
efficiency_median
```

Definitions:

```text
events_per_second_median
    Median throughput for the workload at this thread count.

baseline_events_per_second_median
    Median throughput for the same workload at one thread.

speedup_median
    events_per_second_median / baseline_events_per_second_median

efficiency_median
    speedup_median / threads
```

Check the summary:

```sh
head -n 10 results/thread-scaling/small/summary.csv
```

If merging fails with:

```text
Cannot compute speedup: at least one workload has no 1-thread baseline
```

then at least one workload is missing a `threads=1` JSON file. Rerun that
workload with a thread list that includes `1`, then merge again.

## Plot Results

`src/plot-thread-scan.jl` plots the merged CSV.

Supported metrics:

```text
efficiency
speedup
throughput
```

Efficiency plot:

```sh
julia --project=. src/plot-thread-scan.jl \
  results/thread-scaling/small/summary.csv \
  results/thread-scaling/small/plots \
  --metric efficiency \
  --title "Small pp input"
```

Speedup plot:

```sh
julia --project=. src/plot-thread-scan.jl \
  results/thread-scaling/small/summary.csv \
  results/thread-scaling/small/speedup.png \
  --metric speedup \
  --title "Small pp input"
```

Throughput plot:

```sh
julia --project=. src/plot-thread-scan.jl \
  results/thread-scaling/small/summary.csv \
  results/thread-scaling/small/throughput.png \
  --metric throughput \
  --title "Small pp input" \
  --no-ideal
```

By default, the plotter creates one plot per `input_file` and one line per
`algorithm,strategy,R,p` combination:

```text
--split-by input_file
--group-by algorithm,strategy,R,p
```

This keeps different multiplicities or event samples from being mixed into one
figure by accident.

To put everything in a single plot:

```sh
julia --project=. src/plot-thread-scan.jl \
  results/thread-scaling/small/summary.csv \
  results/thread-scaling/small/combined-throughput.png \
  --metric throughput \
  --split-by none \
  --group-by algorithm,strategy,input_file \
  --title "Small pp input" \
  --no-ideal
```

## Quick End-to-End Example

This is the shortest complete workflow:

```sh
mkdir -p results/thread-scaling/example

./src/thread-scan-json.sh \
  results/thread-scaling/example/AntiKt-N2Plain \
  AntiKt \
  N2Plain \
  data/events-pp-0.5TeV-5GeV.hepmc3.gz \
  small \
  "1 2 4 8" \
  5 \
  1 \
  10 \
  0.4

julia --project=. src/merge-thread-scan.jl \
  results/thread-scaling/example/*/*.json \
  results/thread-scaling/example/summary.csv

julia --project=. src/plot-thread-scan.jl \
  results/thread-scaling/example/summary.csv \
  results/thread-scaling/example/plots \
  --metric efficiency \
  --title "Small pp input"
```

Check the outputs:

```sh
head -n 10 results/thread-scaling/example/summary.csv
ls -lh results/thread-scaling/example/plots
```

## Choosing `nsamples` and `repeats`

`nsamples` controls how many timed measurements are taken for each thread count.

Suggested values:

```text
5       quick smoke test
16      reasonable local benchmark
32+     more stable production benchmark
```

`repeats` controls how many times the full input event sample is processed
inside each timed measurement. For very fast workloads, increasing `repeats`
can reduce noise:

```text
1       quick run
4       more stable for small inputs
8+      useful if individual samples are very short
```

The cost is runtime: larger `nsamples` and larger `repeats` both make the scan
take longer.

## Interpreting Scaling Results

Speedup is:

```text
throughput_at_N_threads / throughput_at_1_thread
```

Efficiency is:

```text
speedup / N_threads
```

Interpretation:

```text
efficiency near 1.0     close to ideal scaling
efficiency below 1.0    sublinear scaling
efficiency above 1.0    possible on noisy short runs; rerun with more samples
```

Small inputs are often noisy because each timed sample is short. For more stable
numbers, use more samples, more repeats, or a higher-multiplicity input.

## Practical Checks

Check JSON success:

```sh
jq -r '[input_filename, .success, .algorithm, .strategy, .julia_threads] | @tsv' \
  results/thread-scaling/example/*/*.json
```

Check available thread counts:

```sh
jq -r '.julia_threads' results/thread-scaling/example/*/*.json | sort -n | uniq -c
```

Check summary columns:

```sh
head -n 1 results/thread-scaling/example/summary.csv
```

Check plot files:

```sh
ls -lh results/thread-scaling/example/plots
```

## Common Pitfalls

### Missing one-thread result

Speedup and efficiency require a one-thread baseline for each workload. Always
include `1` in the thread list.

### Mixing path spellings

`merge-thread-scan.jl` groups workloads by the exact `input_file` string stored
in the JSON. Use the same input path spelling for every thread count of the same
workload. The `src/thread-scan-json.sh` driver helps by normalising existing
input files before it calls `thread-run.jl`.

### Overwriting JSON files

The JSON filename is based on:

```text
ALGORITHM-STRATEGY-LABEL-tTHREADS.json
```

Running the same scan into the same directory overwrites previous files. Use a
new output directory for a new benchmark campaign.

### Comparing unlike workloads

Speedup is only meaningful within the same workload: same algorithm, strategy,
radius, power, and input file. `merge-thread-scan.jl` computes baselines using
these columns, so keep them consistent across thread counts.
