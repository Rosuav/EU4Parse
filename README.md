Europa Universalis IV savefile parser
=====================================

Keep an eye on the state of the game, at least as frequently as your
autosaves happen. Any non-ironman save file should be able to be read
by this script; if you're playing ironman, you probably shouldn't be\
using this sort of tool anyway!

Mods are supported and recognized but may cause issues. Please file
bug reports if you find problems.

Both compressed and uncompressed save files can be read.

The information can best be viewed using a web browser; the default
port is 8087 but this can be changed. A TELNET interface is also
available if desired.

TODO: Document the key sender and consequent "go to province" feature.

TODO: Add an alert to recommend Strong Duchies if you don't have it, have 2+ march/vassal/PU, and either have >50% LD or over slots
TODO: If annexing a subject, replace its date with progress (X/Y) and maybe rate (Z/month)
TODO: Alert if idle colonist
TODO: War progress.
- "Army strength" is defined as sum(unit.men * unit.morale for army in country for unit in army) + country.max_morale * country.manpower
- Plot each country's army strength in the table with a graph showing its change from one save to the next
- Graph the progression of the war as the sum of each side's army strengths
- Is it possible to show history of battles and how they affected war strength? At very least, show every save sighted.

QUIRK: Sighted an issue with the savefile having an arraymap in it, causing the fast parser
to fail. It happened in the "history" of a now-defunct colonial nation (not sure if it was a
problem while the nation existed), with an empty {} inserted prior to the date-keyed entries.
- The slow parser still worked, so this wasn't a major problem, but it's a nuisance.
- Manually hacking out the empty array from the start fixed the problem, and a subsequent
  save worked fine.
