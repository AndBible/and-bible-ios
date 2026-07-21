#ifndef CSEARCHSTEMMERS_H
#define CSEARCHSTEMMERS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum ABSearchStemmerLanguage {
    AB_SEARCH_STEMMER_DANISH = 0,
    AB_SEARCH_STEMMER_DUTCH = 1,
    AB_SEARCH_STEMMER_FINNISH = 2,
    AB_SEARCH_STEMMER_FRENCH = 3,
    AB_SEARCH_STEMMER_ITALIAN = 4,
    AB_SEARCH_STEMMER_NORWEGIAN = 5,
    AB_SEARCH_STEMMER_PORTUGUESE = 6,
    AB_SEARCH_STEMMER_RUSSIAN = 7,
    AB_SEARCH_STEMMER_SPANISH = 8,
    AB_SEARCH_STEMMER_SWEDISH = 9,
} ABSearchStemmerLanguage;

/**
 Stems one lowercased UTF-8 token with the pinned Lucene 3.6.2 Snowball algorithm.

 Returns the output byte count, or a negative value for an invalid language, allocation/runtime
 failure, or insufficient output capacity. The output is not NUL-terminated.
 */
int32_t ab_search_stem_utf8(
    ABSearchStemmerLanguage language,
    const uint8_t *input,
    size_t input_length,
    uint8_t *output,
    size_t output_capacity
);

#ifdef __cplusplus
}
#endif

#endif
