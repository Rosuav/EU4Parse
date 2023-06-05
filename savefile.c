//Parse an EU4 save file (and possibly some config files but not all)
//and output a JSON blob with equivalent information.

#define _GNU_SOURCE
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
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
	if (size) munmap((void *)data, size);
	return 0;
}

void yyerror(const char *error) {
	printf("ERROR parsing: %s\n", error);
}
