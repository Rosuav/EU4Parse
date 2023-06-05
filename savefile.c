//Parse an EU4 save file (and possibly some config files but not all)
//and output a JSON blob with equivalent information.

#define _GNU_SOURCE
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int yyparse(void);
union YYSTYPE;

//Linked list structures for subsequent JSON encoding
struct String {
	char sig; //'S'
	const char *start;
	size_t length;
};
struct Map {
	char sig; //'M'
	struct String *key;
	union YYSTYPE *value;
	struct Map *next;
};
struct Array {
	char sig; //'A'
	union YYSTYPE *value;
	struct Array *next;
};
struct Boolean {char sig;} boolean[2] = {{'B'}, {'B'}}; //Identified by their pointers
struct String *make_string(const char *start, const char *next, int quoted) {
	struct String *ret = malloc(sizeof (struct String));
	if (!ret) return ret;
	ret->sig = quoted ? 'S' : 's';
	ret->start = start;
	ret->length = next - start;
}

struct Map *savefile_result;

struct Map *make_map(struct Map *next, struct String *key, union YYSTYPE *value) {
	struct Map *ret = malloc(sizeof (struct Map));
	if (!ret) return ret;
	ret->sig = 'M';
	ret->next = next;
	ret->key = key;
	ret->value = value;
}

struct Array *make_array(struct Array *next, union YYSTYPE *value) {
	struct Array *ret = malloc(sizeof (struct Array));
	if (!ret) return ret;
	ret->sig = 'A';
	ret->next = next;
	ret->value = value;
}

//Mutually recursive output functions
void output_json(FILE *fp, union YYSTYPE *value);
//Also outputs some non-string values
void output_json_string(FILE *fp, struct String *str) {
	int quoted = str->sig == 'S';
	if (quoted) fputc('"', fp);
	fwrite(str->start, 1, str->length, fp);
	if (quoted) fputc('"', fp);
	free(str);
}

void output_json_mapping(FILE *fp, struct Map *map) {
	if (map->next) {
		output_json_mapping(fp, map->next);
		fputc(',', fp);
	}
	output_json_string(fp, map->key);
	fputc(':', fp);
	output_json(fp, map->value);
	free(map);
}

void output_json_array(FILE *fp, struct Array *arr) {
	if (arr->next) {
		output_json_array(fp, arr->next);
		fputc(',', fp);
	}
	if (arr->value) output_json(fp, arr->value); //Empty arrays have null value pointers.
	free(arr);
}

//Output as JSON and also deallocate memory
void output_json(FILE *fp, union YYSTYPE *value) {
	if (!value) return; //Shouldn't happen
	//Booleans are identified by their pointers.
	if ((struct Boolean *)value == boolean) {fputs("false", fp); return;}
	if ((struct Boolean *)value == boolean + 1) {fputs("true", fp); return;}
	switch (((struct Array *)value)->sig) {
		case 'M':
			fputc('{', fp);
			output_json_mapping(fp, (struct Map *)value);
			fputc('}', fp);
			break;
		case 'A':
			fputc('[', fp);
			output_json_array(fp, (struct Array *)value);
			fputc(']', fp);
			break;
		case 'S': case 's': output_json_string(fp, (struct String *)value); break;
		default: break; //Shouldn't happen (error maybe?)
	}
}

const void *data;
const char *next;
size_t remaining;
int yylex(void);
int main(int argc, const char *argv[]) {
	if (argc < 2) {printf("Need a file name\n"); return 1;}
	int fd = open(argv[1], O_RDONLY|O_NOATIME);
	off_t size = lseek(fd, 0, SEEK_END);
	if (!size) data = "";
	//Possible flags: MAP_NORESERVE MAP_POPULATE
	else {
		data = mmap(NULL, size, PROT_READ, MAP_PRIVATE | MAP_POPULATE, fd, 0);
		if (data == MAP_FAILED) {
			perror("mmap");
			close(fd);
			return 1;
		}
	}
	close(fd);
	next = (char *)data;
	remaining = size;
	//A save file should begin with the prefix "EU4txt". If it doesn't, it might be
	//a config file, or it might be compressed. TODO: Unzip into memory.
	if (remaining > 6 && !strncmp(next, "EU4txt", 6)) {remaining += 6; next += 6;}
	int ret = yyparse();
	if (!ret) {
		FILE *fp = fopen("savefile.json", "w");
		output_json(fp, (union YYSTYPE *)savefile_result);
		fclose(fp);
		printf("Saved to file.\n");
	}
	else {
		int shoe = (char *)data - next, cap = remaining;
		if (shoe < -16) shoe = -16;
		if (cap > 64) cap = 64;
		for (int i = shoe; i < cap; ++i)
			printf("%c", next[i] < ' ' || next[i] > '~' ? '.' : next[i]);
		printf("\n");
		for (int i = shoe; i < 0; ++i)
			printf("-");
		printf("^\n");
	}
	if (size) munmap((void *)data, size); //Don't unmap until output_json is done as strings are referenced directly from the mmap
	return 0;
}

void yyerror(const char *error) {
	printf("ERROR parsing: %s\n", error);
}
