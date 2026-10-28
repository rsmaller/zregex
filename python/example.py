import zregex, sys

zregex.init()
test = zregex.compile(sys.argv[2])
my_match = zregex.match(test, sys.argv[1])

print("Pattern: " + sys.argv[2])
print("Match str: " + sys.argv[1])
print()
zregex.print_ast(test, False)
print()
zregex.print_bytecode(test)
print()
for i in range(len(my_match.groups)):
    print("Group " + str(i) + ": " + my_match.groups[i])