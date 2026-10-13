#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
typedef struct Match { // Expose abi.zig's Match struct type.
    char **groups;
    void *pattern_ptr;
    size_t group_count;
} Match;

#define ZIG_NON_PTR_OPTIONAL_DECL(T) typedef struct ZOptional_##T {\
    T value;\
    bool present;\
} ZOptional_##T;

ZIG_NON_PTR_OPTIONAL_DECL(size_t);

typedef struct ASTPrintOptions { // Expose root.zig's ASTPrintOptions struct type.
    bool show_match_width;
} ASTPrintOptions;

void zregex_dummy(void);

void *zregex_compile(const char *str);
Match *zregex_match(void *pattern_handle, const char *string);

void zregex_destroy_pattern(void *pattern_handle);
void zregex_destroy_match(Match *match_handle);

void zregex_init_zig(void *io_handle); // Takes in the Zig IO handle.
void zregex_init_c(FILE *io_handle); // Takes in a FILE ptr to stdout.

void zregex_print_bytecode(void *pattern_handle);
void zregex_print_ast(void *pattern_handle, ASTPrintOptions options);

const char *zregex_name_index(Match *match_handle, const char *name);
const char *zregex_id_index(Match *match_handle, size_t id);

const ZOptional_size_t zregex_name_to_id(void *pattern_handle, const char *name);
const char *zregex_id_to_name(void *pattern_handle, size_t id);
void zregex_destroy_name(const char *name);