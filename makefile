CC = gcc
FLAGS = -Wall
IFLAGS = -I./include
LFLAGS = -L./zig-out/bin -lzregex

default: all

all: zig-lib c-example

zig-lib:
	zig build

c-example: ./c-example/c-example.c zig-lib
	mkdir c-out
	$(CC) ./c-example/c-example.c $(FLAGS) $(IFLAGS) $(LFLAGS) -o c-out/c-example
	cp ./zig-out/bin/zregex.* c-out/