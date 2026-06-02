#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -d "$script_dir/JetReconstructionBenchmarks.jl" ]; then
  benchmark_dir="$script_dir/JetReconstructionBenchmarks.jl"
else
  benchmark_dir=$(pwd)
fi

outdir=${1:?output directory required}
algorithm=${2:-AntiKt}
strategy=${3:-N2Plain}
input_file=${4:-data/events-pp-0.5TeV-5GeV.hepmc3.gz}
label=${5:-small}
threads_list=${6:-"1 2 4 8"}
nsamples=${7:-5}
repeats=${8:-1}
warmup_events=${9:-10}
radius=${10:-0.4}

mkdir -p "$outdir"
outdir=$(CDPATH= cd -- "$outdir" && pwd)

if [ -f "$input_file" ]; then
  input_dir=$(CDPATH= cd -- "$(dirname -- "$input_file")" && pwd)
  input_file="$input_dir/$(basename -- "$input_file")"
fi

cd "$benchmark_dir"

for threads in $threads_list; do
  julia --threads=$threads --project=. src/thread-run.jl \
    -A "$algorithm" \
    -S "$strategy" \
    -R "$radius" \
    --repeats "$repeats" \
    --nsamples "$nsamples" \
    --warmup-events "$warmup_events" \
    --output "$outdir/${algorithm}-${strategy}-${label}-t${threads}.json" \
    "$input_file"
done
