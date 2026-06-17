# FastJet Test Applications

This code compiles a few small FastJet applications that are used for
benchmarking and validation of alternative implementations of clustering
algorithms.

The code requires the fastjet libraries (<https://fastjet.fr/>) as well as those
from HepMC3 (<https://gitlab.cern.ch/hepmc/HepMC3>).

Depending on your system setup you make need to add the path to the HepMC3 and
Fastjet CMake setup files to `CMAKE_PREFIX_PATH`. It may also be necessary to
set `siscone_DIR`.

## Compilation

Configure and compile the serial executable using CMake in the standard way,
e.g.,

```sh
cmake -S . -B build
cmake --build build
```

Build with OpenMP support explicitly when running multi-threaded benchmarks:

```sh
cmake -S . -B build -DFASTJET_ENABLE_OPENMP=ON
cmake --build build
```

When `FASTJET_ENABLE_OPENMP` is enabled, CMake requires OpenMP and the build
fails if it cannot be found. On macOS with Apple clang, install Homebrew
`libomp`; the CMake setup will try to use it automatically.

```sh
brew install libomp
```

Use the serial build for serial baseline timings. An OpenMP build run with
`--threads 1` measures the single-thread OpenMP path, including any OpenMP
runtime overhead.

## Applications

### `fastjet-finder`

`fastjet-finder` is the main application and will run fastjet with the standard
suite of pp algorithms, optionally outputting a list of inclusive or exclusive
jets. This is the standard executable used to benchmark fastjet.

```sh
./fastjet-finder [options] HEPMC3_INPUT_FILE

Allowed options:
  -h, --help                  produce help message
  -n, --maxevents arg (=-1)   Maximum events in file to process (-1 = all events)
  --skipevents arg (=0)       Number of events to skip over
  -m, --nsamples arg (=1)     Number of repeated trials
  -s, --strategy arg (=Best)  Valid values are 'Best' (default), 'N2Plain', 'N2Tiled'
  -A, --algorithm arg         Valid values are 'AntiKt' 'CA' 'Kt' 'GenKt' 'EEKt' 'Durham'
  -p, --power arg             Algorithm p value, only needed for 'GenKt' and 'EEKt'
  -R, --radius arg (=0.4)     Algorithm R parameter
  --ptmin arg                 pt cut for inclusive jets
  --dijmax arg                dijmax value for exclusive jets
  --njets arg                 njets value for exclusive jets
  -d, --dump arg              Filename to dump jets to
  -c, --debug-clusterseq      Dump cluster sequence history content
  -t, --threads arg (=1)      Number of OpenMP threads to use
  --schedule arg (=static)    OpenMP schedule: static, dynamic, or guided

Note that only one of ptmin, dijmax or njets can be specified!
```

Example timing run:

```sh
./build/fastjet-finder \
  -A AntiKt \
  -p -1 \
  -s N2Plain \
  -R 0.4 \
  --ptmin 5.0 \
  -m 10 \
  -t 4 \
  --schedule dynamic \
  ../data/events-pp-0.5TeV-5GeV.hepmc3
```

`src/benchmark.jl` is the usual wrapper for writing CSV benchmark results. It
passes `--worker-threads` as `--threads`, and passes `--schedule`, to
`fastjet-finder` when `--code Fastjet` is selected. It also decompresses `.gz`
input files before calling this executable. See `../THREAD.md` for the complete
Julia-vs-FastJet thread-scaling workflow.

### `fastjet2json.jl`

`fastjet2json.jl` script converts the text output from the fastjet applications
into a JSON format, more suitable for integration tests.

```sh
julia --project src/fastjet2json.jl fastjet_input_file json_output_file
```
