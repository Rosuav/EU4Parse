/* Restricted grammar suitable for savefiles and some configs
Generates savefile.tab.c via GNU Bison or equivalent. Note that
the savefile.tab.c included in the repository is GPL'd, but this
file, like every other file in the repo, is covered by the MIT
license instead. */
%{
#include <stdio.h>
#include <string.h>

int yylex(void);
void yyerror(const char *);
struct Map; struct Array; struct String;
extern struct Map *savefile_result;
extern struct Boolean {char sig;} boolean[];
union YYSTYPE;
%}

%define api.value.type union
%token <struct String *> NUMBER
%token <struct String *> STRING
%token <struct Boolean *> BOOLEAN
%nterm <struct Map *> varlist savefile
%nterm <struct Array *> array
%nterm <struct String *> name
%nterm <union YYSTYPE *> value

%{
struct String *make_string(const char *start, const char *next, int quoted);
struct Map *make_map(struct Map *next, struct String *key, union YYSTYPE *value);
struct Array *make_array(struct Array *next, union YYSTYPE *value);
%}

%%

savefile: varlist {savefile_result = $1;};
/* A savefile can be empty (even though a varlist can't).
This will often cause problems, but parse_config_dir is okay
with it, since this can be used for all-comment examples. */
savefile: {savefile_result = NULL;};

/* Note that a varlist can't be empty */
varlist: name '=' value {$$ = make_map(NULL, $1, $3);};
varlist: varlist name '=' value {$$ = make_map($1, $2, $4);};
varlist: varlist '{' '}'; /* Weird oddity at one point in the save file - a bunch of empty blocks in what should be a mapping */
/* Nor can an array, although the definition of a value includes an empty array */
array: value {$$ = make_array(NULL, $1);};
array: array value {$$ = make_array($1, $2);};

name: STRING;

value: STRING {$$ = (union YYSTYPE *)$1;};
value: BOOLEAN {$$ = (union YYSTYPE *)$1;};
value: '{' varlist '}' {$$ = (union YYSTYPE *)$2;};
value: '{' array '}' {$$ = (union YYSTYPE *)$2;};
value: '{' '}' {$$ = (union YYSTYPE *)make_map(NULL, NULL, NULL);};
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
			case '"': {
				//Fairly naive handling of quoted strings.
				//Once we find a double quote, we scan for another, but ignoring the
				//next character after any backslash. The entire section will be put
				//into the JSON file unchanged, so we have to assume that the quoting
				//rules are acceptable for JSON.
				const char *start = next - 1;
				char c;
				do {
					c = readchar();
					if (c == '\\') readchar();
				} while (c && c != '"');
				if (!next[-1]) return YYerror; //TODO: Give a better message (unterminated string)
				yylval.STRING = make_string(start, next, 0); //Already includes its quotes
				return STRING;
			}
			default: {
				const char *start = next - 1;
				char c = *start;
				//Special case: 0x introduces a hex value
				if (*start == '0' && remaining && *next == 'x') {
					//TODO. Might make this able to read more config files.
					printf("GOT HEX unimpl\n");
					return YYerror;
				}
				//Scan for any sequence of atom characters. Yes, this DOES include starting
				//with a digit. This will handle numbers, but also "25_permanent_power_projection".
				while ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
					|| c == '_' || c == '\'' || c == ':' || c == '@' || c > 128
					|| c == '.' || c == '-' || (c >= '0' && c <= '9'))
						c = readchar();
				if (next > start + 1) {
					--next; ++remaining; //Unget the character that ended the token
					//Booleans are the strings "yes" and "no", not quoted.
					if (next - start == 3 && !strncmp(start, "yes", 3)) {
						yylval.BOOLEAN = boolean + 1;
						return BOOLEAN;
					}
					if (next - start == 2 && !strncmp(start, "no", 2)) {
						yylval.BOOLEAN = boolean + 0;
						return BOOLEAN;
					}
					yylval.STRING = make_string(start, next, 1); //Add quotes to this one
					//Hack: this one element seems to omit the equals sign for some reason.
					if (next - start == 13 && !strncmp(start, "map_area_data", 13))
						hack_nexttoken = '=';
					return STRING;
				}
				return c; //Unknown character, probably punctuation.
			}
		}
	}
}
