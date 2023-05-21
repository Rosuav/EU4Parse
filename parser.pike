//Parsers of various kinds, but mostly the EU4 Text format (used by config files,
//save files, etc, etc). Can be invoked from the command line to parse a save file.
#if !constant(G)
mapping G = ([]); //Prevent compilation errors, but none of the G-> lookups will work
#endif
Parser.LR.Parser parser = Parser.LR.GrammarParser.make_parser_from_file("eu4_parse.grammar");

int retain_map_indices = 0;
class maparray {
	//Hybrid mapping/array. Can have key-value pairs with string keys, and also an array
	//of values, indexed numerically.
	mapping keyed = ([]);
	array indexed = ({ });
	multiset _is_auto_array = (<>);
	object addkey(string key, mixed value) {
		//HACK: Track country order even though the rest of the file isn't tracked that way
		//If Pike had an order-retaining mapping, this would be unnecessary. Hmm.
		//The main issue is that it MUST be cacheable. Maybe, instead of retaining map indices
		//like this, retain an extra key with the iteration order?
		if (key == "---" && !retain_map_indices) retain_map_indices = 2;
		if (key == "countries" && retain_map_indices == 2) retain_map_indices = 0;
		if (retain_map_indices && mappingp(value)) value |= (["_index": sizeof(keyed)]);
		keyed[key] = value;
		return this;
	}
	object addidx(mixed value) {indexed += ({value}); return this;}
	protected int _sizeof() {return sizeof(keyed) + sizeof(indexed);}
	protected mixed `[](string|int key) {return intp(key) ? indexed[key] : keyed[key];}
	protected mixed `[]=(string key, mixed val) {return keyed[key] = val;}
	protected mixed `->(string key) {
		switch (key) {
			case "keyed": return keyed;
			case "indexed": return indexed;
			case "addkey": return addkey;
			case "addidx": return addidx;
			case "_is_auto_array": return _is_auto_array;
			default: return keyed[key];
		}
	}
	protected string _sprintf(int type, mapping p) {return sprintf("<%*O/%*O>", p, keyed, p, indexed);}
	//Enable foreach(maparray();int i;mixed val) - but not, unfortunately, foreach(maparray,mixed val)
	protected Array.Iterator _get_iterator() {return get_iterator(indexed);}
	string encode_json(int flags, int indent) {
		//Only used if there's a hybrid maparray in the savefile (not in other files that don't
		//get cached in JSON) that can't be coalesced. Discard the indexed part.
		return Standards.JSON.encode(keyed, flags);
	}
}

mapping|array|maparray coalesce(mixed ret_or_brace, mixed ret) {
	if (ret_or_brace != "{") ret = ret_or_brace;
	//Where possible, simplify a maparray down to just a map or an array
	if (!sizeof(ret->indexed)) return ret->keyed;
	if (!sizeof(ret->keyed)) return ret->indexed;
	//Sometimes there's a mapping, but it also has an array of empty mappings after it.
	if (Array.all(ret->indexed, mappingp) && !Array.any(ret->indexed, sizeof)) return ret->keyed;
	return ret;
}
maparray makemapping(mixed name, mixed _, mixed val) {return maparray()->addkey(name, val);}
maparray addmapping(maparray map, mixed name, mixed _, mixed val) {
	//Note that, sometimes, an array is defined by simply assigning multiple times.
	//To properly handle arrays of arrays, we keep track of every key for which such
	//auto-collection has been done.
	if (map->_is_auto_array[name]) map[name] += ({val});
	else if (map[name]) {map[name] = ({map[name], val}); map->_is_auto_array[name] = 1;}
	else map->addkey(name, val);
	return map;
}
maparray makearray(mixed val) {return maparray()->addidx(val);}
maparray addarray(maparray arr, mixed val) {return arr->addidx(val);}
mapping emptymaparray() {return ([]);}

mapping parse_eu4txt(string|Stdio.Buffer data, function|void progress_cb, int|void debug) {
	if (stringp(data)) data = Stdio.Buffer(data); //NOTE: Restricted to eight-bit data. Since EU4 uses ISO-8859-1, that's not a problem. Be aware for future.
	data->read_only();
	if (progress_cb) progress_cb(-sizeof(data)); //Signal the start with a negative size
	string ungetch;
	string|array next() {
		if (progress_cb) progress_cb(sizeof(data));
		if (string ret = ungetch) {ungetch = 0; return ret;}
		data->sscanf("%*[ \t\r\n]");
		while (data->sscanf( "#%*s\n%*[ \t\r\n]")); //Strip comments
		if (!sizeof(data)) return "";
		if (array str = data->sscanf("\"%[^\"]\"")) {
			//Fairly naive handling of backslashes and quotes. It might be better to do this more properly.
			string lit = str[0];
			while (lit != "" && lit[-1] == '\\') {
				str = data->sscanf("%[^\"]\"");
				if (!str) break; //Should possibly be a parse error?
				lit += "\"" + str[0];
			}
			return ({"string", replace(lit, "\\\\", "\\")});
		}
		if (array digits = data->sscanf("%[-0-9.]")) {
			if (array hex = digits[0] == "0" && data->sscanf("x%[0-9a-fA-F]")) return ({"string", "0x" + hex[0]}); //Or should this be converted to decimal?
			return ({"string", digits[0]});
		}
		if (array|string word = data->sscanf("%[0-9a-zA-Z_'\x81-\xFF:]")) { //Include non-ASCII characters as letters
			word = word[0];
			//Unquoted tokens like institution_events.2 should be atoms, not atom-followed-by-number
			if (array dotnumber = data->sscanf(".%[0-9]")) word += "." + dotnumber[0];
			//Hyphenated mapping keys like maidan-e_naqsh-e_jahan should also be atoms.
			while (array hyphenated = data->sscanf("-%[0-9a-zA-Z_'\x81-\xFF:]"))
				word += "-" + hyphenated[0];
			if ((<"yes", "no">)[word]) return ({"boolean", word == "yes"});
			//Hack: this one element seems to omit the equals sign for some reason.
			if (word == "map_area_data") ungetch = "=";
			return ({"string", word});
		}
		return data->read(1);
	}
	string|array shownext() {mixed tok = next(); write("%O\n", tok); return tok;}
	//while (shownext() != ""); return 0; //Dump tokens w/o parsing
	return parser->parse(debug ? shownext : next, this);
}

//File-like object that reads from a string. Potentially does a lot of string copying.
class StringFile(string basis) {
	int pos = 0;
	int seek(int offset, string|void whence) {
		switch (whence) {
			case Stdio.SEEK_SET: pos = offset; break;
			case Stdio.SEEK_CUR: pos += offset; break;
			case Stdio.SEEK_END: pos = sizeof(basis) + offset; break;
			case 0: pos = offset + sizeof(basis) * (offset < 0); break; //Default is SEEK_END if negative, else SEEK_SET
		}
		return pos;
	}
	int tell() {return pos;}
	string(8bit) read(int len) {
		string ret = basis[pos..pos+len-1];
		pos += len;
		return ret;
	}
	void stat() { } //No file system stats available.
}

mapping(string:Image.Image) image_cache = ([]);
Image.Image|array(Image.Image|int) load_image(string fn, int|void withhash) {
	if (!image_cache[fn]) {
		string raw = Stdio.read_file(fn);
		if (!raw) return withhash ? ({0, 0}) : 0;
		sscanf(Crypto.SHA1.hash(raw), "%20c", int hash);
		function decoder = Image.ANY.decode;
		if (has_suffix(fn, ".tga")) decoder = Image.TGA.decode; //Automatic detection doesn't pick these properly.
		if (has_prefix(raw, "DDS")) {
			//Custom flag symbols, unfortunately, come from a MS DirectDraw file. Pike's image
			//library can't read this format, so we have to get help from ImageMagick.
			mapping rc = Process.run(({"convert", fn, "png:-"}));
			//assert rc=0, stderr=""
			raw = rc->stdout;
			decoder = Image.PNG._decode; //HACK: This actually returns a mapping, not just an image.
		}
		if (catch {image_cache[fn] = ({decoder(raw), hash});}) {
			//Try again via ImageMagick.
			mapping rc = Process.run(({"convert", fn, "png:-"}));
			image_cache[fn] = ({Image.PNG.decode(rc->stdout), hash});
		}
	}
	if (withhash) return image_cache[fn];
	else return image_cache[fn][0];
}

array(string) find_mod_directories(array(string) mod_filenames) {
	array config_dirs = ({G->PROGRAM_PATH});
	foreach (mod_filenames, string fn) {
		mapping info = parse_eu4txt(Stdio.read_file(G->LOCAL_PATH + "/" + fn));
		string path = info->path; if (!path) continue;
		if (!has_prefix(path, "/")) path = G->LOCAL_PATH + "/" + path;
		config_dirs += ({path});
	}
	return config_dirs;
}

array list_config_dir(array(string) config_dirs, string dir) {
	//A mod can add more files, or can replace entire files (but not parts of a file).
	//Files are then processed in affabeck regardless of their paths (I think that's how the game does it).
	mapping files = ([]);
	foreach (config_dirs, string base)
		foreach (sort(get_dir(base + dir) || ({ })), string fn)
			files[fn] = base + dir + "/" + fn;
	array filenames = indices(files); sort(lower_case(filenames[*]), filenames); //Sort case insensitively? I think this is how it's to be done?
	return files[filenames[*]];
}

//The current instance of this class is available as G->CFG
class GameConfig {
	//Everything in this class affects the EU4 checksum. Mods can change the underlying
	//files parsed into this data. It may be of value to cache these objects (it takes
	//about 3-4 seconds to do the full parse), but maybe only in memory, not in JSON.
	//If such a cache is created, it should also reference the game version somehow.
	//A save file has a 'checksum' attribute, but how do we know what matches that?
	//Maybe what we should do is build our own checksum based on the same files that the
	//game does, as listed in checksum_manifest.txt? It wouldn't matter if the hash isn't
	//the same as the game's one, as long as it changes whenever the game's hash changes.
	string active_mods; //Comma-separated signature string of all active mods. Might need game version too?
	array config_dirs;
	mapping icons = ([]), textcolors;
	mapping prov_area = ([]), map_areas = ([]), prov_colonial_region = ([]);
	mapping idea_definitions, policy_definitions, reform_definitions, static_modifiers;
	mapping trade_goods, country_modifiers, age_definitions, tech_definitions, institutions;
	mapping cot_definitions, state_edicts, terrain_definitions, imperial_reforms;
	mapping cb_types, wargoal_types, estate_agendas, country_decisions, country_missions;
	mapping tradenode_definitions, great_projects, climates;
	mapping advisor_definitions, religion_definitions, unit_definitions, culture_definitions;
	array military_tech_levels, tradenode_upstream_order, custom_ideas;
	mapping building_types; array building_id;
	mapping(string:string) manufactories = ([]); //Calculated from building_types
	mapping estate_definitions = ([]), estate_privilege_definitions = ([]);
	mapping custom_country_colors;

	//Parse a full directory of configs and merge them into one mapping
	//The specified directory name should not end with a slash.
	//If key is provided, will return only that key from each file.
	array gather_config_dir(string dir, string|void key) {
		array ret = ({([])}); //Ensure that we at least have an empty mapping even if no config files
		array filenames = list_config_dir(config_dirs, dir);
		foreach (filenames, string fn) {
			string data = Stdio.read_file(fn) + "\n";
			if (fn == "DOM_Spain_Missions.txt") data += "}\n"; //HACK: As of 20230419, this file is missing a final close brace.
			mapping cur = parse_eu4txt(data) || ([]);
			if (key) cur = cur[key] || ([]);
			ret += ({cur});
		}
		return ret;
	}
	mapping parse_config_dir(string dir, string|void key) {return `|(@gather_config_dir(dir, key));}
	mapping low_parse_savefile(string fn) { //TODO: Replace all uses with either parse_eu4txt itself or parse_config_dir
		return parse_eu4txt(Stdio.read_file(G->PROGRAM_PATH + fn));
	}

	mapping(string:string) L10n = ([]), province_localised_names;
	void parse_localisation(string data) {
		array lines = utf8_to_string("#" + data) / "\n"; //Hack: Pretend that the heading line is a comment
		foreach (lines, string line) {
			sscanf(line, "%s#", line);
			sscanf(line, " %s:%*d \"%s\"", string key, string val);
			if (key && val) L10n[key] = val;
		}
	}

	protected void create(array(string) mod_filenames) {
		config_dirs = find_mod_directories(mod_filenames);
		active_mods = mod_filenames * ",";
		mapping gfx = low_parse_savefile("/interface/core.gfx");
		//There might be multiple bitmapfonts entries. Logically, I think they should just be merged? Not sure.
		//It seems that only one of them has the textcolors block that we need.
		array|mapping tc = gfx->bitmapfonts->textcolors;
		if (arrayp(tc)) textcolors = (tc - ({0}))[0]; else textcolors = tc;
		foreach (sort(glob("*.gfx", get_dir(G->PROGRAM_PATH + "/interface"))), string fn) {
			string raw = Stdio.read_file(G->PROGRAM_PATH + "/interface/" + fn);
			//HACK: One of the files has a weird loose semicolon in it! Comment character? Unnecessary separator?
			raw = replace(raw, ";", "");
			mapping data = parse_eu4txt(raw);
			array sprites = data->?spriteTypes->?spriteType;
			if (sprites) foreach (Array.arrayify(sprites), mapping sprite)
				icons[sprite->name] += ({sprite->texturefile});
		}
		//Note that caching of l10n files has been dropped; ultimately, this entire GameConfig could be cached.
		foreach (config_dirs, string dir)
			foreach (glob("*_l_english.yml", get_dir(dir + "/localisation") || ({ })), string fn)
				parse_localisation(Stdio.read_file(dir + "/localisation/" + fn));
		map_areas = low_parse_savefile("/map/area.txt");
		foreach (map_areas; string areaname; array|maparray provinces)
			foreach (provinces;; string id) prov_area[id] = areaname;
		mapping colo_regions = parse_config_dir("/common/colonial_regions");
		foreach (colo_regions; string regionname; mapping info)
			foreach (info->provinces || ({ }), string prov) prov_colonial_region[prov] = regionname;
		terrain_definitions = low_parse_savefile("/map/terrain.txt");
		climates = low_parse_savefile("/map/climate.txt");
		retain_map_indices = 1;
		building_types = parse_config_dir("/common/buildings");
		retain_map_indices = 0;
		building_id = allocate(sizeof(building_types));
		foreach (building_types; string id; mapping info) {
			if (info->manufactory) manufactories[id] = info->show_separate ? "Special" : "Basic";
			//Map the index to the ID, counting from 1, but skipping the "manufactory" pseudo-entry
			//(not counting it and collapsing the gap).
			if (id != "manufactory") building_id[info->_index + (info->_index < building_types->manufactory->_index)] = id;
		}
		tech_definitions = ([]);
		foreach (({"adm", "dip", "mil"}), string cat) {
			mapping tech = low_parse_savefile("/common/technologies/" + cat + ".txt");
			tech_definitions[cat] = tech_definitions[cat + "_tech"] = tech;
			foreach (tech->technology; int level; mapping effects) {
				//The effects include names of buildings, eg "university = yes".
				foreach (effects; string id;) if (mapping bld = building_types[id]) {
					bld->tech_required = ({cat + "_tech", level});
					if (bld->make_obsolete) building_types[bld->make_obsolete]->obsoleted_by = id;
				}
			}
		}
		retain_map_indices = 1;
		idea_definitions = parse_config_dir("/common/ideas");
		retain_map_indices = 0;
		mapping cat_ideas = ([]);
		foreach (idea_definitions; string grp; mapping group) {
			array basic_ideas = ({ }), pos = ({ });
			mapping tidied = ([]);
			foreach (group; string id; mixed idea) {
				if (!mappingp(idea)) continue;
				int idx = m_delete(idea, "_index");
				switch (id) {
					case "start": case "bonus":
						idea->desc = grp + " (" + id + ")";
						tidied[id] = idea;
						break;
					case "trigger": case "free": case "category": case "ai_will_do":
						break; //Ignore these attributes, they're not actual ideas
					default:
						idea->desc = grp + ": " + id;
						basic_ideas += ({idea});
						pos += ({idx});
				}
			}
			sort(pos, basic_ideas);
			//tidied->category = group->category; //useful?
			tidied->ideas = basic_ideas;
			idea_definitions[grp] = tidied;
			if (group->category) cat_ideas[group->category] += ({grp});
		}
		policy_definitions = parse_config_dir("/common/policies");
		/*mapping policies = ([]);
		foreach (policy_definitions; string id; mapping info) {
			array ideas = info->allow->?full_idea_group; if (!ideas) continue;
			string cat = info->monarch_power; //Category of the policy. Usually will be one of the idea groups' categories.
			array cats = idea_definitions[ideas[*]]->category;
			sort(cats, ideas);
			if (!policies[ideas[0]]) policies[ideas[0]] = ([]);
			policies[ideas[0]][ideas[1]] = cat;
		}
		mapping counts = ([]);
		foreach (cat_ideas->ADM, string adm) {
			foreach (cat_ideas->DIP, string dip) {
				foreach (cat_ideas->MIL, string mil) {
					string cats = sort(({policies[adm][dip], policies[adm][mil], policies[dip][mil]})) * " ";
					//werror("%s %s %s -> %s\n", adm, dip, mil, cats);
					counts[cats] += ({sprintf("%s %s %s", adm - "_ideas", dip - "_ideas", mil - "_ideas")});
				}
			}
		}
		exit(0, "%O\n", counts);*/
		estate_definitions = parse_config_dir("/common/estates");
		estate_privilege_definitions = parse_config_dir("/common/estate_privileges");
		reform_definitions = parse_config_dir("/common/government_reforms");
		static_modifiers = parse_config_dir("/common/static_modifiers");
		retain_map_indices = 1;
		trade_goods = parse_config_dir("/common/tradegoods");
		institutions = parse_config_dir("/common/institutions");
		array custom_nation_ideas = gather_config_dir("/common/custom_ideas");
		retain_map_indices = 0;
		foreach (trade_goods; string id; mapping info) {
			trade_goods[info->_index + 1] = info;
			info->id = id;
		}

		//Skim over the custom ideas and collect them in order
		//The idea group keys aren't particularly meaningful, but might be of interest; they
		//mostly tell you when something got added (eg leviathan_idea_mil_modifiers).
		foreach (custom_nation_ideas, mapping ideafile) {
			array idea_groups = values(ideafile); sort(idea_groups->_index, idea_groups);
			foreach (idea_groups, mapping grp) {
				string cat = grp->category;
				grp = filter(grp, mappingp); //Some of the entries aren't actual ideas
				array ids = indices(grp), details = values(grp);
				sort(details->_index, ids, details);
				foreach (details; int i; mapping idea) {
					m_delete(idea, "_index");
					m_delete(idea, "enabled"); //Conditions under which this is available (generally a DLC that has to be active)
					m_delete(idea, "chance"); //I think this is for random generation of nations??
					//The mapping contains a handful of administrative entries, plus the
					//actual effects. So if we remove the known administrative keys, we
					//should be able to then use the rest as effects. There'll usually be
					//precisely one; as of version 1.34, only two custom ideas have more
					//(can_recruit_hussars and has_carolean), and they both are a bit
					//broken in the display. I'm not too worried.
					idea->effects = indices(idea) - ({"default", "max_level"}) - filter(indices(idea), has_prefix, "level_cost_");
					idea->effectname = "(no effect)"; //Alternatively, make this a mapping for all of them
					foreach (idea->effects, string eff) {
						string ueff = upper_case(eff);
						//The localisation keys for effects like this are a bit of a mess. For
						//instance, the "+1 missionaries" ability is localised as YEARLY_MISSIONARIES
						//but most things are MODIFIER_THING_BEING_MODIFIED - except a couple, which
						//are THING_BEING_MODIFIED_MOD. And some are even less obvious, such as:
						//idea_claim_colonies -> MODIFIER_CLAIM_COLONIES
						//cb_on_religious_enemies -> MAY_ATTACK_RELIGIOUS_ENEMIES
						//state_governing_cost -> MODIFIER_STATES_GOVERNING_COST (with the 's')
						//leader_naval_manuever -> NAVAL_LEADER_MANEUVER (one's misspelled)
						//My guess is that there's a list somewhere, probably inside the binary (as
						//it's not in the edit files anywhere), that just lists the keys. So for the
						//worst outliers, I'm not even bothering to try; instead, we just take the
						//L10n string for the idea itself. This will make the strings look different
						//from the in-game ones occasionally, but it's too hard to fix the edge cases.
						idea->effectname = L10n["YEARLY_" + ueff] || L10n["MODIFIER_" + ueff]
							|| L10n[eff] || L10n[ueff] || L10n[ueff + "_MOD"]
							|| sprintf("%s (%s)", L10n[ids[i]], eff);
						idea->effectvalue = stringp(idea[eff]) ? G->threeplace(idea[eff]) : idea[eff];
					}
					//idea->_index = custom_ideas && sizeof(custom_ideas); //useful for debugging
					idea->category = cat;
					idea->id = ids[i];
					idea->name = L10n[idea->id] || idea->id;
					idea->desc = L10n[idea->id + "_desc"] || idea->id;
					custom_ideas += ({([
						"max_level": 4, //These defaults come from defines.lua
						"level_cost_1": "0",
						"level_cost_2": "5",
						"level_cost_3": "15",
						"level_cost_4": "30",
						//Defaults for levels 5-10 also exist, but currently, no ideas specify a max_level
						//higher than 4 without also specifying every single cost. If this ends up needed,
						//consider reducing the noise by providing default costs only up to the max_level.
					]) | idea});
				}
			}
		}

		country_modifiers = parse_config_dir("/common/event_modifiers")
			| parse_config_dir("/common/parliament_issues");
		age_definitions = parse_config_dir("/common/ages");
		mapping cot_raw = parse_config_dir("/common/centers_of_trade");
		cot_definitions = ([]);
		foreach (cot_raw; string id; mapping info) {
			cot_definitions[info->type + info->level] = info;
			info->id = id;
		}
		state_edicts = parse_config_dir("/common/state_edicts");
		imperial_reforms = parse_config_dir("/common/imperial_reforms");
		cb_types = parse_config_dir("/common/cb_types");
		wargoal_types = parse_config_dir("/common/wargoal_types");
		custom_country_colors = parse_config_dir("/common/custom_country_colors");
		//estate_agendas = parse_config_dir("/common/estate_agendas"); //Not currently in use
		country_decisions = parse_config_dir("/decisions", "country_decisions");
		country_missions = ([]);
		//country_missions = parse_config_dir("/missions"); //FIXME: Broken in 1.35.3 (lingering maparray)
		advisor_definitions = parse_config_dir("/common/advisortypes");
		culture_definitions = parse_config_dir("/common/cultures");
		religion_definitions = parse_config_dir("/common/religions");
		great_projects = parse_config_dir("/common/great_projects");
		retain_map_indices = 1;
		tradenode_definitions = parse_config_dir("/common/tradenodes");
		retain_map_indices = 0;
		//Trade nodes have outgoing connections recorded, but it's more useful to us to
		//invert that and record the incoming connections.
		foreach (tradenode_definitions; string id; mapping info) {
			info->incoming += ({ }); //Ensure arrays even for end nodes
			foreach (info->outgoing = Array.arrayify(info->outgoing), mapping o)
				tradenode_definitions[o->name]->incoming += ({id});
		}
		//Build a parse order for trade nodes. Within this parse order, any node which sends
		//trade to another node must be later within the order than that node; in other words,
		//Valencia must come after Genoa, because Valencia sends trade to Genoa. This is kinda
		//backwards, but we're using this for predictive purposes, so it's more useful to see
		//the destination nodes first.
		//First, enumerate all nodes, sorted by outgoing node count. Those with zero outgoing
		//nodes (end nodes) will be first, and they have no dependencies.
		//Take the first node from the list. If it has an outgoing node that we haven't seen,
		//flag the other node as a dependency and move on; by sorting by outgoing node count,
		//we minimize the number of times that this should happen.
		//Move this node to the Done list. If it is the dependency of any other nodes, reprocess
		//those nodes, potentially recursively.
		//Iterate. Once the queue is empty, the entire map should have been sorted out, and the
		//last node on the list should be one of the origin nodes (with no incomings). Other
		//origin-only nodes may have been picked up earlier though, so don't rely on this.
		array nodes = indices(tradenode_definitions);
		sort(sizeof(values(tradenode_definitions)->outgoing[*]), nodes);
		array node_order = ({ });
		nextnode: while (sizeof(nodes)) {
			[string cur, nodes] = Array.shift(nodes);
			mapping info = tradenode_definitions[cur];
			foreach (info->outgoing, mapping o) {
				if (!has_value(node_order, o->name)) { //This is potentially O(n²) but there aren't all that many trade nodes.
					//This node sends trade to a node we haven't processed yet.
					//Delay this node until the other one has been processed.
					tradenode_definitions[o->name]->depend += ({cur});
					continue nextnode;
				}
			}
			//(because Pike doesn't have for-else blocks, this is done with a continue)
			//Okay, we didn't run into a node we haven't processed. Accept this one.
			node_order += ({cur});
			//If this is a dep of anything, reprocess them. They might depend on some
			//other unprocessed nodes, although it's unlikely; if they do, they'll get
			//plopped into another dep array.
			if (array dep = m_delete(info, "depend")) nodes = dep + nodes;
			//For convenience, allow the definitions to be accessed by index too.
			//Note that the index used in the "incoming" array is actually one-based
			//and a string, not zero-based integers as we're using.
			//Not currently needed but can be activated if it becomes useful.
			//tradenode_definitions[(string)(info->_index + 1)] = info;
		}
		tradenode_upstream_order = node_order;

		//TODO: What if a mod changes units? How does that affect this?
		unit_definitions = ([]);
		foreach (get_dir(G->PROGRAM_PATH + "/common/units"), string fn) {
			mapping data = low_parse_savefile("/common/units/" + fn);
			unit_definitions[fn - ".txt"] = data;
		}
		mapping cumul = ([
			"infantry_fire": 0, "infantry_shock": 0,
			"cavalry_fire": 0, "cavalry_shock": 0,
			"artillery_fire": 0, "artillery_shock": 0,
			"land_morale": 0,
			"military_tactics": 500,
			"maneuver_value": 0, //What's this do exactly? Does it add to your troops' maneuver? Does it multiply?
		]), techgroups = ([]);
		military_tech_levels = ({ });
		foreach (tech_definitions->mil->technology; int lvl; mapping tech) {
			foreach (cumul; string k; string cur)
				cumul[k] = cur + G->threeplace(tech[k]);
			foreach (Array.arrayify(tech->enable), string un) {
				mapping unit = unit_definitions[un];
				int pips = (int)unit->offensive_morale + (int)unit->defensive_morale
					+ (int)unit->offensive_fire + (int)unit->defensive_fire
					+ (int)unit->offensive_shock + (int)unit->defensive_shock;
				techgroups[unit->unit_type + "_" + unit->type] = pips * 1000; //Put everything in threeplace for consistency
			}
			military_tech_levels += ({cumul + techgroups});
		}

		//Parse out localised province names and map from province ID to all its different names
		province_localised_names = ([]);
		foreach (sort(get_dir(G->PROGRAM_PATH + "/common/province_names")), string fn) {
			mapping names = parse_eu4txt(Stdio.read_file(G->PROGRAM_PATH + "/common/province_names/" + fn) + "\n");
			string lang = L10n[fn - ".txt"] || fn; //Assuming that "castilian.txt" is the culture Castilian, and "TUR.txt" is the nation Ottomans
			foreach (names; string prov; array|string name) {
				if (arrayp(name)) name = name[0]; //The name can be [name, capitalname] but we don't care about the capital name
				province_localised_names[(string)prov] += ({({name, lang})});
			}
		}
	}
}

void update_checksum(object hash, array(string) dirs, string dir, string tail, int recurse) {
	foreach (list_config_dir(dirs, "/" + dir), string fn) {
		if (has_suffix(fn, tail)) hash->update(Stdio.read_file(fn));
		if (recurse && Stdio.is_dir(fn)) update_checksum(hash, dirs, fn, tail, 1);
	}
}

string calculate_checksum(array(string) mod_filenames) {
	array dirs = find_mod_directories(mod_filenames);
	mapping manifest = parse_eu4txt(Stdio.read_file(G->PROGRAM_PATH + "/checksum_manifest.txt"));
	//The hash stored in the EU4 files is the right length for MD5. However, simply using MD5
	//here doesn't give the same result. It might be that it's not MD5, it might be that I'm
	//processing the files in the wrong order, it might be that the file names themselves are
	//included in the hash, or it might be something else entirely. Fortunately I don't need
	//to perfectly match the hash (it would be nice, but it's not vital); I can just update
	//everything any time I see a change.
	//object hash = Crypto.MD5();
	object hash = Crypto.SHA1(); //Nearly as fast as MD5 and probably a better choice. SHA256 is safer but unnecessary, and a lot slower.
	foreach (manifest->directory, mapping dir)
		update_checksum(hash, dirs, dir->name, dir->file_extension, dir->sub_directories);
	return sprintf("%@x", (array)hash->digest());
}

Stdio.File pipe;
int totsize, fraction, nextmark, percentage;
void progress(int remaining) {
	if (remaining < 0) {
		//New parse just started.
		totsize = nextmark = -remaining;
		fraction = totsize / 100; //Rounds down, so the odd few bytes at the end will go above 100% very very briefly
		percentage = -1;
	}
	if (remaining < nextmark) {
		++percentage;
		nextmark -= fraction;
		pipe->write((string)({percentage}));
	}
}

mapping parse_savefile_string(string data, string|void filename) {
	if (has_prefix(data, "PK\3\4")) {
		//Compressed savefile. Consists of three files, one of which ("ai") we don't care
		//about. The other two can be concatenated after stripping their "EU4txt" headers,
		//and should be able to be parsed just like an uncompressed save. (The ai file is
		//also the exact same format, so if it's ever needed, just add a third sscanf.)
		object zip = Filesystem.Zip._Zip(StringFile(data));
		sscanf(zip->read("meta") || "", "EU4txt%s", string meta);
		sscanf(zip->read("gamestate") || "", "EU4txt%s", string state);
		if (meta && state) data = meta + state; else return 0;
	}
	else if (!sscanf(data, "EU4txt%s", data)) return 0;
	if (filename) write("Reading save file %s (%d bytes)...\n", filename, sizeof(data));
	return parse_eu4txt(data, pipe && progress);
}

mapping parse_savefile(string data, string|void filename) {
	sscanf(Crypto.SHA256.hash(data), "%32c", int hash);
	string hexhash = sprintf("%64x", hash);
	mapping cache = Standards.JSON.decode_utf8(Stdio.read_file("eu4_parse.json") || "{}");
	if (cache->hash == hexhash) return cache->data;
	mapping ret = parse_savefile_string(data, filename);
	if (!ret) return 0; //Probably an Ironman save (binary format, can't be parsed by this system).
	foreach (ret->countries; string tag; mapping c) {
		c->tag = tag; //When looking at a country, it's often convenient to know its tag (reverse linkage).
		c->owned_provinces = Array.arrayify(c->owned_provinces); //Several things will crash if you don't have a provinces array
	}
	foreach (ret->provinces; string id; mapping prov) prov->id = -(int)id;
	Stdio.write_file("eu4_parse.json", string_to_utf8(Standards.JSON.encode((["hash": hexhash, "data": ret]))));
	return ret;
}

//Pipe protocol:
//From main to us: File name followed by "\n". As soon as we receive the \n, we process the file.
//From us to main: Progress markers consisting of single byte values from 0x00 to 0x64 (0% to 100%),
//with theoretical possibility for 0x65 (101%) in the case of rounding error; and 0x7e ("~") when
//the file is completely parsed and saved into the cache.
void piperead(object pipe, object incoming) {
	while (array ret = incoming->sscanf("%s\n")) {
		[string fn] = ret;
		string raw = Stdio.read_file(fn); //Assumes ISO-8859-1, which I think is correct
		if (parse_savefile(raw, basename(fn))) pipe->write("~"); //Signal the parent. It can read it back from the cache.
	}
}

int main() {
	//Parser subprocess, invoked by parent for asynchronous parsing.
	pipe = Stdio.File(3); //We should have been given fd 3 as a pipe
	Stdio.Buffer incoming = Stdio.Buffer(), outgoing = Stdio.Buffer();
	pipe->set_buffer_mode(incoming, outgoing);
	pipe->set_nonblocking(piperead, 0, pipe->close);
	return -1;
}
