/* Restricted grammar suitable for savefiles and some configs
Generates savefile.tab.c via GNU Bison or equivalent. Note that
the savefile.tab.c included in the repository is GPL'd, but this
file, like every other file in the repo, is covered by the MIT
license instead. */
%{
#include <stdio.h>

int yylex(void);
void yyerror(const char *);
%}

%define api.value.type {void *}
%token NUMBER

%%

savefile: NUMBER;

%%
#if 0
savefile: varlist;

/* Note that a varlist can't be empty */
varlist: name "=" value {makemapping};
varlist: varlist name "=" value {addmapping};
varlist: varlist "{" "}"; /* Weird oddity at one point in the save file - a bunch of empty blocks in what should be a mapping */
/* Nor can an array, although the definition of a value includes an empty array */
array: value {make_array};
array: array value {add_array};

name: "string";

value: "number";
value: "string";
value: "boolean";
value: "{" varlist "}" {take2};
value: "{" array "}" {take2};
value: "{" "}" {emptyarray};
#endif

extern const void *data;
extern const char *next;
extern size_t remaining;
int yylex(void) {
	if (!remaining) return YYEOF;
	yylval = "foo";
	remaining = 0;
	return NUMBER;
}
