//Read a text (non-ironman) EU4 savefile and scan for matters of interest. Provides info to networked clients.
/* TODO: Split this into several files.
1. eu4_parse.pike - the main entrypoint, and MAYBE hot reload kernel??
2. EU file format parsing
   - Import it into the main analysis script, and also run it standalone for save files
3. Analysis
4. Web server (incl websockets)
5. Persist
Others?
*/
//TODO: Use @export to simplify things (lift from StilleBot)
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

constant LOCAL_PATH = "../.local/share/Paradox Interactive/Europa Universalis IV";
constant SAVE_PATH = LOCAL_PATH + "/save games";
constant PROGRAM_PATH = "../.steam/steam/steamapps/common/Europa Universalis IV"; //Append /map or /common etc to access useful data files

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

mapping building_slots = ([]); //TODO: Move this into CFG (when province data moves there)
array war_rumours = ({ });
mapping province_info; //TODO: Migrate into CFG

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
		G->webserver->update_group(country);
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
void process_savefile(string fn) {parsing = 0; G->webserver->send_updates_all(); parser_pipe->write(fn + "\n");}
void done_processing_savefile(object pipe, string msg) {
	msg += parser_pipe->read() || ""; //Purge any spare text
	foreach ((array)msg, int chr) {
		if (chr <= 100) {parsing = chr; G->webserver->send_to_all((["cmd": "update", "parsing": parsing]));}
		if (chr == '~') {
			mapping data = Standards.JSON.decode_utf8(Stdio.read_file("eu4_parse.json") || "{}")->data;
			if (!data) {werror("Unable to parse save file (see above for errors, hopefully)\n"); return;}
			write("\nCurrent date: %s\n", data->date);
			string mods = (data->mods_enabled_names||({}))->filename * ",";
			G->G->mods_inconsistent = mods != CFG->active_mods;
			G->G->provincecycle = ([]);
			last_parsed_savefile = data;
			parsing = -1; G->webserver->send_updates_all();
		}
	}
}

array recent_peace_treaties = ({ }); //Recent peace treaties only, but hopefully useful

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
		string raw; TIME(raw = Stdio.read_file(SAVE_PATH + "/" + fn));
		mapping data; TIME(data = G->parser->parse_savefile_string(raw));
		write("Parse successful. Date: %s\n", data->date);
		return 0;
	}
	if (argc > 1 && argv[1] == "--checksum") {
		object tm = System.Timer();
		write("Vanilla checksum: %O\n", G->parser->calculate_checksum(({ })));
		array active_mods = Standards.JSON.decode_utf8(Stdio.read_file(LOCAL_PATH + "/dlc_load.json"))->enabled_mods;
		write("Current checksum: %O\n", G->parser->calculate_checksum(active_mods));
		werror("Time %O\n", tm->get());
		return 0;
	}
	bootstrap("webserver"); //Only needed for the main entrypoint
	bootstrap("analysis");
	bootstrap("monitors");

	//Load up some info that is presumed to not change. If you're tweaking a game mod, this may break.
	//In general, if you've made any change that could affect things, restart the parser to force it
	//to reload. Currently, this also applies to changing which mods are active; that may change in the
	//future, but editing the mods themselves will still require a restart.
	//Note: Order of mods is not guaranteed here. The game does them in alphabetical order, but with
	//handling of dependencies.
	array active_mods = Standards.JSON.decode_utf8(Stdio.read_file(LOCAL_PATH + "/dlc_load.json"))->enabled_mods;
	CFG = G->parser->GameConfig(active_mods);

	/* It is REALLY REALLY hard to replicate the game's full algorithm for figuring out which terrain each province
	has. So, instead, let's ask for a little help - from the game, and from the human. And then save the results.
	Unfortunately, it's not possible (as of v1.31) to do an every_province scope that reports the province ID in a
	log message. It also doesn't seem to be possible to iterate over all provinces and increment a counter, as the
	every_province scope skips sea provinces (which still consume province IDs).
	I would REALLY like to do something like this:
	every_province = {
		limit = {
			has_terrain = steppe
			is_wasteland = no
		}
		log = "PROV-TERRAIN: steppe [This.ID] [This.GetName]"
	}
	
	and repeat for each terrain type. A technique others have done is to cede the provinces to different countries,
	save, and parse the savefile; this is slow, messy, and mutates the save, so it won't be very useful in Random
	New World. (Not that I'm going to try to support RNW, but it should be easier this way if I do in the future.)

	Since we can't do it the easy way, let's do it the hard way instead. For each province ID, for each terrain, if
	the province has that terrain, log a message. If it's stupid, but it works........ no, it's still stupid.

	TODO: Mark the log (maybe in PROV-TERRAIN-BEGIN) with the EU4 version, permanently notice this, and key the
	cache by the version. That way it won't be a problem if there are province changes and you switch back and
	forth across the update. This could then move into the CFG object.
	*/
	province_info = Standards.JSON.decode(Stdio.read_file(".eu4_provinces.json") || "0");
	if (!mappingp(province_info)) {
		//Build up a script file to get the info we need.
		//We assume that every province that could be of interest to us will be in an area.
		Stdio.File script = Stdio.File(LOCAL_PATH + "/prov.txt", "wct");
		script->write("log = \"PROV-TERRAIN-BEGIN\"\n");
		foreach (sort(indices(CFG->prov_area)), string provid) {
			script->write(
#"%s = {
	set_variable = { which = terrain_reported value = -1 }
	if = {
		limit = {
			OR = {
				trade_goods = coal
				has_latent_trade_goods = coal
			}
		}
		log = \"PROV-TERRAIN: %<s has_coal=1\"
	}
	if = {
		limit = { has_port = yes is_wasteland = no }
		log = \"PROV-TERRAIN: %<s has_port=1\"
	}
", provid);
			foreach (CFG->terrain_definitions->categories; string type; mapping info) {
				script->write(
#"	if = {
		limit = { has_terrain = %s is_wasteland = no }
		log = \"PROV-TERRAIN: %s terrain=%[0]s\"
	}
", type, provid);
			}
			foreach (CFG->climates; string type; mixed info) if (arrayp(info)) {
				script->write(
#"	if = {
		limit = { has_climate = %s is_wasteland = no }
		log = \"PROV-TERRAIN: %s climate=%[0]s\"
	}
", type, provid);
			}
			script->write("}\n");
		}
		//For reasons of paranoia, iterate over all provinces and make sure we reported their
		//terrain types.
		script->write(#"
every_province = {
	limit = { check_variable = { which = terrain_reported value = 0 } is_wasteland = no }
	log = \"PROV-TERRAIN-ERROR: Terrain not reported for province [This.GetName]\"
}
log = \"PROV-TERRAIN-END\"
");
		script->close();
		//See if the script's already been run (yes, we rebuild the script every time - means you
		//can rerun it in case there've been changes), and if so, parse and save the data.
		string log = Stdio.read_file(LOCAL_PATH + "/logs/game.log") || "";
		if (!has_value(log, "PROV-TERRAIN-BEGIN") || !has_value(log, "PROV-TERRAIN-END"))
			exit(0, "Please open up EU4 and, in the console, type: run prov.txt\n");
		string terrain = ((log / "PROV-TERRAIN-BEGIN")[-1] / "PROV-TERRAIN-END")[0];
		province_info = ([]);
		foreach (terrain / "\n", string line) {
			//Lines look like this:
			//[effectimplementation.cpp:21960]: EVENT [1444.11.11]:PROV-TERRAIN: drylands 224 - Sevilla
			sscanf(line, "%*sPROV-TERRAIN: %d %s=%s", int provid, string key, string val);
			if (!provid) continue;
			mapping pt = province_info[(string)provid] || ([]); province_info[(string)provid] = pt;
			pt[key] = String.trim(val);
		}
		Stdio.write_file(".eu4_provinces.json", Standards.JSON.encode(province_info));
	}
	foreach (province_info; string id; mapping provinfo) {
		mapping terraininfo = CFG->terrain_definitions->categories[provinfo->terrain];
		if (int slots = (int)terraininfo->?allowed_num_of_buildings) building_slots[id] += slots;
		mapping climateinfo = CFG->static_modifiers[provinfo->climate];
		if (int slots = (int)climateinfo->?allowed_num_of_buildings) building_slots[id] += slots;
	}

	object proc = Process.spawn_pike(({argv[0], "--parse"}), (["fds": ({parser_pipe->pipe(Stdio.PROP_NONBLOCK|Stdio.PROP_BIDIRECTIONAL|Stdio.PROP_IPC)})]));
	parser_pipe->set_nonblocking(done_processing_savefile, 0, parser_pipe->close);
	//Find the newest .eu4 file in the directory and (re)parse it, then watch for new files.
	array(string) files = SAVE_PATH + "/" + get_dir(SAVE_PATH)[*];
	sort(file_stat(files[*])->mtime, files);
	if (sizeof(files)) process_savefile(files[-1]);
	Stdio.Port mainsock = Stdio.Port();
	mainsock->bind(1444, sock_connected, "::", 1);
	return -1;
}
