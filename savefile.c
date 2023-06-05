//Parse an EU4 save file (and possibly some config files but not all)
//and output a JSON blob with equivalent information.

#include <stdio.h>
int yyparse(void);
extern void *yylval;

//Linked list structures for subsequent JSON encoding
struct Map {
	int key;
	int value;
	struct Map *next;
};
struct Array {
	int value;
	struct Array *next;
};

int state;
int yylex(void) {
	if (state) {yylval = "foo"; state = 0; return 258;}
	return 0;
}

int main() {
	printf("Hello, world!\n");
	state = 1;
	int ret = yyparse();
	printf("Ret = %d\n", ret);
	return 0;
}

void yyerror(const char *error) {
	printf("ERROR parsing: %s\n", error);
}
