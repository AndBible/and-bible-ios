#include "CSearchStemmers.h"

#include <limits.h>
#include <string.h>

#include "api.h"
#include "stem_UTF_8_danish.h"
#include "stem_UTF_8_dutch.h"
#include "stem_UTF_8_finnish.h"
#include "stem_UTF_8_french.h"
#include "stem_UTF_8_italian.h"
#include "stem_UTF_8_norwegian.h"
#include "stem_UTF_8_portuguese.h"
#include "stem_UTF_8_russian.h"
#include "stem_UTF_8_spanish.h"
#include "stem_UTF_8_swedish.h"

typedef struct ABSearchStemmerFunctions {
    struct SN_env *(*create)(void);
    int (*stem)(struct SN_env *);
    void (*close)(struct SN_env *);
} ABSearchStemmerFunctions;

#define AB_STEMMER_FUNCTIONS(language) \
    { language##_UTF_8_create_env, language##_UTF_8_stem, language##_UTF_8_close_env }

static const ABSearchStemmerFunctions AB_SEARCH_STEMMERS[] = {
    AB_STEMMER_FUNCTIONS(danish),
    AB_STEMMER_FUNCTIONS(dutch),
    AB_STEMMER_FUNCTIONS(finnish),
    AB_STEMMER_FUNCTIONS(french),
    AB_STEMMER_FUNCTIONS(italian),
    AB_STEMMER_FUNCTIONS(norwegian),
    AB_STEMMER_FUNCTIONS(portuguese),
    AB_STEMMER_FUNCTIONS(russian),
    AB_STEMMER_FUNCTIONS(spanish),
    AB_STEMMER_FUNCTIONS(swedish),
};

int32_t ab_search_stem_utf8(
    ABSearchStemmerLanguage language,
    const uint8_t *input,
    size_t input_length,
    uint8_t *output,
    size_t output_capacity
) {
    const size_t stemmer_count = sizeof(AB_SEARCH_STEMMERS) / sizeof(AB_SEARCH_STEMMERS[0]);
    if ((int)language < 0 || (size_t)language >= stemmer_count || input_length > INT_MAX) {
        return -1;
    }

    const ABSearchStemmerFunctions functions = AB_SEARCH_STEMMERS[language];
    struct SN_env *environment = functions.create();
    if (environment == NULL) {
        return -2;
    }

    int32_t result = -3;
    if (SN_set_current(environment, (int)input_length, input) >= 0 &&
        functions.stem(environment) >= 0) {
        if ((size_t)environment->l <= output_capacity) {
            memcpy(output, environment->p, (size_t)environment->l);
            result = environment->l;
        } else {
            result = -4;
        }
    }

    functions.close(environment);
    return result;
}
