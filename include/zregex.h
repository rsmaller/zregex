#include <stddef.h>
typedef struct Match {
    char **groups;
    void *pattern_ptr;
    size_t group_count;
} Match;

void *zregex_compile(const char *str);
void zregex_destroy_pattern(void *pattern_handle);
Match *zregex_match(void *pattern_handle, const char *string);
void zregex_destroy_match(Match *match_handle);