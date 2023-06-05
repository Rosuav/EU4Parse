//Parse an EU4 save file (and possibly some config files but not all)
//and output a JSON blob with equivalent information.

#define _GNU_SOURCE
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
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
struct String *make_string(const char *start, const char *next) {
	struct String *ret = malloc(sizeof (struct String));
	printf("Building a string from %p to %p --> %p\n", start, next, ret);
	if (!ret) return ret;
	ret->sig = 'S';
	ret->start = start;
	ret->length = next - start;
}

struct Map *savefile_result;

struct Map *make_map(struct Map *next, struct String *key, union YYSTYPE *value) {
	struct Map *ret = malloc(sizeof (struct Map));
	printf("Building a map, k %p, v %p, next %p --> %p\n", key, value, next, ret);
	if (!ret) return ret;
	ret->sig = 'M';
	ret->next = next;
	ret->key = key;
	ret->value = value;
}

struct Array *make_array(struct Array *next, union YYSTYPE *value) {
	struct Array *ret = malloc(sizeof (struct Array));
	printf("Building an array, v %p, next %p --> %p\n", value, next, ret);
	if (!ret) return ret;
	ret->sig = 'A';
	ret->next = next;
	ret->value = value;
}

//Output a string (or possibly related values) but does NOT deallocate memory
void output_json_string(int fd, struct String *value) {
	write(fd, "\"", 1);
	write(fd, value->start, value->length);
	write(fd, "\"", 1);
}

//Output as JSON and also deallocate memory
void output_json(int fd, union YYSTYPE *value) {
	if (!value) return; //Shouldn't happen
	switch (((struct Array *)value)->sig) {
		case 'M': {
			struct Map *map = (struct Map *)value;
			write(fd, "{", 1);
			while (map) {
				output_json_string(fd, map->key); free(map->key);
				write(fd, ":", 1);
				output_json(fd, map->value);
				map = map->next;
				if (map) write(fd, ",", 1); //Omit the comma on the last one
			}
			write(fd, "}", 1);
			break;
		}
		case 'A': {
			struct Array *arr = (struct Array *)value;
			write(fd, "[", 1);
			if (arr->value) output_json(fd, arr->value); //Empty arrays have null value pointers.
			while (arr = arr->next) {
				write(fd, ",", 1);
				output_json(fd, arr->value);
			}
			write(fd, "]", 1);
			break;
		}
		case 'S': output_json_string(fd, (struct String *)value); break;
		default: break; //Shouldn't happen (error maybe?)
	}
	free(value);
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
	int ret = yyparse();
	printf("Ret = %d\n", ret);
	//TODO: Output to file?
	write(1, "result: ", sizeof "result:");
	output_json(1, (union YYSTYPE *)savefile_result);
	printf("\n");
	if (size) munmap((void *)data, size);
	return 0;
}

void yyerror(const char *error) {
	printf("ERROR parsing: %s\n", error);
}
