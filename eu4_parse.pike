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

string L10N(string key) {return CFG->L10n[key] || key;}

string tabulate(array(string) headings, array(array(mixed)) data, string|void gutter, int|void summary) {
	if (!gutter) gutter = " ";
	array info = ({headings}) + (array(array(string)))data;
	array(int) widths = map(Array.transpose(info)) {return max(@sizeof(__ARGS__[0][*]));};
	//Hack: First column isn't size-counted or guttered. It's for colour codes and such.
	string fmt = sprintf("%%%ds", widths[1..][*]) * gutter;
	//If there's a summary row, insert a ruler before it. (You can actually have multiple summary rows if you like.)
	if (summary) info = info[..<summary] + ({({headings[0]}) + "\u2500" * widths[1..][*]}) + info[<summary-1..];
	return sprintf("%{%s" + fmt + "\e[0m\n%}", info);
}

int threeplace(string value) {
	//EU4 uses three-place fixed-point for a lot of things. Return the number as an integer,
	//ie "3.142" is returned as 3142. Can handle "-0.1" and "-.1", although to my knowledge,
	//the EU4 files never contain the latter.
	if (!value) return 0;
	sscanf(value, "%[-]%[0-9].%[0-9]", string neg, string whole, string frac);
	return (neg == "-" ? -1 : 1) * ((int)whole * 1000 + (int)sprintf("%.03s", frac + "000"));
}

int interest_priority = 0;
array(string) interesting_province = ({ });
enum {PRIO_UNSET, PRIO_SITUATIONAL, PRIO_IMMEDIATE, PRIO_EXPLICIT};
void interesting(string id, int|void prio) {
	if (prio < interest_priority) return; //We've already had higher priority markers
	if (prio > interest_priority) {interest_priority = prio; interesting_province = ({ });} //Replace with new highest prio
	if (!has_value(interesting_province, id)) interesting_province += ({id}); //Retain order but avoid duplicates
}

mapping province_info;
mapping building_slots = ([]);
void analyze_cot(mapping data, string name, string tag, function|mapping write) {
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
		if (prov->center_of_trade == "3") {maxlvl += ({desc}); area_has_level3[CFG->prov_area[id]] = (int)id;}
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
		array have_states = data->map_area_data[CFG->prov_area[id]]->?state->?country_state->?country;
		string noupgrade;
		if (!have_states || !has_value(have_states, tag)) noupgrade = "is territory";
		else if (cotlevel == "2") {
			if (area_has_level3[CFG->prov_area[id]]) noupgrade = "other l3 in area";
			else if (++level3 > maxlevel3) noupgrade = "need merchants";
		}
		if (!noupgrade) {interesting(id, prio); maxprio = max(prio, maxprio);}
		if (mappingp(write)) return ([
			"id": id, "dev": dev, "name": provname, "tradenode": tradenode,
			"noupgrade": noupgrade || "",
			"level": (int)cotlevel, "interesting": !noupgrade && prio,
		]);
		string desc = sprintf("%s\tLvl %s\tDev %d\t%s", id, cotlevel, dev, string_to_utf8(provname));
		if (noupgrade) return sprintf("%s [%s]", desc, noupgrade);
		else return color + desc;
	}
	if (mappingp(write)) {
		write->cot = ([
			"level3": level3, "max": maxlevel3,
			"upgradeable": colorize("", upgradeable[*], PRIO_IMMEDIATE),
			"developable": colorize("", developable[*], PRIO_SITUATIONAL),
		]);
		write->cot->maxinteresting = maxprio;
		return;
	}
	if (sizeof(maxlvl)) write("Max level CoTs (%d/%d):\n%{%s\n%}\n", level3, maxlevel3, maxlvl[*][-1]);
	else write("Max level CoTs: 0/%d\n", maxlevel3);
	if (sizeof(upgradeable)) write("Upgradeable CoTs:\n%{%s\e[0m\n%}\n", colorize("\e[1;32m", upgradeable[*], PRIO_IMMEDIATE));
	if (sizeof(developable)) write("Developable CoTs:\n%{%s\e[0m\n%}\n", colorize("\e[1;36m", developable[*], PRIO_SITUATIONAL));
}

object calendar(string date) {
	sscanf(date, "%d.%d.%d", int year, int mon, int day);
	return Calendar.Gregorian.Day(year, mon, day);
}

//Pass the full data block, and for scopes, a sequence of country and/or province mappings.
//Triggers are tested on scopes[-1], and PREV= will switch to scopes[-2].
//What happens if you do "PREV = { PREV = { ... } }" ? Should we shorten the scopes array
//or duplicate scopes[-2] to the end of it?
int(1bit) trigger_matches(mapping data, array(mapping) scopes, string type, mixed value) {
	mapping scope = scopes[-1];
	switch (type) {
		case "AND":
			foreach (value; string t; mixed v)
				//Does this need to do the array check same as OR= does?
				if (!trigger_matches(data, scopes, t, v)) return 0;
			return 1;
		case "OR":
			foreach (value; string t; mixed vv)
				foreach (Array.arrayify(vv), mixed v) //Would it be more efficient to arrayp check rather than arrayifying?
					if (trigger_matches(data, scopes, t, v)) return 1;
			return 0;
		case "NOT": return !trigger_matches(data, scopes, "OR", value);
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
		case "trade_income_percentage":
			//Estimate trade income percentage based on last month's figures. I don't know
			//whether the actual effect changes within the month, but this is likely to be
			//close enough anyway. The income table runs ({tax, prod, trade, gold, ...}).
			if (!scope->ledger->lastmonthincometable) return 0; //No idea why, but sometimes this is null. I guess we don't have data??
			return threeplace(scope->ledger->lastmonthincometable[2]) * 1000 / threeplace(scope->ledger->lastmonthincome)
				>= threeplace(value);
		case "has_disaster": return 0; //TODO: Where are current disasters listed?
		case "religion_group":
			//Calculated slightly backwards; instead of asking what religion group the
			//country is in, and then seeing if that's equal to value, we look up the
			//list of religions in the group specified, and ask if the country's is in
			//that list.
			return !undefinedp(CFG->religion_definitions[value][scope->religion]);
		//case "dominant_religion": //TODO
		case "technology_group": return scope->technology_group == value;
		case "has_country_modifier": case "has_ruler_modifier":
			//Hack: I'm counting ruler modifiers the same way as country modifiers.
			return has_value(Array.arrayify(scope->modifier)->modifier, value);
		//Province scope.
		case "development": {
			int dev = (int)scope->base_tax + (int)scope->base_production + (int)scope->base_manpower;
			return dev >= (int)value;
		}
		case "province_has_center_of_trade_of_level": return (int)scope->center_of_trade >= (int)value;
		case "area": return CFG->prov_area[(string)scope->id] == value;
		//Possibly universal scope
		case "has_global_flag": return !undefinedp(data->flags[value]);
		default: return 1; //Unknown trigger. Let it match, I guess - easier to spot? Maybe?
	}
	
}

//List all ideas (including national) that are active
array(mapping) enumerate_ideas(mapping idea_groups) {
	array ret = ({ });
	foreach (idea_groups; string grp; string numtaken) {
		mapping group = CFG->idea_definitions[grp]; if (!group) continue;
		ret += ({group->start}) + group->ideas[..(int)numtaken - 1];
		if (numtaken == "7") ret += ({group->bonus});
	}
	return ret - ({0});
}

//Gather ALL a country's modifiers. Or, try to. Note that conditional modifiers aren't included.
void _incorporate(mapping data, mapping modifiers, string source, mapping effect, int|void mul, int|void div) {
	if (effect) foreach (effect; string id; mixed val) {
		if ((id == "modifier" || id == "modifiers") && mappingp(val)) _incorporate(data, modifiers, source, val, mul, div);
		if (id == "conditional" && mappingp(val)) {
			//Conditional attributes. We understand a very limited set of them here.
			//If in doubt, incorporate them. That might be an unideal default though.
			int ok = 1;
			foreach (val->allow || ([]); string key; string val) switch (key) {
				case "has_dlc": if (!has_value(data->dlc_enabled, val)) ok = 0; break;
				default: break;
			}
			if (ok) _incorporate(data, modifiers, source, val, mul, div);
		}
		if (id == "custom_attributes") _incorporate(data, modifiers, source, val, mul, div); //Government reforms have some special modifiers. It's easiest to count them as country modifiers.
		int effect = 0;
		if (stringp(val) && sscanf(val, "%[-]%d%*[.]%[0-9]%s", string sign, int whole, string frac, string blank) && blank == "")
			modifiers[id] += effect = (sign == "-" ? -1 : 1) * (whole * 1000 + (int)sprintf("%.03s", frac + "000")) * (mul||1) / (div||1);
		if (intp(val) && val == 1) modifiers[id] = effect = 1; //Boolean
		if (effect) modifiers->_sources[id] += ({source + ": " + effect});
	}
}
void _incorporate_all(mapping data, mapping modifiers, string source, mapping definitions, array keys, int|void mul, int|void div) {
	foreach (Array.arrayify(keys), string key)
		_incorporate(data, modifiers, sprintf("%s %O", source, L10N(key)), definitions[key], mul, div);
}
mapping(string:int) all_country_modifiers(mapping data, mapping country) {
	if (mapping cached = country->all_country_modifiers) return cached;
	mapping modifiers = (["_sources": ([])]);
	//Ideas are recorded by their groups and how many you've taken from that group.
	array ideas = enumerate_ideas(country->active_idea_groups);
	_incorporate(data, modifiers, ideas->desc[*], ideas[*]); //TODO: TEST ME
	//NOTE: Custom nation ideas are not in an idea group as standard ideas are; instead
	//you get a set of ten, identified by index, in country->custom_national_ideas, and
	//it doesn't say which ones you have. I think the last three are the traditions and
	//ambition and the first seven are the ideas themselves, but we'll have to count up
	//the regular ideas and see how many to apply. It's possible that that would be out
	//of sync, but it's unlikely. TODO: Test what happens if you remove an idea group.
	if (array ideaids = country->custom_national_ideas) {
		//First, figure out how many ideas you have. We assume that, if you have
		//custom ideas, you don't also have a country idea set; which means that the
		//ideas listed are exclusively ones from idea sets. On the assumption that
		//you get one national idea for every three currently-held unlockable ideas
		//(which may not be true if an idea set is removed), sum them and calculate.
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
			mapping defn = CFG->custom_ideas[(int)idea->index];
			_incorporate(data, modifiers, "Custom idea - " + L10N(defn->id), defn, (int)idea->level, 1);
		}
	}
	_incorporate_all(data, modifiers, "Policy", CFG->policy_definitions, Array.arrayify(country->active_policy)->policy);
	_incorporate_all(data, modifiers, "Reform", CFG->reform_definitions, country->government->reform_stack->reforms);
	array tradebonus = CFG->trade_goods[((array(int))Array.arrayify(country->traded_bonus))[*]];
	_incorporate(data, modifiers, ("Trading in " + tradebonus->id[*])[*], tradebonus[*]); //TODO: TEST ME
	_incorporate_all(data, modifiers, "Modifier", CFG->country_modifiers, Array.arrayify(country->modifier)->modifier);
	mapping age = CFG->age_definitions[data->current_age]->abilities;
	_incorporate(data, modifiers, "Age ability", age[Array.arrayify(country->active_age_ability)[*]][*]); //TODO: Add description
	mapping tech = country->technology || ([]);
	sscanf(data->date, "%d.%d.%d", int year, int mon, int day);
	foreach ("adm dip mil" / " ", string cat) {
		int level = (int)tech[cat + "_tech"];
		string desc = String.capitalize(cat) + " tech";
		_incorporate_all(data, modifiers, desc, CFG->tech_definitions[cat]->technology, enumerate(level));
		if ((int)CFG->tech_definitions[cat]->technology[level]->year > year)
			_incorporate(data, modifiers, "Ahead of time in " + desc, CFG->tech_definitions[cat]->ahead_of_time);
		//TODO: > or >= ?
	}
	if (array have = country->institutions) foreach (CFG->institutions; string id; mapping inst) {
		if (have[inst->_index] == "1") _incorporate(data, modifiers, "Institution", inst->bonus);
	}
	//More modifier types to incorporate:
	//- Monuments. Might be hard, since they have restrictions. Can we see in the savefile if they're active?
	//- Religious modifiers (icons, cults, aspects, etc)
	//- Government type modifiers (eg march, vassal, colony)
	//- Naval tradition (which affects trade steering and thus the trade recommendations)
	//- Being a trade league leader (scaled by the number of members)
	//- Stability

	if (country->luck) _incorporate(data, modifiers, "Luck", CFG->static_modifiers->luck); //Lucky nations (AI-only) get bonuses.
	if (int innov = threeplace(country->innovativeness)) _incorporate(data, modifiers, "Innovativeness", CFG->static_modifiers->innovativeness, innov, 100000);
	if (int corr = threeplace(country->corruption)) _incorporate(data, modifiers, "Corruption", CFG->static_modifiers->corruption, corr, 100000);
	//Having gone through all of the above, we should now have estate influence modifiers.
	//Now we can calculate the total influence, and then add in the effects of each estate.
	if (country->estate) {
		//Some estates might not work like this. Not sure.
		//First, incorporate country-wide modifiers from privileges. (It's possible for privs to
		//affect other estates' influences.)
		country->estate = Array.arrayify(country->estate); //In case there's only one estate
		foreach (country->estate, mapping estate) {
			foreach (Array.arrayify(estate->granted_privileges), [string priv, string date]) {
				mapping privilege = CFG->estate_privilege_definitions[priv]; if (!privilege) continue;
				string desc = sprintf("%s: %s", L10N(estate->type), L10N(priv));
				_incorporate(data, modifiers, desc, privilege->penalties);
				_incorporate(data, modifiers, desc, privilege->benefits);
			}
		}
		//Now calculate the influence and loyalty of each estate, and the resulting effects.
		foreach (country->estate, mapping estate) {
			mapping estate_defn = CFG->estate_definitions[estate->type];
			if (!estate_defn) continue;
			mapping influence = (["Base": (int)estate_defn->base_influence * 1000]);
			//There are some conditional modifiers. Sigh. This is seriously complicated. Why can't estate influence just be in the savefile?
			foreach (Array.arrayify(estate->granted_privileges), [string priv, string date])
				influence["Privilege " + L10N(priv)] =
					threeplace(CFG->estate_privilege_definitions[priv]->?influence) * 100;
			foreach (Array.arrayify(estate->influence_modifier), mapping mod)
				//It's possible to have the same modifier more than once (eg "Diet Summoned").
				//Rather than show them all separately, collapse them into "Diet Summoned: 15%".
				influence[L10N(mod->desc) || "(unknown modifier)"] += threeplace(mod->value);
			foreach (Array.arrayify(modifiers->_sources[replace(estate->type, "estate_", "") + "_influence_modifier"]), string mod) {
				sscanf(reverse(mod), "%[0-9] :%s", string value, string desc);
				influence[reverse(desc)] += (int)reverse(value) * 100; //Just in case they show up more than once
			}
			influence["Land share"] = threeplace(estate->territory) / 2; //Is this always the case? 42% land share gives 21% influence?
			//Attempt to parse the estate influence modifier blocks. This is imperfect and limited.
			foreach (Array.arrayify(estate_defn->influence_modifier), mapping mod) {
				if (!trigger_matches(data, ({country}), "AND", mod->trigger)) continue;
				influence[L10N(mod->desc)] = threeplace(mod->influence);
			}
			int total_influence = estate->estimated_milliinfluence = `+(@values(influence));
			string opinion = "neutral";
			if ((float)estate->loyalty >= 60.0) opinion = "happy";
			else if ((float)estate->loyalty < 30.0) opinion = "angry";
			int mul = 4;
			if (total_influence < 60000) mul = 3;
			if (total_influence < 40000) mul = 2;
			if (total_influence < 20000) mul = 1;
			_incorporate(data, modifiers, String.capitalize(opinion) + " " + L10N(estate->type), estate_defn["country_modifier_" + opinion], mul, 4);
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
		mapping type = CFG->advisor_definitions[adv->type];
		_incorporate(data, modifiers, L10N(adv->type) + " (" + adv->name + ")", type);
	}
	return country->all_country_modifiers = modifiers;
}

mapping(string:int) all_province_modifiers(mapping data, int id) {
	mapping prov = data->provinces["-" + id];
	if (mapping cached = prov->all_province_modifiers) return cached;
	mapping country = data->countries[prov->owner];
	mapping modifiers = (["_sources": ([])]);
	if (prov->center_of_trade) {
		string type = province_info[(string)id]->?has_port ? "coastal" : "inland";
		mapping cot = CFG->cot_definitions[type + prov->center_of_trade];
		_incorporate(data, modifiers, "Level " + prov->center_of_trade + " COT", cot->?province_modifiers);
	}
	if (int l3cot = country->area_has_level3[?CFG->prov_area[(string)id]]) {
		string type = province_info[(string)l3cot]->?has_port ? "coastal3" : "inland3";
		mapping cot = CFG->cot_definitions[type];
		_incorporate(data, modifiers, "L3 COT in area", cot->?state_modifiers);
	}
	foreach (prov->buildings || ([]); string b;)
		_incorporate(data, modifiers, "Building", CFG->building_types[b]);
	mapping area = data->map_area_data[CFG->prov_area[(string)id]]->?state;
	foreach (Array.arrayify(area->?country_state), mapping state) if (state->country == prov->owner) {
		if (state->prosperity == "100.000") _incorporate(data, modifiers, "Prosperity", CFG->static_modifiers->prosperity);
		_incorporate(data, modifiers, "State edict - " + L10N(state->active_edict->?which), CFG->state_edicts[state->active_edict->?which]);
	}
	_incorporate(data, modifiers, "Terrain", CFG->terrain_definitions->categories[province_info[(string)id]->terrain]);
	_incorporate(data, modifiers, "Climate", CFG->static_modifiers[province_info[(string)id]->climate]);
	if (prov->hre) {
		foreach (Array.arrayify(data->empire->passed_reform), string reform)
			_incorporate(data, modifiers, "HRE province (" + L10N(reform) + ")", CFG->imperial_reforms[reform]->?province);
	}
	_incorporate(data, modifiers, "Trade good: " + prov->trade_goods, CFG->trade_goods[prov->trade_goods]->?province);
	return prov->all_province_modifiers = modifiers;
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
	array ret = ({ });
	string religion = prov->religion;
	if (religion != country->religion) religion = "n/a";
	array accepted_cultures = ({country->primary_culture}) + Array.arrayify(country->accepted_culture);
	if (country->government_rank == "3") //Empire rank, all in culture group are accepted
		foreach (CFG->culture_definitions; string group; mapping info)
			if (info[country->primary_culture]) accepted_cultures += indices(info);

	//Some two-part checks can also be described in one part. Fold them together.
	if (m_delete(req, "has_owner_religion")) {
		if (string rel = m_delete(req, "religion"))
			req->province_is_or_accepts_religion = (["religion": Array.arrayify(rel)[*]]);
		if (string grp = m_delete(req, "religion_group"))
			req->province_is_or_accepts_religion_group = (["religion_group": Array.arrayify(grp)[*]]);
	}
	foreach (sort(indices(req)), string type) {
		array need = Array.arrayify(req[type]);
		switch (type) {
			case "province_is_or_accepts_religion_group": {
				//If multiple, it's gonna be "OR" mode, otherwise it could never be true
				mapping accepted = `+(@CFG->religion_definitions[need->religion_group[*]]);
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
				if (has_value(`+(@indices(CFG->culture_definitions[need[*]][*])), prov->culture)
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

void analyze_leviathans(mapping data, string name, string tag, function|mapping write) {
	if (!has_value(data->dlc_enabled, "Leviathan")) return;
	mapping country = data->countries[tag];
	array projects = ({ });
	foreach (country->owned_provinces, string id) {
		mapping prov = data->provinces["-" + id];
		if (!prov->great_projects) continue;
		mapping con = prov->great_project_construction || ([]);
		foreach (prov->great_projects, string project) {
			mapping proj = data->great_projects[project] || (["development_tier": "0"]); //Weirdly, I have once seen a project that's just missing from the file.
			mapping defn = CFG->great_projects[project];
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
				({"", id, "Lvl " + proj->development_tier, prov->name, CFG->L10n[project] || "#" + project,
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
		//if (con) write("Construction: %O\n", con);
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
		cooldowns += ({({"", days, date, String.capitalize(tradefor), cur})}); //TODO: Don't include the initial empty string here, add it for tabulate() only
	}
	if (mappingp(write)) {
		write->monuments = projects[*][2];
		//Favors are all rendered on the front end.
		mapping owed = ([]);
		foreach (data->countries; string other; mapping c) {
			int favors = threeplace(c->active_relations[tag]->?favors);
			if (favors > 0) owed[other] = ({favors / 1000.0}) + estimate_per_month(data, c)[*] * 6;
		}
		write->favors = (["cooldowns": cooldowns, "owed": owed]);
		return;
	}
	if (sizeof(projects)) write("%s\n", string_to_utf8(tabulate(({""}) + "ID Tier Province Project Upgrading" / " ", projects[*][1], "  ", 0)));
	write("\nFavors:\n");
	foreach (data->countries; string other; mapping c) {
		int favors = threeplace(c->active_relations[tag]->?favors);
		if (favors > 1000) write("%s owes you %d.%03d\n", c->name || L10N(other), favors / 1000, favors % 1000);
	}
	write("%s\n", string_to_utf8(tabulate(({"", "Days", "Date", "Trade for", "Max gain"}), cooldowns, "  ", 0)));
}

int count_building_slots(mapping data, string id) {
	//Count building slots. Not perfect. Depends on the CoTs being provided accurately.
	//Doesn't always give the terrain bonus.
	int slots = 2 + building_slots[id]; //All cities get 2, plus possibly a bonus from terrain and/or a penalty from climate.
	mapping prov = data->provinces["-" + id];
	if (prov->buildings->?university) ++slots; //A university effectively doesn't consume a slot.
	if (data->countries[prov->owner]->?area_has_level3[?CFG->prov_area[id]]) ++slots; //A level 3 CoT in the state adds a building slot
	//TODO: Modifiers, incl event flags (see all_country_modifiers maybe?)
	//Notably global_allowed_num_of_buildings
	int dev = (int)prov->base_tax + (int)prov->base_production + (int)prov->base_manpower;
	return slots + dev / 10;
}

void analyze_furnace(mapping data, string name, string tag, function|mapping write) {
	mapping country = data->countries[tag];
	array coalprov = ({ });
	foreach (country->owned_provinces, string id) {
		mapping prov = data->provinces["-" + id];
		if (!province_info[id]->has_coal) continue;
		int dev = (int)prov->base_tax + (int)prov->base_production + (int)prov->base_manpower;
		mapping bldg = prov->buildings || ([]);
		mapping mfg = bldg & CFG->manufactories;
		string status = "";
		if (prov->trade_goods != "coal") {
			//Not yet producing coal. There are a few reasons this could be the case.
			if (country->institutions[6] != "1") status = "Not embraced";
			else if (prov->institutions[6] != "100.000") status = "Not Enlightened";
			else if (dev < 20 && (int)country->innovativeness < 20) status = "Need 20 dev/innov";
			else status = "Producing " + prov->trade_goods; //Assuming the above checks are bug-free, the province should flip to coal at the start of the next month.
		}
		else if (bldg->furnace) status = "Has Furnace";
		else if (CFG->building_id[(int)prov->building_construction->?building] == "furnace")
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
			string upg = CFG->building_id[(int)prov->building_construction->building];
			while (string was = CFG->building_types[upg]->make_obsolete) {
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
	if (mappingp(write)) {write->coal_provinces = coalprov; return;}
	if (!sizeof(coalprov)) return;
	write("Coal-producing provinces:\n");
	foreach (coalprov, mapping p)
		if (p->status == "") {
			interesting(p->id, PRIO_IMMEDIATE); //TODO: Should it always be highlighted at the same prio? Should it always even be highlighted?
			write("\e[1;%dm%s\t%d/%d bldg\t%d dev\t%s\n", p->buildings < p->slots ? 32 : 36,
				p->id, p->buildings, p->slots, p->dev, string_to_utf8(p->name));
		}
		else write("%s\t%s\t%d dev\t%s\n", p->id, p->status, p->dev, string_to_utf8(p->name));
	write("\n");
}

void analyze_upgrades(mapping data, string name, string tag, function|mapping write) {
	mapping country = data->countries[tag];
	mapping upgradeables = ([]);
	foreach (country->owned_provinces, string id) {
		mapping prov = data->provinces["-" + id];
		if (!prov->buildings) continue;
		string constructing = CFG->building_id[(int)prov->building_construction->?building]; //0 if not constructing anything
		foreach (prov->buildings; string b;) {
			mapping bldg = CFG->building_types[b]; if (!bldg) continue; //Unknown building??
			if (bldg->influencing_fort) continue; //Ignore forts - it's often not worth upgrading all forts. (TODO: Have a way to request forts too.)
			mapping target;
			while (mapping upgrade = CFG->building_types[bldg->obsoleted_by]) {
				[string techtype, int techlevel] = upgrade->tech_required;
				if ((int)country->technology[techtype] < techlevel) break;
				//Okay. It can be upgraded. But before we report it, see if we can go another level.
				//For instance, if you have a Marketplace and Diplo tech 22, you can upgrade to a
				//Trade Depot, but could go straight to Stock Exchange.
				target = bldg->obsoleted_by;
				bldg = upgrade;
			}
			if (target && target != constructing) {
				interesting(id, PRIO_SITUATIONAL);
				upgradeables[L10N("building_" + target)] += ({(["id": id, "name": prov->name])}); //Do we need any more info?
			}
		}
	}
	if (mappingp(write)) sort(indices(upgradeables), write->upgradeables = (array)upgradeables); //Sort alphabetically by target building
	else foreach (sort(indices(upgradeables)), string b) {
		write("Can upgrade %d buildings to %s\n", sizeof(upgradeables[b]), b);
		write("==> %s\n", string_to_utf8(upgradeables[b]->name * ", "));
	}
}

void analyze_findbuildings(mapping data, string name, string tag, function|mapping write, string highlight) {
	if (mappingp(write)) write->highlight = (["id": highlight, "name": L10N("building_" + highlight), "provinces": ({ })]);
	mapping country = data->countries[tag];
	foreach (country->owned_provinces, string id) {
		mapping prov = data->provinces["-" + id];
		//Building shipyards in inland provinces isn't very productive
		if (CFG->building_types[highlight]->build_trigger->?has_port && !province_info[id]->?has_port) continue;
		mapping bldg = prov->buildings || ([]);
		int slots = count_building_slots(data, id);
		int buildings = sizeof(bldg);
		if (prov->building_construction) {
			//Duplicate of the above
			++buildings;
			string upg = CFG->building_id[(int)prov->building_construction->building];
			while (string was = CFG->building_types[upg]->?make_obsolete) {
				if (bldg[was]) {--buildings; break;}
				upg = was;
			}
		}
		if (buildings < slots) continue; //Got room. Not a problem. (Note that the building slots calculation may be wrong but usually too low.)
		//Check if a building of the highlight type already exists here.
		int gotone = 0;
		foreach (prov->buildings || ([]); string b;) {
			if (b == highlight) {gotone = 1; break;}
			while (string upg = CFG->building_types[b]->make_obsolete) {
				if (upg == highlight) {gotone = 1; break;}
				b = upg;
			}
			if (gotone) break;
		}
		if (gotone) continue;
		interesting(id, PRIO_EXPLICIT);
		int dev = (int)prov->base_tax + (int)prov->base_production + (int)prov->base_manpower;
		int need_dev = (dev - dev % 10) + 10 * (buildings - slots + 1);
		if (mappingp(write)) write->highlight->provinces += ({([
			"id": (int)id, "buildings": buildings, "maxbuildings": slots,
			"name": prov->name, "dev": dev, "need_dev": need_dev,
			"cost": calc_province_devel_cost(data, (int)id, need_dev - dev),
		])});
		else write("\e[1;32m%s\t%d/%d bldg\tDev %d\t%s\e[0m\n", id, buildings, slots, dev, string_to_utf8(prov->name));
	}
	if (mappingp(write)) sort(write->highlight->provinces->cost[*][-1], write->highlight->provinces);
}

int(0..1) passes_filter(mapping country, mapping|array filter, int|void any) {
	//If any is 1, then as soon as we find a true return, we propagate it.
	//If any is 0 (ie we need all, the default), we propagate false instead.
	//An empty block - or one containing only types we don't know - will
	//pass an AND check (no restrictions, all fine), but fail an OR check.
	foreach (filter; string kwd; mixed values) {
		//There could be multiple of the same keyword (eg in an OR block, or multiple OR blocks). They're independent.
		foreach (Array.arrayify(values), mixed value) switch (kwd) {
			case "OR": if (passes_filter(country, value, 1) == any) return any;
			default: break; //Unknown type, don't do anything
		}
	}
	return !any;
}

mapping analyze_trade_node(mapping data, mapping trade_nodes, string tag, string node, mapping prefs) {
	//Analyze one trade node and estimate the yield from transferring trade. Assumes
	//that the only place you collect is your home node and you transfer everything
	//else in from all other nodes. Note that this function should only be called
	//on a node when all of its outgoing nodes have already been processed; this is
	//assured by the use of tradenode_upstream_order, which guarantees never to move
	//downstream (but is otherwise order-independent).
	mapping here = trade_nodes[node];
	mapping us = here[tag], defn = CFG->tradenode_definitions[node];
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

void analyze_obscurities(mapping data, string name, string tag, mapping write, mapping prefs) {
	//Gather some more obscure or less-interesting data for the web interface only.
	//It's not worth consuming visual space for these normally, but the client might
	//want to open this up and have a look.

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
			mapping typeinfo = CFG->cb_types[cb->type] || ([]);
			mapping wargoal = CFG->wargoal_types[typeinfo->war_goal] || ([]);
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
			foreach (CFG->country_modifiers[mod->modifier] || ([]); string effect; string value) {
				if (effect == "picture") continue; //Would be cool to show the icon in the front end, but whatever
				string desc = upper_case(effect);
				if (effect == "province_trade_power_value") desc = "PROVINCE_TRADE_VALUE"; //Not sure why, but the localisation files write this one differently.
				effects += ({sprintf("%s: %s", CFG->L10n[desc] || CFG->L10n["MODIFIER_" + desc] || effect || "(unknown)", (string)value)});
			}
			return ([
				"name": L10N(mod->modifier),
				"effects": effects,
			]);
		} - ({0});
		mapping provinfo = province_info[id - "-"];
		mapping terraininfo = CFG->terrain_definitions->categories[provinfo->terrain] || ([]);
		mapping climateinfo = CFG->static_modifiers[provinfo->climate] || ([]);
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
		//Proper handling of highlight types would require parsing the CFG->estate_agendas
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
			"[agenda_province.GetAreaName]": "[" + L10N(CFG->prov_area[write->agenda->province]) + "]",
			"[Root.Culture.GetName]": "[" + L10N(country->primary_culture) + "]",
			//We slightly cheat here and always just use the name from the localisation files.
			//This ignores any tag-specific or culture-specific alternate naming - see the
			//triggered name blocks in /common/colonial_regions/* - but it'll usually give a
			//reasonably decent result.
			"[agenda_province.GetColonialRegionName]": "[" + L10N(CFG->prov_colonial_region[write->agenda->province]) + "]",
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
			foreach (CFG->map_areas[area];; string provid) {
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
						//Not sure where unrest is stored. It's probably in separate pieces, like
						//the whiskey wasn't.
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
				(["color": CFG->textcolors->B * ",", "text": L10N(state->active_edict->which)]),
				" in ",
				(["color": CFG->textcolors->B * ",", "text": L10N(area)]),
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
			mapping mission = Array.arrayify(CFG->country_missions[kwd]);
			foreach (mission; string id; mixed info) {
				if (has_value(completed, id)) continue; //Already done this mission, don't highlight it.
				string title = CFG->L10n[id + "_title"];
				if (!title) continue; //TODO: What happens if there's a L10n failure?
				//if (!mappingp(info)) {werror("WARNING: Not mapping - %O\n", id); continue;} //FIXME: Parse error on Ottoman_Missions, conquer_serbia, fails this assertion (see icon)
				int prereq = 1;
				if (arrayp(info->required_missions)) foreach (info->required_missions, string req)
					if (!has_value(completed, req)) prereq = 0;
				if (!prereq) continue; //One or more prerequisite missions isn't completed, don't highlight it
				mapping highlight = info->provinces_to_highlight;
				if (!highlight) continue; //Mission does not involve provinces, don't highlight it.
				//Very simplistic filter handling.
				array filters = ({ });
				//TODO: Require that the province not be owned by you *or any non-trib subject*
				if (highlight->NOT->?country_or_non_sovereign_subject_holds == "ROOT")
					filters += ({ lambda(mapping p) {return p->controller != tag;} });
				//Very simplistic search criteria.
				array provs = Array.arrayify(highlight->province_id) + Array.arrayify(highlight->OR->?province_id);
				array areas = Array.arrayify(highlight->area) + Array.arrayify(highlight->OR->?area);
				array interesting = ({ });
				foreach (CFG->map_areas[areas[*]] + ({provs}), array|object area)
					foreach (area;; string provid) {
						mapping prov = data->provinces["-" + provid];
						int keep = 1;
						foreach (filters, function f) keep = keep && f(prov);
						if (!keep) continue;
						interesting += ({({provid, prov->name})});
					}
				if (sizeof(interesting)) write->decisions_missions += ({([
					"id": id,
					"name": title,
					"provinces": interesting,
				])});
			}
		}
	}
	/* TODO: List decisions as well as missions
	- For the most part, just filter by tag, nothing else. Be aware that there might be
	  "OR = { tag = X tag = Y }", as quite a few decisions are shared.
	- May also need to check "culture_group = iberian" and "primary_culture = basque"
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
	foreach (CFG->country_decisions; string kwd; mapping info) {
		//TODO.
		if (!passes_filter(country, info->potential)) continue;
		//werror("%s -> %s %O\n", tag, kwd, info->potential);
	}

	//Get some info about provinces, for the sake of the province details view
	write->province_info = (mapping)map((array)data->provinces) {[[string id, mapping prov]] = __ARGS__;
		return ({id - "-", ([
			"discovered": has_value(Array.arrayify(prov->discovered_by), tag),
			"controller": prov->controller, "owner": prov->owner,
			"name": prov->name,
			"wet": CFG->terrain_definitions->categories[province_info[id - "-"]->?terrain]->?is_water,
			"terrain": province_info[id - "-"]->?terrain,
			"climate": province_info[id - "-"]->?climate,
			//"raw": prov,
		])});
	};

	//Get some info about trade nodes
	array all_nodes = data->trade->node;
	mapping trade_nodes = mkmapping(all_nodes->definitions, all_nodes);
	write->trade_nodes = analyze_trade_node(data, trade_nodes, tag, CFG->tradenode_upstream_order[*], prefs);

	//Get info about mil tech levels and which ones are important
	write->miltech = ([
		"current": (int)country->technology->mil_tech,
		"group": country->technology_group,
		"units": country->unit_type,
		"groupname": L10N(country->technology_group),
		"levels": CFG->military_tech_levels,
	]);

	//List all cultures present in your nation, and the impact of promoting or demoting them.
	mapping cultures = ([]);
	string primary = country->primary_culture;
	array accepted = Array.arrayify(country->accepted_culture);
	int cultural_union = country->government_rank == "3"; //Empire rank, no penalty for brother cultures
	int is_republic = all_country_modifiers(data, country)->republic ? 50 : 0;
	array brother_cultures = ({ });
	foreach (CFG->culture_definitions; string group; mapping info) if (info[primary]) brother_cultures = indices(info);
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
			mp += has_value(CFG->building_types->soldier_households->bonus_manufactory, prov->trade_goods) ? 1500000 : 750000;
		affect(culture, "manpower", mp, autonomy, impact);
		//Sailors are 60 per base dev _of any kind_, with a manufactory. They also have
		//different percentage impact for culture discrepancies.
		int sailors = province_info[id]->?has_port && dev * 60;
		impact = culture->status == "brother" ? 100 * !cultural_union
			: culture->status == "foreign" ? 200 - is_republic : 0;
		if (prov->buildings->?impressment_offices)
			sailors += has_value(CFG->building_types->impressment_offices->bonus_manufactory, prov->trade_goods) ? 500000 : 250000;
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

	//List all current rebellions and whether the provinces are covered by troops
	mapping coverage = ([]);
	foreach (Array.arrayify(country->army), mapping army) {
		//TODO: Calculate the actual effective unrest bonus. The base value is 0.25
		//per regiment, then multiply that by five if hunting rebels, but split the
		//effect across the provinces. For now, we just mark it as "done".
		int effect = 1;
		coverage[army->location] += effect;
		mapping hunt_rebel = army->mission->?hunt_rebel;
		if (!hunt_rebel) continue; //Not hunting rebels (maybe on another mission, or no mission at all).
		foreach (hunt_rebel->areas, string a)
			foreach (CFG->map_areas[a];; string id) coverage[id] += effect;
	}
	write->unguarded_rebels = ({ });
	foreach (Array.arrayify(data->rebel_faction), mapping faction) if (faction->country == tag) {
		//A bit of a cheat here. I would like to check whether any province has positive
		//unrest, but that's really hard to calculate. So instead, we just show every
		//rebel faction with at least 30% progress.
		//NOTE: faction->province is a single province ID. Not sure what it is.
		//NOTE: faction->active is a thing. Maybe says if rebels have spawned??
		//What happens with rebels that spawn without unrest (eg pretenders)? Don't crash.
		//What if rebels cross the border? (Probably not in this list, since ->country != tag)
		if ((int)faction->progress < 30) continue; //Could be null, otherwise is eg "10.000" for 10% progress
		array uncovered = ({ });
		foreach (faction->possible_provinces || ({ }), string prov)
			if (!coverage[prov]) uncovered += ({prov});
		if (sizeof(uncovered)) write->unguarded_rebels += ({([
			"provinces": uncovered,
			"name": faction->name,
			"progress": (int)faction->progress,
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
		"appanage": 10, //French special vassal type. Can we calculate all these from the files somewhere?
	]);
	foreach (Array.arrayify(country->subjects), string|mapping stag) {
		mapping subj = data->countries[stag];
		mapping dep = subjects[tag + stag] || ([]);
		int impr = 0;
		foreach (Array.arrayify(subj->active_relations[tag]->?opinion), mapping opine)
			if (opine->modifier == "improved_relation") impr = threeplace(opine->current_opinion);
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
		write->subjects += ({([
			"tag": stag,
			"type": dep->subject_type ? L10N(dep->subject_type + "_title") : "(unknown)",
			"improved": impr,
			"liberty_desire": subj->cached_liberty_desire, //How accurate is this?
			"start_date": dep->start_date, "integration_date": integration_date,
			"can_integrate": can_integrate,
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

mapping(string:array) interesting_provinces = ([]);
void analyze(mapping data, string name, string tag, function|mapping|void write, mapping|void prefs) {
	if (!write) write = Stdio.stdin->write;
	interesting_province = ({ }); interest_priority = 0;
	if (mappingp(write)) {
		write->name = name + " (" + (data->countries[tag]->name || L10N(tag)) + ")";
		write->fleetpower = prefs->fleetpower || 1000;
	}
	else write("\e[1m== Player: %s (%s) ==\e[0m\n", name, tag);
	({analyze_cot, analyze_leviathans, analyze_furnace, analyze_upgrades})(data, name, tag, write);
	if (mappingp(write)) analyze_obscurities(data, name, tag, write, prefs || ([]));
	if (string highlight = prefs->highlight_interesting) analyze_findbuildings(data, name, tag, write, highlight);
	//write("* %s * %s\n\n", tag, Standards.JSON.encode((array(int))interesting_province)); //If needed in a machine-readable format
	interesting_provinces[tag] = interesting_province;
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

//Not currently triggered from anywhere. Doesn't currently have a primary use-case.
void show_tradegoods(mapping data, string tag, function|void write) {
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

void analyze_flagships(mapping data, function|mapping write) {
	array flagships = ({ });
	foreach (data->countries; string tag; mapping country) {
		//mapping country = data->countries[tag];
		if (!country->navy) continue;
		foreach (Array.arrayify(country->navy), mapping fleet) {
			foreach (Array.arrayify(fleet->ship), mapping ship) {
				if (!ship->flagship) continue;
				string was = ship->flagship->is_captured && ship->flagship->original_owner;
				string cap = was ? " CAPTURED from " + (data->countries[was]->name || L10N(was)) : "";
				if (mappingp(write)) flagships += ({({
					tag, fleet->name,
					L10N(ship->type), ship->name,
					L10N(ship->flagship->modification[*]),
					ship->flagship->is_captured ? (data->countries[was]->name || L10N(was)) : ""
				})});
				else flagships += ({({
					string_to_utf8(sprintf("\e[1m%s\e[0m - %s: \e[36m%s %q\e[31m%s\e[0m",
						country->name || L10N(tag), fleet->name,
						L10N(ship->type), ship->name, cap)),
					//Measure size without colour codes or UTF-8 encoding
					sizeof(sprintf("%s - %s: %s %q%s",
						country->name || L10N(tag), fleet->name,
						L10N(ship->type), ship->name, cap)),
					L10N(ship->flagship->modification[*]) * ", ",
				})});
				//write("%O\n", ship->flagship);
			}
		}
	}
	sort(flagships);
	if (mappingp(write)) {write->flagships = flagships; return;}
	if (!sizeof(flagships)) return;
	write("\n\e[1m== Flagships of the World ==\e[0m\n");
	int width = max(@flagships[*][1]);
	foreach (flagships, array f) f[1] = " " * (width - f[1]);
	write("%{%s %s %s\n%}", flagships);
}

array war_rumours = ({ });

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

void analyze_wars(mapping data, multiset(string) tags, function|mapping|void write) {
	if (!write) write = Stdio.stdin->write;
	if (mappingp(write)) write->wars = (["current": ({ }), "rumoured": war_rumours]);
	foreach (values(data->active_war || ({ })), mapping war) {
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
		if (mappingp(write)) write->wars->current += ({summary});
		else write("\n\e[1;31m== War: %s - %s ==\e[0m\n", war->action, string_to_utf8(war->name));
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
			if (mappingp(write)) side = (({a && "attacker", d && "defender", tags[p->tag] && "player"}) - ({0})) * ",";
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
					side,
					mappingp(write) ? p->tag : country->name || L10N(p->tag),
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
					side,
					mappingp(write) ? p->tag : country->name || L10N(p->tag),
					mil->heavy_ship, mil->light_ship, mil->galley, mil->transport, total_navy, sailors,
					sprintf("%3.0f%%", (float)country->navy_tradition),
				}),
			})});
			navy_total[d] = navy_total[d][*] + navies[-1][1][2..<1][*];
		}
		string atot = "\e[48;2;50;0;0m" + atk + "  ", dtot = "\e[48;2;0;0;50m" + def + "  ";
		if (mappingp(write)) {atot = "attacker,total"; dtot="defender,total";}
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
		if (mappingp(write)) {summary->armies = armies[*][-1]; summary->navies = navies[*][-1]; continue;}
		write("%s\n", string_to_utf8(tabulate(({"   "}) + "Country Infantry Cavalry Artillery Inf$$ Cav$$ Art$$ Total Manpower Prof Trad" / " ", armies[*][-1], "  ", 2)));
		write("%s\n", string_to_utf8(tabulate(({"   "}) + "Country Heavy Light Galley Transp Total Sailors Trad" / " ", navies[*][-1], "  ", 2)));
	}
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
	add_constant("L10N", L10N);
	G->parser = compile_file("parser.pike")("parser"); //Needed for special modes as well as the main

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
	G->webserver = compile_file("webserver.pike")("webserver"); //Only needed for the main entrypoint

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

	mapping cfg = ([]);
	catch {cfg = Standards.JSON.decode(Stdio.read_file(".eu4_preferences.json"));};
	if (mappingp(cfg) && cfg->tag_preferences) G->webserver->tag_preferences = cfg->tag_preferences;
	if (mappingp(cfg) && cfg->effect_display_mode) G->webserver->effect_display_mode = cfg->effect_display_mode;

	object proc = Process.spawn_pike(({"parser.pike"}), (["fds": ({parser_pipe->pipe(Stdio.PROP_NONBLOCK|Stdio.PROP_BIDIRECTIONAL|Stdio.PROP_IPC)})]));
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
