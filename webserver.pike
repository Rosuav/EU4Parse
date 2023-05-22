//HTTP handler including WebSockets
mapping(string:array(object)) websocket_groups = ([]);
mapping respond(Protocols.HTTP.Server.Request req) {
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
			[Image.Image backgrounds, int bghash] = G->G->parser->load_image(G->PROGRAM_PATH + "/gfx/custom_flags/pattern" + "2" * (flag >= 34) + ".tga", 1);
			//NOTE: Symbols for custom nations are drawn from a pool of 120, of which client states
			//are also selected, but restricted by religious group. (Actually there seem to be 121 on
			//the spritesheet, but the last one isn't available to customs.)
			//The symbol spritesheet is 4 rows of 32, each 64x64. It might be possible to find
			//this info in the edit files somewhere, but for now I'm hard-coding it.
			[mapping symbols, int symhash] = G->G->parser->load_image(G->PROGRAM_PATH + "/gfx/interface/client_state_symbols_large.dds", 1);
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
			[img, int hash] = G->G->parser->load_image(G->PROGRAM_PATH + "/gfx/flags/" + tag + ".tga", 1);
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
void persist_save() {Stdio.write_file(".eu4_preferences.json", Standards.JSON.encode(([
	"tag_preferences": tag_preferences,
	"effect_display_mode": effect_display_mode,
]), 7));}

void websocket_cmd_highlight(mapping conn, mapping data) {
	mapping prefs = persist_path(conn->group);
	if (!G->building_types[data->building]) m_delete(prefs, "highlight_interesting");
	else prefs->highlight_interesting = data->building;
	persist_save(); update_group(conn->group);
}

void websocket_cmd_fleetpower(mapping conn, mapping data) {
	mapping prefs = persist_path(conn->group);
	prefs->fleetpower = threeplace(data->power) || 1000;
	persist_save(); update_group(conn->group);
}

void websocket_cmd_goto(mapping conn, mapping data) {
	indices(G->connections)->provnotify(data->tag, (int)data->province);
}

void websocket_cmd_pin(mapping conn, mapping data) {
	mapping pins = persist_path(conn->group, "pinned_provinces");
	if (pins[data->province]) m_delete(pins, data->province);
	else /*if (last_parsed_savefile->provinces["-" + data->province])*/ pins[data->province] = max(@values(pins)) + 1;
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
	indices(G->connections)->provnotify(data->tag, (int)id);
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
	string customdir = G->LOCAL_PATH + "/custom nations";
	mapping nations = ([]);
	foreach (sort(get_dir(customdir)), string fn)
		nations[fn] = G->low_parse_savefile(Stdio.read_file(customdir + "/" + fn));
	send_update(({conn->sock}), ([
		"cmd": "customnations",
		"nations": nations,
		"custom_ideas": G->custom_ideas,
		"effect_display_mode": effect_display_mode,
		"map_colors": G->CFG->custom_country_colors->color,
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
	string customdir = G->LOCAL_PATH + "/custom nations";
	string fn = data->filename; if (!fn) return "Need a file name";
	if (!has_value(get_dir(customdir), fn)) return "File not found";
	sscanf(Stdio.read_file(customdir + "/" + fn), "# Editable: %s\n", string pwd);
	if (!pwd || pwd != data->password) return "Permission denied";
	//Okay. Let's build up a file. We'll look for keys in a specific order, to make
	//the file more consistent (no point randomly reordering stuff).
	string output = sprintf("# Editable: %s\n", pwd);
	foreach (custnat_keys, string key) {
		mapping val = data->data[key];
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

mapping get_state(string group) {
	[mapping data, array recent_peace_treaties] = get_savefile_info();
	if (!data) return (["error": "Processing savefile... "]);
	if (G->G->mods_inconsistent) return (["error": "MODS INCONSISTENT, restart parser to fix"]); //TODO: Never do this, just fix automatically
	//For the landing page, offer a menu of player countries
	if (group == "?!?") return (["menu": data->players_countries / 2]);
	string tag = group;
	if (!data->countries[tag]) {
		//See if it's a player identifier. These get rechecked every get_state
		//because they will track the player through tag changes (eg if you were
		//Castille (CAS) and you form Spain (SPA), your tag will change, but you
		//want to see data for Spain now plsthx).
		foreach (data->players_countries / 2, [string name, string trytag])
			if (lower_case(tag) == lower_case(name)) tag = trytag;
	}
	mapping country = data->countries[tag];
	if (!country) return (["error": "Country/player not found: " + group]);
	mapping ret = (["tag": tag, "self": data->countries[tag], "highlight": ([]), "recent_peace_treaties": recent_peace_treaties]);
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
				string folded = lower_case(tryme); //TODO: Fold to ASCII for the search
				int pos = search(folded, term);
				if (pos == -1) continue;
				int end = pos + sizeof(term);
				string before = tryme[..pos-1], match = tryme[pos..end-1], after = tryme[end..];
				if (lang != "") {before = prov->name + " (" + lang + ": " + before; after += ")";}
				results += ({({(int)(id - "-"), before, match, after})});
				order += ({folded}); //Is it better to sort by the folded or by the tryme?
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
	sock->onmessage = ws_msg;
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
	if (socks && sizeof(socks)) send_update(websocket_groups[tag], get_state(tag) | (["parsing": G->parsing]));
}
void send_updates_all() {foreach (websocket_groups; string tag;) update_group(tag);}

protected void create(string name) {
	Protocols.WebSocket.Port(http_handler, ws_handler, 8087, "::");
}
