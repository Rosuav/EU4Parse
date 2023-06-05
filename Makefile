savefile: savefile.c savefile.tab.c
	gcc -o$@ $^

savefile.tab.c: savefile.y
	bison $^

%.c: %.y
