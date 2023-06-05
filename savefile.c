//Parse an EU4 save file (and possibly some config files but not all)
//and output a JSON blob with equivalent information.

#define _GNU_SOURCE
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
int yyparse(void);
extern void *yylval;

//Linked list structures for subsequent JSON encoding
struct String {
	char sig; //'S'
	const char *start;
	size_t length;
};
struct Map {
	char sig; //'M'
	struct String *key;
	void *value; //Will be one of the union members
	struct Map *next;
};
struct Array {
	char sig; //'A'
	void *value; //As above, will be a union member
	struct Array *next;
};
struct String *make_string(const char *start, const char *next) {
	struct String *ret = malloc(sizeof (struct String));
	if (!ret) return ret;
	ret->sig = 'S';
	ret->start = start;
	ret->length = next - start;
}

struct Map *make_map(struct Map *next, struct String *key, void *value) {
	struct Map *ret = malloc(sizeof (struct Map));
	if (!ret) return ret;
	ret->sig = 'M';
	ret->next = next;
	ret->key = key;
	ret->value = value;
}

struct Array *make_array(struct Array *next, void *value) {
	struct Array *ret = malloc(sizeof (struct Array));
	if (!ret) return ret;
	ret->sig = 'A';
	ret->next = next;
	ret->value = value;
}

const void *data;
const char *next;
size_t remaining;
int yylex(void);
int main(int argc, const char *argv[]) {
	if (argc < 2) {printf("Need a file name\n"); return 1;}
	int fd = open(argv[1], O_RDONLY|O_NOATIME);
	printf("fd = %d\n", fd);
	off_t size = lseek(fd, 0, SEEK_END);
	printf("size = %d\n", (int)size);
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
	printf("Hello, world!\n");
	int ret = yyparse();
	printf("Ret = %d\n", ret);
	printf("yylval = %c\n", ((struct String *)yylval)->sig);
	if (size) munmap((void *)data, size);
	return 0;
}

void yyerror(const char *error) {
	printf("ERROR parsing: %s\n", error);
}
