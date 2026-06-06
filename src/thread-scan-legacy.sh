#! /bin/sh
#
# Benchmark on different thread numbers

# Abort on error
set -e

max_threads=${1:-"10"}

echo "threads,time_per_event,event_rate"
threads=1
while [ $threads -le $max_threads ]; do
    # julia --threads=$threads --project src/thread-run.jl -A Durham --repeats 4 --nsamples 100 data/events-ee-H.hepmc3.gz
    julia --threads=$threads --project src/thread-run.jl -A AntiKt -S N2Tiled -R 0.4 --repeats 4 --nsamples 32 data/events-pp-13TeV-20GeV.hepmc3.gz
    threads=$(($threads+1))
done
