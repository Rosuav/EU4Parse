//HTTP handler including WebSockets
mapping(string:array(object)) websocket_groups = ([]);
multiset(object) notifiers = (<>);

mapping respond(Protocols.HTTP.Server.Request req) {
	if (req->not_query == "/test") return (["type": "text/html", "data": "Test!\n"]);
	mapping mimetype = (["eu4_parse.js": "text/javascript", "eu4_parse.css": "text/css"]);
	if (string ty = mimetype[req->not_query[1..]]) return ([
		"type": ty, "file": Stdio.File(req->not_query[1..]),
		"extra_heads": (["Access-Control-Allow-Origin": "*"]),
	]);
	if (req->not_query == "/" || sscanf(req->not_query, "/tag/%s", string tag)) return ([
		"type": "text/html",
		"data": sprintf(#"<!DOCTYPE HTML><html lang=en>
<head><title>EU4 Savefile Analysis</title><link rel=stylesheet href=\"/eu4_parse.css\"><style id=ideafilterstyles></style></head>
<body><script>
let ws_code = new URL(\"/eu4_parse.js\", location.href), ws_type = \"eu4\", ws_group = \"%s\";
let ws_sync = null; import('https://sikorsky.rosuav.com/static/ws_sync.js').then(m => ws_sync = m);
</script><main></main></body></html>
", Protocols.HTTP.uri_decode(tag || "?!?")),
	]);
	if (sscanf(req->not_query, "/flags/%[A-Z_a-z0-9]%[-0-9A-F].%s", string tag, string color, string ext) && tag != "" && ext == "png") {
		//Generate a country flag in PNG format
		string etag; Image.Image img;
		if (tag == "Custom") {
			//Custom nation flags are defined by a symbol and four colours.
			sscanf(color, "-%d-%d-%d-%d-%d%s", int symbol, int flag, int color1, int color2, int color3, color);
			if (!color || sizeof(color) != 7 || color[0] != '-') color = "";
			//If flag (the "Background" in the UI) is 0-33 (1-34 in the UI), it is a two-color
			//flag defined in gfx/custom_flags/pattern.tga, which is a spritesheet of 128x128
			//sections, ten per row, four rows. Replace red with color1, green with color2.
			//If it is 34-53 (35-54 in the UI), it is a three-color flag from pattern2.tga,
			//also ten per row, two rows, also 128x128. Replace blue with color3.
			//(Some of this could be parsed out of custom_country_colors. Hardcoded for now.)
			[Image.Image backgrounds, int bghash] = G->G->parser->load_image(PROGRAM_PATH + "/gfx/custom_flags/pattern" + "2" * (flag >= 34) + ".tga", 1);
			//NOTE: Symbols for custom nations are drawn from a pool of 120, of which client states
			//are also selected, but restricted by religious group. (Actually there seem to be 121 on
			//the spritesheet, but the last one isn't available to customs.)
			//The symbol spritesheet is 4 rows of 32, each 64x64. It might be possible to find
			//this info in the edit files somewhere, but for now I'm hard-coding it.
			[mapping symbols, int symhash] = G->G->parser->load_image(PROGRAM_PATH + "/gfx/interface/client_state_symbols_large.dds", 1);
			//Note that if the definitions of the colors change but the spritesheets don't,
			//we'll generate the exact same etag. Seems unlikely, and not that big a deal anyway.
			etag = sprintf("W/\"%x-%x-%d-%d-%d-%d-%d%s\"", bghash, symhash, symbol, flag, color1, color2, color3, color);
			if (has_value(req->request_headers["if-none-match"] || "", etag)) return (["error": 304]); //Already in cache
			if (flag >= 34) flag -= 34; //Second sheet of patterns
			int bgx = 128 * (flag % 10), bgy = 128 * (flag / 10);
			int symx = 64 * (symbol % 32), symy = 64 * (symbol / 32);
			img = backgrounds->copy(bgx, bgy, bgx + 127, bgy + 127)
				->change_color(255, 0, 0, @(array(int))G->CFG->custom_country_colors->flag_color[color1])
				->change_color(0, 255, 0, @(array(int))G->CFG->custom_country_colors->flag_color[color2])
				->change_color(0, 0, 255, @(array(int))G->CFG->custom_country_colors->flag_color[color3])
				->paste_mask(
					symbols->image->copy(symx, symy, symx + 63, symy + 63),
					symbols->alpha->copy(symx, symy, symx + 63, symy + 63),
				32, 32);
		}
		else {
			//Standard flags are loaded as-is.
			[img, int hash] = G->G->parser->load_image(PROGRAM_PATH + "/gfx/flags/" + tag + ".tga", 1);
			if (!img) return 0;
			//For colonial nations, instead of using the country's own tag (eg C03), we get
			//a flag definition based on the parent country and a colour.
			if (!color || sizeof(color) != 7 || color[0] != '-') color = "";
			//NOTE: Using weak etags since the result will be semantically identical, but
			//might not be byte-for-byte (since the conversion to PNG might change it).
			etag = sprintf("W/\"%x%s\"", hash, color);
			if (has_value(req->request_headers["if-none-match"] || "", etag)) return (["error": 304]); //Already in cache
		}
		if (sscanf(color, "-%2x%2x%2x", int r, int g, int b))
			img = img->copy()->box(img->xsize() / 2, 0, img->xsize(), img->ysize(), r, g, b);
		//TODO: Mask flags off with shield_mask.tga or shield_fancy_mask.tga or small_shield_mask.tga
		//I'm using 128x128 everywhere, but the fancy mask (the largest) is only 92x92. For inline
		//flags in text, small_shield_mask is the perfect 24x24.
		return ([
			"type": "image/png", "data": Image.PNG.encode(img),
			"extra_heads": (["ETag": etag, "Cache-Control": "max-age=604800"]),
		]);
	}
	if (sscanf(req->not_query, "/load/%s", string fn) && fn) {
		if (fn != "") {
			G->G->parser->process_savefile(SAVE_PATH + "/" + fn);
			return (["type": "text/plain", "data": "Loaded"]);
		}
		//Show a list of loadable files
		array(string) files = get_dir(SAVE_PATH);
		sort(file_stat((SAVE_PATH + "/" + files[*])[*])->mtime[*] * -1, files);
		return ([
			"type": "text/html",
			"data": sprintf(#"<!DOCTYPE HTML><html lang=en>
<head><title>EU4 Savefile Analysis</title><link rel=stylesheet href=\"/eu4_parse.css\"></head>
<body><main><h1>Select a file</h1><ul>%{<li><a href=%q>%<s</a></li>%}</ul></main></body></html>
", files),
		]);
	}
}
constant NOT_FOUND = (["error": 404, "type": "text/plain", "data": "Not found"]);
void http_handler(Protocols.HTTP.Server.Request req) {req->response_and_finish(respond(req) || NOT_FOUND);}

//Persisted prefs, keyed by country tag or player name. They apply to all connections for that user (to prevent inexplicable loss of config on dc).
mapping(string:mapping(string:mixed)) tag_preferences = ([]);
mapping(string:string) effect_display_mode = ([]); //If an effect is not listed, display it as a number (threeplace)
//tag_preferences->Rosuav ==> prefs for Rosuav, regardless of country
//tag_preferences->CAS ==> prefs for Castille, regardless of player
//...->highlight_interesting == building ID highlighted for further construction
//...->group_selection == slash-delimited path to the group of provinces to cycle through
//...->cycle_province_ids == array of (string) IDs to cycle through; if absent or empty, use default algorithm
//...->pinned_provinces == mapping of (string) IDs to sequential numbers
//...->search == current search term
mapping persist_path(string ... parts)
{
	mapping ret = tag_preferences;
	foreach (parts, string idx)
	{
		if (undefinedp(ret[idx])) ret[idx] = ([]);
		ret = ret[idx];
	}
	return ret;
}
void persist_save() {Stdio.write_file("preferences.json", Standards.JSON.encode(([
	"tag_preferences": tag_preferences,
	"effect_display_mode": effect_display_mode,
]), 7));}

void websocket_cmd_highlight(mapping conn, mapping data) {
	mapping prefs = persist_path(conn->group);
	if (!G->CFG->building_types[data->building]) m_delete(prefs, "highlight_interesting");
	else prefs->highlight_interesting = data->building;
	persist_save(); update_group(conn->group);
}

void websocket_cmd_fleetpower(mapping conn, mapping data) {
	mapping prefs = persist_path(conn->group);
	prefs->fleetpower = threeplace(data->power) || 1000;
	persist_save(); update_group(conn->group);
}

void websocket_cmd_goto(mapping conn, mapping data) {
	indices(notifiers)->provnotify(data->tag, (int)data->province);
}

void websocket_cmd_pin(mapping conn, mapping data) {
	mapping pins = persist_path(conn->group, "pinned_provinces");
	if (pins[data->province]) m_delete(pins, data->province);
	else /*if (G->G->last_parsed_savefile->provinces["-" + data->province])*/ pins[data->province] = max(@values(pins)) + 1;
	persist_save(); update_group(conn->group);
}

void websocket_cmd_cyclegroup(mapping conn, mapping data) {
	mapping prefs = persist_path(conn->group);
	if (!data->cyclegroup || data->cyclegroup == "") m_delete(prefs, "cyclegroup");
	else prefs->cyclegroup = data->cyclegroup;
	m_delete(G->G->provincecycle, conn->group);
	persist_save(); update_group(conn->group);
}

void websocket_cmd_cycleprovinces(mapping conn, mapping data) {
	mapping prefs = persist_path(conn->group);
	if (prefs->cyclegroup != data->cyclegroup) return;
	if (!prefs->cyclegroup || !arrayp(data->provinces)) m_delete(G->G->provincecycle, conn->group);
	else G->G->provincecycle[conn->group] = (array(string))(array(int))data->provinces - ({"0"});
	persist_save(); update_group(conn->group);
}

void websocket_cmd_cyclenext(mapping conn, mapping data) {
	mapping prefs = persist_path(conn->group);
	string country = conn->group;
	if (!arrayp(G->G->provincecycle[country])) return; //Can't use this for the default cycling of "interesting" provinces. Pick explicitly.
	[int id, array rest] = Array.shift(G->G->provincecycle[country]);
	G->G->provincecycle[country] = rest + ({id});
	update_group(country);
	indices(notifiers)->provnotify(data->tag, (int)id);
}

void websocket_cmd_search(mapping conn, mapping data) {
	mapping prefs = persist_path(conn->group);
	prefs->search = stringp(data->term) ? lower_case(data->term) : "";
	persist_save(); update_group(conn->group);
}

void websocket_cmd_set_effect_mode(mapping conn, mapping data) {
	if (!stringp(data->effect)) return;
	if (!has_value("threeplace percent boolean" / " ", data->mode)) return;
	effect_display_mode[data->effect] = data->mode;
	persist_save();
	//Note that currently-connected clients do not get updated.
}

void websocket_cmd_listcustoms(mapping conn, mapping data) {
	string customdir = LOCAL_PATH + "/custom nations";
	mapping nations = ([]);
	foreach (sort(get_dir(customdir)), string fn)
		nations[fn] = G->G->parser->parse_eu4txt(Stdio.read_file(customdir + "/" + fn));
	send_update(({conn->sock}), ([
		"cmd": "customnations",
		"nations": nations,
		"custom_ideas": G->CFG->custom_ideas,
		"effect_display_mode": effect_display_mode,
		"map_colors": G->CFG->custom_country_colors->color,
	]));
}

void websocket_cmd_analyzebattles(mapping conn, mapping msg) {
	//Collect some useful info about the units a country is using
	//NOTE: Can be used for countries you're not at war with (yet), to allow for
	//Luke 14:31-32 style analysis, but be aware that it may provide information
	//that you couldn't have seen in-game about the precise composition of the
	//opposing army. (You can see the totals across the entire nation, but not
	//how many in any given stack, unless they're near your borders.) Unlikely
	//to be of massively unbalancing value, since you could usually see one army
	//and deduce that others will be similar.
	mapping data = G->G->last_parsed_savefile; if (!data) return;
	array countries = ({
		//Could add others if necessary eg allies/subjects. For now, reanalyze with those tags.
		data->countries[group_to_tag(data, conn->group)],
		data->countries[msg->tag],
	});
	if (has_value(countries, 0)) return;
	array infos = ({ });
	int combat_width = 15;
	foreach (countries, mapping country) {
		mapping info = (["tag": country->tag, "unit_details": ([])]);
		foreach (country->sub_unit; string type; string id) {
			info->unit_details[id] = ([
				"type": type, //eg "infantry"
				"defn": G->CFG->unit_definitions[id],
			]);
		}
		info->armies = ({ });
		foreach (Array.arrayify(country->army), mapping raw) {
			mapping army = ([
				"name": raw->name,
				//TODO: General's pips, if any; otherwise ({0,0,0,0})
				//Also general's trait, if any.
				//Not supported by this tool, but what happens if two armies with two generals
				//combine, and both have traits? Do you get both?
				"regiments": Array.arrayify(raw->regiment), //TODO: Is the arrayify needed? Probably.
				"infantry": 0, "cavalry": 0, "artillery": 0,
			]);
			foreach (army->regiments, mapping reg) army[info->unit_details[reg->type]->type]++;
			info->armies += ({army});
		}
		info->mod = ([]);
		mapping all = G->G->analysis->all_country_modifiers(data, country);
		//TODO: Province bonuses?? local_{defender,attacker}_dice_roll_bonus, own_territory_dice_roll_bonus,
		//terrain, river crossing, landing from ship...
		foreach (({
			"military_tactics", "discipline",
			"infantry_fire", "infantry_shock",
			"cavalry_fire", "cavalry_shock",
			"artillery_fire", "artillery_shock",
			"infantry_power", "cavalry_power", "artillery_power",
			"morale_damage", "morale_damage_received",
			"global_defender_dice_roll_bonus", "global_attacker_dice_roll_bonus",
		}), string mod) info->mod[mod] = all[mod] || 0;
		info->mod->land_morale = all->base_land_morale * (1000 + all->land_morale) / 1000;
		int wid = all->combat_width + 15; //The base combat width is in defines.lua so we just add 15 manually
		if (wid > combat_width) combat_width = wid; //NOTE: If reworking this for naval combat, remember that naval combat width is per side.
		infos += ({info});
	}
	send_update(({conn->sock}), ([
		"cmd": "analyzebattles",
		"countries": infos,
		"combat_width": combat_width,
	]));
}

constant custnat_keys = "name adjective country_colors index graphical_culture technology_group religion "
			"government government_reform government_rank idea culture monarch heir queen" / " ";
mapping custnat_handlers = ([
	"country_colors": lambda(mapping col) {
		return sprintf(#"{
	flag=%s
	color=%s
	symbol_index=%s
	flag_colors={
		%{%s %}
	}
}", col->flag, col->color, col->symbol_index, col->flag_colors);
	},
	"idea": lambda(array idea) {
		return "{" + sprintf(#"
	{
		level=%s
		index=%s
		name=%q
		desc=%q
	}", idea->level[*], idea->index[*], idea->name[*], idea->desc[*]) * "" + "\n}";
	},
	"monarch": lambda(mapping mon) {
		return sprintf(#"{
	admin=%s
	diplomacy=%s
	military=%s
	age=%s
	religion=%s
	culture=%q
	female=%s
	name=%q
	dynasty=%q
	is_null=%s
	personality={
%{		%q
%}	}
}", mon->admin, mon->diplomacy, mon->military, mon->age, mon->religion, mon->culture || "",
		mon->female ? "yes" : "no", mon->name || "", mon->dynasty || "", mon->is_null ? "yes" : "no",
		mon->personality);
	},
	"heir": "monarch", "queen": "monarch",
]);

string save_custom_nation(mapping data) {
	//In order to save a custom nation:
	//1) The nation definition file must already exist
	//2) It must begin with a manually-added comment line starting "# Editable: "
	//3) The save request must include the rest of the line, which is a sort of password
	//4) All attributes to be saved must be included.
	//It's up to you to make sure the file actually is loadable. The easiest way is to
	//make minor, specific changes to an existing custom nation.
	string customdir = LOCAL_PATH + "/custom nations";
	string fn = data->filename; if (!fn) return "Need a file name";
	if (!has_value(get_dir(customdir), fn)) return "File not found";
	sscanf(Stdio.read_file(customdir + "/" + fn), "# Editable: %s\n", string pwd);
	if (!pwd || pwd != data->password) return "Permission denied";
	//Okay. Let's build up a file. We'll look for keys in a specific order, to make
	//the file more consistent (no point randomly reordering stuff).
	string output = sprintf("# Editable: %s\n", pwd);
	foreach (custnat_keys, string key) {
		mixed val = data->data[key];
		if (stringp(val) || intp(val)) {
			//Strings that look like numbers get output without quotes
			if ((string)(int)val == val) output += sprintf("%s=%d\n", key, (int)val);
			else output += sprintf("%s=%q\n", key, val);
		}
		else if (arrayp(val) || mappingp(val)) {
			function|string f = custnat_handlers[key];
			if (stringp(f)) f = custnat_handlers[f]; //Alias one to another
			if (f) output += sprintf("%s=%s\n", key, f(val));
		}
	}
	Stdio.write_file(customdir + "/" + fn, output);
	return "Saved.";
}

void websocket_cmd_savecustom(mapping conn, mapping data) {
	string ret = save_custom_nation(data);
	send_update(({conn->sock}), ([
		"cmd": "savecustom",
		"result": ret,
	]));
}

//For a group like "TUR", return it unchanged; but a group like "Rosuav" will be
//translated into the actual country tag that that player is controlling.
string group_to_tag(mapping data, string tag) {
	if (!data->countries[tag] && data->players_countries) {
		//See if it's a player identifier. These get rechecked every get_state
		//because they will track the player through tag changes (eg if you were
		//Castille (CAS) and you form Spain (SPA), your tag will change, but you
		//want to see data for Spain now plsthx).
		foreach (data->players_countries / 2, [string name, string trytag])
			if (lower_case(tag) == lower_case(name)) return trytag;
	}
	return tag;
}

mapping get_state(string group) {
	mapping data = G->G->last_parsed_savefile;
	if (G->G->error) return (["error": G->G->error]);
	if (!data) return (["error": "Processing savefile... "]);
	//For the landing page, offer a menu of player countries
	if (group == "?!?") return (["menu": data->players_countries / 2]);
	string tag = group_to_tag(data, group);
	mapping country = data->countries[tag];
	if (!country) return (["error": "Country/player not found: " + group]);
	mapping ret = (["tag": tag, "self": data->countries[tag], "highlight": ([]), "recent_peace_treaties": G->G->recent_peace_treaties]);
	ret->capital_province = data->provinces["-" + data->countries[tag]->capital];
	G->G->analysis->analyze(data, group, tag, ret, persist_path(group));
	multiset players = (multiset)((data->players_countries || ({ })) / 2)[*][1]; //Normally, show all wars involving players.
	if (!players[tag]) players = (<tag>); //But if you switch to a non-player country, show that country's wars instead.
	G->G->analysis->analyze_wars(data, players, ret);
	G->G->analysis->analyze_flagships(data, ret);
	//Enumerate available building types for highlighting. TODO: Check if some changes here need to be backported to the console interface.
	mapping available = ([]);
	mapping tech = country->technology;
	int have_mfg = 0;
	foreach (G->CFG->building_types; string id; mapping bldg) {
		[string techtype, int techlevel] = bldg->tech_required || ({"", 100}); //Ignore anything that's not a regular building
		if ((int)tech[techtype] < techlevel) continue; //Hide IDs you don't have the tech to build
		if (bldg->manufactory && !bldg->show_separate) {have_mfg = 1; continue;} //Collect regular manufactories under one name
		if (bldg->influencing_fort) continue; //You won't want to check forts this way
		available[id] = ([
			"id": id, "name": L10N("building_" + id),
			"cost": bldg->manufactory ? 500 : (int)bldg->cost,
			"raw": bldg,
		]);
	}
	//Restrict to only those buildings for which you don't have an upgrade available
	foreach (indices(available), string id) if (available[G->CFG->building_types[id]->obsoleted_by]) m_delete(available, id);
	if (have_mfg) available->manufactory = ([ //Note that building_types->manufactory is technically valid
		"id": "manufactory", "name": "Manufactory (standard)",
		"cost": 500,
	]);
	array bldg = values(available); sort(indices(available), bldg);
	ret->buildings_available = bldg;
	mapping prefs = persist_path(group);
	mapping pp = prefs->pinned_provinces || ([]);
	array ids = indices(pp); sort(values(pp), ids);
	ret->pinned_provinces = map(ids) {return ({__ARGS__[0], data->provinces["-" + __ARGS__[0]]->?name || "(unknown)"});};
	if (prefs->cyclegroup) {ret->cyclegroup = prefs->cyclegroup; ret->cycleprovinces = G->G->provincecycle[group];}

	string term = prefs->search;
	array results = ({ }), order = ({ });
	if (term != "") {
		foreach (sort(indices(data->provinces)), string id) { //Sort by ID for consistency
			mapping prov = data->provinces[id];
			foreach (({({prov->name, ""})}) + (G->CFG->province_localised_names[id - "-"]||({ })), [string|array(string) tryme, string lang]) {
				//I think this is sometimes getting an array of localised names
				//(possibly including a capital name??). Should we pick one, or
				//search all?
				if (arrayp(tryme)) tryme = tryme[0];
				string folded = lower_case(tryme);
				//For searching purposes, it's convenient to allow "München" to match "munc".
				string decomp = Unicode.normalize(folded, "NFKD");
				decomp = replace(decomp, (string)enumerate(0x70, 1, 0x300) / 1, ""); //Remove combining diacritical marks
				string sans_dia = Unicode.normalize(decomp, "NFC");
				//So we now have three strings: the original, the lower-cased, and the no-diacriticals.
				//It's quite likely that they're all the same length, but not guaranteed.
				//So what do we do? We match against any of them.
				int pos = -1; string morph;
				foreach (({tryme, folded, sans_dia}), morph)
					if ((pos = search(morph, term)) != -1) break;
				if (pos == -1) continue;
				//Converting "München" into "munchen" won't break the offset calculations, so
				//pretend that "munc" matched "Münc" in the highlight. However, if the length
				//has changed, show the lower-cased version. Note that this could give bizarre
				//results if there are multiple characters that change length, such that the
				//overall string happens to end up just as long as the original; this seems a
				//rather unlikely possibility, so I won't worry about it for now. (It's just a
				//display issue anyway.)
				if (sizeof(morph) != sizeof(tryme)) tryme = morph;
				int end = pos + sizeof(term);
				string before = tryme[..pos-1], match = tryme[pos..end-1], after = tryme[end..];
				if (lang != "") {before = prov->name + " (" + lang + ": " + before; after += ")";}
				results += ({({(int)(id - "-"), before, match, after})});
				order += ({morph}); //Is it better to sort by the folded or by the tryme?
				break;
			}
			if (sizeof(results) >= 25) break;
		}
		if (sizeof(results) < 25) foreach (sort(indices(ret->countries)), string t) {
			string tryme = ret->countries[t]->name + " (" + t + ")";
			string folded = lower_case(tryme); //TODO: As above. Also, dedup if possible.
			int pos = search(folded, term);
			if (pos == -1) continue;
			int end = pos + sizeof(term);
			string before = tryme[..pos-1], match = tryme[pos..end-1], after = tryme[end..];
			results += ({({t, before, match, after})});
			order += ({folded});
			if (sizeof(results) >= 25) break;
		}
	}
	sort(order, results); //Sort by name for the actual results. So if it's truncated to 25, it'll be the first 25 by (string)id, but they'll be in name order.
	ret->search = (["term": term, "results": results]);

	//Scan all provinces for whether you've discovered them or not
	//Deprecated in favour of the province_info[] mapping
	mapping discov = ret->discovered_provinces = ([]);
	foreach (data->provinces; string id; mapping prov) if (has_value(Array.arrayify(prov->discovered_by), tag)) discov[id - "-"] = 1;

	return ret;
}

void ws_msg(Protocols.WebSocket.Frame frm, mapping conn)
{
	mixed data;
	if (catch {data = Standards.JSON.decode(frm->text);}) return; //Ignore frames that aren't text or aren't valid JSON
	if (!stringp(data->cmd)) return;
	if (data->cmd == "init")
	{
		//Initialization is done with a type and a group.
		//The type has to be "eu4", and exists for convenient compatibility with StilleBot.
		//The group is a country tag or player name as a string.
		if (conn->type) return; //Can't init twice
		if (data->type != "eu4") return; //Ignore any unknown types.
		//Note that we don't validate the group here, beyond basic syntactic checks. We might have
		//the wrong save loaded, in which case the precise country tag won't yet exist.
		if (!stringp(data->group)) return;
		write("Socket connection established for %O\n", data->group);
		conn->type = data->type; conn->group = data->group;
		websocket_groups[conn->group] += ({conn->sock});
		send_update(({conn->sock}), get_state(data->group));
		return;
	}
	if (function handler = this["websocket_cmd_" + data->cmd]) handler(conn, data);
	else write("Message: %O\n", data);
}

void ws_msg_bouncer(Protocols.WebSocket.Frame frm, mapping conn) {G->G->ws_msg(frm, conn);}

void ws_close(int reason, mapping conn)
{
	if (conn->type == "eu4") websocket_groups[conn->group] -= ({conn->sock});
	m_delete(conn, "sock"); //De-floop
}

void ws_handler(array(string) proto, Protocols.WebSocket.Request req)
{
	if (req->not_query != "/ws") {req->response_and_finish(NOT_FOUND); return;}
	Protocols.WebSocket.Connection sock = req->websocket_accept(0);
	sock->set_id((["sock": sock])); //Minstrel Hall style floop
	sock->onmessage = ws_msg_bouncer;
	sock->onclose = ws_close;
}

void send_update(array(object) socks, mapping state) {
	if (!socks || !sizeof(socks)) return;
	string resp = Standards.JSON.encode((["cmd": "update"]) | state, 4);
	foreach (socks, object sock)
		if (sock && sock->state == 1) sock->send_text(resp);
}

void send_to_all(mapping sendme) {
	string msg = Standards.JSON.encode(sendme);
	foreach (websocket_groups;; array socks)
		foreach (socks, object sock)
			if (sock && sock->state == 1) sock->send_text(msg);
}

void update_group(string tag) {
	array socks = websocket_groups[tag];
	if (socks && sizeof(socks)) send_update(websocket_groups[tag], get_state(tag) | (["parsing": G->G->parser->parsing]));
}
void send_updates_all() {foreach (websocket_groups; string tag;) update_group(tag);}

class Connection(Stdio.File sock) {
	Stdio.Buffer incoming = Stdio.Buffer(), outgoing = Stdio.Buffer();
	string notify;

	protected void create() {
		sock->set_buffer_mode(incoming, outgoing);
		sock->set_nonblocking(sockread, 0, sockclosed);
	}
	void sockclosed() {notifiers[this] = 0; sock->close();}

	string find_country(mapping data, string country) {
		foreach (data->players_countries / 2, [string name, string tag])
			if (lower_case(country) == lower_case(name)) country = tag;
		if (data->countries[country]) return country;
	}

	void provnotify(string country, int province) {
		//A request has come in (from the web) to notify a country to focus on a province.
		if (!notify) return;
		string tag = find_country(G->G->last_parsed_savefile, notify);
		if (tag != country) return; //Not found, or not for us.
		outgoing->sprintf("provfocus %d\n", province);
		sock->write(""); //Force a write callback (shouldn't be necessary??)
	}

	void sockread() {
		while (array ret = incoming->sscanf("%s\n")) {
			string cmd = String.trim(ret[0]), arg = "";
			sscanf(cmd, "%s %s", cmd, arg);
			switch (cmd) {
				case "notify":
					notifiers[this] = 0;
					if (sscanf(arg, "province %s", arg)) ; //notiftype = "province";
					else sock->write("Warning: Old 'notify' no longer supported, using 'notify province' instead\n");
					notify = arg; notifiers[this] = 1;
					break;
				default: sock->write(sprintf("Unknown command %O\n", cmd)); break;
			}
		}
	}
}

void sock_connected(object mainsock) {while (object sock = mainsock->accept()) Connection(sock);}

object tlsctx;
class trytls {
	inherit Protocols.WebSocket.Request;
	void opportunistic_tls(string s) {
		SSL.File ssl = SSL.File(my_fd, tlsctx);
		ssl->accept(s);
		attach_fd(ssl, server_port, request_callback);
	}
}

protected void create(string name) {
	mapping cfg = ([]);
	catch {cfg = Standards.JSON.decode(Stdio.read_file("preferences.json"));};
	if (mappingp(cfg) && cfg->tag_preferences) tag_preferences = cfg->tag_preferences;
	if (mappingp(cfg) && cfg->effect_display_mode) effect_display_mode = cfg->effect_display_mode;
	G->G->ws_msg = ws_msg;
	if (G->G->have_sockets) return; //Hack: Don't relisten on sockets on code reload
	Protocols.WebSocket.Port(http_handler, ws_handler, 8087, "::")->request_program = Function.curry(trytls)(ws_handler);
	tlsctx = SSL.Context();
	array|zero wildcard = ({"*"});
	foreach (({"", "_local"}), string tag) {
		string cert = Stdio.read_file("../stillebot/certificate" + tag + ".pem");
		string key = Stdio.read_file("../stillebot/privkey" + tag + ".pem");
		if (key && cert) {
			string pk = Standards.PEM.simple_decode(key);
			array certs = Standards.PEM.Messages(cert)->get_certificates();
			tlsctx->add_cert(pk, certs, wildcard);
			wildcard = UNDEFINED; //Only one wildcard cert.
		}
	}
	Stdio.Port mainsock = Stdio.Port();
	mainsock->bind(1444, sock_connected, "::", 1);
	G->G->have_sockets = 1;
}
