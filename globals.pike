protected void create(string n) {
	foreach (indices(this), string f) if (f != "create" && f[0] != '_') add_constant(f, this[f]);
}
