//Monitor files and directories for changes

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
		foreach (({"GFX_text_" + icon, "GFX_" + icon}), string tryme) if (G->CFG->icons[tryme]) {key = tryme; break;}
		array|string img = key ? G->CFG->icons[key] : "data:image/borked,unknown_key";
		if (arrayp(img)) {
			//Some icons have multiple files. Try each one in turn until one succeeds.
			//Hack: Some are listed with TGA files, but actually have DDSes provided.
			//So we ignore the suffix and just try both.
			array allfn = ({ });
			foreach (img, string fn) allfn += ({fn, replace(fn, ".dds", ".tga"), replace(fn, ".tga", ".dds")});
			img = Array.uniq(allfn);
			foreach (img, string fn) {
				object|mapping png = G->G->parser->load_image(PROGRAM_PATH + "/" + fn);
				if (mappingp(png)) png = png->image;
				if (!png) continue;
				img = "data:image/png;base64," + MIME.encode_base64(Image.PNG.encode(png), 1);
				break;
			}
			if (arrayp(img)) img = "data:image/borked," + img * ","; //Hopefully browsers will know that they can't render this
			G->CFG->icons["GFX_text_" + icon] = img;
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
		array(string) color = G->CFG->textcolors[code];
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
	string logfn = LOCAL_PATH + "/logs/game.log";
	object log = Stdio.File(logfn);
	log->set_nonblocking();
	string data = "";
	G->G->recent_peace_treaties = G->G->war_rumours = ({ });
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
				array info = parse_text_markers(line);
				sendme->recent_peace_treaties = G->G->recent_peace_treaties = ({info}) + G->G->recent_peace_treaties;
				//write("\e[1mPEACE:\e[0m %s\n", string_to_utf8(render_text(info)));
			}
			if (sscanf(line, "%d %s %d - %s is preparing to attack %s.",
					int day, string mon, int year, string aggressor, string defender) && defender) {
				//The various "rumour that X is about to attack Y" messages, eg because
				//someone's a babbling buffoon.
				int month = search("January February March April May June July August September October November December" / " ", mon) + 1;
				if (!month) werror("\e[1;33mRUMOUR FAIL - bad month %O\n", mon);
				G->G->war_rumours += ({([
					"atk": aggressor, "def": defender,
					"rumoured": sprintf("%d.%02d.%02d", year, month, day),
				])});
				write("\e[1;33mRUMOUR:\e[0m %s is planning to attack %s [%02d %s %d]\n",
					string_to_utf8(aggressor), string_to_utf8(defender), day, mon, year);
				sendme->war_rumours = G->G->war_rumours;
			}
			if (sscanf(line, "%d %s %d - %s started the %s against %s.",
					int day, string mon, int year, string aggressor, string war, string defender) && defender) {
				//We have declared war, because SOME people need to learn the hard way.
				int month = search("January February March April May June July August September October November December" / " ", mon) + 1;
				if (!month) werror("\e[1;33mWAR FAIL - bad month %O\n", mon);
				string last_year = sprintf("%d.%02d.%02d", year - 1, month, day); //Note that this date might not exist; it's just for the inequality check. It's fine to ask if a date is more recent than 29th Feb 1447.
				mapping found;
				foreach (G->G->war_rumours, mapping r) {
					if (r->atk == aggressor && r->def == defender && r->rumoured > last_year)
						found = r; //Don't break though; keep the last match.
				}
				if (found) {
					found->war = war;
					found->declared = sprintf("%d.%02d.%02d", year, month, day);
					write("\e[1;31mACTUAL WAR:\e[0m %s has attacked %s [%s --> %s]\n",
						string_to_utf8(aggressor), string_to_utf8(defender), found->rumoured, found->declared);
					sendme->war_rumours = G->G->war_rumours;
				}
			}
			if (sscanf(line, "%d %s %d - %s has gone bankrupt%s",
					int day, string mon, int year, string country, string dot) && dot == ".") {
				//TODO: Record bankruptcies and when they'll expire (five years later)
				werror("\e[1;33mBANKRUPT:\e[0m %s (%d %s %d)\n", country, day, mon, year);
			}
			if (sizeof(sendme) > 1) G->G->connection->send_to_all(sendme);
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
			G->G->recent_peace_treaties = G->G->war_rumours = ({ });
		}
		parse();
		pos = log->tell();
	};
	//If we need to handle deletes/recreations or file movements, watch the directory too.
	/*inot->add_watch(LOCAL_PATH + "/logs", System.Inotify.IN_CREATE | System.Inotify.IN_MOVED_TO) {
		[int event, int cookie, string path] = __ARGS__;
		write("Got a dir event! %O %O %O\n", event, cookie, path); //Moved is 128, create is 256
	};*/
}

protected void create() {
	if (G->G->inotify) destruct(G->G->inotify); //Hack. TODO: Keep the inotify and change the code it calls, rather than closing it and start over.
	object inot = G->G->inotify = System.Inotify.Instance();
	string new_file; int nomnomcookie;
	#if constant(SKIP_SAVEFILES)
	if (0)
	#endif
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
			case System.Inotify.IN_MOVED_TO: if (cookie == nomnomcookie) {nomnomcookie = 0; G->G->parser->process_savefile(path);} break;
		}
	};
	watch_game_log(inot);
	inot->set_nonblocking();
}
