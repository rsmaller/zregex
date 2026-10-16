CC = gcc
FLAGS = -Wall
IFLAGS = -I./include
LFLAGS = -L./c-out/
OS := $(shell uname)
ifeq ($(OS), Darwin)
	LFLAGS += -Wl,-rpath,./c-out
endif

default: all

all: zig-lib c-example

zig-lib:
	zig build

c-example: ./c-example/c-example.c zig-lib
	mkdir -p c-out
	cp ./zig-out/bin/* ./c-out
	cp ./zig-out/lib/* ./c-out
	$(CC) ./c-example/c-example.c $(FLAGS) $(IFLAGS) $(LFLAGS) -lzregex -o c-out/c-example
	