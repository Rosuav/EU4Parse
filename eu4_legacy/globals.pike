protected void create(string n) {
	foreach (indices(this), string f) if (f != "create" && f[0] != '_') add_constant(f, this[f]);
}

constant LOCAL_PATH = "../.local/share/Paradox Interactive/Europa Universalis IV";
constant SAVE_PATH = LOCAL_PATH + "/save games";
constant PROGRAM_PATH = "../.steam/steam/steamapps/common/Europa Universalis IV"; //Append /map or /common etc to access useful data files

string L10N(string key) {return G->CFG->L10n[key] || key;}

int threeplace(string value) {
	//EU4 uses three-place fixed-point for a lot of things. Return the number as an integer,
	//ie "3.142" is returned as 3142. Can handle "-0.1" and "-.1", although to my knowledge,
	//the EU4 files never contain the latter.
	if (!value) return 0;
	sscanf(value, "%[-]%[0-9].%[0-9]", string neg, string whole, string frac);
	return (neg == "-" ? -1 : 1) * ((int)whole * 1000 + (int)sprintf("%.03s", frac + "000"));
}
