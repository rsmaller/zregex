CC = gcc
FLAGS = -Wall

default: zig-lib c-example

zig-lib: ../
	zig build
	cp ../zig-out/bin/zregex.dll ./

c-example: ./c-example.c
	$(CC) ./c-example.c $(FLAGS) -I../include -L. -lzregex -o c-example