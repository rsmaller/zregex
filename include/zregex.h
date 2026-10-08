#include <stddef.h>
#include <stdbool.h>
typedef struct Match { // Expose abi.zig's Match struct type.
    char **groups;
    void *pattern_ptr;
    size_t group_count;
} Match;

typedef struct ASTPrintOptions { // Expose root.zig's ASTPrintOptions struct type.
    bool show_match_width;
} ASTPrintOptions;

void *zregex_compile(const char *str);
Match *zregex_match(void *pattern_handle, const char *string);

void zregex_destroy_pattern(void *pattern_handle);
void zregex_destroy_match(Match *match_handle);

void zregex_init_zig(void *io_handle);

void zregex_print_bytecode(void *pattern_handle);
void zregex_print_ast(void *pattern_handle, ASTPrintOptions options);