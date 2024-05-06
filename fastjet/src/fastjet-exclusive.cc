// fastejet-finder.cc
// MIT Licenced, Copyright (c) 2023-2024 CERN
//
// Code to run and time the jet finding of against various
// HepMC3 input files

// Original version of this code Philippe Gras, IRFU
// Modified by Graeme A Stewart, CERN

#include <iostream> // needed for io
#include <cstdio>   // needed for io
#include <string>
#include <vector>
#include <chrono>

#include <unistd.h>
#include <stdlib.h>

// Program Options Parser Library (https://github.com/badaix/popl)
#include "popl.hpp"

#include "fastjet/ClusterSequence.hh"
#include "fastjet/PseudoJet.hh"

#include "HepMC3/GenEvent.h"
#include "HepMC3/GenParticle.h"
#include "HepMC3/ReaderAscii.h"

#include "fastjet-utils.hh"

using namespace std;
using namespace popl;
using Time = std::chrono::high_resolution_clock;
using us = std::chrono::microseconds;

fastjet::ClusterSequence run_fastjet_clustering(std::vector<fastjet::PseudoJet> input_particles,
  fastjet::Strategy strategy, fastjet::JetAlgorithm algorithm, double R) {

  fastjet::RecombinationScheme recomb_scheme=fastjet::E_scheme;
  fastjet::JetDefinition jet_def(algorithm, R, recomb_scheme, strategy);

  // run the jet clustering with the above jet definition
  fastjet::ClusterSequence clust_seq(input_particles, jet_def);

  return clust_seq;
}

int main(int argc, char* argv[]) {
  // Default values
  int maxevents = -1;
  int trials = 8;
  string mystrategy = "Best";
  int power = -1;
  double R = 0.4;
  double ptmin = 0.5;
  int njets = -1;
  double dmin = 0.0;
  string dump_file = "";

  OptionParser opts("Allowed options");
  auto help_option = opts.add<Switch>("h", "help", "produce help message");
  auto max_events_option = opts.add<Value<int>>("m", "maxevents", "Maximum events in file to process (-1 = all events)", maxevents, &maxevents);
  auto trials_option = opts.add<Value<int>>("n", "trials", "Number of repeated trials", trials, &trials);
  auto strategy_option = opts.add<Value<string>>("s", "strategy", "Valid values are 'Best' (default), 'N2Plain', 'N2Tiled'", mystrategy, &mystrategy);
  auto power_option = opts.add<Value<int>>("p", "power", "Algorithm p value: -1=antikt, 0=cambridge_achen, 1=inclusive kt", power, &power);
  auto radius_option = opts.add<Value<double>>("R", "radius", "Algorithm R parameter", R, &R);
  auto ptmin_option = opts.add<Value<double>>("P", "ptmin", "pt cut for inclusive jets", ptmin, &ptmin);
  auto dump_option = opts.add<Value<string>>("d", "dump", "Filename to dump jets to");


  opts.parse(argc, argv);

  if (help_option->count() == 1) {
    cout << argv[0] << " [options] HEPMC3_INPUT_FILE" << endl;
    cout << endl;
	  cout << opts << "\n";
    exit(EXIT_SUCCESS);
  }

  const auto extra_args = opts.non_option_args();
  std::string input_file{};
  if (extra_args.size() == 1) {
    input_file = extra_args[0];
  } else if (extra_args.size() == 0) {
    std::cerr << "No <HepMC3_input_file> argument after options" << std::endl;
  } else {
    std::cerr << "Only one <HepMC3_input_file> supported" << std::endl;
  }

  // read in input events
  //----------------------------------------------------------
  auto events = read_input_events(input_file.c_str(), maxevents);
  
  // Set strategy
  fastjet::Strategy strategy = fastjet::Best;
  if (mystrategy == string("N2Plain")) {
    strategy = fastjet::N2Plain;
  } else if (mystrategy == string("N2Tiled")) {
    strategy = fastjet::N2Tiled;
  }

  auto algorithm = fastjet::antikt_algorithm;
  if (power == 0) {
    algorithm = fastjet::cambridge_aachen_algorithm;
  } else if (power == 1) {
    algorithm = fastjet::kt_algorithm;
  }

  std::cout << "Strategy: " << mystrategy << "; Alg: " << power << endl;

  auto dump_fh = stdout;
  if (dump_option->is_set()) {
    if (dump_option->value() != "") {
      dump_fh = fopen(dump_option->value().c_str(), "w");
    }
  }

  double time_total = 0.0;
  double time_total2 = 0.0;
  double sigma = 0.0;
  double time_lowest = 1.0e20;
  for (long trial = 0; trial < trials; ++trial) {
    std::cout << "Trial " << trial << " ";
    auto start_t = std::chrono::steady_clock::now();
    for (size_t ievt = 0; ievt < events.size(); ++ievt) {
      auto cluster_sequence = run_fastjet_clustering(events[ievt], strategy, algorithm, R);
      vector<fastjet::PseudoJet> inclusive_jets = sorted_by_pt(cluster_sequence.inclusive_jets(ptmin));

      if (dump_option->is_set()) {
         fprintf(dump_fh, "Jets in processed event %zu\n", ievt+1);
    
        // print out the details for each jet
        for (unsigned int i = 0; i < inclusive_jets.size(); i++) {
          fprintf(dump_fh, "%5u %15.10f %15.10f %15.10f\n",
          i, inclusive_jets[i].rap(), inclusive_jets[i].phi(),
          inclusive_jets[i].perp());
        }
      }
    }
    auto stop_t = std::chrono::steady_clock::now();
    auto elapsed = stop_t - start_t;
    auto us_elapsed = double(chrono::duration_cast<chrono::microseconds>(elapsed).count());
    std::cout << us_elapsed << " us" << endl;
    time_total += us_elapsed;
    time_total2 += us_elapsed*us_elapsed;
    if (us_elapsed < time_lowest) time_lowest = us_elapsed;
  }
  time_total /= trials;
  time_total2 /= trials;
  if (trials > 1) {
    sigma = std::sqrt(double(trials)/(trials-1) * (time_total2 - time_total*time_total));
  } else {
    sigma = 0.0;
  }
  double mean_per_event = time_total / events.size();
  double sigma_per_event = sigma / events.size();
  time_lowest /= events.size();
  std::cout << "Processed " << events.size() << " events, " << trials << " times" << endl;
  std::cout << "Total time " << time_total << " us" << endl;
  std::cout << "Time per event " << mean_per_event << " +- " << sigma_per_event << " us" << endl;
  std::cout << "Lowest time per event " << time_lowest << " us" << endl;

  return 0;
}