// Copyright (C) 2021 Torbjorn Sjostrand.
// Copyright (C) 2021 Ph. Gras.
// PYTHIA is licenced under the GNU GPL v2 or later, see COPYING for details.
// Please respect the MCnet Guidelines, see GUIDELINES for details.

// Authors: Mikhail Kirsanov <Mikhail.Kirsanov@cern.ch>.

#include "Pythia8/Pythia.h"
#include "Pythia8Plugins/HepMC3.h"

using namespace Pythia8;

int main() {

  // Interface for conversion from Pythia8::Event to HepMC
  // event. Specify file where HepMC events will be stored.
  Pythia8::Pythia8ToHepMC topHepMC("events-ee-H-2000.hepmc3");

  // Generator. Process selection. LHC initialization. Histogram.
  Pythia pythia;

  // Allow no substructure in e+- beams: normal for corrected LEP data.
  pythia.readString("PDF:lepton = off");
  // Process selection, e+e- -> H
  pythia.readString("HiggsSM:ffbar2HZ = on");
  pythia.readString("25:m0 = 125.0");
  pythia.readString("25:onMode = off");
  pythia.readString("25:onIfMatch = 5 -5");

  // e+e- beams
  pythia.readString("Beams:idA =  11");
  pythia.readString("Beams:idB = -11");
  
  // Set beam energy here
  pythia.readString("Beams:eCM = 250.");

  pythia.init();
  Hist mult("charged multiplicity", 100, -0.5, 799.5);

  // Begin event loop. Generate event. Skip if error.
  for (int iEvent = 0; iEvent < 2000; ++iEvent) {
    if (!pythia.next()) continue;

    // Find number of all final charged particles and fill histogram.
    int nCharged = 0;
    for (int i = 0; i < pythia.event.size(); ++i)
      if (pythia.event[i].isFinal() && pythia.event[i].isCharged())
        ++nCharged;
    mult.fill( nCharged );

    // Construct new empty HepMC event, fill it and write it out.
    topHepMC.writeNextEvent( pythia );


  // End of event loop. Statistics. Histogram.
  }
  pythia.stat();
  cout << mult;

  // Done.
  return 0;
}
