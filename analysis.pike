//Various functions to do different forms of savefile analysis.
//The primary entrypoint is analyze() which receives a savefile (as a mapping),
//a country (and optionally player name) to analyze, and the user prefs; it will
//return the useful and interesting data as a mapping.

//Note that analyzing may mutate the savefile mapping, but only to cache information
//that would not change without the savefile itself changing.

void analyze_cot(mapping data, string name, string tag, mapping write) {
	mapping country = data->countries[tag];
	mapping(string:int) area_has_level3 = country->area_has_level3 = ([]);
	array maxlvl = ({ }), upgradeable = ({ }), developable = ({ });
	foreach (country->owned_provinces, string id) {
		mapping prov = data->provinces["-" + id];
		if (!prov->center_of_trade) continue;
		int dev = (int)prov->base_tax + (int)prov->base_production + (int)prov->base_manpower;
		int need = prov->center_of_trade == "1" ? 10 : 25;
		array desc = ({
			sprintf("%s %04d %s", prov->owner, 9999-dev, prov->name), //Sort key
			prov->center_of_trade, id, dev, prov->name, L10N(prov->trade),
		});
		if (prov->center_of_trade == "3") {maxlvl += ({desc}); area_has_level3[G->CFG->prov_area[id]] = (int)id;}
		else if (dev >= need) upgradeable += ({desc});
		else developable += ({desc});
	}
	sort(maxlvl); sort(upgradeable); sort(developable);
	int maxlevel3 = sizeof(Array.arrayify(country->merchants->?envoy)); //You can have as many lvl 3 CoTs as you have merchants.
	int level3 = sizeof(maxlvl); //You might already have some.
	int maxprio = 0;
	string|mapping colorize(string color, array info, int prio) {
		//Colorize if it's interesting. It can't be upgraded if not in a state; also, not all level 2s
		//can become level 3s, for various reasons.
		[string key, string cotlevel, string id, int dev, string provname, string tradenode] = info;
		array have_states = data->map_area_data[G->CFG->prov_area[id]]->?state->?country_state->?country;
		string noupgrade;
		if (!have_states || !has_value(have_states, tag)) noupgrade = "is territory";
		else if (cotlevel == "2") {
			if (area_has_level3[G->CFG->prov_area[id]]) noupgrade = "other l3 in area";
			else if (++level3 > maxlevel3) noupgrade = "need merchants";
		}
		if (!noupgrade) maxprio = max(prio, maxprio);
		return ([
			"id": id, "dev": dev, "name": provname, "tradenode": tradenode,
			"noupgrade": noupgrade || "",
			"level": (int)cotlevel, "interesting": !noupgrade && prio,
		]);
	}
	write->cot = ([
		"level3": level3, "max": maxlevel3,
		"upgradeable": colorize("", upgradeable[*], 2),
		"developable": colorize("", developable[*], 1),
	]);
	write->cot->maxinteresting = maxprio;
}

object calendar(string date) {
	sscanf(date, "%d.%d.%d", int year, int mon, int day);
	return Calendar.Gregorian.Day(year, mon, day);
}

//Substitute string args into strings. Currently does not support the full "and parse another
//entire block of code" substitution form.
mixed substitute_args(mixed trigger, mapping args) {
	if (stringp(trigger)) return replace(trigger, args);
	if (arrayp(trigger)) return substitute_args(trigger[*], args);
	if (mappingp(trigger)) return mkmapping(
		substitute_args(indices(trigger)[*], args),
		substitute_args(values(trigger)[*], args));
	return trigger; //Anything unknown presumably can't have replacements done (eg integers).
}

//Resolve a relative reference to the actual value. See https://eu4.paradoxwikis.com/Scopes for concepts and explanation.
string resolve_scope(mapping data, array(mapping) scopes, string value, string|void attr) {
	if (!attr) attr = "tag";
	switch (value) {
		case "ROOT": return scopes[0][attr];
		case "FROM": return scopes[-2][attr]; //Not sure if this is right
		case "PREV": return scopes[-2][attr];
		case "PREV_PREV": return scopes[-3][attr];
		case "THIS": return scopes[-1][attr];
		default: return value;
	}
}

//Pass the full data block, and for scopes, a sequence of country and/or province mappings.
//Triggers are tested on scopes[-1], and PREV= will switch to scopes[-2].
//What happens if you do "PREV = { PREV = { ... } }" ? Should we shorten the scopes array
//or duplicate scopes[-2] to the end of it?
int(1bit) DEBUG_TRIGGER_MATCHES = 0;
int(1bit) trigger_matches(mapping data, array(mapping) scopes, string type, mixed value) {
	mapping scope = scopes[-1];
	switch (type) {
		case "AND": {
			//Inside an AND block (and possibly an OR??), you can have an "if/else" pair.
			//An "if" block has a "limit", and if the limit is true, the rest of the "if"
			//applies. Otherwise, the immediately-following "else" does.
			//I'm assuming here that if/else pairs are correctly matched; if there are,
			//say, three "if" blocks, I assume that if[1] corresponds to else[1].
			//This would be WAY easier if the "else" were inside the "if".
			//Note that I may have represented the logic here incorrectly. No idea how
			//this is supposed to behave if you do OR = { if = { limit = {...} a = 1 b = 2 } else = { c = 3 d = 4 } }
			//with multiple entries. Is that even possible?
			if (value["if"]) {
				array ifs = Array.arrayify(value["if"]), elses = Array.arrayify(value["else"]);
				if (sizeof(ifs) != sizeof(elses)) return 0; //Borked.
				foreach (ifs; int i; mapping blk) {
					mapping useme = trigger_matches(data, scopes, "AND", blk->limit || ([])) ? blk : elses[i];
					if (!trigger_matches(data, scopes, "AND", useme)) return 0;
				}
			}
			foreach (value; string t; mixed vv)
				foreach (Array.arrayify(vv), mixed v) //Would it be more efficient to arrayp check rather than arrayifying?
					if (!trigger_matches(data, scopes, t, v)) return 0;
			return 1;
		}
		case "OR":
			foreach (value; string t; mixed vv)
				foreach (Array.arrayify(vv), mixed v) //Would it be more efficient to arrayp check rather than arrayifying?
					if (trigger_matches(data, scopes, t, v)) return 1;
			return 0;
		case "NOT": return !trigger_matches(data, scopes, "OR", value);
		case "root": return trigger_matches(data, scopes + ({scope}), "AND", value);
		case "custom_trigger_tooltip": return trigger_matches(data, scopes, "AND", value);
		case "tooltip": return 1; //Inside custom_trigger_tooltip is a tooltip that visually replaces the other effects.
		//Okay, now for the actual triggers. Country scope.
		case "has_reform": return has_value(scope->government->reform_stack->reforms, value);
		case "any_owned_province":
			foreach (scope->owned_provinces, string id) {
				mapping prov = data->provinces["-" + id];
				if (trigger_matches(data, scopes + ({prov}), "AND", value)) return 1;
			}
			return 0;
		case "tag": return scope->tag == value;
		case "capital": //Check if your capital is a particular province
			return (int)scope->capital == (int)value;
		case "capital_scope": //Check other details about the capital, by switching scope
			return trigger_matches(data, scopes + ({data->provinces["-" + scope->capital]}), "AND", value);
		case "is_subject": return !!scope->overlord == value;
		case "overlord":
			if (!scope->overlord) return 0;
			return trigger_matches(data, scopes + ({data->countries[scope->overlord]}), "AND", value);
		case "trade_income_percentage":
			//Estimate trade income percentage based on last month's figures. I don't know
			//whether the actual effect changes within the month, but this is likely to be
			//close enough anyway. The income table runs ({tax, prod, trade, gold, ...}).
			if (!scope->ledger->lastmonthincometable) return 0; //No idea why, but sometimes this is null. I guess we don't have data??
			return threeplace(scope->ledger->lastmonthincometable[2]) * 1000 / threeplace(scope->ledger->lastmonthincome)
				>= threeplace(value);
		case "land_maintenance": return threeplace(scope->land_maintenance) >= threeplace(value);
		case "has_disaster": return 0; //TODO: Where are current disasters listed?
		case "num_of_continents": return `+(@(array(int))scope->continent) >= (int)value;
		case "religion": return scope->religion == value;
		case "religion_group":
			//Calculated slightly backwards; instead of asking what religion group the
			//country is in, and then seeing if that's equal to value, we look up the
			//list of religions in the group specified, and ask if the country's is in
			//that list.
			return !undefinedp(G->CFG->religion_definitions[value][scope->religion]);
		case "dominant_religion": return scope->dominant_religion == resolve_scope(data, scopes, value, "dominant_religion");
		case "religious_unity": return threeplace(scope->religious_unity) >= threeplace(value);
		case "is_defender_of_faith": {
			mapping rel = data->religion_instance_data[scope->religion] || ([]);
			return (rel->defender == scope->tag) == value;
		}
		case "has_church_aspect": return has_value(Array.arrayify(scope->church->?aspect), value);
		case "technology_group": return scope->technology_group == value;
		case "primary_culture": return scope->primary_culture == value;
		case "culture_group":
			//Checked the same slightly-backwards way that religion group is.
			return !undefinedp(G->CFG->culture_definitions[value][?scope->primary_culture]);
		case "stability": return (int)scope->stability >= (int)value;
		case "corruption": return threeplace(scope->corruption) >= threeplace(value);
		case "num_of_loans": return sizeof(Array.arrayify(scope->loan)) >= (int)value;
		case "has_country_modifier": case "has_ruler_modifier":
			//Hack: I'm counting ruler modifiers the same way as country modifiers.
			return has_value(Array.arrayify(scope->modifier)->modifier, value);
		case "has_country_flag":
			return !!scope->flags[?value]; //Flags are mapped to the date when they happened. We just care about presence.
		case "had_country_flag": { //Oh, but what if we don't just care about presence?
			string date = scope->flags[?value->flag];
			if (!date) return 0; //Don't have the flag, so we haven't had it for X days
			object today = calendar(data->date);
			int days; catch {days = calendar(date)->distance(today) / today;};
			return days >= (int)value->days;
		}
		case "was_tag": return has_value(Array.arrayify(scope->previous_country_tags), value);
		case "check_variable": return (int)scope->variables[?value->which] >= (int)value->value;
		case "has_parliament":
			return all_country_modifiers(data, scope)->has_parliament;
		case "has_government_attribute": //Government attributes are thrown in with country modifiers for simplicity.
			return all_country_modifiers(data, scope)[value];
		case "has_estate":
			return has_value(Array.arrayify(scope->estate)->type, value);
		case "has_estate_privilege":
			foreach (Array.arrayify(scope->estate), mapping est) {
				if (has_value(Array.arrayify(est->granted_privileges)[*][0], value)) return 1;
			}
			return 0;
		case "estate_influence":
			foreach (Array.arrayify(scope->estate), mapping est) {
				if (est->type != value->estate) continue;
				return est->estimated_milliinfluence >= threeplace(value->influence);
			}
			return 0; //If you don't have that estate, its influence isn't above X for any X.
		case "estate_loyalty":
			foreach (Array.arrayify(scope->estate), mapping est) {
				if (est->type != value->estate) continue;
				return threeplace(est->loyalty) >= threeplace(value->loyalty);
			}
			return 0; //Ditto - non-estates aren't loyal to you
		case "has_idea": return has_value(enumerate_ideas(scope->active_idea_groups)->id, value);
		case "has_idea_group": return !undefinedp(scope->active_idea_groups[value]);
		case "full_idea_group": return scope->active_idea_groups[?value] == "7";
		case "adm_tech": case "dip_tech": case "mil_tech":
			return (int)scope->technology[type] >= (int)value;
		case "uses_piety":
			return all_country_modifiers(data, scope)->uses_piety;
		case "num_of_janissaries": return (int)scope->num_subunits->?janissaries >= (int)value;
		case "janissary_percentage": {
			if (undefinedp(scope->janissary_percentage)) {
				//This gets checked a LOT by the Janissaries Estate, so cache the value
				int janis = threeplace(scope->num_subunits_type_and_cat->?infantry->?janissaries);
				if (janis) { //Avoid crashing if there's weird things like armies that have no regiments
					int total_army = scope->army && sizeof(scope->army) && `+(@sizeof(scope->army->regiment[*])) || 1;
					scope->janissary_percentage = janis / total_army;
				} else scope->janissary_percentage = 0;
			}
			return scope->janissary_percentage >= threeplace(value);
		}
		//What's the proper way to recognize colonial nations?
		//One of these is almost certainly wrong. Do they both need a condition (has/hasn't an overlord)?
		//Should they be identified by governmental forms?
		case "is_colonial_nation":
			return (scope->tag[0] == 'C' && !sizeof((multiset)(array)scope->tag[1..] - (multiset)(array)"012345789")) == value;
		case "is_former_colonial_nation":
			return (scope->tag[0] == 'C' && !sizeof((multiset)(array)scope->tag[1..] - (multiset)(array)"012345789")) == value;
		case "is_revolutionary": return all_country_modifiers(data, scope)->revolutionary;
		case "is_emperor": return (data->empire->emperor == scope->tag) == value;
		case "is_elector": return has_value(data->empire->electors || ({ }), scope->tag);
		case "is_part_of_hre": //For countries, equivalent to asking "is the capital_scope part of the HRE?"
			return (scope->capital_scope || scope)->hre;
		case "hre_religion_locked": return (int)data->hre_religion_status == (int)value; //TODO: Check if this is correct (post-league-war)
		case "hre_religion": return 0; //FIXME: Where is this stored, post-league-war?
		case "hre_reform_passed": return has_value(Array.arrayify(data->empire->passed_reform), value); //TODO: Check savefile with 0 or 1 reforms passed - do we need the arrayify?
		case "num_of_cities": return (int)scope->num_of_cities >= (int)value;
		case "num_of_ports": return (int)scope->num_of_ports >= (int)value;
		case "owns": return has_value(scope->owned_provinces, value);
		case "has_mission": {
			foreach (Array.arrayify(scope->country_missions->?mission_slot), array slot) {
				foreach (Array.arrayify(slot), string kwd) {
					if (G->CFG->country_missions[kwd][?value]) return 1;
				}
			}
			return 0;
		}
		case "prestige": return threeplace(scope->prestige) >= threeplace(value);
		case "meritocracy": return threeplace(scope->meritocracy) >= threeplace(value); //TODO: Only if you use meritocracy?? Only relevant if you test for "meritocracy = 0".
		case "adm": case "dip": case "mil": { //Test monarch skills. We cache this in country modifiers.
			mapping mod = scope->_all_country_modifiers;
			if (mod) return mod[type] >= (int)value;
			//Not there yet? Well, we can't call all_country_modifiers or we'll have a loop.
			//(Though it might be okay given that this won't be needed until estate calculations??)
			//Duplicate the code, for now.
			if (!scope->monarch) return 0;
			mapping monarch = ([]);
			foreach (sort(indices(scope->history)), string key)
				monarch = ((int)key && mappingp(scope->history[key]) && (scope->history[key]->monarch || scope->history[key]->monarch_heir)) || monarch;
			if (arrayp(monarch)) monarch = monarch[0];
			return (int)monarch[upper_case(type)] >= (int)value;
		}
		//Province scope.
		case "province_id": return (int)scope->id == (int)value;
		case "development": {
			int dev = (int)scope->base_tax + (int)scope->base_production + (int)scope->base_manpower;
			return dev >= (int)value;
		}
		case "province_has_center_of_trade_of_level": return (int)scope->center_of_trade >= (int)value;
		case "area": return G->CFG->prov_area[(string)scope->id] == value;
		case "region": return G->CFG->area_region[G->CFG->prov_area[(string)scope->id]] == value;
		case "superregion": return G->CFG->region_superregion[G->CFG->area_region[G->CFG->prov_area[(string)scope->id]]] == value;
		case "colonial_region": return G->CFG->prov_colonial_region[(string)scope->id] == value;
		case "continent": return G->CFG->prov_continent[(string)scope->id] == value;
		case "has_province_modifier": return all_province_modifiers(data, (int)scope->id)[value];
		case "is_strongest_trade_power": {
			//Assumes the province is a trade node
			foreach (data->trade->node, mapping node) {
				if (G->CFG->tradenode_definitions[node->definitions]->location != (string)scope->id) continue;
				array top = Array.arrayify(node->top_power);
				if (!sizeof(top)) return 0; //There's nobody trading in this node (yet), so nobody is the top trade power.
				return resolve_scope(data, scopes, value) == top[0];
			}
			return 1; //Trade node not found, probably should throw an error actually
		}
		case "owned_by": return resolve_scope(data, scopes, value) == scope->owner;
		case "country_or_non_sovereign_subject_holds": {
			string tag = resolve_scope(data, scopes, value);
			if (tag == scope->owner) return 1;
			mapping owner = data->countries[tag];
			//It's owned by someone else. Are they subject to you?
			foreach (Array.arrayify(data->diplomacy->dependency), mapping dep)
				if (dep->first == tag && dep->second == scope->owner)
					//Hack: Assume the subject type ID is enough of a check
					return dep->subject_type != "tributary_state";
			return 0; //Guess not.
		}
		//Possibly universal scope
		case "has_discovered": {
			//Can be used at province scope (has_discovered = FRA) or country scope (has_discovered = 123)
			if (scope->discovered_by)
				//At province scope. Handle "discovered_by = ROOT" and other notations.
				return has_value(scope->discovered_by, resolve_scope(data, scopes, value));
			//At country scope. Assume it's a province ID.
			mapping prov = data->provinces["-" + value];
			if (!prov) return 0; //TODO: What if it's not an ID?
			return has_value(prov->discovered_by, scope->tag);
		}
		case "has_dlc": return has_value(data->dlc_enabled, value);
		case "has_global_flag": return !undefinedp(data->flags[value]);
		case "had_global_flag": {
			string date = data->flags[value->flag];
			if (!date) return 0; //Don't have the flag, so we haven't had it for X days
			object today = calendar(data->date);
			int days; catch {days = calendar(date)->distance(today) / today;};
			return days >= (int)value->days;
		}
		case "current_age": return data->current_age == value;
		case "always": return value; //"always = no" blocks everything
		//Minor point of confusion here. As well as "exists = SPA" to test whether Spain exists,
		//the wiki also mentions "exists = yes" to test whether the current scope exists. But in
		//other contexts where a new scope is selected (eg "overlord = { ... }"), they seem to
		//implicitly check that one exists. So I'm not sure when it's possible to switch to a
		//scope that doesn't exist, and what OTHER checks should do in that situation.
		case "exists": {
			//Note that a country might be present in the save file but without any provinces.
			//This counts as not existing. If it were to be given a province, it would exist.
			mapping target = data->countries[value];
			return target && (int)target->num_of_cities;
		}
		case "normal_or_historical_nations": return 1 == (int)value; //TODO: Is this in data->gameplaysettings??
		default:
			//Switching to a specific province is done by giving its (numeric) ID.
			if ((int)type) return trigger_matches(data, scopes + ({data->provinces["-" + type]}), "AND", value);
			//Switching to a specific country, similarly, with tag.
			if (data->countries[type]) return trigger_matches(data, scopes + ({data->countries[type]}), "AND", value);
			if (mapping st = G->CFG->scripted_triggers[type]) {
				//Scripted triggers can be called in two ways: "st = yes/no" and
				//"st = { ...args... }". I don't think there's a way to internally
				//negate the version with arguments (use "NOT = { st = { ... } }").
				mapping args = mappingp(value) ? value : ([]); //Booleans have no args
				args = mkmapping(sprintf("$%s$", indices(args)[*]), values(args)); //It's easier to include the dollar signs in the mapping
				int match = trigger_matches(data, scopes, "AND", substitute_args(st, args));
				if (value == 0) return !match; //"st = no" negates the result!
				return match;
			}
			if (DEBUG_TRIGGER_MATCHES) werror("Unknown trigger %O = %O\n", type, value);
			return 1; //Unknown trigger. Let it match, I guess - easier to spot? Maybe?
	}
	
}

//List all ideas (including national) that are active
array(mapping) enumerate_ideas(mapping idea_groups) {
	array ret = ({ });
	foreach (idea_groups; string grp; string numtaken) {
		mapping group = G->CFG->idea_definitions[grp]; if (!group) continue;
		ret += ({group->start}) + group->ideas[..(int)numtaken - 1];
		if (numtaken == "7") ret += ({group->bonus});
	}
	return ret - ({0});
}

//Gather ALL a country's modifiers. Or, try to. Note that conditional modifiers aren't included.
void _incorporate(mapping data, mapping scope, mapping modifiers, string source, mapping effect, int|void mul, int|void div) {
	if (!div) mul = div = 1; //Note that mul might be zero (with a nonzero div), in which case there's no effect; or negative.
	if (effect && mul) foreach (effect; string id; mixed val) {
		if ((id == "modifier" || id == "modifiers") && mappingp(val)) _incorporate(data, scope, modifiers, source, val, mul, div);
		if (id == "conditional") {
			//Conditional attributes. There may be multiple independent blocks; each
			//one has its "allow" block and then some attributes. At least, I *think*
			//they're independent; the way some of them are coded, it might be that
			//only one can ever match. Not sure.
			foreach (Array.arrayify(val), mixed cond) if (mappingp(cond)) {
				if (trigger_matches(data, ({scope}), "AND", cond->allow || ([])))
					_incorporate(data, scope, modifiers, source, cond, mul, div);
			}
		}
		if (id == "custom_attributes") _incorporate(data, scope, modifiers, source, val, mul, div); //Government reforms have some special modifiers. It's easiest to count them as country modifiers.
		int effect = 0;
		if (stringp(val) && sscanf(val, "%[-]%d%*[.]%[0-9]%s", string sign, int whole, string frac, string blank) && blank == "")
			modifiers[id] += effect = (sign == "-" ? -1 : 1) * (whole * 1000 + (int)sprintf("%.03s", frac + "000")) * (mul||1) / (div||1);
		if (intp(val) && val == 1) modifiers[id] = effect = 1; //Boolean
		if (effect) modifiers->_sources[id] += ({source + ": " + effect});
	}
}
void _incorporate_all(mapping data, mapping scope, mapping modifiers, string source, mapping definitions, array keys, int|void mul, int|void div) {
	foreach (Array.arrayify(keys), string key)
		_incorporate(data, scope, modifiers, sprintf("%s \"%s\"", source, L10N((string)key)), definitions[key], mul, div);
}
mapping(string:int) all_country_modifiers(mapping data, mapping country) {
	if (mapping cached = country->all_country_modifiers) return cached;
	mapping modifiers = (["_sources": ([])]);
	_incorporate(data, country, modifiers, "Base", G->CFG->static_modifiers->base_values);

	mapping tech = country->technology || ([]);
	sscanf(data->date, "%d.%d.%d", int year, int mon, int day);
	foreach ("adm dip mil" / " ", string cat) {
		int level = (int)tech[cat + "_tech"];
		string desc = String.capitalize(cat) + " tech";
		_incorporate_all(data, country, modifiers, desc, G->CFG->tech_definitions[cat]->technology, enumerate(level + 1));
		if ((int)G->CFG->tech_definitions[cat]->technology[level]->year > year)
			_incorporate(data, country, modifiers, "Ahead of time in " + desc, G->CFG->tech_definitions[cat]->ahead_of_time);
		//TODO: > or >= ?
	}
	//HACK: Army morale is actually handled in two parts: base and modifier. They are called land_morale and land_morale.
	//Yeah. The one that comes from tech is the base, the other is percentage modifiers, but they have the same name.
	//So in our analysis, we rename the tech ones to base_land_morale. This needs to happen prior to anything that could
	//provide a percentage modifier, such as ideas, advisors, and temporary modifiers.
	modifiers->base_land_morale = m_delete(modifiers, "land_morale");
	modifiers->_sources->base_land_morale = m_delete(modifiers->_sources, "land_morale");
	//TODO: Is naval_morale done the same way?

	//Ideas are recorded by their groups and how many you've taken from that group.
	array ideas = enumerate_ideas(country->active_idea_groups);
	_incorporate(data, country, modifiers, ideas->desc[*], ideas[*]);
	//NOTE: Custom nation ideas are not in an idea group as standard ideas are; instead
	//you get a set of ten, identified by index, in country->custom_national_ideas, and
	//it doesn't say which ones you have. I think the last three are the traditions and
	//ambition and the first seven are the ideas themselves, but we'll have to count up
	//the regular ideas and see how many to apply. It's possible that that would be out
	//of sync, but it's unlikely. (If you remove an idea group, you lose national ideas
	//corresponding to the number of removed ideas.)
	if (array ideaids = country->custom_national_ideas) {
		//First, figure out how many ideas you have. We assume that, if you have
		//custom ideas, you don't also have a country idea set; which means that the
		//ideas listed are exclusively ones from idea sets. You get one national idea
		//for every three currently-held unlockable ideas; sum them and calculate.
		int idea_count = `+(0, @(array(int))filter(values(country->active_idea_groups), stringp));
		if (idea_count < 21)
			//You don't have all the ideas. What you have is the first N ideas,
			//plus the eighth and ninth, which are your national traditions.
			ideaids = ideaids[..idea_count / 3 - 1] + ideaids[7..8];
		//But if you have at least 21 other ideas, then you have all ten: the seven
		//ideas, the two traditions, and the ambition.

		//So! Let's figure out what those ideas actually are. They're identified by
		//index, which is the same as array indices in custom_ideas[], and level,
		//which is a simple multiplier on the effect. Conveniently, we already have
		//a way to multiply the effects of things!
		foreach (ideaids, mapping idea) {
			mapping defn = G->CFG->custom_ideas[(int)idea->index];
			_incorporate(data, country, modifiers, "Custom idea - " + L10N(defn->id), defn, (int)idea->level, 1);
		}
	}

	_incorporate_all(data, country, modifiers, "Reform", G->CFG->reform_definitions, country->government->reform_stack->reforms);
	//TODO: Reforms can have conditional modifiers. Notably, if you have Statists vs
	//Monarchists (or Orangists), the one in power affects your country. This is
	//tracked in country->statists_vs_monarchists; note that if the gauge is at
	//precisely zero, this puts the statists in power, which effectively includes
	//zero with the negative numbers.
	//Conditional modifiers have an "allow" block and then everything else gets
	//incorporated as normal. The attribute "states_general_mechanic" seems to have
	//the effects of the two sides, although I'm not 100% sure of the details.

	if (data->celestial_empire->emperor == country->tag) {
		int mandate = threeplace(data->celestial_empire->imperial_influence);
		if (mandate > 50000) _incorporate(data, country, modifiers, L10N("positive_mandate"), G->CFG->static_modifiers->positive_mandate, mandate - 50000, 50000);
		if (mandate < 50000) _incorporate(data, country, modifiers, L10N("negative_mandate"), G->CFG->static_modifiers->negative_mandate, 50000 - mandate, 50000);
		//TODO: Reforms should affect tributaries too. This only catches the Emperor.
		foreach (Array.arrayify(data->celestial_empire->passed_reform), string reform)
			_incorporate(data, country, modifiers, L10N(reform + "_emperor"), G->CFG->imperial_reforms[reform]->?emperor);
	}

	int stab = (int)country->stability;
	if (stab > 0) _incorporate(data, country, modifiers, L10N("positive_stability"), G->CFG->static_modifiers->positive_stability, stab, 1);
	if (stab < 0) _incorporate(data, country, modifiers, L10N("negative_stability"), G->CFG->static_modifiers->negative_stability, stab, 1);
	_incorporate_all(data, country, modifiers, "Policy", G->CFG->policy_definitions, Array.arrayify(country->active_policy)->policy);
	array tradebonus = G->CFG->trade_goods[Array.arrayify(country->traded_bonus)[*]];
	_incorporate(data, country, modifiers, ("Trading in " + tradebonus->id[*])[*], tradebonus[*]); //TODO: TEST ME
	_incorporate_all(data, country, modifiers, "Modifier", G->CFG->country_modifiers, Array.arrayify(country->modifier)->modifier);
	mapping age = G->CFG->age_definitions[data->current_age]->abilities;
	_incorporate(data, country, modifiers, "Age ability", age[Array.arrayify(country->active_age_ability)[*]][*]); //TODO: Add description
	_incorporate(data, country, modifiers, L10N("war_exhaustion"), G->CFG->static_modifiers->war_exhaustion, threeplace(country->war_exhaustion), 1000);
	_incorporate(data, country, modifiers, L10N("over_extension"), G->CFG->static_modifiers->over_extension, threeplace(country->overextension_percentage), 1000);
	_incorporate_all(data, country, modifiers, "Aspect", G->CFG->church_aspects, Array.arrayify(country->church->?aspect));
	int relig_unity = min(max(threeplace(country->religious_unity), 0), 1000);
	_incorporate(data, country, modifiers, L10N("religious_unity"), G->CFG->static_modifiers->religious_unity, relig_unity, 1000);
	_incorporate(data, country, modifiers, L10N("religious_unity"), G->CFG->static_modifiers->inverse_religious_unity, 1000 - relig_unity, 1000);
	if (array have = country->institutions) foreach (G->CFG->institutions; string id; mapping inst) {
		if (have[inst->_index] == "1") _incorporate(data, country, modifiers, "Institution", inst->bonus);
	}
	if (country->monarch) {
		//Is there any way to directly look up the monarch details by ID?
		mapping monarch = ([]);
		foreach (sort(indices(country->history)), string key)
			monarch = ((int)key && mappingp(country->history[key]) && (country->history[key]->monarch || country->history[key]->monarch_heir)) || monarch;
		if (arrayp(monarch)) monarch = monarch[0]; //What does it mean when there are multiple? Check by ID?
		if (mappingp(monarch->personalities))
			_incorporate_all(data, country, modifiers, "Ruler -", G->CFG->ruler_personalities, indices(monarch->personalities));
		modifiers->adm = (int)monarch->ADM;
		modifiers->dip = (int)monarch->DIP;
		modifiers->mil = (int)monarch->MIL;
	}

	//Legitimacy and its alternates
	string legitimacy_type = "";
	if (modifiers->republic) legitimacy_type = "republican_tradition";
	else if (modifiers->enables_horde_idea_group) legitimacy_type = "horde_unity";
	else if (modifiers->has_meritocracy) legitimacy_type = "meritocracy";
	else if (modifiers->monarchy) legitimacy_type = "legitimacy";
	else if (modifiers->has_devotion) legitimacy_type = "devotion";
	//else if (modifiers->native_mechanic) ; //Native tribes have no legitimacy-like mechanic
	//else werror("UNKNOWN LEGITIMACY TYPE: %O\n", country); //Shouldn't happen.
	int legitimacy_value = threeplace(country[legitimacy_type]);
	if (mapping inverse = G->CFG->static_modifiers["inverse_" + legitimacy_type]) {
		//Republican Tradition has two contradictory effects, one scaling from 0%-100% as tradition goes 0-100,
		//the other scaling as tradition goes 100-0.
		_incorporate(data, country, modifiers, L10N(legitimacy_type), G->CFG->static_modifiers[legitimacy_type], legitimacy_value, 100000);
		_incorporate(data, country, modifiers, L10N("inverse_" + legitimacy_type), inverse, 100000 - legitimacy_value, 100000);
	} else {
		//Everything else has a single main effect that scales both directions from 50.
		//They may also have a low_ modifier which applies only if below 50.
		_incorporate(data, country, modifiers, L10N(legitimacy_type), G->CFG->static_modifiers[legitimacy_type], legitimacy_value - 50000, 100000);
		if (legitimacy_value < 50000)
			_incorporate(data, country, modifiers, L10N(legitimacy_type), G->CFG->static_modifiers["low_" + legitimacy_type], 50000 - legitimacy_value, 100000);
	}
	int pp = `+(0, @threeplace(Array.arrayify(country->power_projection)->current[*]));
	_incorporate(data, country, modifiers, L10N("power_projection"), G->CFG->static_modifiers->power_projection, pp, 100000);
	_incorporate(data, country, modifiers, L10N("prestige"), G->CFG->static_modifiers->prestige, threeplace(country->prestige), 100000);
	_incorporate(data, country, modifiers, L10N("army_tradition"), G->CFG->static_modifiers->army_tradition, threeplace(country->army_tradition), 100000);

	//More modifier types to incorporate:
	//- Religious modifiers (icons, cults, etc)
	//- Government type modifiers (eg march, vassal, colony)
	//- Naval tradition (which affects trade steering and thus the trade recommendations)
	//- Being a trade league leader (scaled by the number of members)
	//- Province Triggered Modifiers (handle them alongside monuments?)

	foreach (country->owned_provinces, string id) {
		mapping prov = data->provinces["-" + id];
		if (prov->great_projects) foreach (prov->great_projects, string project) {
			mapping proj = data->great_projects[project];
			if (!(int)proj->?development_tier) continue; //Not upgraded, presumably has no effect (is that always true?)
			mapping defn = G->CFG->great_projects[project];
			if (!defn) continue; //In analyze_leviathans, there's a note about this possibility
			mapping req = defn->can_use_modifiers_trigger;
			if (sizeof(req) && !describe_requirements(req, prov, country)[1]) continue;
			mapping active = defn["tier_" + proj->development_tier]; if (!active) continue;
			_incorporate(data, country, modifiers, L10N(project), active->country_modifiers);
		}
	}

	if (country->luck) _incorporate(data, country, modifiers, "Luck", G->CFG->static_modifiers->luck); //Lucky nations (AI-only) get bonuses.
	if (int innov = threeplace(country->innovativeness)) _incorporate(data, country, modifiers, "Innovativeness", G->CFG->static_modifiers->innovativeness, innov, 100000);
	if (int corr = threeplace(country->corruption)) _incorporate(data, country, modifiers, "Corruption", G->CFG->static_modifiers->corruption, corr, 100000);
	//Having gone through all of the above, we should now have estate influence modifiers.
	//Now we can calculate the total influence, and then add in the effects of each estate.
	if (country->estate) {
		//Some estates might not work like this. Not sure.
		//First, incorporate country-wide modifiers from privileges. (It's possible for privs to
		//affect other estates' influences.)
		country->estate = Array.arrayify(country->estate); //In case there's only one estate
		foreach (country->estate, mapping estate) {
			foreach (Array.arrayify(estate->granted_privileges), [string priv, string date]) {
				mapping privilege = G->CFG->estate_privilege_definitions[priv]; if (!privilege) continue;
				string desc = sprintf("%s: %s", L10N(estate->type), L10N(priv));
				_incorporate(data, country, modifiers, desc, privilege->penalties);
				_incorporate(data, country, modifiers, desc, privilege->benefits);
			}
		}
		//Now calculate the influence and loyalty of each estate, and the resulting effects.
		foreach (country->estate, mapping estate) {
			mapping estate_defn = G->CFG->estate_definitions[estate->type];
			if (!estate_defn) continue;
			mapping influence = (["Base": (int)estate_defn->base_influence * 1000]);
			//There are some conditional modifiers. Sigh. This is seriously complicated. Why can't estate influence just be in the savefile?
			foreach (Array.arrayify(estate->granted_privileges), [string priv, string date])
				influence["Privilege " + L10N(priv)] =
					threeplace(G->CFG->estate_privilege_definitions[priv]->?influence) * 100;
			foreach (Array.arrayify(estate->influence_modifier), mapping mod)
				//It's possible to have the same modifier more than once (eg "Diet Summoned").
				//Rather than show them all separately, collapse them into "Diet Summoned: 15%".
				influence[L10N(mod->desc) || "(unknown modifier)"] += threeplace(mod->value);
			foreach (Array.arrayify(modifiers->_sources[replace(estate->type, "estate_", "") + "_influence_modifier"])
					+ Array.arrayify(modifiers->_sources->all_estate_influence_modifier), string mod) {
				sscanf(reverse(mod), "%[-0-9] :%s", string value, string desc);
				influence[reverse(desc)] += (int)reverse(value) * 100; //Just in case they show up more than once
			}
			influence["Land share"] = threeplace(estate->territory) * threeplace(estate_defn->influence_from_dev_modifier) / 2000; //Not sure why the "/2" part; the modifier is 1.0 if it scales this way, otherwise larger or smaller numbers.
			//Attempt to parse the estate influence modifier blocks. This is imperfect and limited.
			foreach (Array.arrayify(estate_defn->influence_modifier), mapping mod) {
				if (!trigger_matches(data, ({country}), "AND", mod->trigger)) continue;
				influence[L10N(mod->desc)] = threeplace(mod->influence);
			}
			int total_influence = estate->estimated_milliinfluence = `+(@values(influence));
			estate->influence_sources = influence; //Not quite the same format as _sources elsewhere though
			string opinion = "neutral";
			if ((float)estate->loyalty >= 60.0) opinion = "happy";
			else if ((float)estate->loyalty < 30.0) opinion = "angry";
			int mul = 4;
			if (total_influence < 60000) mul = 3;
			if (total_influence < 40000) mul = 2;
			if (total_influence < 20000) mul = 1;
			_incorporate(data, country, modifiers, String.capitalize(opinion) + " " + L10N(estate->type), estate_defn["country_modifier_" + opinion], mul, 4);
		}
	}
	//To figure out what advisors you have hired, we first need to find all advisors.
	//They're not listed in country details; they're listed in the provinces that they
	//came from. So we first have to find all available advisors.
	mapping advisors = ([]);
	foreach (country->owned_provinces, string id) {
		mapping prov = data->provinces["-" + id];
		foreach (prov->history;; mixed infoset) foreach (Array.arrayify(infoset), mixed info) {
			if (!mappingp(info)) continue; //Some info in history is just strings or booleans
			if (info->advisor) advisors[info->advisor->id->id] = info->advisor;
		}
		if (prov->history->advisor) advisors[prov->history->advisor->id->id] = prov->history->advisor;
	}
	foreach (Array.arrayify(country->advisor), mapping adv) {
		adv = advisors[adv->id]; if (!adv) continue;
		mapping type = G->CFG->advisor_definitions[adv->type];
		_incorporate(data, country, modifiers, L10N(adv->type) + " (" + adv->name + ")", type);
	}

	//Your religion affects your country (whodathunk). Note that we also incorporate some other
	//attributes here for convenience, even though they're not really country modifiers.
	foreach (G->CFG->religion_definitions; string grpname; mapping group) {
		mapping relig = group[country->religion];
		if (!relig) continue; //Not this group. Moving on!
		_incorporate(data, country, modifiers, L10N(country->religion), relig->country);
		_incorporate(data, country, modifiers, L10N(country->religion), relig & (<
			"uses_anglican_power", "uses_hussite_power", "uses_church_power", "has_patriarchs",
			"fervor", "uses_piety", "uses_karma", "uses_harmony", "uses_isolationism", "uses_judaism_power",
			"personal_deity", "fetishist_cult", "ancestors", "authority", "religious_reforms",
			"doom", "declare_war_in_regency", "can_have_secondary_religion", "fetishist_cult",
		>));
		_incorporate(data, country, modifiers, L10N(grpname), group & (<"can_form_personal_unions">));
		//What is relig->country_as_secondary used for? Syncretic?
		//TODO: Also check Muslim schools for their attributes
	}
	//Additional religion-specific information.
	mapping rel = data->religion_instance_data[country->religion] || ([]);
	if (string gb = rel->papacy->?golden_bull) _incorporate(data, country, modifiers, L10N(gb), G->CFG->golden_bulls[gb]);
	//TODO: Defender of the Faith? Crusade? Curia controller? Do these get listed as their
	//own modifiers or do we need to pick them up from here?
	if (modifiers->uses_harmony) {
		int harmony = threeplace(country->harmony);
		if (harmony > 50000) _incorporate(data, country, modifiers, L10N("high_harmony"), G->CFG->static_modifiers->high_harmony, harmony - 50000, 50000);
		if (harmony < 50000) _incorporate(data, country, modifiers, L10N("low_harmony"), G->CFG->static_modifiers->low_harmony, 50000 - harmony, 50000);
	}

	//Triggered modifiers. Some of these might be affected by other country modifiers,
	//so we stash the ones we have so far. This might mean we get inaccurate results
	//(if one triggered modifier affects another), but at least we don't get infinite
	//recursion.
	country->all_country_modifiers = modifiers;
	#if 0
	DEBUG_TRIGGER_MATCHES = 1;
	foreach (G->CFG->triggered_modifiers; string id; mapping mod) {
		if (mod->potential && !trigger_matches(data, ({country}), "AND", mod->potential)) continue;
		if (!trigger_matches(data, ({country}), "AND", mod->trigger)) continue;
		//Disabled for now; need to get a lot more trigger_matches clauses.
		//At the moment, I'd rather have no triggered modifiers at all than
		//have a ton of false positives.
		//_incorporate(data, country, modifiers, L10N(id), mod);
		werror("Triggered Modifier: %s %O\n", id, L10N(id));
	}
	DEBUG_TRIGGER_MATCHES = 0;
	#endif
	return modifiers;
}

mapping(string:int) all_province_modifiers(mapping data, int id) {
	mapping prov = data->provinces["-" + id];
	if (mapping cached = prov->all_province_modifiers) return cached;
	mapping country = data->countries[prov->owner];
	mapping modifiers = (["_sources": ([])]);
	if (prov->center_of_trade) {
		string type = G->CFG->province_info[(string)id]->?has_port ? "coastal" : "inland";
		mapping cot = G->CFG->cot_definitions[type + prov->center_of_trade];
		_incorporate(data, prov, modifiers, "Level " + prov->center_of_trade + " COT", cot->?province_modifiers);
	}
	if (int l3cot = country->?area_has_level3[?G->CFG->prov_area[(string)id]]) {
		string type = G->CFG->province_info[(string)l3cot]->?has_port ? "coastal3" : "inland3";
		mapping cot = G->CFG->cot_definitions[type];
		_incorporate(data, prov, modifiers, "L3 COT in area", cot->?state_modifiers);
	}
	foreach (prov->buildings || ([]); string b;) {
		_incorporate(data, prov, modifiers, "Building", G->CFG->building_types[b]);
		if (has_value(G->CFG->building_types[b]->bonus_manufactory || ({ }), prov->trade_goods))
			_incorporate(data, prov, modifiers, "Mfg has " + prov->trade_goods, G->CFG->building_types[b]->bonus_modifier);
	}
	mapping area = data->map_area_data[G->CFG->prov_area[(string)id]]->?state;
	foreach (Array.arrayify(area->?country_state), mapping state) if (state->country == prov->owner) {
		if (state->prosperity == "100.000") _incorporate(data, prov, modifiers, "Prosperity", G->CFG->static_modifiers->prosperity);
		_incorporate(data, prov, modifiers, "State edict - " + L10N(state->active_edict->?which), G->CFG->state_edicts[state->active_edict->?which]);
		_incorporate(data, prov, modifiers, "Holy order - " + L10N(state->holy_order), G->CFG->holy_orders[state->holy_order]);
	}
	_incorporate(data, prov, modifiers, "Terrain", G->CFG->terrain_definitions->categories[G->CFG->province_info[(string)id]->terrain]);
	_incorporate(data, prov, modifiers, "Climate", G->CFG->static_modifiers[G->CFG->province_info[(string)id]->climate]);
	if (prov->hre) {
		foreach (Array.arrayify(data->empire->passed_reform), string reform)
			_incorporate(data, prov, modifiers, "HRE province (" + L10N(reform + "_province") + ")", G->CFG->imperial_reforms[reform]->?province);
	}
	_incorporate(data, prov, modifiers, "Trade good: " + prov->trade_goods, G->CFG->trade_goods[prov->trade_goods]->?province);
	//How do we know if it's a city or not? This should be applied only if it's a fully-developed province, not a colony.
	_incorporate(data, prov, modifiers, "City", G->CFG->static_modifiers->city);
	if (prov->has_port) _incorporate(data, prov, modifiers, "Port", G->CFG->static_modifiers->port);
	int dev = (int)prov->base_tax + (int)prov->base_production + (int)prov->base_manpower;
	modifiers->development = dev;
	_incorporate(data, prov, modifiers, "Development", G->CFG->static_modifiers->development, dev);
	//TODO: development_scaled (to calculate the actual development cost)
	//TODO: expanded_infrastructure, centralize_state
	//TODO: in_state, in_capital_state, coastal, seat_in_parliament
	//TODO: Syncretic/Secondary religion for Tengri
	//TODO: Confucian harmonization bonuses
	//TODO: Sow Discontent (diplomatic action)
	if (prov->owner) {
		mapping counmod = all_country_modifiers(data, country);
		//First off, what kind of religious tolerance is this?
		//TODO: Use "own" if harmonized with religion or group
		string type = "heathen";
		if (prov->religion == country->religion) type = "own";
		else foreach (G->CFG->religion_definitions; string grp; mapping defn) {
			if (defn[prov->religion] && defn[country->religion]) type = "heretic";
		}
		int tolerance = counmod["tolerance_" + type];
		//Tolerance of True Faith has no limit, but the other two are capped.
		if (type != "own") tolerance = min(tolerance, counmod["tolerance_of_" + type + "s_capacity"]);
		if (tolerance > 0) _incorporate(data, prov, modifiers, L10N("tolerance"), G->CFG->static_modifiers->tolerance, tolerance, 1000);
		if (tolerance < 0) _incorporate(data, prov, modifiers, L10N("intolerance"), G->CFG->static_modifiers->intolerance, tolerance, 1000);
	}
	//TODO: Fold this in with the equivalent block in all_country_modifiers()
	if (prov->great_projects) foreach (prov->great_projects, string project) {
		mapping proj = data->great_projects[project];
		if (!(int)proj->?development_tier) continue; //Not upgraded, presumably has no effect (is that always true?)
		mapping defn = G->CFG->great_projects[project];
		if (!defn) continue; //In analyze_leviathans, there's a note about this possibility
		mapping req = defn->can_use_modifiers_trigger;
		if (sizeof(req) && !describe_requirements(req, prov, country)[1]) continue;
		mapping active = defn["tier_" + proj->development_tier]; if (!active) continue;
		_incorporate(data, prov, modifiers, L10N(project), active->province_modifiers);
	}

	string cul = prov->culture, cul_modifier = "non_accepted_culture";
	if (cul == country->?primary_culture || has_value(Array.arrayify(country->?accepted_culture), cul))
		cul_modifier = "same_culture"; //This doesn't actually exist - there seem to be no "accepted culture" modifiers
	else {
		//What if it's in your culture group?
		foreach (G->CFG->culture_definitions; string group; mapping info)
			if (info[country->?primary_culture] && info[cul])
				//Same group. If you're empire rank, that counts as accepted.
				cul_modifier = country->government_rank == "3" ? "same_culture" : "same_culture_group";
	}
	_incorporate(data, prov, modifiers, L10N(cul_modifier), G->CFG->static_modifiers[cul_modifier]);
	//TODO: accepted_culture_demoted (time-delay, possibly decaying, after unaccepting a culture)
	//TODO: non_accepted_culture_republic (additional modifier if you're a republic)

	return prov->all_province_modifiers = modifiers;
}

//Note that, unlike province and country modifiers, this is not actually cached anywhere.
//(It does make good use of province modifier caching though.)
mapping(string:int) all_area_modifiers(mapping data, string area) {
	mapping modifiers = (["_sources": ([])]);
	foreach (G->CFG->map_areas[area], string id) {
		mapping prov = all_province_modifiers(data, (int)id);
		string label = data->provinces["-" + id]->name + ": ";
		foreach ("statewide_governing_cost" / " ", string attr) if (prov[attr]) {
			modifiers[attr] += prov[attr];
			modifiers->_sources[attr] += label + prov->_sources[attr][*];
		}
	}
	return modifiers;
}

//Estimate a months' production of ducats/manpower/sailors (yes, I'm fixing the scaling there)
array(float) estimate_per_month(mapping data, mapping country) {
	float gold = (float)country->ledger->lastmonthincome - (float)country->ledger->lastmonthexpense;
	float manpower = (float)country->max_manpower * 1000 / 120.0;
	float sailors = (float)country->max_sailors / 120.0;
	//Attempt to calculate modifiers. This is not at all accurate but should give a reasonable estimate.
	float mp_mod = 1.0, sail_mod = 1.0;
	mp_mod += (float)country->army_tradition * 0.001;
	sail_mod += (float)country->navy_tradition * 0.002;
	mp_mod -= (float)country->war_exhaustion / 100.0;
	sail_mod -= (float)country->war_exhaustion / 100.0;
	mapping modifiers = all_country_modifiers(data, country);
	mp_mod += modifiers->manpower_recovery_speed / 1000.0;
	sail_mod += modifiers->sailors_recovery_speed / 1000.0;

	//Add back on the base manpower recovery (10K base manpower across ten years),
	//which isn't modified by recovery bonuses/penalties. Doesn't apply to sailors
	//as there's no "base sailors".
	//CJA 20211224: Despite what the wiki says, it seems this isn't the case, and
	//manpower recovery modifiers are applied to the base 10K as well.
	manpower = manpower * mp_mod; sailors *= sail_mod;
	return ({gold, max(manpower, 100.0), max(sailors, sailors > 0.0 ? 5.0 : 0.0)}); //There's minimum manpower/sailor recovery
}

array(string|int) describe_requirements(mapping req, mapping prov, mapping country, int|void any) {
	if (!country) return ({"n/a", 3}); //Not sure how useful this will be.
	array ret = ({ });
	string religion = prov->religion;
	if (religion != country->religion) religion = "n/a";
	array accepted_cultures = ({country->primary_culture}) + Array.arrayify(country->accepted_culture);
	if (country->government_rank == "3") //Empire rank, all in culture group are accepted
		foreach (G->CFG->culture_definitions; string group; mapping info)
			if (info[country->primary_culture]) accepted_cultures += indices(info);

	//Some two-part checks can also be described in one part. Fold them together.
	if (m_delete(req, "has_owner_religion")) {
		if (string rel = m_delete(req, "religion"))
			req->province_is_or_accepts_religion = (["religion": Array.arrayify(rel)[*]]);
		if (string grp = m_delete(req, "religion_group"))
			req->province_is_or_accepts_religion_group = (["religion_group": Array.arrayify(grp)[*]]);
	}
	foreach (sort(indices(req)), string type) {
		array|mapping need = Array.arrayify(req[type]);
		switch (type) {
			case "province_is_or_accepts_religion_group": {
				//If multiple, it's gonna be "OR" mode, otherwise it could never be true
				mapping accepted = `+(@G->CFG->religion_definitions[need->religion_group[*]]);
				//If it says "Christian or Muslim" and you're Catholic, it will just say "Catholic"
				if (accepted[religion]) ret += ({({L10N(religion), 1})});
				//If it says "Christian" and you're Catholic but the province is Protestant, it will say "Christian" but type 2
				else if (accepted[country->religion]) ret += ({({L10N(need->religion_group[*]) * " / ", 2})});
				//Otherwise, it's unviable.
				else ret += ({({L10N(need->religion_group[*]) * " / ", 3})});
				break;
			}
			case "province_is_buddhist_or_accepts_buddhism":
				need = (["religion": ({"buddhism", "vajrayana", "mahayana"})]);
				//Fall through
			case "province_is_or_accepts_religion": {
				if (has_value(need->religion, religion)) ret += ({({L10N(religion), 1})});
				else if (has_value(need->religion, country->religion)) ret += ({({L10N(need->religion[*]) * " / ", 2})});
				else ret += ({({L10N(need->religion[*]) * " / ", 3})});
				break;
			}
			case "province_is_buddhist_or_accepts_buddhism_or_is_dharmic":
				ret += ({describe_requirements(([
					"has_owner_religion": 1,
					"religion": ({"buddhism", "vajrayana", "mahayana"}),
					"religion_group": "dharmic",
				]), prov, country, 1)});
				break;
			case "culture_group":
				if (has_value(`+(@indices(G->CFG->culture_definitions[need[*]][*])), prov->culture)
						&& has_value(accepted_cultures, prov->culture))
					ret += ({({L10N(prov->culture), 1})});
				else ret += ({({L10N(need[*]) * " / ", 2})});
				break;
			case "culture":
				if (has_value(need[*], prov->culture)
						&& has_value(accepted_cultures, prov->culture))
					ret += ({({L10N(prov->culture), 1})});
				else ret += ({({L10N(need[*]) * " / ", 2})});
				break;
			case "province_is_or_accepts_culture": break; //Always goes with culture/culture_group and is assumed to be a requirement
			case "custom_trigger_tooltip": switch (need[0]->tooltip) {
				//Hack: For the known ones, render them in a simplified way
				case "hagia_sophia_tt":
					ret += ({describe_requirements(([
						"has_owner_religion": 1,
						"religion": ({"orthodox", "coptic", "catholic"}),
						"religion_group": "muslim",
					]), prov, country, 1)});
					break;
				case "mount_fuji_tt":
					ret += ({describe_requirements(([
						"has_owner_religion": 1,
						"religion": ({"shinto", "mahayana"}),
					]), prov, country, 1)});
					break;
				//Otherwise, render the tooltip itself.
				default: ret += ({({L10N(need[0]->tooltip), 3})});
			}
			break;
			case "OR": ret += describe_requirements(need[*], prov, country, 1); break;
			case "AND": ret += describe_requirements(need[*], prov, country); break;
			case "if":
				//There may be other conditions happening. As of v1.34, the only use of 'if'
				//is a simple check that allows a country to ignore the requirements under
				//some conditions, so we'll just ignore the limit and carry on.
				ret += describe_requirements((need[*] - (<"limit">))[*], prov, country, any);
				break;
			case "owner": if (need[0]->has_reform) {ret += ({({L10N(need[0]->has_reform), 3})}); break;} //else unknown
			default: ret += ({({"Unknown", 3})});
		}
	}
	if (any) return ({ret[*][0] * " / ", min(@ret[*][1])});
	return ({ret[*][0] * " + ", max(@ret[*][1])});
}

void analyze_leviathans(mapping data, string name, string tag, mapping write) {
	if (!has_value(data->dlc_enabled, "Leviathan")) return;
	mapping country = data->countries[tag];
	array projects = ({ });
	foreach (country->owned_provinces, string id) {
		mapping prov = data->provinces["-" + id];
		if (!prov->great_projects) continue;
		mapping con = prov->great_project_construction || ([]);
		foreach (prov->great_projects, string project) {
			mapping proj = data->great_projects[project] || (["development_tier": "0"]); //Weirdly, I have once seen a project that's just missing from the file.
			mapping defn = G->CFG->great_projects[project];
			if (!defn) { //FIXME: When are we seeing unknown projects??
				werror("UNKNOWN PROJECT %O\n", project);
				defn = (["can_use_modifiers_trigger": ({ })]);
			}
			//TODO: Parse out defn->can_use_modifiers_trigger and determine:
			//1) Religion-locked (list religions and/or groups that are acceptable)
			//   "province_is_or_accepts_religion_group", "province_is_buddhist_or_accepts_buddhism", "province_is_buddhist_or_accepts_buddhism_or_is_dharmic"
			//2) Culture-locked (ditto) "culture[_group]" + "province_is_or_accepts_culture = yes"
			//3) Religion-or-Culture locked (an OR= of the above two)
			//4) No requirements
			//5) custom_trigger_tooltip - use the tooltip as-is
			//6) Other. Show the definition for debugging. (Celestial Empire possibly?)
			string requirements = "None"; int req_achieved = 1;
			mapping req = defn->can_use_modifiers_trigger;
			if (sizeof(req))
				[requirements, req_achieved] = describe_requirements(req, prov, country);
			projects += ({({
				//Sort key
				(int)id - (int)proj->development_tier * 10000,
				//Legacy: preformatted table data
				({"", id, "Lvl " + proj->development_tier, prov->name, G->CFG->L10n[project] || "#" + project,
					con->great_projects != project ? "" : //If you're upgrading a different great project in this province, leave this one blank (you can't upgrade two at once)
					sprintf("%s%d%%, due %s",
						con->type == "2" ? "Moving: " : "", //Upgrades are con->type "1", moving to capital is type "2"
						threeplace(con->progress) / 10, con->date),
				}), ([
				//Data for the front end JS to render
					"province": id, "tier": proj->development_tier,
					"name": L10N(project),
					"upgrading": con->great_projects != project ? 0 : con->type == "2" ? "moving" : "upgrading",
					"progress": threeplace(con->progress), "completion": con->date, //Meaningful only if upgrading is nonzero
					"requirements": requirements, "req_achieved": req_achieved,
				]),
			})});
			//werror("Project: %O\n", proj);
		}
	}
	sort(projects);
	object today = calendar(data->date);
	array cooldowns = ({ });
	mapping cd = country->cooldowns || ([]);
	array(float) permonth = estimate_per_month(data, country);
	foreach ("gold men sailors" / " "; int i; string tradefor) {
		string date = cd["trade_favors_for_" + tradefor];
		string cur = sprintf("%.3f", permonth[i] * 6);
		//Sometimes the cooldown is still recorded, but is in the past. No idea why. We hide that completely.
		int days; catch {if (date) days = today->distance(calendar(date)) / today;};
		if (!days) {cooldowns += ({({"", "---", "--------", String.capitalize(tradefor), cur})}); continue;}
		cooldowns += ({({"", days, date, String.capitalize(tradefor), cur})}); //TODO: Remove the unnecessary empty string at the start
	}
	write->monuments = projects[*][2];
	//Favors are all rendered on the front end.
	mapping owed = ([]);
	foreach (data->countries; string other; mapping c) {
		int favors = threeplace(c->active_relations[tag]->?favors);
		if (favors > 0) owed[other] = ({favors / 1000.0}) + estimate_per_month(data, c)[*] * 6;
	}
	write->favors = (["cooldowns": cooldowns, "owed": owed]);
}

int count_building_slots(mapping data, string id) {
	mapping prov = data->provinces["-" + id];
	return (all_province_modifiers(data, (int)id)->allowed_num_of_buildings
		+ all_country_modifiers(data, data->countries[prov->owner])->global_allowed_num_of_buildings
	) / 1000; //round down - partial building slots from dev don't count
}

void analyze_furnace(mapping data, string name, string tag, mapping write) {
	mapping country = data->countries[tag];
	array coalprov = ({ });
	foreach (country->owned_provinces, string id) {
		mapping prov = data->provinces["-" + id];
		if (!G->CFG->province_info[id]->has_coal) continue;
		int dev = (int)prov->base_tax + (int)prov->base_production + (int)prov->base_manpower;
		mapping bldg = prov->buildings || ([]);
		mapping mfg = bldg & G->CFG->manufactories;
		string status = "";
		if (prov->trade_goods != "coal") {
			//Not yet producing coal. There are a few reasons this could be the case.
			if (country->institutions[6] != "1") status = "Not embraced";
			else if (prov->institutions[6] != "100.000") status = "Not Enlightened";
			else if (dev < 20 && (int)country->innovativeness < 20) status = "Need 20 dev/innov";
			else status = "Producing " + prov->trade_goods; //Assuming the above checks are bug-free, the province should flip to coal at the start of the next month.
		}
		else if (bldg->furnace) status = "Has Furnace";
		else if (G->CFG->building_id[(int)prov->building_construction->?building] == "furnace")
			status = prov->building_construction->date;
		else if (sizeof(mfg)) status = values(mfg)[0];
		else if (prov->settlement_growth_construction) status = "SETTLER ACTIVE"; //Can't build while there's a settler promoting growth);
		int slots = count_building_slots(data, id);
		int buildings = sizeof(bldg);
		if (prov->building_construction) {
			//There's something being built. That consumes a slot, but if it's an
			//upgrade, then that slot doesn't really count. If you have four slots,
			//four buildings, and one of them is being upgraded, the game will show
			//that there are five occupied slots and none open; for us here, it's
			//cleaner to show it as 4/4.
			++buildings;
			string upg = G->CFG->building_id[(int)prov->building_construction->building];
			while (string was = G->CFG->building_types[upg]->make_obsolete) {
				if (bldg[was]) {--buildings; break;}
				upg = was;
			}
		}
		coalprov += ({([
			"id": id, "name": prov->name,
			"status": status, "dev": dev,
			"buildings": buildings, "slots": slots,
		])});
	}
	write->coal_provinces = coalprov;
}

void analyze_upgrades(mapping data, string name, string tag, mapping write) {
	mapping country = data->countries[tag];
	mapping upgradeables = ([]);
	foreach (country->owned_provinces, string id) {
		mapping prov = data->provinces["-" + id];
		if (!prov->buildings) continue;
		string constructing = G->CFG->building_id[(int)prov->building_construction->?building]; //0 if not constructing anything
		foreach (prov->buildings; string b;) {
			mapping bldg = G->CFG->building_types[b]; if (!bldg) continue; //Unknown building??
			if (bldg->influencing_fort) continue; //Ignore forts - it's often not worth upgrading all forts. (TODO: Have a way to request forts too.)
			string target;
			while (mapping upgrade = G->CFG->building_types[bldg->obsoleted_by]) {
				[string techtype, int techlevel] = upgrade->tech_required;
				if ((int)country->technology[techtype] < techlevel) break;
				//Okay. It can be upgraded. But before we report it, see if we can go another level.
				//For instance, if you have a Marketplace and Diplo tech 22, you can upgrade to a
				//Trade Depot, but could go straight to Stock Exchange.
				target = bldg->obsoleted_by;
				bldg = upgrade;
			}
			if (target && target != constructing)
				upgradeables[L10N("building_" + target)] += ({(["id": id, "name": prov->name])}); //Do we need any more info?
		}
	}
	sort(indices(upgradeables), write->upgradeables = (array)upgradeables); //Sort alphabetically by target building
}

array(int) calc_province_devel_cost(mapping data, int id, int|void improvements) {
	mapping prov = data->provinces["-" + id];
	mapping country = data->countries[prov->owner];
	if (!country) return ({50, 0, 0, 50 * (improvements||1)}); //Not owned? Probably not meaningful, just return base values.
	mapping mods = all_country_modifiers(data, country);
	//Development efficiency from admin tech affects the base cost multiplicatively before everything else.
	int base_cost = 50 * (1000 - mods->development_efficiency) / 1000;

	mapping localmods = all_province_modifiers(data, id);
	int cost_factor = mods->development_cost + localmods->local_development_cost + mods->all_power_cost;

	//As the province gains development, the cost goes up.
	int devel = (int)prov->base_tax + (int)prov->base_production + (int)prov->base_manpower;
	int devcost = 0;
	//Add 3% for every development above 9, add a further 3% for every devel above 19, another above 29, etc.
	for (int thr = 9; thr < devel; thr += 10) devcost += 30 * (devel - thr);

	int final_cost = base_cost * (1000 + cost_factor + devcost) / 1000;
	//If you asked for more than one improvement, calculate the total cost.
	for (int i = 1; i < improvements; ++i) {
		++devel;
		devcost += devel / 10;
		final_cost += base_cost * (1000 + cost_factor + devcost) / 1000;
	}
	//NOTE: Some of these factors won't be quite right. For instance, Burghers influence
	//is not perfectly calculated, so if it goes above or below a threshold, that can
	//affect the resulting costs. Hopefully that will always apply globally, so the
	//relative effects of province choice will still be meaningful. (This will skew things
	//somewhat based on the number of improvements required though.)
	return ({base_cost, cost_factor, devcost, final_cost});
}

void analyze_findbuildings(mapping data, string name, string tag, mapping write, string highlight) {
	write->highlight = (["id": highlight, "name": L10N("building_" + highlight), "provinces": ({ })]);
	mapping country = data->countries[tag];
	foreach (country->owned_provinces, string id) {
		mapping prov = data->provinces["-" + id];
		//Building shipyards in inland provinces isn't very productive
		if (G->CFG->building_types[highlight]->build_trigger->?has_port && !G->CFG->province_info[id]->?has_port) continue;
		mapping bldg = prov->buildings || ([]);
		int slots = count_building_slots(data, id);
		int buildings = sizeof(bldg);
		if (prov->building_construction) {
			//Duplicate of the above
			++buildings;
			string upg = G->CFG->building_id[(int)prov->building_construction->building];
			while (string was = G->CFG->building_types[upg]->?make_obsolete) {
				if (bldg[was]) {--buildings; break;}
				upg = was;
			}
		}
		if (buildings < slots) continue; //Got room. Not a problem. (Note that the building slots calculation may be wrong but usually too low.)
		//Check if a building of the highlight type already exists here.
		int gotone = 0;
		foreach (prov->buildings || ([]); string b;) {
			if (b == highlight) {gotone = 1; break;}
			while (string upg = G->CFG->building_types[b]->?make_obsolete) {
				if (upg == highlight) {gotone = 1; break;}
				b = upg;
			}
			if (gotone) break;
		}
		if (gotone) continue;
		int dev = (int)prov->base_tax + (int)prov->base_production + (int)prov->base_manpower;
		int need_dev = (dev - dev % 10) + 10 * (buildings - slots + 1);
		write->highlight->provinces += ({([
			"id": (int)id, "buildings": buildings, "maxbuildings": slots,
			"name": prov->name, "dev": dev, "need_dev": need_dev,
			"cost": calc_province_devel_cost(data, (int)id, need_dev - dev),
		])});
	}
	sort(write->highlight->provinces->cost[*][-1], write->highlight->provinces);
}

mapping analyze_trade_node(mapping data, mapping trade_nodes, string tag, string node, mapping prefs) {
	//Analyze one trade node and estimate the yield from transferring trade. Assumes
	//that the only place you collect is your home node and you transfer everything
	//else in from all other nodes. Note that this function should only be called
	//on a node when all of its outgoing nodes have already been processed; this is
	//assured by the use of tradenode_upstream_order, which guarantees never to move
	//downstream (but is otherwise order-independent).
	mapping here = trade_nodes[node];
	mapping us = here[tag], defn = G->CFG->tradenode_definitions[node];
	//Note that all trade power values here are sent to the client in fixed-place format.

	//Total trade value in the node, equivalent to what is shown in-game as "Incoming" and "Local"
	//This is also the sum of "Outgoing" and "Retained" (called "Total" in some places). Note that
	//the outgoing value will be increased by trade steering bonuses before it arrives, but the
	//value we see in this node is before the increase.
	int total_value = threeplace(here->local_value) + `+(0, @threeplace(Array.arrayify(here->incoming)->value[*]));

	//From here on, we broadly replicate the calculations done in-game, but forked into
	//"passive" and "active", with three possibilities:
	//1) In your home node (where your main trading city is), you have the option to
	//   collect, or not collect. "Passive" and "Active" are the effect of passively
	//   collecting (which only happens in your home node) vs having a merchant there.
	//2) If you are currently collecting from trade, "passive" is your current collection
	//   and "active" is a placeholder with a marker to show that calculations are not
	//   accurate here. This tool does not handle this case.
	//3) Otherwise, "passive" is where the trade goes if you have no merchant, and "active"
	//   is where it goes if you have one steering in the best possible direction. Note
	//   that "best" can change across the course of the game, eg if you gain a lot of the
	//   trade power in a particular downstream node.
	//To assist with these calculations, we calculate, for every trade node, its "yield"
	//value. This is the number of monthly ducats that you gain per trade value in the node
	//(and can be above 1, esp if you have trade efficiency bonuses). Steering trade to a
	//high-yield node benefits your balance sheet more than steering to a low-yield node.
	//Note that the *true* comparison is always between passive and active, however, which
	//can mean that trade value and trade power themselves do not tell you where it's worth
	//transferring. For instance, Valencia has only one downstream, so the passive transfer
	//can only go that direction; but Tunis has three. If you collect in Genoa, your trade
	//power in Sevilla and Valencia will affect the impact a merchant in Tunis has, but the
	//impact of a Valencia merchant is affected only by your trade power in Valencia itself.
	//This sounds involved. It is (sorry Blanche), but it's right enough.

	mapping country_modifiers = all_country_modifiers(data, data->countries[tag]);
	int trade_efficiency = 1000 + country_modifiers->trade_efficiency; //Default trade efficiency is 100%
	int merchant_power = 2000 + country_modifiers->placed_merchant_power; //Default merchant trade power is 2.0. Both come from defines, but modifiers are more important than defines.
	int foreign_power = threeplace(here->total) - threeplace(us->val); //We assume this won't change.

	int potential_power = threeplace(us->max_pow);
	int power_modifiers = threeplace(us->max_demand); //max_demand sums all your current bonuses and penalties
	if (us->has_trader) {
		//Remove the effects of the merchant so we get a baseline.
		potential_power -= merchant_power;
		//Note that trading policy effects are hard-coded here since the only one that
		//affects any of our calculations is the default.
		if (us->trading_policy == "maximize_profit") power_modifiers -= 50;
	}
	//Your final trade power is the total trade power modified by all percentage effects,
	//and then transferred-in trade power is added on afterwards (it isn't modified).
	//TODO: Calculate the effect of transferred-OUT trade power.
	int passive_power = potential_power * power_modifiers / 1000 + threeplace(us->t_in);
	int active_power = (potential_power + merchant_power) * (power_modifiers + 50) / 1000 + threeplace(us->t_in);

	//Calculate this trade node's "received" value. This will be used for the predictions
	//of this, and all upstream nodes that can (directly or indirectly) get trade value to
	//this one. Broadly speaking, here->received is the number of ducats of income which
	//you would receive if the trade value in this node were increased by 1000 ducats. Note
	//that it is very possible for this value to exceed 1000 - trade efficiency is applied
	//to this value - and even the base value can grow superlinearly when you transfer to a
	//node you dominate at.

	int received = us->money && threeplace(us->money) * 1000 / total_value;

	//Regardless of collection, you also can potentially gain revenue from any downstream
	//nodes. This node enhances the nodes downstream of it according to the non-retained
	//proportion of its value, sharing that value according to the steer_power fractions,
	//and enhanced by the ratio of incoming to outgoing for that link. Due to the way the
	//nodes have been ordered, we are guaranteed that every downstream link has already
	//been assigned its there->received value, so we can calculate, for each downstream:
	//  (1-retention) * steer_power[n] * there->received
	//and then sum that value for each downstream. Add all of these onto here->received.
	array outgoings = Array.arrayify(here->steer_power);
	array downstream = allocate(sizeof(outgoings));
	array downstream_boost = allocate(sizeof(outgoings));
	int tfr_fraction = 1000 - threeplace(here->retention); //What isn't retained is pulled forward
	foreach (defn->outgoing; int i; mapping o) {
		int fraction = threeplace(outgoings[i]);
		//Find the destination index. This is 1-based and corresponds to the
		//order of the nodes in the definitions file.
		mapping dest = trade_nodes[o->name];
		string id = (string)(defn->_index + 1);
		//Find the corresponding incoming entry in the destination node
		foreach (Array.arrayify(dest->incoming), mapping inc) if (inc->from == id) {
			//The amount sent out from here
			int transfer = tfr_fraction * fraction / 1000;
			//Assume that the current enhancement rate (if any) will continue.
			int val = threeplace(inc->value);
			if (val) transfer = transfer * val / (val - threeplace(inc->add));
			received += transfer * dest->received / 1000;
			downstream[i] = dest->received; //Allow simulation of changes to this node
			downstream_boost[i] = val ? 1000 * val / (val - threeplace(inc->add)) : 1000;
		}
	}
	here->received = received;

	int passive_income = 0, active_income = 0;
	if (us->has_capital) {
		//This node is where our main trade city is. (The attribute says "capital", but
		//with the Wealth of Nations DLC, you can move your main trade city independently
		//of your capital. We only care about trade here.) You can collect passively or
		//have a merchant collecting, but you can never transfer trade away.
		//Predict passive income: our power / (our power + other power) * value * trade efficiency
		//You would get this even without a merchant at home. Depending on your setup, it may
		//be more profitable to collect passively, and transfer more in; but since there's a
		//trade efficiency bonus for collecting with a merchant, this probably won't be the
		//case until you have quite a lot of other efficiency bonuses, or you totally dominate
		//your home node such that the 5% power bonus is meaningless.
		int passive_collection = total_value * passive_power / (passive_power + foreign_power);
		passive_income = passive_collection * trade_efficiency / 1000;
		int active_collection = total_value * active_power / (active_power + foreign_power);
		active_income = active_collection * (trade_efficiency + 100) / 1000;
	}
	else if (us->has_trader && !us->type) passive_income = -1; //Collecting outside of home. Flag as unknowable.
	else if (here->steer_power && total_value) {
		//You are transferring trade power. If active, you get to choose where to, and
		//your trade power is stronger; but even if passive, you'll still transfer.
		//To calculate the benefit of a merchant here, we first sum up trade power of
		//all other countries in this node, according to what they're doing.
		//(If there's no steer_power entry, that means there's no downstreams, so you
		//can't steer trade. Leave the estimates at zero.)
		if (!arrayp(here->steer_power)) here->steer_power = ({here->steer_power});
		int foreign_tfr, foreign_coll;
		array(int) tfr_power = allocate(sizeof(here->steer_power));
		array(int) tfr_count = allocate(sizeof(here->steer_power));
		foreach (here->top_power || ({ }); int i; string t) {
			if (t == tag) continue; //Ignore ourselves for the moment.
			mapping them = here[t] || ([]);
			int power = threeplace(here->top_power_values[i]);
			//If your home node is here, or you have a merchant collecting, your
			//trade power is attempting to retain value here.
			if (them->has_capital || (them->has_trader && !them->type)) foreign_coll += power;
			else {
				//Otherwise you're trying to move trade downstream, but without
				//a merchant here, you are not affecting the precise direction.
				//Note that this won't much matter if there's only one downstream.
				foreign_tfr += power;
				if (them->has_trader) {
					//Modify every country's trade power by its trade steering bonus
					int steering = all_country_modifiers(data, data->countries[t])->trade_steering;
					if (steering) power = power * (1000 + steering) / 1000;
					tfr_power[(int)them->steer_power] += power;
					tfr_count[(int)them->steer_power]++;
				}
			}
		}
		int total_steer = `+(0, @tfr_power);
		//There are some special cases. Normally, if nobody's steering trade, it gets
		//split evenly among the destinations; but a destination is excluded if no
		//country has trade power in both that node and this one. This is unlikely to
		//make a material difference to the estimates, so I'm ignoring that rule.
		//Okay. So, we now know what other nations are doing. Now we can add our own entry.
		//First, passive. This means that our passive trade power is added to the "pulling"
		//trade power, but not to any "steering".
		int outgoing = total_value * (foreign_tfr + passive_power) / ((foreign_tfr + passive_power + foreign_coll) || 1);
		//If we split this outgoing value according to the ratios in tfr_power, increase
		//them according to their current growths, and multiply them by the destinations'
		//received values, we'll see how much passive income we would get.
		if (!total_steer) {tfr_power[*]++; total_steer = sizeof(tfr_power);} //Avoid division by zero; if there's no pull anywhere, pretend there's one trade power each way.
		passive_income = outgoing * `+(@(`*(downstream[*], downstream_boost[*], tfr_power[*]))) / total_steer / 1000000;
		//Next, active. For every possible destination, calculate the benefit. Or, since
		//it's almost always going to be the right choice, just pick the one with the
		//highest Received value. For a different destination to be materially better, it
		//would have to somehow involve boosting a very strong pull that already exists,
		//which will be a bit chancy (that strong pull will probably take most of the value).
		int dest = 0;
		foreach (downstream; int d; int rcvd) if (rcvd > downstream[dest]) dest = d;
		outgoing = total_value * (foreign_tfr + active_power) / (foreign_tfr + active_power + foreign_coll);
		int steering_power = active_power;
		int steering_bonus = all_country_modifiers(data, data->countries[tag])->trade_steering;
		if (steering_bonus) steering_power = steering_power * (1000 + steering_bonus) / 1000;
		tfr_power[dest] += steering_power; total_steer += steering_power;
		//Have a guess at how much the trade link would gain by the additional merchant.
		//This won't be perfectly accurate, as we won't necessarily be added at the end
		//(which means the trade steering bonuses may get applied separately), but it
		//should be kinda closeish.
		if (tfr_count[dest] < 5) downstream_boost[dest] += ({50, 25, 16, 12, 10})[tfr_count[dest]] * (1000 + steering_bonus) / 1000;
		active_income = outgoing * `+(@(`*(downstream[*], downstream_boost[*], tfr_power[*]))) / total_steer / 1000000;
	}

	//Calculate the benefit of additional fleet power in a naive way:
	//Your fraction will increase from (us->val / here->total) to
	//((us->val + fleetpower) / (here->total + fleetpower)), and your
	//revenue is assumed to increase by that multiplied by your
	//received value times the value in the node.
	int fleet_benefit = -1;
	int total_power = threeplace(here->total);
	if (total_power && !defn->inland) { //... no sending trade fleets inland, it ruins the keels
		int fleetpower = prefs->fleetpower; if (fleetpower < 1000) fleetpower = 1000;
		int current_power = threeplace(us->val);
		int current_value = total_value * received * current_power / total_power;
		int buffed_value = total_value * received * (current_power + fleetpower) / (total_power + fleetpower);
		fleet_benefit = (buffed_value - current_value) / 1000;
	}

	//Note: here->incoming[*]->add gives the bonus provided by traders pulling value, and is
	//one of the benefits of Transfer Trade Power over collecting in multiple nodes.
	//TODO: Check effect of trade company, colonial nation, caravan power (and modifiers)
	//TODO: Check effect of embargoes
	/* Privateering:
	us->privateer_mission has our power, after all modifiers
	us->privateer_money is the ducats/month gained in Spoils of War here
	This is already factored into the node's total power, so every country's fraction is
	effectively calculated correctly.
	Spoils of War is not factored into this tool.
	*/

	mapping ret = ([
		"id": node, "name": L10N(node), "province": defn->location,
		"raw_us": us, "raw_defn": defn,
		"raw_here_abbr": (mapping)filter((array)here) {return __ARGS__[0][0] != upper_case(__ARGS__[0][0]);},
		"has_capital": us->has_capital,
		"trader": us->has_trader && (us->type ? "transferring" : "collecting"),
		"policy": us->trading_policy,
		"ships": (int)us->light_ship, "ship_power": threeplace(us->ship_power),
		"prov_power": threeplace(us->province_power),
		"your_power": passive_power, "total_power": total_power,
		"fleet_benefit": fleet_benefit,
		//What is us->already_sent?
		"total_value": total_value,
		"current_collection": threeplace(us->money),
		"retention": threeplace(here->retention), //Per-mille retention of trade value
		"received": received,
		"passive_income": passive_income, "active_income": active_income,
		"downstreams": defn->outgoing->name,
	]);
	return ret;
}

mapping transform(string ... types) {
	mapping ret = ([]);
	foreach (types, string type) {
		sscanf(type, "%s: %{%s %}", string value, array keys);
		foreach (keys, [string key]) ret[key] = value;
	}
	return ret;
}
mapping ship_types = transform(
	"heavy_ship: early_carrack carrack galleon wargalleon twodecker threedecker ",
	"light_ship: barque caravel early_frigate frigate heavy_frigate great_frigate ",
	"galley: galley war_galley galleass galiot chebeck archipelago_frigate ",
	"transport: war_canoe cog flute brig merchantman trabakul eastindiaman ",
);

//Step through a set of highlighting instructions and list the relevant provinces
//Returns an array of provinces, with subgroups of provinces indicated with subarrays
//starting with a heading. (Province IDs are all returned numerically.)
array(int|array(string|int|array)) enumerate_highlight_provinces(mapping data, mapping country, mapping highlight, mapping|void filter) {
	if (!highlight || !sizeof(highlight)) return ({ }); //Mission does not involve provinces, don't highlight it.
	if (!filter) filter = highlight;
	//In theory, I think, this ought to be done by going through every possible province
	//and seeing if it passes the filter. In practice, though, we'd rather check differently,
	//so this recursively scans the highlight mapping for provinces and groups.
	array interesting = ({ });
	foreach (highlight; string kwd; mixed value) {
		switch (kwd) {
			case "province_id":
				foreach (Array.arrayify(value), int|string prov)
					if (trigger_matches(data, ({country, data->provinces["-" + prov]}), "AND", filter))
						interesting += ({(int)prov});
				break;
			case "area":
				foreach (Array.arrayify(value), string area)
					interesting += ({({
						"Area: " + L10N(area),
						enumerate_highlight_provinces(data, country, (["province_id": G->CFG->map_areas[area]]), filter),
					})});
				break;
			case "region":
				foreach (Array.arrayify(value), string reg) {
					array prov = ({ });
					foreach (Array.arrayify(G->CFG->map_regions[reg]->areas), string area)
						//There seem to be some degenerate areas which, due to the way the parser
						//handles empty arrays, are showing up as mappings. They're empty, so just
						//ignore them.
						if (sizeof(G->CFG->map_areas[area])) prov += G->CFG->map_areas[area];
					interesting += ({({
						"Region: " + L10N(reg),
						enumerate_highlight_provinces(data, country, (["province_id": prov]), filter),
					})});
				}
				break;
			//The distinction between AND and OR isn't important here, although it will be for the
			//checks inside trigger_matches() after we've listed provinces.
			case "AND": case "OR":
				interesting += enumerate_highlight_provinces(data, country, Array.arrayify(value)[*], filter); break;
			//case "NOT": case "ROOT": case "root": break;
			//default: werror("Unknown filter keyword: %O %O\n", kwd, value); //List unknowns if desired
		}
	}
	//Post-process the list to remove anything uninteresting.
	foreach (interesting; int i; mixed val)
		if (arrayp(val)) switch (sizeof(val)) {
			case 0: interesting[i] = 0; break; //Empty arrays are uninteresting.
			case 1:
				if (stringp(val[0])) interesting[i] = 0; //Arrays containing only a heading are uninteresting.
				else interesting[i] = val[0]; //Arrays containing only one element can devolve to that element.
				break;
			case 2:
				if (stringp(val[0]) && arrayp(val[1]) && !sizeof(val[1])) interesting[i] = 0; //Just a heading and an empty array? Bo-ring.
				break;
			default: break; //Everything else is presumed interesting.
		}
	return interesting - ({0});
}
/*
Need to show how many merchants (other than you) are transferring on this path.
- For each country, if them->type == "1", and if them->steer_power == us->steer_power, add 1. Exclude self.
- Show value from ({.05, .025, .016, .012, .01, .0})[count]. Infinite zeroes after the array. ==> steer_bonus_power
- Note that this is not being increased by your trade steering bonus, which is affected by
  naval tradition. The actual bonus would be a bit higher than this, usually. It's hard to
  figure the exact bonus, though, since you may be inserted somewhere in the list (due to
  tag order), and the steering bonuses of all nations past you will be recalculated. But
  it'll be roughly this value.
- From downstream, calculate the current merchant bonus
  - Find the appropriate incoming[] entry
    - They have a inc->from value - probably index into definitions
  - inc->add / (inc->value - inc->add) ==> current_steer_bonus
  - Or look at upstream's node and check its outgoing amount.
- predicted_steer_bonus is current_steer_bonus if already transferring *to this node*.
- Otherwise, add steer_bonus_power.

Transfer Trade Power will increase the value of the downstream node by:
- steer_amount * predicted_steer_bonus + inc->value*(predicted_steer_bonus - current_steer_bonus)

The financial benefit of Transfer Trade Power is the increased value of the downstream node
multiplied by the fraction that you collect. It should be possible to calculate this fraction
recursively; your home node and anywhere you collect grant collection_amount/total_value
(or collection_power/(collection_power + foreign_power)), and transfers multiply the downstream
collection fraction by the fraction transferred downstream.

SPECIAL CASE: If you are not collecting *anywhere* except your home node (with or without a home
merchant), you receive a 10% trade power bonus in your home node for each transferring merchant.
This isn't just those transferring directly to the home node - it's every merchant you have. This
could be HUGE on a big nation!

Trade Policy is a DLC feature (Cradle). Check if DLC disabled - is policy always null?
- Might not matter, since the effect of trade policy is incorporated into max_demand and val

us->prev == "Transfers from traders downstream". It's 20% of provincial trade power, as
long as you have at least 10.
*/

//Returns threeplace of the net unrest, and optionally array of strings of why
int|array(int|array(string)) provincial_unrest(mapping data, string provid, int|void detail) {
	mapping prov = data->provinces["-" + provid];
	mapping country = data->countries[prov->owner];

	//Calculate and cache which provinces are covered by troops
	mapping coverage = country->rebel_suppression_coverage;
	if (!coverage) {
		coverage = ([]);
		foreach (Array.arrayify(country->army), mapping army) {
			//TODO: Calculate the actual effective unrest bonus. The base value is 0.25
			//per regiment, then multiply that by five if hunting rebels, but split the
			//effect across the provinces. For now, we just mark it as "done".
			//TODO: Rebel suppression efficiency?
			int effect = 1;
			coverage[army->location] += effect;
			mapping hunt_rebel = army->mission->?hunt_rebel;
			if (!hunt_rebel) continue; //Not hunting rebels (maybe on another mission, or no mission at all).
			foreach (hunt_rebel->areas, string a)
				foreach (G->CFG->map_areas[a];; string id) coverage[id] += effect;
		}
		country->rebel_suppression_coverage = coverage;
	}

	//So! How much unrest is there?
	//werror("%O\n", prov - (<"discovered_by", "all_province_modifiers">));
	int unrest = 0;
	array sources = ({ });
	//m_delete(country, "all_country_modifiers"); //Purge for debugging if hammering things eg with reload checks
	mapping counmod = all_country_modifiers(data, country);
	//m_delete(prov, "all_province_modifiers");
	mapping provmod = all_province_modifiers(data, (int)provid);

	//If you seize land from estates, you get 10 unrest that decays 1 per year, or 0.08333/month.
	if (string estate_unrest = prov->flags->?has_estate_unrest_flag) {
		sscanf(estate_unrest, "%d.%d.", int since_year, int since_mon);
		sscanf(data->date, "%d.%d.", int now_year, int now_mon);
		int months = 120 - ((now_year - since_year) * 12 + now_mon - since_mon);
		if (months > 0) {
			unrest += 1000 * months / 12;
			sources += ({sprintf("Seizure of Estate Land: %d", 1000 * months / 12)});
		}
	}

	unrest += counmod->global_unrest + provmod->local_unrest;
	sources += counmod->_sources->global_unrest;
	sources += provmod->_sources->local_unrest;
	if (prov->religion == "catholic" && country->religion == "catholic" && counmod->unrest_catholic_provinces) {
		//An unusual modifier, and specific to Catholic provinces in Catholic countries.
		unrest += counmod->unrest_catholic_provinces;
		sources += counmod->_sources->unrest_catholic_provinces;
	}
	//Separatism is a bit harder to calculate. This could theoretically be incorporated
	//into all_province_modifiers(), but it's notably more costly than other things, and
	//as of 20230930 it only affects unrest.
	//What happens if you have fractional years of nationalism? Not currently supported.
	int years = 30 + (counmod->years_of_nationalism + provmod->local_years_of_nationalism) / 1000 + (int)prov->nationalism;
	int owner_change = -1;
	foreach (sort(indices(prov->history)), string key) {
		if (!(int)key) continue;
		mapping|array entry = prov->history[key];
		if (arrayp(entry)) entry = `|(@entry); //Fold them all together; really we only care about the presence of particular attributes.
		if (!entry->owner) continue;
		owner_change = (int)key;
		if (entry->add_core) owner_change = -1; //Hypothesis #2: If you got core on a province at the same time as gaining ownership, no separatism?
	}
	//Hypothesis #3, not currently tested: If prov->history->add_core is/has the current owner, no separatism.
	int nationalism = owner_change + years - (int)data->date;
	//Note that, in theory, this could incorporate G->CFG->static_modifiers->nationalism for
	//each year of nationalism. For now though, we just have this hard-coded.
	if (prov->owner != prov->history->owner && nationalism > 0) {
		//NOTE: I'm currently working with the hypothesis that prov->history->owner is
		//an indication of whether there's separatism. For example, provinces owned at
		//the start of the game have no separatism, despite the latest "owner" marker
		//being 1444.11.11 (or 1444.11.12), but their owner hasn't actually changed.
		unrest += nationalism * 500; sources += ({"Separatism: " + nationalism * 500});
	}

	if (prov->missionary_construction) {unrest += 6000; sources += ({"Active Missionary: 6000"});}
	if (detail) return ({unrest, sources});
	return unrest;
}

void analyze_obscurities(mapping data, string name, string tag, mapping write, mapping prefs) {
	//TODO: Break this gigantic function up, maybe put some things in with existing functions.

	//Go through your navies and see if any have outdated ships.
	mapping country = data->countries[tag], units = country->sub_unit;
	write->navy_upgrades = ({ });
	foreach (Array.arrayify(country->navy), mapping fleet) {
		mapping composition = ([]);
		int upgrades = 0;
		foreach (Array.arrayify(fleet->ship), mapping ship) {
			string cat = ship_types[ship->type]; //eg heavy_ship, transport
			composition[cat]++;
			//Note that buying or capturing a higher-level unit will show it as upgradeable.
			if (ship->type != units[cat]) {composition[cat + "_upg"]++; upgrades = 1;}
		}
		if (!upgrades) continue;
		string desc = "";
		mapping navy = (["name": fleet->name]);
		foreach ("heavy_ship light_ship galley transport" / " ", string cat)
			navy[cat] = ({composition[cat + "_upg"]||0, composition[cat]||0});
		write->navy_upgrades += ({navy});
	}
	//Enumerate all CBs from and against you, categorized by type
	//TODO: On Conquest CBs, find all provinces with claims and find
	//the last to expire, or a permanent, to show as CB expiration.
	write->cbs = (["from": (["tags": ({ })]), "against": (["tags": ({ })]), "types": ([])]);
	foreach (Array.arrayify(data->diplomacy->casus_belli), mapping cb) {
		if (cb->first != tag && cb->second != tag) continue;
		//if second is tag, put into against
		mapping info = (["tag": cb->first == tag ? cb->second : cb->first]);
		if (cb->end_date) info->end_date = cb->end_date; //Time-limited casus belli
		mapping which = write->cbs[cb->first == tag ? "from" : "against"];
		which[cb->type] += ({info});
		if (!has_value(which->tags, info->tag)) which->tags += ({info->tag});
		if (!write->cbs->types[cb->type]) {
			mapping ty = write->cbs->types[cb->type] = ([
				"name": L10N(cb->type),
				"desc": L10N(cb->type + "_desc"),
			]);
			//These may be null (and thus empty mappings) if the war goal comes from a mod
			//or other alteration, and thus cannot be found in the core data files.
			mapping typeinfo = G->CFG->cb_types[cb->type] || ([]);
			mapping wargoal = G->CFG->wargoal_types[typeinfo->war_goal] || ([]);
			if (typeinfo->attacker_disabled_po) ty->restricted = "Some peace offers disabled";
			else if (wargoal->allowed_provinces_are_eligible) ty->restricted = "Province selection is restricted";
			foreach (({"badboy", "prestige", "peace_cost"}), string key) ty[key] = (array(float))({
				wargoal->attacker[?key + "_factor"] || wargoal[key + "_factor"],
				wargoal->defender[?key + "_factor"] || wargoal[key + "_factor"],
			});
		}
	}
	//Gather basic country info in a unified format.
	write->countries = map(data->countries) {mapping c = __ARGS__[0];
		if (!sizeof(c->owned_provinces)) return 0;
		mapping capital = data->provinces["-" + c->capital];
		string flag = c->tag;
		if (c->colonial_parent) {
			//Look up the parent country's flag. Then add a solid color to it, using
			//the designated country color. We assume that this can't happen more than
			//once (a colonial nation can't be overlord of another colonial nation).
			mapping par = data->countries[flag = c->colonial_parent];
			if (mapping cust = par->colors->custom_colors)
				flag = (({"Custom", cust->symbol_index, cust->flag}) + cust->flag_colors) * "-";
			flag += sprintf("-%{%02X%}", (array(int))c->colors->country_color);
		}
		if (mapping cust = c->colors->custom_colors) {
			//Custom flags are defined by a symbol and four colours.
			//These are available in the savefile as:
			//cust->symbol_index = emblem
			//cust->flag = background
			//cust->flag_colors = ({color 1, color 2, color 3})
			//(Also, cust->color = map color, fwiw)
			//In each case, the savefile is zero-based, but otherwise, the numbers are
			//the same as can be seen in the nation designer.
			flag = (({"Custom", cust->symbol_index, cust->flag}) + cust->flag_colors) * "-";
		}
		//HACK: I'm not currently processing tech groups fully, but for now,
		//just quickly alias some of the tech groups' units together.
		string unit_type = ([
			"central_african": "sub_saharan",
			"east_african": "sub_saharan",
			"andean": "south_american",
		])[c->technology_group] || c->technology_group;
		return ([
			"name": c->name || L10N(c->tag),
			"tech": ({(int)c->technology->adm_tech, (int)c->technology->dip_tech, (int)c->technology->mil_tech}),
			"technology_group": c->technology_group,
			"unit_type": unit_type,
			"province_count": sizeof(c->owned_provinces),
			"capital": c->capital, "capitalname": capital->name,
			"hre": capital->hre, //If the country's capital is in the HRE, the country itself is part of the HRE.
			"development": c->development,
			"institutions": `+(@(array(int))c->institutions),
			"flag": flag,
			"opinion_theirs": c->opinion_cache[country->_index],
			"opinion_yours": country->opinion_cache[c->_index],
			"armies": sizeof(Array.arrayify(c->army)),
			"navies": sizeof(Array.arrayify(c->navy)),
		]);
	};
	write->countries = filter(write->countries) {return __ARGS__[0];}; //Keep only countries that actually have territory
	foreach (Array.arrayify(data->diplomacy->dependency), mapping dep) {
		mapping c = write->countries[dep->second]; if (!c) continue;
		c->overlord = dep->first;
		c->subject_type = L10N(dep->subject_type + "_title");
		write->countries[dep->first]->subjects++;
	}
	foreach (Array.arrayify(data->diplomacy->alliance), mapping dep) {
		write->countries[dep->first]->alliances++;
		write->countries[dep->second]->alliances++;
	}
	//TODO: Maybe count weaker one-way relationships like guarantees and tributary subjects separately?

	//List countries that could potentially join a coalition
	write->badboy_hatred = ({ });
	foreach (data->countries;; mapping risk) {
		int ae = 0, impr = 0;
		foreach (Array.arrayify(risk->active_relations[tag]->?opinion), mapping opine) {
			if (opine->modifier == "aggressive_expansion") ae = -threeplace(opine->current_opinion);
			if (opine->modifier == "improved_relation") impr = threeplace(opine->current_opinion);
		}
		if (ae < 50000 && risk->coalition_target != tag) continue;
		write->badboy_hatred += ({([
			"tag": risk->tag,
			"badboy": ae, "improved": impr,
			"in_coalition": risk->coalition_target == tag,
		])});
	}

	//List truces, grouped by end date
	mapping truces = ([]);
	foreach (data->countries; string other; mapping c) {
		//Truces view - sort by date, showing blocks of nations that all peaced out together
		//- Can't find actual truce dates, but anti-shenanigans truces seem to set a thing into
		//active_relations[tag]->truce = yes, ->last_war = date when the action happened (truce is
		//five years from then). If there's an actual war, ->last_warscore ranges from 0 to 100?
		mapping rel = c->active_relations[?tag];
		if (!rel->?truce) continue;
		//Instead of getting the truce end date, we get the truce start date and warscore.
		//As warscore ranges from 0 to 100, truce length ranges from 5 to 15 years.
		int truce_months = 60 + 120 - (100 - (int)rel->last_warscore) * 120 / 100; //Double negation to force round-up
		//This could be off by one or two months, but it should be consistent for all
		//countries truced out at once, so they'll remain grouped.
		sscanf(rel->last_war, "%d.%d.%*d", int year, int mon);
		mon += truce_months % 12 + 1; //Always move to the next month
		year += truce_months / 12 + (mon > 12);
		if (mon > 12) mon -= 12;
		string key = sprintf("%04d.%02d", year, mon);
		if (!truces[key]) truces[key] = ({sprintf("%s %d", ("- Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec" / " ")[mon], year)});
		truces[key] += ({({other, ""})}); //TODO: Put info about the war in the second slot?
		if (mapping info = write->countries[other]) info->truce = truces[key][0];
	}
	//Since "annul treaties" has a similar sort of cooldown, and since it can be snuck in
	//when the other party loses very minorly in a war, list those too.
	foreach (Array.arrayify(data->diplomacy->annul_treaties), mapping annulment) {
		string other;
		if (annulment->first == tag) other = annulment->second;
		else if (annulment->second == tag) other = annulment->first;
		else continue;
		//We have the start date; the annulment is always for precisely ten years.
		sscanf(annulment->start_date, "%d.%d.%*d", int year, int mon);
		year += 10;
		//TODO: Should I increment the month to the next one? If you have annul treaties until May 25th,
		//is it more useful to show "May" or "June"?
		string key = sprintf("%04d.%02d", year, mon);
		if (!truces[key]) truces[key] = ({sprintf("%s %d", ("- Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec" / " ")[mon], year)});
		truces[key] += ({({other, "(annul treaties)"})});
	}
	sort(indices(truces), write->truces = values(truces));

	//Previous wars have an "outcome" which isn't always present, but seems to be
	//"2" or "3". Most often 2. I would guess that 2 means victory for attackers,
	//3 victory for defenders, absent means white peace.
	//I'd like to be able to reconstruct the peace treaty, but currently, can't
	//find the necessary info. It might not be saved.
	/*foreach (Array.arrayify(data->previous_war), mapping war) {
		werror("%O [%O/%O] ==> %s\n", war->outcome, war->attacker_score, war->defender_score, war->name);
	}*/

	//Potential colonies, regardless of distance.
	array(mapping) colonization_targets = ({ });
	foreach (data->provinces; string id; mapping prov) {
		if (prov->controller) continue;
		int dev = (int)prov->base_tax + (int)prov->base_production + (int)prov->base_manpower;
		if (dev < 3) continue; //Sea province, probably
		if (!has_value(prov->discovered_by || ({ }), tag)) continue; //Filter to the ones you're aware of
		array modifiers = map(Array.arrayify(prov->modifier)) { [mapping mod] = __ARGS__;
			if (mod->hidden) return 0;
			array effects = ({ });
			foreach (G->CFG->country_modifiers[mod->modifier] || ([]); string effect; string value) {
				if (effect == "picture") continue; //Would be cool to show the icon in the front end, but whatever
				string desc = upper_case(effect);
				if (effect == "province_trade_power_value") desc = "PROVINCE_TRADE_VALUE"; //Not sure why, but the localisation files write this one differently.
				effects += ({sprintf("%s: %s", G->CFG->L10n[desc] || G->CFG->L10n["MODIFIER_" + desc] || effect || "(unknown)", (string)value)});
			}
			return ([
				"name": L10N(mod->modifier),
				"effects": effects,
			]);
		} - ({0});
		mapping provinfo = G->CFG->province_info[id - "-"];
		mapping terraininfo = G->CFG->terrain_definitions->categories[provinfo->terrain] || ([]);
		mapping climateinfo = G->CFG->static_modifiers[provinfo->climate] || ([]);
		colonization_targets += ({([
			"id": id - "-",
			"name": prov->name,
			"cot": (int)prov->center_of_trade,
			"dev": dev,
			"modifiers": modifiers,
			"terrain": provinfo->terrain,
			"climate": provinfo->climate || "temperate", //I *think* the ones with no climate specification are always Temperate??
			"has_port": provinfo->has_port,
			"settler_penalty": -(int)climateinfo->local_colonial_growth,
			//Default sort order: "interestingness"
			"score": (int)id + //Disambiguation
				10000 * (dev + (int)climateinfo->local_colonial_growth + 100 * (int)prov->center_of_trade + 1000 * sizeof(modifiers)),
		])});
		//Is there any way to figure out whether the province is accessible? Anything that has_port
		//is accessible, as is anything adjacent to an existing province - even an unfinished colony,
		//since it will at some point be viable. TODO?
	}
	sort(-colonization_targets->score[*], colonization_targets);
	write->colonization_targets = colonization_targets;

	//Pick up a few possible notifications.
	write->notifications = ({ });
	//Would it be safe to seize land?
	object seizetime = calendar(country->flags->?recent_land_seizure || "1.1.1")->add(Calendar.Gregorian.Year() * 5);
	if (country->estate && seizetime < calendar(data->date)) {
		int ok = 1;
		foreach (country->estate, mapping estate) {
			float threshold = estate->estimated_milliinfluence >= 100000 ? 70.0
				: country->all_country_modifiers["seizing_land_no_rebels_from_" + estate->type] ? 0.0
				: 50.0;
			if ((float)estate->loyalty < threshold) ok = 0;
		}
		//How much crownland do you have? Or rather: how much land do your estates have?
		//If you have 100% crownland, you can't seize. But if you have 99%, you probably
		//don't want to seize, so don't prompt.
		int estateland = `+(0, @threeplace(country->estate->territory[*]));
		if (estateland < 1000) ok = 0;
		if (ok) write->notifications += ({"Estate land seizure is available"});
	}
	if (mapping ag = country->active_agenda) {
		//You have an active agenda.
		write->agenda = ([
			"expiry": ag->expiry_date,
		]);
		//Agendas have different types of highlighting available to them.
		//We support agenda_province and agenda_country modes, but that's
		//all; there are a number of more complicated ones, including:
		//- Any in this area
		//- All in this area
		//- All non-owned in this area
		//- Provinces controlled by rebels
		//We don't support these. Some of them will highlight a province
		//(eg the "area" ones), others won't highlight anything.
		//Proper handling of highlight types would require parsing the G->CFG->estate_agendas
		//files and interpreting the provinces_to_highlight block. These files can now be
		//parsed (see parser.pike, commented out), but executing the highlight block is hard.
		foreach (Array.arrayify(ag->scope->?saved_event_target), mapping target) switch (target->name) {
			case "agenda_trade_node": //TODO: Show that it's actually the trade node there??
			case "agenda_province": write->agenda->province = target->province; break;
			case "agenda_country": write->agenda->country = target->country; break;
			case "rival_country": write->agenda->rival_country = target->country; break;
		}
		if (write->agenda->province) write->agenda->province_name = data->provinces["-" + write->agenda->province]->name;
		//If we never find a target of a type we recognize, there's nothing to highlight.
		string desc = L10N(ag->agenda);
		//Process some other agenda description placeholders before shooting it through to the front end
		//Most of these are hacks to make it less ugly, because the specific info isn't really interesting.
		desc = replace(desc, ([
			//Trade node names aren't easy to get, and we can't focus on the trade node
			//anyway, so just focus on the (sea) province and name it.
			"[agenda_trade_node.GetTradeNodeName]": "[agenda_province.GetName]",
			//When you need to convert a province, it's obvious which religion to convert to.
			"[Root.Religion.GetName]": "", "[Root.GetReligionNoun]": "",
			//If you have Meritocracy mechanics, yeah, whatever, it's just legitimacy in the description.
			"[Root.GetLegitimacyOrMeritocracy]": "Legitimacy",
			//This might be close enough?
			"[agenda_country.GetAdjective]": "[agenda_country.GetUsableName]",
			"[Root.GetAdjective]": "",
			//These two aren't too hard, at least. Assuming they have proper localisations.
			"[agenda_province.GetAreaName]": "[" + L10N(G->CFG->prov_area[write->agenda->province]) + "]",
			"[Root.Culture.GetName]": "[" + L10N(country->primary_culture) + "]",
			//We slightly cheat here and always just use the name from the localisation files.
			//This ignores any tag-specific or culture-specific alternate naming - see the
			//triggered name blocks in /common/colonial_regions/* - but it'll usually give a
			//reasonably decent result.
			"[agenda_province.GetColonialRegionName]": "[" + L10N(G->CFG->prov_colonial_region[write->agenda->province]) + "]",
		]));
		write->agenda->desc = desc;
	}
	else if (country->estate) {
		write->agenda = ([]);
		//Can you summon the diet?
		//This requires (a) no current agenda, (b) at least five years since last diet summoned
		//(note that Supremacy agendas don't block this, though they still count as a current agenda)
		//and (c) you have to not have any of those things that prevent you from summoning, like
		//being England or not having estates.
		object agendatime = calendar(country->flags->?recent_estate_agenda || "1.1.1")->add(Calendar.Gregorian.Year() * 5);
		if (agendatime < calendar(data->date) && sizeof(country->estate) &&
				!country->all_country_modifiers->blocked_call_diet) {
			write->notifications += ({"It's possible to summon the diet"});
		}
	}
	foreach (data->map_area_data; string area; mapping info) {
		foreach (Array.arrayify(info->state->?country_state), mapping state) {
			if (state->country != tag) continue;
			if (!state->active_edict) continue;
			int unnecessary = 1;
			string highlightid = ""; //There should always be at least ONE owned province, otherwise you can't have a state!
			foreach (G->CFG->map_areas[area];; string provid) {
				mapping prov = data->provinces["-" + provid];
				if (prov->owner != tag) continue; //Ignore other people's land in your state
				highlightid = provid;
				switch (state->active_edict->which) {
					case "edict_advancement_effort": {
						//Necessary if any spawned institution is neither embraced by your
						//country nor at 100% in the province
						foreach (data->institutions; int i; string spawned) if (spawned == "1") {
							if (prov->institutions[i] != "100.000" && country->institutions[i] != "1")
								unnecessary = 0;
						}
						break;
					}
					case "edict_centralization_effort": {
						//Necessary when local autonomy is above the autonomy floor.
						//This doesn't reflect the floor, so the edict might become
						//functionally unnecessary before it gets flagged here. Note
						//that this actually ignores fractional autonomy, on the basis
						//that it's not really significant anyway.
						if ((int)prov->local_autonomy) unnecessary = 0;
						break;
					}
					case "edict_feudal_de_jure_law": {
						//Necessary when net unrest is above -5
						int unrest = provincial_unrest(data, provid);
						if (unrest > -5000) unnecessary = 0;
						break;
					}
					case "religious_tolerance_state_edict": //Special age ability if you have the right govt reform
					case "edict_religious_unity": {
						//Necessary if province does not follow state religion
						if (prov->religion != country->religion) unnecessary = 0;
						break;
					}
					default: unnecessary = 0; break; //All other edicts are presumed to be deliberate.
				}
			}
			if (unnecessary) write->notifications += ({({
				"Unnecessary ",
				(["color": G->CFG->textcolors->B * ",", "text": L10N(state->active_edict->which)]),
				" in ",
				(["color": G->CFG->textcolors->B * ",", "text": L10N(area)]),
				(["prov": highlightid, "nameoverride": ""]),
			})});
		}
	}

	write->vital_interest = map(Array.arrayify(country->vital_provinces)) {return ({__ARGS__[0], data->provinces["-" + __ARGS__[0]]->?name || "(unknown)"});};

	//What decisions and missions are open to you, and what provinces should they highlight?
	write->decisions_missions = ({ });
	array completed = country->completed_missions || ({ });
	foreach (Array.arrayify(country->country_missions->?mission_slot), array slot) {
		foreach (Array.arrayify(slot), string kwd) {
			//Each of these is a mission chain, I think. They're indexed by slot
			//which is 1-5 going across, and each mission has one or two parents
			//that have to be completed. I think that, if there are multiple
			//mission chains in a slot, they are laid out vertically. In any case,
			//we don't really care about layout, just which missions there are.
			mapping mission = G->CFG->country_missions[kwd] || ([]);
			foreach (mission; string id; mixed info) {
				if (has_value(completed, id)) continue; //Already done this mission, don't highlight it.
				string title = G->CFG->L10n[id + "_title"];
				if (!title) continue; //TODO: What happens if there's a L10n failure?
				if (!mappingp(info)) {werror("WARNING: Not mapping - %O\n", id); continue;}
				int prereq = 1;
				if (arrayp(info->required_missions)) foreach (info->required_missions, string req)
					if (!has_value(completed, req)) prereq = 0;
				if (!prereq) continue; //One or more prerequisite missions isn't completed, don't highlight it
				array interesting = enumerate_highlight_provinces(data, country, info->provinces_to_highlight);
				if (sizeof(interesting)) write->decisions_missions += ({([
					"id": id,
					"name": title,
					"provinces": interesting,
				])});
			}
		}
	}
	/* TODO: List decisions as well as missions
	- Show if major decision
	- provinces_to_highlight
	  - May list a single province_id, an area name, or a region name
	  - May instead have an OR block with zero or more of any of the above
	  - Unsure if "provinces_to_highlight { province_id = 1 area = yemen_area }" would work
	  - Filters are tricky. Look for a few of the most common, ignore the rest.
	    - NOT = { country_or_non_sovereign_subject_holds = ROOT }
	      - ie ignore everything you or a non-tributary subject owns
	    - others?
	*/
	multiset ignored = (multiset)Array.arrayify(country->ignore_decision);
	foreach (G->CFG->country_decisions; string kwd; mapping info) {
		if (ignored[kwd]) continue; //The user has said to ignore it, so hide it from the list.
		if (!trigger_matches(data, ({country}), "AND", info->potential)) continue;
		//Some missions get special handling. For the rest, show their province highlights.
		switch (kwd) {
			case "confirm_thalassocracy": {
				//This decision has two parts: Complete one of the key idea sets, and
				//get enough trade power. We're going to suppress this altogether if
				//you don't have the ideas, and show the trade power as percentages in
				//a nice table.
				if (has_value(Array.arrayify(country->modifier)->modifier, "thalassocracy")) break; //Already a thalassocrat!
				if (!country->active_idea_groups->?maritime_ideas
					&& !country->active_idea_groups->?naval_ideas
					&& !country->active_idea_groups->?trade_ideas //Technically only valid starting in 1.37 and newer but I'll show this even if you're on an older one
				) break; //If you don't have the ideas even unlocked, don't show it.
				//You need to be the strongest trader in all nodes in any one group.
				array(array) groups = ({
					({"Northern Europe", ({"lubeck", "baltic_sea", "english_channel", "north_sea", "novgorod"})}),
					({"Western Mediterranean", ({"sevilla", "valencia", "genua", "tunis", "safi"})}),
					({"Eastern Mediterranean", ({"venice", "ragusa", "alexandria", "constantinople", "aleppo"})}),
					({"Western Indian Ocean", ({"zanzibar", "gulf_of_aden", "hormuz", "gujarat", "comorin_cape"})}),
					({"Eastern Indian Ocean", ({"ganges_delta", "gulf_of_siam", "malacca", "the_moluccas", "philippines"})}),
				});
				mapping nodes_by_id = mkmapping(data->trade->node->definitions, data->trade->node);
				foreach (groups, [string label, array group]) {
					foreach (group; int i; string id) {
						mapping node = nodes_by_id[id] || ([]);
						array top = Array.arrayify(node->top_power);
						group[i] = ([
							"name": L10N(id),
							"loc": G->CFG->tradenode_definitions[id]->location,
							//Since search() returns -1 on failure, adding 1 to get to one-based ranks makes that into zero :) Convenient.
							"rank": search(top, tag) + 1,
							"percent": node->total && threeplace(node[tag]->?val || "0") * 100 / threeplace(node->total),
						]);
					}
				}
				write->decisions_missions += ({([
					"id": kwd,
					"name": L10N(kwd + "_title"),
					"trade_nodes": groups,
				])});
				break;
			}
			default:
				array interesting = enumerate_highlight_provinces(data, country, info->provinces_to_highlight);
				if (sizeof(interesting)) write->decisions_missions += ({([
					"id": kwd,
					"name": L10N(kwd + "_title"),
					"provinces": interesting,
				])});
		}
	}

	//Get some info about provinces, for the sake of the province details view
	write->province_info = (mapping)map((array)data->provinces) {[[string id, mapping prov]] = __ARGS__;
		return ({id - "-", ([
			"discovered": has_value(Array.arrayify(prov->discovered_by), tag),
			"controller": prov->controller, "owner": prov->owner,
			"name": prov->name,
			"wet": G->CFG->terrain_definitions->categories[G->CFG->province_info[id - "-"]->?terrain]->?is_water,
			"terrain": G->CFG->province_info[id - "-"]->?terrain,
			"climate": G->CFG->province_info[id - "-"]->?climate,
			"has_port": G->CFG->province_info[id - "-"]->?has_port,
			//"raw": prov,
		])});
	};

	//Get some info about trade nodes
	array all_nodes = data->trade->node;
	mapping trade_nodes = mkmapping(all_nodes->definitions, all_nodes);
	write->trade_nodes = analyze_trade_node(data, trade_nodes, tag, G->CFG->tradenode_upstream_order[*], prefs);

	//Get info about mil tech levels and which ones are important
	write->miltech = ([
		"current": (int)country->technology->mil_tech,
		"group": country->technology_group,
		"units": country->unit_type,
		"groupname": L10N(country->technology_group),
		"levels": G->CFG->military_tech_levels,
	]);

	//List all cultures present in your nation, and the impact of promoting or demoting them.
	mapping cultures = ([]);
	string primary = country->primary_culture;
	array accepted = Array.arrayify(country->accepted_culture);
	int cultural_union = country->government_rank == "3"; //Empire rank, no penalty for brother cultures
	int is_republic = all_country_modifiers(data, country)->republic ? 50 : 0;
	array brother_cultures = ({ });
	foreach (G->CFG->culture_definitions; string group; mapping info) if (info[primary]) brother_cultures = indices(info);
	void affect(mapping culture, string cat, int amount, int autonomy, int impact) {
		culture[cat + "_base"] += amount;
		culture[cat + "_auto"] += amount * (100000 - autonomy) / 100000;
		culture[cat + "_impact"] += amount * impact / 1000;
		culture[cat + "_impact_auto"] += amount * (100000 - autonomy) * impact / 100000000;
	}
	//The penalties for tax and manpower are the same; sailors have reduced penalties. (Note that sailors
	//won't spawn from development on non-coastal provinces, and you can't normally build Impressment there,
	//so generally you'll get nothing from inland provinces.) Republics reduce the penalty for foreign.
	//Tax/manpower: accepted 0%, brother 15%, republic 23%, foreign 33%
	//Sailors: accepted 0%, brother 10%, republic 15%, foreign 20%
	foreach (country->owned_provinces, string id) {
		mapping prov = data->provinces["-" + id];
		mapping culture = cultures[prov->culture];
		if (!culture) culture = cultures[prov->culture] = ([
			"label": L10N(prov->culture),
			"status": prov->culture == primary ? "primary"
				: has_value(brother_cultures, prov->culture) ? "brother"
				: "foreign",
			"accepted": prov->culture == primary ? 2 : has_value(accepted, prov->culture),
		]);
		culture->provcount++;
		int tax = threeplace(prov->base_tax), manpower = threeplace(prov->base_manpower);
		int dev = tax + threeplace(prov->base_production) + manpower;
		culture->total_dev += dev;
		int autonomy = threeplace(prov->local_autonomy);
		//Tax revenue is 1 ducat/year per base tax. There are, in theory, other sources of
		//base revenue in a province, but they're unlikely so we'll ignore them here.
		int impact = culture->status == "brother" ? 150 * !cultural_union
			: culture->status == "foreign" ? 330 - is_republic * 2 : 0;
		affect(culture, "tax", tax / 12, autonomy, impact);
		//Manpower is 250 per base tax, with a very real source of additional base manpower.
		int mp = manpower * 250;
		if (prov->buildings->?soldier_households)
			mp += has_value(G->CFG->building_types->soldier_households->bonus_manufactory, prov->trade_goods) ? 1500000 : 750000;
		affect(culture, "manpower", mp, autonomy, impact);
		//Sailors are 60 per base dev _of any kind_, with a manufactory. They also have
		//different percentage impact for culture discrepancies.
		int sailors = G->CFG->province_info[id]->?has_port && dev * 60;
		impact = culture->status == "brother" ? 100 * !cultural_union
			: culture->status == "foreign" ? 200 - is_republic : 0;
		if (prov->buildings->?impressment_offices)
			sailors += has_value(G->CFG->building_types->impressment_offices->bonus_manufactory, prov->trade_goods) ? 500000 : 250000;
		affect(culture, "sailors", sailors, autonomy, impact);
	}
	//List accepted cultures first, then non-accepted, in order of impact.
	array all_cultures = values(cultures);
	sort(-all_cultures->manpower_impact[*], all_cultures);
	sort(-all_cultures->accepted[*], all_cultures);
	write->cultures = ([
		"accepted_cur": sizeof(accepted),
		"accepted_max": 2 + all_country_modifiers(data, country)->num_accepted_cultures / 1000,
		"cultures": all_cultures,
	]);

	write->unguarded_rebels = ({ });
	foreach (Array.arrayify(data->rebel_faction), mapping faction) if (faction->country == tag) {
		//werror("Faction: %O\n", faction);
		//NOTE: faction->province is a single province ID. Not sure what it is.
		//NOTE: faction->active is a thing. Maybe says if rebels have spawned??
		//What happens with rebels that spawn without unrest (eg pretenders)? Don't crash.
		//What if rebels cross the border? (Probably not in this list, since ->country != tag)
		//TODO: Find all possible_provinces which have >0 unrest (if none, ignore this faction)
		//Show faction and all provinces with unrest; highlight those provinces not guarded.
		//Notify if any provinces are unguarded. Priority notify if any unguarded and progress > 50%.
		//Can we assume that every province will be included in one of these factions? Probably.
		//if ((int)faction->progress < 30) continue; //Could be null, otherwise is eg "10.000" for 10% progress
		array uncovered = ({ });
		foreach (faction->possible_provinces || ({ }), string provid) {
			[int unrest, array(string) sources] = provincial_unrest(data, provid, 1);
			if (unrest > 0 && !country->rebel_suppression_coverage[provid])
				uncovered += ({(["id": provid, "unrest": unrest, "sources": sources])});
		}
		if (sizeof(uncovered)) write->unguarded_rebels += ({([
			"provinces": uncovered,
			"name": faction->name,
			"progress": (int)faction->progress || 0, //(force integer zero rather than null)
			"home_province": faction->province, //Probably irrelevant
		])});
	}

	write->subjects = ({ });
	mapping subjects = ([]);
	foreach (Array.arrayify(data->diplomacy->dependency), mapping dep)
		subjects[dep->first + dep->second] = dep; //Is it ever possible to be subjugated in two ways at once?
	//Years to integrate/annex. If not present, integration not possible.
	constant integration = ([
		"personal_union": 50,
		"vassal": 10, "daimyo_vassal": 10, "client_vassal": 10, //Assuming all these have the same ten-year delay?
		"core_eyalet": 10, //Ottoman special vassal type.
		"appanage": 10, //French special vassal type. Can we calculate all these from the files somewhere?
	]);
	foreach (Array.arrayify(country->subjects), string|mapping stag) {
		mapping subj = data->countries[stag];
		mapping dep = subjects[tag + stag] || ([]);
		array relations = ({ });
		int impr = 0;
		foreach (Array.arrayify(subj->active_relations[tag]->?opinion), mapping opine) {
			if (opine->modifier == "improved_relation") impr = threeplace(opine->current_opinion);
			relations += ({opine | (G->CFG->opinion_modifiers[opine->modifier]||([])) | (["name": L10N(opine->modifier)])});
		}
		int integ = integration[dep->subject_type];
		string integration_date = "n/a";
		int can_integrate = 0;
		if (integ) {
			sscanf(dep->start_date, "%d.%d.%d", int y, int m, int d);
			integration_date = sprintf("%d.%d.%d", y + integ, m, d);
			sscanf(data->date, "%d.%d.%d", int yy, int mm, int dd);
			if (sprintf("%4d.%02d.%02d", y + integ, m, d) <= sprintf("%4d.%02d.%02d", yy, mm, dd))
				can_integrate = 1;
		}
		write->countries[stag]->relations = relations; //TODO: Provide this for all countries, not just subjects
		int integration_cost, integration_speed;
		string integration_finished;
		if (integration_date != "n/a") {
			//Calculate the annexation cost. This is their total development,
			//minus any provinces that we have core on, modified by annexation
			//cost modifiers. Also, to make this relevant, we also need to know
			//how much diplo power we can pour into annexation per month.
			int dev = threeplace(subj->development); //TODO: Subtract out any cores we have (or count dev ourselves from the provinces)
			//NOTE: This isn't shown on the wiki, but if a subject has fractional dev, it seems to get rounded up.
			//Need to test this further. For now, sticking with the precise value.
			mapping overlord = all_country_modifiers(data, country);
			//mapping subject = all_country_modifiers(data, subj);
			//werror("%O: Dev %d admin eff %d mods %d power cost %d\n",
			//	stag, dev, overlord->administrative_efficiency, overlord->diplomatic_annexation_cost, overlord->all_power_cost);
			dev = dev * 8 //Base annexaction cost is 8 diplo power
				* (1000 + overlord->administrative_efficiency)
				* (1000 + overlord->diplomatic_annexation_cost)
				* (1000 + overlord->all_power_cost)
				/ 1000000000000; //Rescale to integers (dev is in threeplace)
			integration_cost = dev;
			integration_speed = 2 + (subj->religion == country->religion) + overlord->diplomatic_reputation / 1000;
			if (subj->primary_culture == country->primary_culture) integration_speed++; //Same primary culture? Definitely same group.
			else {
				//I don't think there's an easy way to go from a culture to a group.
				foreach (G->CFG->culture_definitions; string key; mapping grp)
					if (grp[country->primary_culture]) {
						if (grp[subj->primary_culture]) integration_speed++;
						break;
					}
			}
			//Can't integrate yet? Estimate from when we can. Can? Estimate from today.
			//Already started? Estimate from today and reduce the cost by progress.
			string date = !can_integrate ? integration_date : data->date;
			foreach (Array.arrayify(data->diplomacy->annexation), mapping dep)
				if (dep->first == tag && dep->second == stag) {
					date = data->date;
					integration_cost -= (int)dep->progress;
				}
			sscanf(date, "%d.%d.", int yy, int mm);
			if (integration_speed > 0) {
				int months = integration_cost / integration_speed; //We need to round up. Easiest to add another month at the end.
				yy += (mm + months) / 12;
				mm = (mm + months) % 12 + 1; //Adding a month here means zero cost equals next month.
				integration_finished = sprintf("%d.%d.1", yy, mm);
			}
		}
		write->subjects += ({([
			"tag": stag,
			"type": dep->subject_type ? L10N(dep->subject_type + "_title") : "(unknown)",
			"improved": impr,
			"liberty_desire": subj->cached_liberty_desire,
			"start_date": dep->start_date, "integration_date": integration_date,
			"can_integrate": can_integrate, "integration_cost": integration_cost,
			"integration_speed": integration_speed, "integration_finished": integration_finished,
		])});
	}

	write->golden_eras = ({ });
	array sortkeys = ({ });
	sscanf(data->date, "%d.%d.%d", int nowy, int nowm, int nowd);
	int now = nowy * 10000 + nowm * 100 + nowd;
	foreach (data->countries;; mapping c) if (c->golden_era_date) {
		sscanf(c->golden_era_date, "%d.%d.%d", int y, int m, int d);
		//TODO: See what happens when a golden era is extended
		int sortkey = (y + 50) * 10000 + m * 100 + d; sortkeys += ({sortkey});
		write->golden_eras += ({([
			"tag": c->tag,
			"startdate": c->golden_era_date,
			"enddate": sprintf("%d.%d.%d", y + 50, m, d),
			"active": sortkey >= now,
		])});
	}
	sort(sortkeys, write->golden_eras);
}

void analyze(mapping data, string name, string tag, mapping write, mapping|void prefs) {
	write->name = name + " (" + (data->countries[tag]->name || L10N(tag)) + ")";
	write->fleetpower = prefs->fleetpower || 1000;
	({analyze_cot, analyze_leviathans, analyze_furnace, analyze_upgrades})(data, name, tag, write);
	analyze_obscurities(data, name, tag, write, prefs || ([]));
	if (string highlight = prefs->highlight_interesting) analyze_findbuildings(data, name, tag, write, highlight);
}

//Not currently triggered from anywhere. Doesn't currently have a primary use-case.
void show_tradegoods(mapping data, string tag) {
	//write("Sevilla: %O\n", data->provinces["-224"]);
	//write("Demnate: %O\n", data->provinces["-4568"]);
	mapping prod = ([]), count = ([]);
	mapping country = data->countries[tag];
	float prod_efficiency = 1.0;
	foreach (country->owned_provinces, string id) {
		mapping prov = data->provinces["-" + id];
		//1) Goods produced: base production * 0.2 + flat modifiers (eg Manufactory)
		int production = threeplace(prov->base_production) / 5;
		//2) Trade value: goods * price
		float trade_value = production * (float)data->change_price[prov->trade_goods]->current_price / 1000;
		//3) Prod income: trade value * national efficiency * local efficiency * (1 - autonomy)
		float local_efficiency = 1.0, autonomy = 0.0; //TODO.
		float prod_income = trade_value * prod_efficiency * local_efficiency * (1.0 - autonomy);
		//Done. Now gather the stats.
		prod[prov->trade_goods] += prod_income;
		count[prov->trade_goods]++;
	}
	float total_value = 0.0;
	array goods = indices(prod); sort(-values(prod)[*], goods);
	foreach (goods, string tradegood) {
		float annual_value = prod[tradegood];
		if (annual_value > 0) write("%.2f/year from %d %s provinces\n", annual_value, count[tradegood], tradegood);
		total_value += annual_value;
	}
	write("Total %.2f/year or %.4f/month\n", total_value, total_value / 12);
}

void analyze_flagships(mapping data, mapping write) {
	array flagships = ({ });
	foreach (data->countries; string tag; mapping country) {
		//mapping country = data->countries[tag];
		if (!country->navy) continue;
		foreach (Array.arrayify(country->navy), mapping fleet) {
			foreach (Array.arrayify(fleet->ship), mapping ship) {
				if (!ship->flagship) continue;
				string was = ship->flagship->is_captured && ship->flagship->original_owner;
				string cap = was ? " CAPTURED from " + (data->countries[was]->name || L10N(was)) : "";
				flagships += ({({
					tag, fleet->name,
					L10N(ship->type), ship->name,
					L10N(ship->flagship->modification[*]),
					ship->flagship->is_captured ? (data->countries[was]->name || L10N(was)) : ""
				})});
			}
		}
	}
	sort(flagships);
	write->flagships = flagships;
}

void analyze_wars(mapping data, multiset(string) tags, mapping write) {
	write->wars = (["current": ({ }), "rumoured": G->G->war_rumours]);
	foreach (values(Array.arrayify(data->active_war)), mapping war) {
		if (!mappingp(war)) continue; //Dunno what's with these, there seem to be some strings in there.
		//To keep displaying the war after all players separate-peace out, use
		//war->persistent_attackers and war->persistent_defenders instead.
		int is_attacker = war->attackers && sizeof((multiset)war->attackers & tags);
		int is_defender = war->defenders && sizeof((multiset)war->defenders & tags);
		if (!is_attacker && !is_defender) continue; //Irrelevant bickering somewhere in the world.
		//If there are players on both sides of the war, show "attackers" and "defenders".
		//But if all players are on one side of a war, show "allies" and "enemies".
		string atk = "\U0001f5e1\ufe0f", def = "\U0001f6e1\ufe0f";
		int defender = is_defender && !is_attacker;
		if (defender) [atk, def] = ({def, atk});
		mapping summary = (["date": war->action, "name": war->name, "raw": war, "atk": is_attacker, "def": is_defender]);
		summary->cb = war->superiority || war->take_province || war->blockade_ports || (["casus_belli": "(none)"]);
		//TODO: See if there are any other war goals
		//NOTE: In a no-CB war, there is no war goal, so there'll be no attribute to locate.
		write->wars->current += ({summary});
		//war->action is the date it started?? Maybe the last date when a call to arms is valid?
		//war->called - it's all just numbers, no country tags. No idea.

		//Ticking war score is either war->defender_score or war->attacker_score and is a positive number.
		float ticking_ws = (float)(war->attacker_score || "-" + war->defender_score);
		if (defender) ticking_ws = -ticking_ws;
		//Overall war score?? Can't figure that out. It might be that it isn't stored.

		//war->participants[*]->value is the individual contribution. To turn this into a percentage,
		//be sure to sum only the values on one side, as participants[] has both sides of the war in it.
		array armies = ({ }), navies = ({ });
		array(array(int)) army_total = ({allocate(8), allocate(8)});
		array(array(int)) navy_total = ({allocate(6), allocate(6)});
		summary->participants = ({ });
		foreach (war->participants, mapping p) {
			mapping partic = (["tag": p->tag]);
			summary->participants += ({partic});
			mapping country = data->countries[p->tag];
			int a = has_value(war->attackers || ({ }), p->tag), d = has_value(war->defenders || ({ }), p->tag);
			if (!a && !d) continue; //War participant has subsequently peaced out
			partic->attacker = a; partic->defender = d; partic->player = tags[p->tag];
			string side = sprintf("\e[48;2;%d;%d;%dm%s  ",
				a && 30, //Red for attacker
				tags[p->tag] && 60, //Cyan or olive for player
				d && 30,
				a ? atk : def, //Sword or shield
			);
			side = (({a && "attacker", d && "defender", tags[p->tag] && "player"}) - ({0})) * ",";
			//I don't know how to recognize that eastern_militia is infantry and muscovite_cossack is cavalry.
			//For land units, we can probably assume that you use only your current set. For sea units, there
			//aren't too many (and they're shared by all nations), so I just hard-code them.
			mapping unit_types = mkmapping(values(country->sub_unit), indices(country->sub_unit));
			mapping mil = ([]), mercs = ([]);
			if (country->army) foreach (Array.arrayify(country->army), mapping army) {
				string merc = army->mercenary_company ? "merc_" : "";
				foreach (Array.arrayify(army->regiment), mapping reg) {
					//Note that regiment strength is eg "0.807" for 807 men. We want the
					//number of men, so there's no need to re-divide.
					mil[merc + unit_types[reg->type]] += reg->strength ? threeplace(reg->strength) : 1000;
				}
			}
			if (country->navy) foreach (Array.arrayify(country->navy), mapping navy) {
				foreach (Array.arrayify(navy->ship), mapping ship) {
					mil[ship_types[ship->type]] += 1; //Currently not concerned about hull strength. You either have or don't have a ship.
				}
			}
			int mp = threeplace(country->manpower);
			int total_army = mil->infantry + mil->cavalry + mil->artillery + mil->merc_infantry + mil->merc_cavalry + mil->merc_artillery;
			armies += ({({
				-total_army * 1000000000 - mp,
				({
					side, p->tag,
					mil->infantry, mil->cavalry, mil->artillery,
					mil->merc_infantry, mil->merc_cavalry, mil->merc_artillery,
					total_army, mp,
					sprintf("%3.0f%%", (float)country->army_professionalism * 100.0),
					sprintf("%3.0f%%", (float)country->army_tradition),
				}),
			})});
			army_total[d] = army_total[d][*] + armies[-1][1][2..<2][*];
			int sailors = (int)country->sailors; //Might be 0, otherwise is eg "991.795" (we don't care about the fraction, this means 991 sailors)
			int total_navy = mil->heavy_ship + mil->light_ship + mil->galley + mil->transport;
			navies += ({({
				-total_navy * 1000000000 - sailors,
				({
					side, p->tag,
					mil->heavy_ship, mil->light_ship, mil->galley, mil->transport, total_navy, sailors,
					sprintf("%3.0f%%", (float)country->navy_tradition),
				}),
			})});
			navy_total[d] = navy_total[d][*] + navies[-1][1][2..<1][*];
		}
		string atot = "attacker,total", dtot="defender,total";
		armies += ({
			//The totals get sorted after the individual country entries. Their sort keys are
			//guaranteed positive, and are such that the larger army has a smaller sort key.
			//Easiest way to do that is to swap them :)
			({1 + army_total[1][-2] + army_total[1][-1], ({atot, ""}) + army_total[0] + ({"", ""})}),
			({1 + army_total[0][-2] + army_total[0][-1], ({dtot, ""}) + army_total[1] + ({"", ""})}),
		});
		navies += ({
			({1 + navy_total[1][-2] + navy_total[1][-1], ({atot, ""}) + navy_total[0] + ({""})}),
			({1 + navy_total[0][-2] + navy_total[0][-1], ({dtot, ""}) + navy_total[1] + ({""})}),
		});
		sort(armies); sort(navies);
		summary->armies = armies[*][-1]; summary->navies = navies[*][-1];
	}
}

/* TODO:
1. Enumerate all areas in which you have provinces. Show whether state or not.
2. For each state, show and sum the governing cost. Should match the in-game display.
3. For each territory, show the number of provinces with full cores vs territorial cores vs trade company vs colony
4. Predict the REAL governing cost of stating that area.

Note that a lot of this info IS available in-game, but only as raw numbers. For example, attempting to state a territory
will tell you the increase in cost that would occur, but you then have to check that against others. Also, the current
usage does not update for colonial core to full core transitions until EOM.
*/
void analyze_states(mapping data, string name, string tag, mapping write, mapping prefs) {
	mapping country = data->countries[tag];
	//string base_province = "1166"; //Loango in Kongolese Coast (territory)
	string base_province = "4549"; //Xativa in Valencia (state)
	//string base_province = "183"; //Paris in Ile-de-France (state)
	foreach (G->CFG->map_areas[G->CFG->prov_area[base_province]], string id) m_delete(data->provinces["-" + id], "all_province_modifiers"); //Decache
	mapping area = all_area_modifiers(data, G->CFG->prov_area[base_province]);
	mapping nation = all_country_modifiers(data, country);
	int is_state = has_value(Array.arrayify(data->map_area_data[G->CFG->prov_area[base_province]]->?state->?country_state)->country, tag);
	werror("Area [%s]: %O\n", is_state ? "state" : "territory", area);
	foreach (G->CFG->map_areas[G->CFG->prov_area[base_province]], string id) {
		mapping prov = all_province_modifiers(data, (int)id) - (<"_index", "_sources">);
		int cost = prov->development * 1000;
		int mod = 1000 + prov->local_governing_cost + area->statewide_governing_cost + nation->governing_cost;
		if (is_state) mod += nation->state_governing_cost; //Check these!
		else mod += nation->territory_governing_cost - 750; //Territories get a 75% discount
		//TODO: Colonial core - 50% reduction
		//TODO: territory_governing_cost, trade_company_governing_cost, state_governing_cost
		if (mod < 10) mod = 10; //Can't get the percentage modifiers stronger than a 99% discount
		werror("%s: %O\n", data->provinces["-" + id]->name, prov);
		werror("%s: %d * %d/1000 %+d\n", data->provinces["-" + id]->name, cost, mod, prov->local_governing_cost_increase);
		cost = (cost * mod) / 1000 + prov->local_governing_cost_increase;
		if (cost < 0) cost = 0; //But a state house can reduce it all the way to zero.
		werror("%s: %d\n", data->provinces["-" + id]->name, cost);
	}
}

protected void create() {
	mapping data = G->G->last_parsed_savefile;
	if (!data) return;
	//analyze_states(data, "Rosuav", data->players_countries[1], write, ([]));
	//analyze_obscurities(data, "Rosuav", data->players_countries[1], write, ([]));
	//NOTE: Tolerances seem to be being incorrectly calculated for theocracies.
	//NOTE: Reform "Expand Temple Rights" aka secure_clergy_power_reform does not
	//seem to properly apply its effect. Possible issue with has_tax_building_trigger?
	//werror("702: %O\n", provincial_unrest(data, "702", 1));
	mapping country = data->countries[data->player];
	m_delete(country, "all_country_modifiers");
	mapping attrs = all_country_modifiers(data, country);
	foreach (({
		"military_tactics", "discipline", "base_land_morale", "land_morale",
		"infantry_fire", "infantry_shock",
		"cavalry_fire", "cavalry_shock",
		"artillery_fire", "artillery_shock",
		"infantry_power", "cavalry_power", "artillery_power",
		"morale_damage", "morale_damage_received",
		"global_defender_dice_roll_bonus", "global_attacker_dice_roll_bonus",
		"combat_width",
	}), string mod) {
		werror("%s: %d%{\n\t%s%}\n", L10N(mod), attrs[mod], attrs->_sources[mod] || ({ }));
	}
	return;
	DEBUG_TRIGGER_MATCHES = 1;
	foreach (G->CFG->triggered_modifiers; string id; mapping mod) {
		string label = "Applicable!";
		if (mod->potential && !trigger_matches(data, ({country}), "AND", mod->potential)) label = "Not potent.";
		else if (!trigger_matches(data, ({country}), "AND", mod->trigger)) label = "Not trigger";
		werror("%s -- Triggered Modifier: %s %O\n", label, id, L10N(id));
	}
	DEBUG_TRIGGER_MATCHES = 0;
}
