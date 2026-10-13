#include "../include/zregex.h"
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 3) {
        printf("Please provide a string and pattern!\n");
        return -1;
    }
    zregex_init_c(stdout);
    char *string_to_match = argv[1]; //"john.doe@gmail.com";
    char *pattern = argv[2];
    printf("String: %s, Pattern: %s\n", string_to_match, pattern); // So string and pattern print before errors.
    void *compiled_pattern = zregex_compile(pattern);
    printf("AST:\n");
    ASTPrintOptions x = { true };
    zregex_print_ast(compiled_pattern, x);
    printf("\nBytecode:\n");
    zregex_print_bytecode(compiled_pattern);
    printf("\nMatch against string %s:\n", string_to_match);
    Match *my_match = zregex_match(compiled_pattern, string_to_match);
    if (my_match != NULL) {
        const char *match_str = zregex_name_index(my_match, "test");
        if (match_str != NULL) {
            printf("Testing match name \"test\": \"%s\"\n", match_str);
        } else {
            printf("Testing match name \"test\": <NULL>\n");
        }
        const ZOptional_size_t match_id_container = zregex_name_to_id(compiled_pattern, "test");
        if (match_id_container.present) {
            printf("Testing id fetch from name \"test\": %llu\n", match_id_container.value);
        } else {
            printf("Testing id fetch from name \"test\": NULL\n");
        }
        for (size_t id=0; id<my_match->group_count; id++) {
            printf("Group %llu", id);
            const char *name = zregex_id_to_name(compiled_pattern, id);
            if (name != NULL) {
                printf(" <%s>", name);
                zregex_destroy_name(name);
            }
            printf(": ");
            const char *item = zregex_id_index(my_match, id);
            if (item != NULL) {
                printf("\"%s\"\n", item);
            } else {
                printf("<NULL>\n");
            }
        }
    }

    // All defer statements down here!
    if (my_match != NULL) {
        zregex_destroy_match(my_match);
    }
    zregex_destroy_pattern(compiled_pattern);
}