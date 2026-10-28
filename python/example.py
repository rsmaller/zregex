import zregex, sys

zregex.init()
test = zregex.compile(sys.argv[2])
my_match = test.match(sys.argv[1])

print("Pattern: " + sys.argv[2])
print("Match str: " + sys.argv[1])
print()
test.print_ast(False)
print()
test.print_bytecode()
print()
for i in range(len(my_match.groups)):
    print("Group " + str(i) + ": " + my_match[i])

print("Other name \"test\": " + str(my_match["test"]))
print("Id of that name: " + str(test.name_to_id("test")))
print("Name of that id: " + str(test.id_to_name(test.name_to_id("test"))))