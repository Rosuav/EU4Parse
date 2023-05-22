//Read a text (non-ironman) EU4 savefile and scan for matters of interest. Provides info via a web page.
/*
NOTE: Province group selection inverts the normal rules and has the web client in charge.
This ensures that there can be no desynchronization between user view and province ID
selection, but it does mean that the client must remain active in order to keep things
synchronized. In practice, not a problem, since the client selects the group anyway.
*/
//TODO: Background service to do the key sending. See example systemd script in my cfgsystemd.

/* TODO: Support mods better.
Current: Preload on startup, cache the last-used-mod-list in eu4_parse.json, and if the save
doesn't have the same set, warn. The localisation files will probably be wrong.
Better fix: Isolate all the global state from the socket connections and, instead of dying, keep
the sockets and reload all the definitions. Might also allow connections earlier, fwiw.

May end up switching all definition loading to parse_config_dir even if there's normally only the
one file, since it makes mod handling easier. Will need to handle a replace_path block in the mod
definition, possibly also a dependencies block. See: https://eu4.paradoxwikis.com/Mod_structure

It may be of value to have multiple L10n caches, since mod switching is costly at the moment.
It may also be of value to have a way to recognize a change to a mod, to force a reload.

If there are any issues remaining - notably, if anything crashes - report it on the client. Once
that and the above are all done, the server can become purely a service, no console needed.
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

multiset(object) connections = (<>);
mapping last_parsed_savefile;
class Connection(Stdio.File sock) {
	Stdio.Buffer incoming = Stdio.Buffer(), outgoing = Stdio.Buffer();
	string notify;

	protected void create() {
		sock->set_buffer_mode(incoming, outgoing);
		sock->set_nonblocking(sockread, 0, sockclosed);
	}
	void sockclosed() {connections[this] = 0; sock->close();}

	string find_country(mapping data, string country) {
		foreach (data->players_countries / 2, [string name, string tag])
			if (lower_case(country) == lower_case(name)) country = tag;
		if (data->countries[country]) return country;
	}

	void provnotify(string country, int province) {
		//A request has come in (from the web) to notify a country to focus on a province.
		if (!notify) return;
		string tag = find_country(last_parsed_savefile, notify);
		if (tag != country) return; //Not found, or not for us.
		outgoing->sprintf("provfocus %d\n", province);
		sock->write(""); //Force a write callback (shouldn't be necessary??)
	}

	void cycle_provinces(string country) {
		if (!last_parsed_savefile) return;
		if (!G->G->provincecycle[country]) {
			sock->write("Need to select a cycle group before cycling provinces\n");
			return;
		}
		[string id, array rest] = Array.shift(G->G->provincecycle[country]);
		G->G->provincecycle[country] = rest + ({id});
		G->connection->update_group(country);
		//Note: Ignores buffered mode and writes directly. I don't think it's possible to
		//put a "shutdown write direction when done" marker into the Buffer.
		sock->write("provfocus " + id + "\nexit\n");
		sock->close("w");
	}

	void sockread() {
		while (array ret = incoming->sscanf("%s\n")) {
			string cmd = String.trim(ret[0]), arg = "";
			sscanf(cmd, "%s %s", cmd, arg);
			switch (cmd) {
				case "notify":
					connections[this] = 0;
					if (sscanf(arg, "province %s", arg)) ; //notiftype = "province";
					else sock->write("Warning: Old 'notify' no longer supported, using 'notify province' instead\n");
					notify = arg; connections[this] = 1;
					break;
				case "province": cycle_provinces(arg); break;
				default: sock->write(sprintf("Unknown command %O\n", cmd)); break;
			}
		}
	}
}

void sock_connected(object mainsock) {while (object sock = mainsock->accept()) Connection(sock);}

Stdio.File parser_pipe = Stdio.File();
int parsing = -1;
void process_savefile(string fn) {parsing = 0; G->connection->send_updates_all(); parser_pipe->write(fn + "\n");}
void done_processing_savefile(object pipe, string msg) {
	msg += parser_pipe->read() || ""; //Purge any spare text
	foreach ((array)msg, int chr) {
		if (chr <= 100) {parsing = chr; G->connection->send_to_all((["cmd": "update", "parsing": parsing]));}
		if (chr == '~') {
			mapping data = Standards.JSON.decode_utf8(Stdio.read_file("eu4_parse.json") || "{}")->data;
			if (!data) {werror("Unable to parse save file (see above for errors, hopefully)\n"); return;}
			write("\nCurrent date: %s\n", data->date);
			string mods = (data->mods_enabled_names||({}))->filename * ",";
			G->G->mods_inconsistent = mods != CFG->active_mods;
			G->G->provincecycle = ([]);
			last_parsed_savefile = data;
			parsing = -1; G->connection->send_updates_all();
		}
	}
}

int main(int argc, array(string) argv) {
	add_constant("G", this);
	G->G = G; //Allow code in this file to use G->G-> as it will need that when it moves out
	bootstrap("globals");
	bootstrap("parser");

	if (argc > 1 && argv[1] == "--parse") return G->parser->main();
	if (argc > 1 && argv[1] == "--timeparse") {
		string fn = argc > 2 ? argv[2] : "mp_autosave.eu4";
		object start = System.Timer();
		#define TIME(x) {float tm = gauge {x;}; write("%.3f\t%.3f\t%s\n", start->get(), tm, #x);}
		string raw; TIME(raw = Stdio.read_file(G->globals->SAVE_PATH + "/" + fn));
		mapping data; TIME(data = G->parser->parse_savefile_string(raw));
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
	bootstrap("connection"); //Only needed for the main entrypoint
	bootstrap("analysis");
	bootstrap("monitors");

	//Load up some info that is presumed to not change. If you're tweaking a game mod, this may break.
	//In general, if you've made any change that could affect things, restart the parser to force it
	//to reload. Currently, this also applies to changing which mods are active; that may change in the
	//future, but editing the mods themselves will still require a restart.
	//Note: Order of mods is not guaranteed here. The game does them in alphabetical order, but with
	//handling of dependencies.
	array active_mods = Standards.JSON.decode_utf8(Stdio.read_file(G->globals->LOCAL_PATH + "/dlc_load.json"))->enabled_mods;
	CFG = G->parser->GameConfig(active_mods);

	object proc = Process.spawn_pike(({argv[0], "--parse"}), (["fds": ({parser_pipe->pipe(Stdio.PROP_NONBLOCK|Stdio.PROP_BIDIRECTIONAL|Stdio.PROP_IPC)})]));
	parser_pipe->set_nonblocking(done_processing_savefile, 0, parser_pipe->close);
	//Find the newest .eu4 file in the directory and (re)parse it, then watch for new files.
	array(string) files = G->globals->SAVE_PATH + "/" + get_dir(G->globals->SAVE_PATH)[*];
	sort(file_stat(files[*])->mtime, files);
	if (sizeof(files)) process_savefile(files[-1]);
	Stdio.Port mainsock = Stdio.Port();
	mainsock->bind(1444, sock_connected, "::", 1);
	return -1;
}
