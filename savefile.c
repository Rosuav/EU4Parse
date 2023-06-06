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
	char sig; //'S' or 's'
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
	char sig; //'A' or 'a'
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

struct Array *make_array(struct Array *next, union YYSTYPE *value) {
	struct Array *ret = malloc(sizeof (struct Array));
	if (!ret) return ret;
	ret->sig = 'A';
	ret->next = next;
	ret->value = value;
}

struct Map *make_map(struct Map *next, struct String *key, union YYSTYPE *value) {
	//If next is non-null, we're adding an entry to an existing map. This is usually
	//not a problem, and it simply means attaching ourselves to the head of the linked
	//list, but the EU4 format sometimes creates arrays by multiple assignment. So we
	//have to scan the map for any matching key. If we find one, is the value already an
	//automatic array? (Note that "is the value an array" is not sufficient here.) If
	//so, append ourselves to it (which means becoming the head of the LL - the lists
	//in memory are actually stored backwards for efficiency). But if it's NOT, we
	//have to replace it with an array of two elements. This is the only situation in
	//which these constructor functions will ever mutate existing data.
	if (next) {
		struct Map *cur = next;
		while (cur) {
			if (key->length == cur->key->length && !strncmp(key->start, cur->key->start, key->length)) {
				//Matching key.
				struct Array *aa = (struct Array *)cur->value;
				if (aa->sig != 'a') {
					//It's not an autoarray. Make one.
					aa = make_array(NULL, cur->value);
					//aa->sig = 'a'; //No point flagging the first element, although it would be more logical to.
				}
				aa = make_array(aa, value);
				aa->sig = 'a'; //Carry autoarrayness onto the new head
				cur->value = (union YYSTYPE *)aa;
				return next; //The overall map doesn't change head, we just mutated deep inside it
			}
			cur = cur->next;
		}
		//Not found? Make this the new head.
	}
	struct Map *ret = malloc(sizeof (struct Map));
	if (!ret) return ret;
	ret->sig = 'M';
	ret->next = next;
	ret->key = key;
	ret->value = value;
}

//Mutually recursive output functions
void output_json(FILE *fp, union YYSTYPE *value);
//Also outputs some non-string values
void output_json_string(FILE *fp, struct String *str) {
	int quoted = str->sig == 'S';
	if (quoted) fputc('"', fp);
	//If we could be sure the string was entirely ASCII, this would be fine.
	//Unfortunately, this won't work with anything non-ASCII, since the save
	//file is encoded ISO-8859-1 and JSON has to be UTF-8. So we do it one
	//character at a time instead.
	//fwrite(str->start, 1, str->length, fp);
	const unsigned char *stop = str->start + str->length;
	for (const unsigned char *ch = str->start; ch < stop; ++ch) {
		if (*ch >= ' ' && *ch < 128) fputc(*ch, fp);
		else fprintf(fp, "\\u%04x", *ch);
	}
	if (quoted) fputc('"', fp);
	free(str);
}

int output_json_mapping(FILE *fp, struct Map *map, int add_index) {
	if (!map->value) {free(map); return add_index;} //Empty maps have null key and value pointers.
	//Special case: Retain _index entries for the countries.
	int want_order = map->key->length == 9 && !strncmp(map->key->start, "countries", 9) && ((struct Map *)map->value)->sig == 'M';
	if (map->next) {
		add_index += output_json_mapping(fp, map->next, add_index);
		fputc(',', fp);
	}
	output_json_string(fp, map->key);
	fputc(':', fp);
	if (want_order) {
		fputc('{', fp);
		output_json_mapping(fp, (struct Map *)map->value, 1);
		fputc('}', fp);
	}
	else if (add_index && ((struct Map *)map->value)->sig == 'M') {
		fputc('{', fp);
		fprintf(fp, "\"_index\":%d,", add_index - 1); //Record zero-based indices
		output_json_mapping(fp, (struct Map *)map->value, 0);
		fputc('}', fp);
	}
	else output_json(fp, map->value);
	free(map);
	return add_index;
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
	if ((struct Boolean *)value == boolean) {fputc('0', fp); return;}
	if ((struct Boolean *)value == boolean + 1) {fputc('1', fp); return;}
	switch (((struct Array *)value)->sig) {
		case 'M':
			fputc('{', fp);
			output_json_mapping(fp, (struct Map *)value, 0);
			fputc('}', fp);
			break;
		case 'A': case 'a':
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
		FILE *fp = stdout;
		if (argc > 2) fp = fopen(argv[2], "w");
		int hash = argc > 3 && !strcmp(argv[3], "--hash");
		if (hash) fprintf(fp, "{\"data\":");
		if (savefile_result) output_json(fp, (union YYSTYPE *)savefile_result);
		else fputs("{}", fp); //No output? Output an empty object.
		if (hash) fprintf(fp, ",\"hash\":\"\"}"); //Note that we don't ACTUALLY hash it, we just leave a stub.
		if (fp != stdout) fclose(fp);
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
	return ret;
}

void yyerror(const char *error) {
	printf("ERROR parsing: %s\n", error);
}
