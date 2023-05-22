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

/* Peace treaty analysis

A peace treaty found in game.log begins with a date, eg "20 November 1445".
If this was the final peace treaty (between war leaders), then data->previous_war will contain an entry
that has its final history block carrying the same date ("1445.11.20").
If it's a separate peace and the war is still ongoing in the current savefile, then data->active_war
will contain an entry with a history block for the same date, stating that the attacker or defender
was removed from the war.
If it was a separate peace, but the entire war has closed out before the savefile happened, then the
same war entry will be in data->previous_war.

To check:
1) In a non-final history entry, is it possible to get rem_attacker and rem_defender with the same date? It
   would require a separate peace each direction while the game is paused. Get Stephen to help test.
   (To test, declare war on each other, both with allies. Drag out the war, don't accept any peace terms,
   until allies on both sides are willing to white peace. White peace one ally out. Can the *opposite* war
   leader send a peace treaty? The same one can't. Keep war going until next save, or just save immediately.)
   - Yes. It is absolutely possible to send peace treaties both directions on the same day. They show up in
     the file as separate blocks with the same key, which the parser will combine. You can't get two blocks
     with rem_attacker or two with rem_defender, but you CAN have one of each getting merged.
2) When a country is annexed, does their entry remain, with the same country_name visible? We get tags in the
   save file, but names in the summary ("Yas have accepted peace with Hormuz").
3) Does a country always have a truce entry for that war? Check odd edge cases. Normally, if rem_attacker,
   look for original_defender, and vice versa; self->active_relations[original_other] should have entries.
4) What is last_war_status?
*/

array recent_peace_treaties = ({ }); //Recent peace treaties only, but hopefully useful
/* @export: */ array get_savefile_info() {return ({last_parsed_savefile, recent_peace_treaties});}

array|string text_with_icons(string text) {
	//Note: This assumes the log file is ISO-8859-1. (It does always seem to be.)
	//Parse out icons like "\xA3dip" into image references
	text = replace(text, "\xA4", "\xA3icon_gold\xA3"); //\xA4 is a shorthand for the "ducats" icon
	array ret = ({ });
	while (sscanf(text, "%s\xA3%s%[ .,()\xA3]%s", string plain, string icon, string end, text) == 4) {
		//For some reason, %1[...] doesn't do what I want.
		sscanf(end, "%1s%s", end, string trail); text = trail + text;
		//The icon marker ends with either another \xA3 or some punctuation. If it's punctuation, retain it.
		if (end != "\xA3") text = end + text;
		string key;
		//TODO: If we find multiple arrays of filenames, join them together
		foreach (({"GFX_text_" + icon, "GFX_" + icon}), string tryme) if (CFG->icons[tryme]) {key = tryme; break;}
		array|string img = key ? CFG->icons[key] : "data:image/borked,unknown_key";
		if (arrayp(img)) {
			//Some icons have multiple files. Try each one in turn until one succeeds.
			//Hack: Some are listed with TGA files, but actually have DDSes provided.
			//So we ignore the suffix and just try both.
			array allfn = ({ });
			foreach (img, string fn) allfn += ({fn, replace(fn, ".dds", ".tga"), replace(fn, ".tga", ".dds")});
			img = Array.uniq(allfn);
			foreach (img, string fn) {
				object|mapping png = G->parser->load_image(PROGRAM_PATH + "/" + fn);
				if (mappingp(png)) png = png->image;
				if (!png) continue;
				img = "data:image/png;base64," + MIME.encode_base64(Image.PNG.encode(png), 1);
				break;
			}
			if (arrayp(img)) img = "data:image/borked," + img * ","; //Hopefully browsers will know that they can't render this
			CFG->icons["GFX_text_" + icon] = img;
		}
		ret += ({plain, (["icon": img, "title": icon])});
	}
	if (!sizeof(ret)) return text;
	return ret + ({text});
}

array parse_text_markers(string line) {
	//Parse out colour codes and other markers
	array info = ({ });
	while (sscanf(line, "%s\xA7%1s%s", string txt, string code, line) == 3) {
		if (txt != "") info += ({text_with_icons(txt)});
		//"\xA7!" means reset, and "\xA7W" means white, which seems to be used
		//as a reset. Ignore them both and just return the text as-is.
		if (code == "!" || code == "W") continue;
		array(string) color = CFG->textcolors[code];
		if (!color) {
			info += ({(["abbr": "<COLOR>", "title": "Unknown color code (" + code + ")"])});
			continue;
		}
		//Sometimes color codes daisy-chain into each other. We prefer to treat them as containers though.
		sscanf(line, "%s\xA7%s", line, string next);
		info += ({(["color": color * ",", "text": text_with_icons(line)])});
		if (next) line = "\xA7" + next; else line = "";
	}
	return info + ({text_with_icons(line)});
}

constant ICON_REPRESENTATIONS = ([
	"dip": "\U0001F54A\uFE0F", //Diplomacy is for the birds
]);

string render_text(array|string|mapping txt) {
	//Inverse of parse_text_markers: convert the stream into ANSI escape sequences.
	if (stringp(txt)) return txt;
	if (arrayp(txt)) return render_text(txt[*]) * "";
	if (txt->color) return sprintf("\e[38;2;%sm%s\e[0m", replace(txt->color, ",", ";"), render_text(txt->text));
	if (txt->abbr) return txt->abbr; //Ignore the hover (if there's no easy way to put it)
	if (txt->icon) return ICON_REPRESENTATIONS[txt->title] || "[" + txt->title + "]";
	return "<ERROR>";
}

void watch_game_log(object inot) {
	//Monitor the log, and every time there's a new line that matches "[messagehandler.cpp:351]: ... accepted peace ...",
	//add it to a list of peace treaties. When the log is truncated or replaced, clear that list.
	string logfn = SAVE_PATH + "/../logs/game.log";
	object log = Stdio.File(logfn);
	log->set_nonblocking();
	string data = "";
	void parse() {
		data += log->read();
		while (sscanf(data, "%s\n%s", string line, data)) {
			line = String.trim(line);
			if (!sscanf(line, "[messagehandler.cpp:%*d]: %s", line)) continue;
			mapping sendme = (["cmd": "update"]);
			if (has_value(line, "accepted peace")) { //TODO: Make sure this filters out any that don't belong, like some event choices
				//TODO: Tag something so that, the next time we see a save file, we augment the
				//peace info with the participants, the peace treaty value (based on truce length),
				//and the name of the war. Should be possible to match on the date (beginning of line).
				recent_peace_treaties = ({parse_text_markers(line)}) + recent_peace_treaties;
				write("\e[1mPEACE:\e[0m %s\n", string_to_utf8(render_text(recent_peace_treaties[0])));
				sendme->recent_peace_treaties = recent_peace_treaties;
			}
			if (sscanf(line, "%d %s %d - %s is preparing to attack %s.",
					int day, string mon, int year, string aggressor, string defender) && defender) {
				//The various "rumour that X is about to attack Y" messages, eg because
				//someone's a babbling buffoon.
				int month = search("January February March April May June July August September October November December" / " ", mon) + 1;
				if (!month) werror("\e[1;33mRUMOUR FAIL - bad month %O\n", mon);
				war_rumours += ({([
					"atk": aggressor, "def": defender,
					"rumoured": sprintf("%d.%02d.%02d", year, month, day),
				])});
				write("\e[1;33mRUMOUR:\e[0m %s is planning to attack %s [%02d %s %d]\n",
					string_to_utf8(aggressor), string_to_utf8(defender), day, mon, year);
				sendme->war_rumours = war_rumours;
			}
			if (sscanf(line, "%d %s %d - %s started the %s against %s.",
					int day, string mon, int year, string aggressor, string war, string defender) && defender) {
				//We have declared war, because SOME people need to learn the hard way.
				int month = search("January February March April May June July August September October November December" / " ", mon) + 1;
				if (!month) werror("\e[1;33mWAR FAIL - bad month %O\n", mon);
				string last_year = sprintf("%d.%02d.%02d", year - 1, month, day); //Note that this date might not exist; it's just for the inequality check. It's fine to ask if a date is more recent than 29th Feb 1447.
				mapping found;
				foreach (war_rumours, mapping r) {
					if (r->atk == aggressor && r->def == defender && r->rumoured > last_year)
						found = r; //Don't break though; keep the last match.
				}
				if (found) {
					found->war = war;
					found->declared = sprintf("%d.%02d.%02d", year, month, day);
					write("\e[1;31mACTUAL WAR:\e[0m %s has attacked %s [%s --> %s]\n",
						string_to_utf8(aggressor), string_to_utf8(defender), found->rumoured, found->declared);
					sendme->war_rumours = war_rumours;
				}
			}
			if (sscanf(line, "%d %s %d - %s has gone bankrupt%s",
					int day, string mon, int year, string country, string dot) && dot == ".") {
				//TODO: Record bankruptcies and when they'll expire (five years later)
				werror("\e[1;33mBANKRUPT:\e[0m %s (%d %s %d)\n", country, day, mon, year);
			}
			if (sizeof(sendme) > 1) G->webserver->send_to_all(sendme);
		}
	}
	parse();
	int pos = log->tell();
	inot->add_watch(logfn, System.Inotify.IN_MODIFY) {
		[int event, int cookie, string path] = __ARGS__;
		if (file_stat(logfn)->size < pos) {
			//File seems to have been truncated. Note that this won't catch
			//deleting the file and creating a new one.
			log->seek(0);
			recent_peace_treaties = war_rumours = ({ });
		}
		parse();
		pos = log->tell();
	};
	//If we need to handle deletes/recreations or file movements, watch the directory too.
	/*inot->add_watch(SAVE_PATH + "/../logs", System.Inotify.IN_CREATE | System.Inotify.IN_MOVED_TO) {
		[int event, int cookie, string path] = __ARGS__;
		write("Got a dir event! %O %O %O\n", event, cookie, path); //Moved is 128, create is 256
	};*/
}

int main(int argc, array(string) argv) {
	add_constant("G", this);
	G->G = G; //Allow code in this file to use G->G-> as it will need that when it moves out
	add_constant("get_savefile_info", get_savefile_info);
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
		Stdio.File script = Stdio.File(SAVE_PATH + "/../prov.txt", "wct");
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
	object inot = System.Inotify.Instance();
	string new_file; int nomnomcookie;
	inot->add_watch(SAVE_PATH, System.Inotify.IN_CLOSE_WRITE | System.Inotify.IN_MOVED_TO | System.Inotify.IN_MOVED_FROM) {
		[int event, int cookie, string path] = __ARGS__;
		//EU4 seems to always save into a temporary file, then rename it over the target. This
		//sometimes includes renaming the target out of the way first (eg old_autosave.eu4).
		//There are a few ways to detect new save files.
		//1) Watch for a CLOSE_WRITE event, which will be the temporary file (eg autosave.tmp).
		//   When you see that, watch for the next MOVED_FROM event for that same name, and then
		//   the corresponding MOVED_TO event is the target name. Assumes that the file is created
		//   in the savegames directory and only renamed, never moved in.
		//2) Watch for all MOVED_TO events, and arbitrarily ignore any that we don't think are
		//   interesting (eg if starts with "old_" or "older_").
		//3) Watch for any CLOSE_WRITE or MOVED_TO. Wait a little bit. See what the newest file in
		//   the directory is. Assumes that the directory is quiet apart from what we care about.
		//Currently using option 1. Change if this causes problems.
		switch (event) {
			case System.Inotify.IN_CLOSE_WRITE: new_file = path; break;
			case System.Inotify.IN_MOVED_FROM: if (path == new_file) {new_file = 0; nomnomcookie = cookie;} break;
			case System.Inotify.IN_MOVED_TO: if (cookie == nomnomcookie) {nomnomcookie = 0; process_savefile(path);} break;
		}
	};
	watch_game_log(inot);
	inot->set_nonblocking();
	Stdio.Port mainsock = Stdio.Port();
	mainsock->bind(1444, sock_connected, "::", 1);
	return -1;
}
