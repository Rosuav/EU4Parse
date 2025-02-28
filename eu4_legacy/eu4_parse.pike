//Read a text (non-ironman) EU4 savefile and scan for matters of interest. Provides info via a web page.
/*
NOTE: Province group selection inverts the normal rules and has the web client in charge.
This ensures that there can be no desynchronization between user view and province ID
selection, but it does mean that the client must remain active in order to keep things
synchronized. In practice, not a problem, since the client selects the group anyway.
*/
//TODO: Background service to do the key sending. See example systemd script in my cfgsystemd.

/* TODO: Improve mod support.
May end up switching all definition loading to parse_config_dir even if there's normally only the
one file, since it makes mod handling easier. Will need to handle a replace_path block in the mod
definition, possibly also a dependencies block. See: https://eu4.paradoxwikis.com/Mod_structure
*/

/* TODO: Missions and decisions parsing.
Seems to be utterly broken maybe?? Never really got it going. Would be nice to have it list the
provinces you need to look at, in separate sections if there are multiple groups.
*/

/* TODO: Reload signals.
On the front end, have a couple of (or maybe just one combined) reload button.
* Reload code - bootstrap all files again - make sure they retain as needed
* Reload config - force a full reload of G->CFG, including a hash check and maybe
  something that makes sure it checks the log for prov.txt output
*/

mapping G = ([]);
object CFG;

void bootstrap(string module) {
	program|object compiled;
	mixed ex = catch {compiled = compile_file(module + ".pike");};
	if (ex) {werror("Exception in compile!\n%s\n", ex->describe()); return 0;}
	if (!compiled) werror("Compilation failed for %s\n", module);
	if (mixed ex = catch {compiled = compiled(module);}) werror(describe_backtrace(ex) + "\n");
	werror("Bootstrapped %s.pike\n", module);
	G[module] = compiled;
}

int main(int argc, array(string) argv) {
	add_constant("G", this);
	G->G = G; //Allow code in this file to use G->G-> as it will need that when it moves out
	bootstrap("globals");
	bootstrap("parser");
	CFG = G->parser->NullGameConfig();

	if (argc > 2 && argv[1] == "--parse") {
		string raw = Stdio.read_file(argv[2]);
		mapping data = G->parser->parse_eu4txt(raw);
		if (!data) exit(0, "Parse unsuccessful (see above).\n");
		string json = Standards.JSON.encode(data);
		write("Parse successful. Indices: %O\n", indices(data));
		return 0;
	}
	if (argc > 1 && argv[1] == "--parse") return G->parser->main();
	if (argc > 1 && argv[1] == "--timeparse") {
		string fn = argc > 2 ? argv[2] : "mp_autosave.eu4";
		object start = System.Timer();
		#define TIME(x) {float tm = gauge {x;}; write("%.3f\t%.3f\t%s\n", start->get(), tm, #x);}
		TIME(CFG = G->parser->GameConfig());
		//string raw; TIME(raw = Stdio.read_file(G->globals->SAVE_PATH + "/" + fn));
		//mapping data; TIME(data = G->parser->parse_savefile_string(raw));
		string raw; TIME(raw = Process.run(({"./savefile", G->globals->SAVE_PATH + "/" + fn}))->stdout);
		mapping data; TIME(data = Standards.JSON.decode(raw));
		string json; TIME(json = Standards.JSON.encode(data));
		write("Parse successful. Date: %s\n", data->date);
		return 0;
	}
	if (argc > 1 && argv[1] == "--checksum") {
		catch {
			mapping data = Standards.JSON.decode_utf8(Stdio.read_file("eu4_parse.json") || "{}")->data;
			write("Latest save file: %O\n", data->checksum);
		}; //Ignore errors and just don't print the checksum
		object tm = System.Timer();
		write("Vanilla checksum: %O\n", G->parser->calculate_checksum(({ })));
		array active_mods = Standards.JSON.decode_utf8(Stdio.read_file(G->globals->LOCAL_PATH + "/dlc_load.json"))->enabled_mods;
		write("Current checksum: %O\n", G->parser->calculate_checksum(active_mods));
		werror("Time %O\n", tm->get());
		return 0;
	}
	if (argc > 1 && argv[1] == "--peace") {
		//Just watch for peace treaties, nothing else.
		add_constant("SKIP_SAVEFILES", 1);
		bootstrap("monitors");
		return -1;
	}
	bootstrap("connection"); //Only needed for the main entrypoint
	bootstrap("analysis");
	bootstrap("monitors");
	G->parser->spawn();
	signal(3) { //SIGQUIT, generally sent by Ctrl-Backslash, can be used to trigger a code reload.
		werror("RELOADING/^\n"); //heh heh... there'll probably be a "\^" at the start of the line...
		bootstrap("globals");
		bootstrap("parser");
		bootstrap("connection");
		bootstrap("analysis");
		bootstrap("monitors");
		//Note that G->CFG is not replaced here
	};
	return -1;
}
