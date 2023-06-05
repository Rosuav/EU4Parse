/* Restricted grammar suitable for savefiles and some configs
Generates savefile.tab.c via GNU Bison or equivalent. Note that
the savefile.tab.c included in the repository is GPL'd, but this
file, like every other file in the repo, is covered by the MIT
license instead. */
%{
#include <stdio.h>

int yylex(void);
void yyerror(const char *);
struct Map; struct Array; struct String;
struct String *make_string(const char *start, const char *next);
%}

%define api.value.type union
%token <struct String *> NUMBER
%token <struct String *> STRING
%token <struct String *> BOOLEAN

%%

savefile: varlist;

/* Note that a varlist can't be empty */
varlist: name '=' value /*{makemapping}*/;
varlist: varlist name '=' value /*{addmapping}*/;
varlist: varlist '{' '}'; /* Weird oddity at one point in the save file - a bunch of empty blocks in what should be a mapping */
/* Nor can an array, although the definition of a value includes an empty array */
array: value /*{make_array}*/;
array: array value /*{add_array}*/;

name: STRING;

value: NUMBER;
value: STRING;
value: BOOLEAN;
value: '{' varlist '}' /*{take2}*/;
value: '{' array '}' /*{take2}*/;
value: '{' '}' /*{emptyarray}*/;
%%

extern const char *next;
extern size_t remaining;
int hack_nexttoken = 0;
static inline char readchar() {
	if (!remaining) return 0;
	--remaining;
	return *next++;
}
int yylex(void) {
	if (hack_nexttoken) {int ret = hack_nexttoken; hack_nexttoken = 0; return ret;}
	while (1) {
		switch (readchar()) {
			case 0: return YYEOF;
			case ' ': case '\t': case '\r': case '\n': break; //Skip whitespace
			case '#': //Strip comments (needed in savefiles? maybe not?)
				do {if (readchar() == '\n') break;} while (remaining);
				break;
			case '0': case '1': case '2': case '3': case '4':
			case '5': case '6': case '7': case '8': case '9':
			case '-': case '.': {
				const char *start = next - 1;
				//Special case: 0x introduces a hex value
				if (*start == '0' && remaining && *next == 'x') {
					//TODO
					printf("GOT HEX unimpl\n");
					//yylval = "HEX";
					return NUMBER;
				}
				while (1) {
					switch (readchar()) {
						case '0': case '1': case '2': case '3': case '4':
						case '5': case '6': case '7': case '8': case '9':
						case '-': case '.': continue;
						default: break;
					}
					break;
				}
				printf("Got a number from %p length %ld\n", start, next - start);
				--next; //Unget the character that ended the token
				yylval = (YYSTYPE)make_string(start, next);
				return NUMBER;
			}
			default: {
				const char *start = next - 1;
				char c = *start;
				//If it starts with a suitable atom character...
				if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
						|| c == '_' || c == '\'' || c == ':' || c > 128) {
					//... collect all sequential atom characters as a token.
					while ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
							|| c == '_' || c == '\'' || c == ':' || c > 128
							|| (c >= '0' && c <= '9'))
						c = readchar();
					--next; //Unget the character that ended the token
					printf("Got a string from %p length %ld\n", start, next-start);
					yylval = (YYSTYPE)make_string(start, next);
					return STRING;
				}
				printf("Returning character '%c' as a token\n", c);
				return c; //Unknown character, probably punctuation.
			}
		}
	}
}

#if 0
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
#endif
