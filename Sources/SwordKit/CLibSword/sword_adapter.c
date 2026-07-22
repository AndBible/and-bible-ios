// sword_adapter.c — Bridge between simplified API and real SWORD library
//
// When USE_REAL_SWORD is defined, implements our simplified flatapi.h functions
// by calling through to the real org_crosswire_sword_* functions from libsword.
// Otherwise, provides stub implementations for development without libsword.

#include "include/flatapi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#ifdef USE_REAL_SWORD

// ============================================================
// REAL SWORD IMPLEMENTATION
// ============================================================

#include "sword_real_api.h"

const char **SWModule_getVerseKeyChildrenDirect(void *module);

// --- Cached state for module list iteration ---
static const struct org_crosswire_sword_ModInfo *cached_mod_list = NULL;
static SWHANDLE cached_mod_list_mgr = 0;
static int cached_mod_count = -1;

// --- Cached state for search results ---
static const struct org_crosswire_sword_SearchHit *cached_search_hits = NULL;

// Helper: count entries in NULL-name-terminated ModInfo array
static int count_mod_info(const struct org_crosswire_sword_ModInfo *list) {
    if (!list) return 0;
    int count = 0;
    while (list[count].name != NULL) count++;
    return count;
}

// Helper: count entries in NULL-modName-terminated SearchHit array
static int count_search_hits(const struct org_crosswire_sword_SearchHit *hits) {
    if (!hits) return 0;
    int count = 0;
    while (hits[count].modName != NULL) count++;
    return count;
}

// --- SWMgr ---

void *SWMgr_new(const char *path) {
    SWHANDLE h;
    if (path) {
        h = org_crosswire_sword_SWMgr_newWithPath(path);
    } else {
        h = org_crosswire_sword_SWMgr_new();
    }
    // Enable headings and other OSIS features by default
    if (h) {
        org_crosswire_sword_SWMgr_setGlobalOption(h, "Headings", "On");
        org_crosswire_sword_SWMgr_setGlobalOption(h, "Cross-references", "Off");
        org_crosswire_sword_SWMgr_setGlobalOption(h, "Footnotes", "Off");
        org_crosswire_sword_SWMgr_setGlobalOption(h, "Words of Christ in Red", "On");
    }
    return (void *)(uintptr_t)h;
}

void SWMgr_delete(void *mgr) {
    if (!mgr) return;
    SWHANDLE h = (SWHANDLE)(uintptr_t)mgr;
    // Invalidate cache if this manager was cached
    if (h == cached_mod_list_mgr) {
        cached_mod_list = NULL;
        cached_mod_list_mgr = 0;
        cached_mod_count = -1;
    }
    org_crosswire_sword_SWMgr_delete(h);
}

static void ensure_mod_list_cached(void *mgr) {
    SWHANDLE h = (SWHANDLE)(uintptr_t)mgr;
    if (cached_mod_list_mgr != h || cached_mod_count < 0) {
        cached_mod_list = org_crosswire_sword_SWMgr_getModInfoList(h);
        cached_mod_list_mgr = h;
        cached_mod_count = count_mod_info(cached_mod_list);
    }
}

int SWMgr_getModuleCount(void *mgr) {
    if (!mgr) return 0;
    ensure_mod_list_cached(mgr);
    return cached_mod_count;
}

const char *SWMgr_getModuleNameByIndex(void *mgr, int index) {
    if (!mgr) return NULL;
    ensure_mod_list_cached(mgr);
    if (index < 0 || index >= cached_mod_count) return NULL;
    return cached_mod_list[index].name;
}

void *SWMgr_getModuleByName(void *mgr, const char *name) {
    if (!mgr || !name) return NULL;
    SWHANDLE h = (SWHANDLE)(uintptr_t)mgr;
    SWHANDLE mod = org_crosswire_sword_SWMgr_getModuleByName(h, name);
    return (void *)(uintptr_t)mod;
}

void SWMgr_setGlobalOption(void *mgr, const char *option, const char *value) {
    if (!mgr) return;
    org_crosswire_sword_SWMgr_setGlobalOption(
        (SWHANDLE)(uintptr_t)mgr, option, value);
}

const char *SWMgr_getGlobalOption(void *mgr, const char *option) {
    if (!mgr) return "";
    return org_crosswire_sword_SWMgr_getGlobalOption(
        (SWHANDLE)(uintptr_t)mgr, option);
}

const char *SWMgr_getConfigPath(void *mgr) {
    if (!mgr) return "";
    return org_crosswire_sword_SWMgr_getConfigPath(
        (SWHANDLE)(uintptr_t)mgr);
}

const char *SWMgr_getPrefixPath(void *mgr) {
    if (!mgr) return "";
    return org_crosswire_sword_SWMgr_getPrefixPath(
        (SWHANDLE)(uintptr_t)mgr);
}

void SWMgr_setCipherKey(void *mgr, const char *moduleName, const char *key) {
    if (!mgr || !moduleName || !key) return;
    org_crosswire_sword_SWMgr_setCipherKey(
        (SWHANDLE)(uintptr_t)mgr, moduleName, key);
}

void SWMgr_setJavascript(void *mgr, int enabled) {
    if (!mgr) return;
    org_crosswire_sword_SWMgr_setJavascript(
        (SWHANDLE)(uintptr_t)mgr, (char)enabled);
}

// --- SWModule ---

const char *SWModule_getName(void *module) {
    if (!module) return "";
    return org_crosswire_sword_SWModule_getName(
        (SWHANDLE)(uintptr_t)module);
}

const char *SWModule_getDescription(void *module) {
    if (!module) return "";
    return org_crosswire_sword_SWModule_getDescription(
        (SWHANDLE)(uintptr_t)module);
}

const char *SWModule_getType(void *module) {
    if (!module) return "Unknown";
    return org_crosswire_sword_SWModule_getCategory(
        (SWHANDLE)(uintptr_t)module);
}

const char *SWModule_getLanguage(void *module) {
    if (!module) return "en";
    // Real API has no getLanguage — use config entry
    const char *lang = org_crosswire_sword_SWModule_getConfigEntry(
        (SWHANDLE)(uintptr_t)module, "Lang");
    return lang ? lang : "en";
}

void SWModule_setKeyText(void *module, const char *keyText) {
    if (!module || !keyText) return;
    org_crosswire_sword_SWModule_setKeyText(
        (SWHANDLE)(uintptr_t)module, keyText);
}

const char *SWModule_getKeyText(void *module) {
    if (!module) return "";
    return org_crosswire_sword_SWModule_getKeyText(
        (SWHANDLE)(uintptr_t)module);
}

const char **SWModule_getEntryAttribute(void *module,
                                        const char *level1,
                                        const char *level2,
                                        const char *level3,
                                        char filteredBool) {
    if (!module) return NULL;
    return org_crosswire_sword_SWModule_getEntryAttribute(
        (SWHANDLE)(uintptr_t)module, level1, level2, level3, filteredBool);
}

const char **SWModule_parseKeyList(void *module, const char *keyText) {
    if (!module || !keyText) return NULL;
    return org_crosswire_sword_SWModule_parseKeyList(
        (SWHANDLE)(uintptr_t)module, keyText);
}

const char *SWModule_getRenderText(void *module) {
    if (!module) return "";
    return org_crosswire_sword_SWModule_renderText(
        (SWHANDLE)(uintptr_t)module);
}

const char *SWModule_getRawEntry(void *module) {
    if (!module) return "";
    return org_crosswire_sword_SWModule_getRawEntry(
        (SWHANDLE)(uintptr_t)module);
}

const char *SWModule_getRenderHeader(void *module) {
    if (!module) return "";
    return org_crosswire_sword_SWModule_getRenderHeader(
        (SWHANDLE)(uintptr_t)module);
}

const char *SWModule_getStripText(void *module) {
    if (!module) return "";
    return org_crosswire_sword_SWModule_stripText(
        (SWHANDLE)(uintptr_t)module);
}

int SWModule_next(void *module) {
    if (!module) return -1;
    SWHANDLE h = (SWHANDLE)(uintptr_t)module;
    org_crosswire_sword_SWModule_next(h);
    return (int)org_crosswire_sword_SWModule_popError(h);
}

int SWModule_previous(void *module) {
    if (!module) return -1;
    SWHANDLE h = (SWHANDLE)(uintptr_t)module;
    org_crosswire_sword_SWModule_previous(h);
    return (int)org_crosswire_sword_SWModule_popError(h);
}

void SWModule_begin(void *module) {
    if (!module) return;
    org_crosswire_sword_SWModule_begin(
        (SWHANDLE)(uintptr_t)module);
}

int SWModule_isEnd(void *module) {
    if (!module) return 1;
    // Check via popError — if error is non-zero, we're past the end
    return (int)org_crosswire_sword_SWModule_popError(
        (SWHANDLE)(uintptr_t)module);
}

char SWModule_popError(void *module) {
    if (!module) return 1;
    return org_crosswire_sword_SWModule_popError(
        (SWHANDLE)(uintptr_t)module);
}

// No-op progress callback to prevent null pointer dereference in SWORD's search
static void noop_search_progress(int percent) {
    (void)percent;
}

void *SWModule_search(void *module, const char *searchString,
                      int searchType, int flags, const char *scope,
                      void *progressCallback) {
    if (!module) return NULL;
    org_crosswire_sword_SWModule_SearchCallback cb = progressCallback
        ? (org_crosswire_sword_SWModule_SearchCallback)progressCallback
        : (org_crosswire_sword_SWModule_SearchCallback)noop_search_progress;
    cached_search_hits = org_crosswire_sword_SWModule_search(
        (SWHANDLE)(uintptr_t)module, searchString,
        searchType, (long)flags, scope, cb);
    return (void *)cached_search_hits;
}

int SWModule_searchResultCount(void *module) {
    return count_search_hits(cached_search_hits);
}

const char *SWModule_getSearchResultKeyText(void *module, int index) {
    if (!cached_search_hits) return "";
    int count = count_search_hits(cached_search_hits);
    if (index < 0 || index >= count) return "";
    return cached_search_hits[index].key;
}

int SWModule_hasFeature(void *module, const char *feature) {
    if (!module || !feature) return 0;
    // Check via config entry — SWORD modules list features in config
    const char *val = org_crosswire_sword_SWModule_getConfigEntry(
        (SWHANDLE)(uintptr_t)module, "Feature");
    if (val && strstr(val, feature)) return 1;
    // Also check GlobalOptionFilter for features like StrongsNumbers
    val = org_crosswire_sword_SWModule_getConfigEntry(
        (SWHANDLE)(uintptr_t)module, "GlobalOptionFilter");
    if (val && strstr(val, feature)) return 1;
    // Map feature names to OSIS filter names:
    // "StrongsNumbers" -> check for "OSISStrongs" filter
    if (strcmp(feature, "StrongsNumbers") == 0) {
        if (val && strstr(val, "OSISStrongs")) return 1;
        // Also check Feature=StrongsNumbers (some modules use this)
        val = org_crosswire_sword_SWModule_getConfigEntry(
            (SWHANDLE)(uintptr_t)module, "Feature");
        if (val && strstr(val, "Strongs")) return 1;
    }
    return 0;
}

const char *SWModule_getConfigEntry(void *module, const char *key) {
    if (!module) return NULL;
    return org_crosswire_sword_SWModule_getConfigEntry(
        (SWHANDLE)(uintptr_t)module, key);
}

void SWModule_setCipherKey(void *module, const char *key) {
    // Real API sets cipher key on SWMgr, not SWModule.
    // For now, this is a no-op. The module-level cipher key
    // should be set via SWMgr_setCipherKey instead.
}

const char **SWModule_getKeyChildren(void *module) {
    if (!module) return NULL;
    const char **verseKeyChildren = SWModule_getVerseKeyChildrenDirect(module);
    if (verseKeyChildren) return verseKeyChildren;
    return org_crosswire_sword_SWModule_getKeyChildren(
        (SWHANDLE)(uintptr_t)module);
}

// --- InstallMgr ---

void *InstallMgr_new(const char *basePath) {
    SWHANDLE h = org_crosswire_sword_InstallMgr_new(basePath, NULL);
    return (void *)(uintptr_t)h;
}

void InstallMgr_delete(void *installMgr) {
    if (!installMgr) return;
    org_crosswire_sword_InstallMgr_delete(
        (SWHANDLE)(uintptr_t)installMgr);
}

void InstallMgr_setUserDisclaimerConfirmed(void *installMgr) {
    if (!installMgr) return;
    org_crosswire_sword_InstallMgr_setUserDisclaimerConfirmed(
        (SWHANDLE)(uintptr_t)installMgr);
}

int InstallMgr_refreshRemoteSource(void *installMgr, const char *sourceName) {
    if (!installMgr) return -1;
    return org_crosswire_sword_InstallMgr_refreshRemoteSource(
        (SWHANDLE)(uintptr_t)installMgr, sourceName);
}

// Cached remote sources for count/name iteration
static const char **cached_remote_sources = NULL;

static int count_string_array(const char **arr) {
    if (!arr) return 0;
    int count = 0;
    while (arr[count] != NULL) count++;
    return count;
}

int InstallMgr_getRemoteSourceCount(void *installMgr) {
    if (!installMgr) return 0;
    cached_remote_sources = org_crosswire_sword_InstallMgr_getRemoteSources(
        (SWHANDLE)(uintptr_t)installMgr);
    return count_string_array(cached_remote_sources);
}

const char *InstallMgr_getRemoteSourceName(void *installMgr, int index) {
    if (!cached_remote_sources) return NULL;
    int count = count_string_array(cached_remote_sources);
    if (index < 0 || index >= count) return NULL;
    return cached_remote_sources[index];
}

// Cached remote modules for count/name/desc/type/lang iteration
static const struct org_crosswire_sword_ModInfo *cached_remote_mods = NULL;
static int cached_remote_mod_count = -1;

static void ensure_remote_mods_cached(void *installMgr, const char *sourceName) {
    cached_remote_mods = org_crosswire_sword_InstallMgr_getRemoteModInfoList(
        (SWHANDLE)(uintptr_t)installMgr, 0, sourceName);
    cached_remote_mod_count = count_mod_info(cached_remote_mods);
}

int InstallMgr_getRemoteModuleCount(void *installMgr, const char *sourceName) {
    if (!installMgr) return 0;
    ensure_remote_mods_cached(installMgr, sourceName);
    return cached_remote_mod_count;
}

const char *InstallMgr_getRemoteModuleName(void *installMgr,
                                            const char *sourceName, int index) {
    if (!cached_remote_mods || index < 0 || index >= cached_remote_mod_count) return NULL;
    return cached_remote_mods[index].name;
}

const char *InstallMgr_getRemoteModuleDescription(void *installMgr,
                                                    const char *sourceName,
                                                    int index) {
    if (!cached_remote_mods || index < 0 || index >= cached_remote_mod_count) return NULL;
    return cached_remote_mods[index].description;
}

const char *InstallMgr_getRemoteModuleType(void *installMgr,
                                            const char *sourceName, int index) {
    if (!cached_remote_mods || index < 0 || index >= cached_remote_mod_count) return NULL;
    return cached_remote_mods[index].category;
}

const char *InstallMgr_getRemoteModuleLanguage(void *installMgr,
                                                const char *sourceName,
                                                int index) {
    if (!cached_remote_mods || index < 0 || index >= cached_remote_mod_count) return NULL;
    return cached_remote_mods[index].language;
}

// --- SWConfig ---
// Real SWORD API is path-based (no handle). We store the path as our "handle".

typedef struct {
    char path[1024];
} ConfigHandle;

void *SWConfig_new(const char *filename) {
    if (!filename) return NULL;
    ConfigHandle *h = (ConfigHandle *)malloc(sizeof(ConfigHandle));
    if (!h) return NULL;
    strncpy(h->path, filename, sizeof(h->path) - 1);
    h->path[sizeof(h->path) - 1] = '\0';
    return h;
}

void SWConfig_delete(void *config) {
    free(config);
}

const char *SWConfig_getValue(void *config, const char *section,
                               const char *key) {
    if (!config) return NULL;
    ConfigHandle *h = (ConfigHandle *)config;
    return org_crosswire_sword_SWConfig_getKeyValue(h->path, section, key);
}

void SWConfig_setValue(void *config, const char *section, const char *key,
                        const char *value) {
    if (!config) return;
    ConfigHandle *h = (ConfigHandle *)config;
    org_crosswire_sword_SWConfig_setKeyValue(h->path, section, key, value);
}

void SWConfig_save(void *config) {
    // Real SWConfig_setKeyValue saves immediately, so this is a no-op
}

#else // !USE_REAL_SWORD

// ============================================================
// STUB IMPLEMENTATION (development without libsword)
// ============================================================

static const char *empty_string = "";

void *SWMgr_new(const char *path) {
    static int sentinel = 1;
    return (void *)&sentinel;
}
void SWMgr_delete(void *mgr) { }
int SWMgr_getModuleCount(void *mgr) { return 0; }
const char *SWMgr_getModuleNameByIndex(void *mgr, int index) { return NULL; }
void *SWMgr_getModuleByName(void *mgr, const char *name) { return NULL; }
void SWMgr_setGlobalOption(void *mgr, const char *option, const char *value) { }
const char *SWMgr_getGlobalOption(void *mgr, const char *option) { return empty_string; }
const char *SWMgr_getConfigPath(void *mgr) { return empty_string; }
const char *SWMgr_getPrefixPath(void *mgr) { return empty_string; }
void SWMgr_setCipherKey(void *mgr, const char *moduleName, const char *key) { }
void SWMgr_setJavascript(void *mgr, int enabled) { }

const char *SWModule_getName(void *module) { return empty_string; }
const char *SWModule_getDescription(void *module) { return empty_string; }
const char *SWModule_getType(void *module) { return "Unknown"; }
const char *SWModule_getLanguage(void *module) { return "en"; }
void SWModule_setKeyText(void *module, const char *keyText) { }
const char *SWModule_getKeyText(void *module) { return empty_string; }
const char **SWModule_getEntryAttribute(void *module,
                                        const char *level1,
                                        const char *level2,
                                        const char *level3,
                                        char filteredBool) { return NULL; }
const char **SWModule_parseKeyList(void *module, const char *keyText) { return NULL; }
const char *SWModule_getRenderText(void *module) { return empty_string; }
const char *SWModule_getRawEntry(void *module) { return empty_string; }
const char *SWModule_getRenderHeader(void *module) { return empty_string; }
const char *SWModule_getStripText(void *module) { return empty_string; }
int SWModule_next(void *module) { return -1; }
int SWModule_previous(void *module) { return -1; }
void SWModule_begin(void *module) { }
int SWModule_isEnd(void *module) { return 1; }
char SWModule_popError(void *module) { return 1; }
void *SWModule_search(void *module, const char *searchString,
                      int searchType, int flags, const char *scope,
                      void *progressCallback) { return NULL; }
int SWModule_searchResultCount(void *module) { return 0; }
const char *SWModule_getSearchResultKeyText(void *module, int index) { return empty_string; }
int SWModule_hasFeature(void *module, const char *feature) { return 0; }
const char *SWModule_getConfigEntry(void *module, const char *key) { return NULL; }
void SWModule_setCipherKey(void *module, const char *key) { }
const char **SWModule_getKeyChildren(void *module) { return NULL; }
long SWModule_getVerseKeyIndex(void *module) { return -1; }
int SWModule_setVerseKeyIndex(void *module, long index) { return 1; }
int SWVersification_mapVerse(const char *sourceVersification, const char *targetVersification,
                             const char *osisBookName, int chapter, int verse,
                             const char **targetOsisBookOut, int *targetChapterOut,
                             int *targetVerseOut) { return 1; }
int SWVersification_mapVerseToKJVA(const char *sourceVersification, const char *osisBookName,
                                   int chapter, int verse, const char **kjvaOsisBookOut,
                                   int *kjvaChapterOut, int *kjvaVerseOut) { return 1; }
int SWVersification_mapVerseFromKJVA(const char *targetVersification, const char *kjvaOsisBookName,
                                     int chapter, int verse, const char **targetOsisBookOut,
                                     int *targetChapterOut, int *targetVerseOut) { return 1; }
int SWVersification_getReferenceIndex(const char *versification, const char *osisBookName,
                                      int chapter, int verse, long *indexOut) { return 1; }
int SWVersification_getReferenceForIndex(const char *versification, long index,
                                         const char **osisBookOut, int *chapterOut,
                                         int *verseOut) { return 1; }
int SWVersification_decodeOrdinal(const char *versification, long ordinal,
                                  const char **osisBookOut, int *chapterOut,
                                  int *verseOut) { return 1; }
int SWVersification_hasSystem(const char *versification) { return 0; }
int SWVersification_isSystemDefined(const char *versification) { return 0; }

void *InstallMgr_new(const char *basePath) {
    static int sentinel = 2;
    return (void *)&sentinel;
}
void InstallMgr_delete(void *installMgr) { }
void InstallMgr_setUserDisclaimerConfirmed(void *installMgr) { }
int InstallMgr_refreshRemoteSource(void *installMgr, const char *sourceName) { return -1; }
int InstallMgr_getRemoteSourceCount(void *installMgr) { return 0; }
const char *InstallMgr_getRemoteSourceName(void *installMgr, int index) { return NULL; }
int InstallMgr_getRemoteModuleCount(void *installMgr, const char *sourceName) { return 0; }
const char *InstallMgr_getRemoteModuleName(void *installMgr,
                                            const char *sourceName, int index) { return NULL; }
const char *InstallMgr_getRemoteModuleDescription(void *installMgr,
                                                    const char *sourceName, int index) { return NULL; }
const char *InstallMgr_getRemoteModuleType(void *installMgr,
                                            const char *sourceName, int index) { return NULL; }
const char *InstallMgr_getRemoteModuleLanguage(void *installMgr,
                                                const char *sourceName, int index) { return NULL; }
void *SWConfig_new(const char *filename) {
    static int sentinel = 3;
    return (void *)&sentinel;
}
void SWConfig_delete(void *config) { }
const char *SWConfig_getValue(void *config, const char *section,
                               const char *key) { return NULL; }
void SWConfig_setValue(void *config, const char *section, const char *key,
                        const char *value) { }
void SWConfig_save(void *config) { }

#endif // USE_REAL_SWORD

// ============================================================
// GZIP DECOMPRESSION (always available, uses zlib)
// ============================================================

#include <zlib.h>

unsigned char *gzip_data(const unsigned char *input, unsigned long input_len,
                         unsigned long *output_len) {
    if (!input || input_len == 0 || !output_len) return NULL;

    z_stream stream;
    memset(&stream, 0, sizeof(stream));

    if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8,
                     Z_DEFAULT_STRATEGY) != Z_OK) {
        return NULL;
    }

    unsigned long bound = deflateBound(&stream, input_len);
    unsigned char *output = (unsigned char *)malloc(bound);
    if (!output) {
        deflateEnd(&stream);
        return NULL;
    }

    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_len;
    stream.next_out = output;
    stream.avail_out = (uInt)bound;

    int ret = deflate(&stream, Z_FINISH);
    if (ret != Z_STREAM_END) {
        free(output);
        deflateEnd(&stream);
        return NULL;
    }

    *output_len = stream.total_out;
    deflateEnd(&stream);
    return output;
}

unsigned char *gunzip_data(const unsigned char *input, unsigned long input_len,
                           unsigned long *output_len) {
    if (!input || input_len == 0 || !output_len) return NULL;

    z_stream stream;
    memset(&stream, 0, sizeof(stream));

    // windowBits = 15 + 16 enables gzip decoding (auto-detect gzip header)
    if (inflateInit2(&stream, 15 + 16) != Z_OK) return NULL;

    // Start with 4x estimated output buffer
    unsigned long buf_size = input_len * 4;
    if (buf_size < 16384) buf_size = 16384;
    unsigned char *output = (unsigned char *)malloc(buf_size);
    if (!output) { inflateEnd(&stream); return NULL; }

    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_len;

    int ret;
    do {
        if (stream.total_out >= buf_size) {
            buf_size *= 2;
            unsigned char *new_buf = (unsigned char *)realloc(output, buf_size);
            if (!new_buf) { free(output); inflateEnd(&stream); return NULL; }
            output = new_buf;
        }
        stream.next_out = output + stream.total_out;
        stream.avail_out = (uInt)(buf_size - stream.total_out);
        ret = inflate(&stream, Z_NO_FLUSH);
    } while (ret == Z_OK);

    if (ret != Z_STREAM_END) {
        free(output);
        inflateEnd(&stream);
        return NULL;
    }

    *output_len = stream.total_out;
    inflateEnd(&stream);
    return output;
}

unsigned char *inflate_raw_data(const unsigned char *input, unsigned long input_len,
                                unsigned long expected_len, unsigned long *output_len) {
    // Allocate output buffer — use expected size or 4x compressed as fallback
    unsigned long buf_size = expected_len > 0 ? expected_len : input_len * 4;
    unsigned char *output = (unsigned char *)malloc(buf_size);
    if (!output) return NULL;

    z_stream stream;
    memset(&stream, 0, sizeof(stream));

    // windowBits = -15 for raw deflate (no gzip/zlib header)
    if (inflateInit2(&stream, -15) != Z_OK) {
        free(output);
        return NULL;
    }

    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_len;
    stream.next_out = output;
    stream.avail_out = (uInt)buf_size;

    int ret = inflate(&stream, Z_FINISH);
    if (ret != Z_STREAM_END && ret != Z_OK) {
        inflateEnd(&stream);
        free(output);
        return NULL;
    }

    *output_len = stream.total_out;
    inflateEnd(&stream);
    return output;
}

typedef struct {
    z_stream stream;
    uLong crc;
    unsigned long long input_byte_count;
    unsigned long long output_byte_count;
    int finished;
} raw_deflater_context;

void *raw_deflater_create(void) {
    raw_deflater_context *context = calloc(1, sizeof(raw_deflater_context));
    if (!context) return NULL;
    context->crc = crc32(0L, Z_NULL, 0);
    if (deflateInit2(&context->stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8,
                     Z_DEFAULT_STRATEGY) != Z_OK) {
        free(context);
        return NULL;
    }
    return context;
}

int raw_deflater_process(void *opaque_context,
                         const unsigned char *input,
                         unsigned int input_len,
                         int finish,
                         unsigned char *output,
                         unsigned int output_capacity,
                         unsigned int *consumed,
                         unsigned int *produced) {
    if (!opaque_context || !output || output_capacity == 0 || !consumed || !produced) {
        return -1;
    }
    raw_deflater_context *context = (raw_deflater_context *)opaque_context;
    if (context->finished) return -2;
    context->stream.next_in = (Bytef *)input;
    context->stream.avail_in = input_len;
    context->stream.next_out = output;
    context->stream.avail_out = output_capacity;

    int result = deflate(&context->stream, finish ? Z_FINISH : Z_NO_FLUSH);
    *consumed = input_len - context->stream.avail_in;
    *produced = output_capacity - context->stream.avail_out;
    if (*consumed > 0 && input) {
        context->crc = crc32(context->crc, input, *consumed);
        context->input_byte_count += *consumed;
    }
    context->output_byte_count += *produced;
    if (result == Z_STREAM_END) {
        context->finished = 1;
        return 1;
    }
    return result == Z_OK || result == Z_BUF_ERROR ? 0 : -3;
}

int raw_deflater_metadata(void *opaque_context,
                          unsigned int *crc32_value,
                          unsigned long long *input_byte_count,
                          unsigned long long *output_byte_count) {
    if (!opaque_context || !crc32_value || !input_byte_count || !output_byte_count) {
        return -1;
    }
    raw_deflater_context *context = (raw_deflater_context *)opaque_context;
    if (!context->finished) return -2;
    *crc32_value = (unsigned int)context->crc;
    *input_byte_count = context->input_byte_count;
    *output_byte_count = context->output_byte_count;
    return 0;
}

void raw_deflater_destroy(void *opaque_context) {
    if (!opaque_context) return;
    raw_deflater_context *context = (raw_deflater_context *)opaque_context;
    deflateEnd(&context->stream);
    free(context);
}

typedef struct {
    z_stream stream;
    unsigned long long input_byte_count;
    unsigned long long output_byte_count;
    int finished;
} raw_inflater_context;

void *raw_inflater_create(void) {
    raw_inflater_context *context = calloc(1, sizeof(raw_inflater_context));
    if (!context) return NULL;
    if (inflateInit2(&context->stream, -15) != Z_OK) {
        free(context);
        return NULL;
    }
    return context;
}

int raw_inflater_process(void *opaque_context,
                         const unsigned char *input,
                         unsigned int input_len,
                         unsigned char *output,
                         unsigned int output_capacity,
                         unsigned int *consumed,
                         unsigned int *produced) {
    if (!opaque_context || !output || output_capacity == 0 || !consumed || !produced) {
        return -1;
    }
    raw_inflater_context *context = (raw_inflater_context *)opaque_context;
    if (context->finished) return -2;
    context->stream.next_in = (Bytef *)input;
    context->stream.avail_in = input_len;
    context->stream.next_out = output;
    context->stream.avail_out = output_capacity;

    int result = inflate(&context->stream, Z_NO_FLUSH);
    *consumed = input_len - context->stream.avail_in;
    *produced = output_capacity - context->stream.avail_out;
    context->input_byte_count += *consumed;
    context->output_byte_count += *produced;
    if (result == Z_STREAM_END) {
        context->finished = 1;
        return 1;
    }
    return result == Z_OK || result == Z_BUF_ERROR ? 0 : -3;
}

int raw_inflater_metadata(void *opaque_context,
                          unsigned long long *input_byte_count,
                          unsigned long long *output_byte_count) {
    if (!opaque_context || !input_byte_count || !output_byte_count) return -1;
    raw_inflater_context *context = (raw_inflater_context *)opaque_context;
    if (!context->finished) return -2;
    *input_byte_count = context->input_byte_count;
    *output_byte_count = context->output_byte_count;
    return 0;
}

void raw_inflater_destroy(void *opaque_context) {
    if (!opaque_context) return;
    raw_inflater_context *context = (raw_inflater_context *)opaque_context;
    inflateEnd(&context->stream);
    free(context);
}

int inflate_raw_file_range_to_file(const char *input_path,
                                   unsigned long input_offset,
                                   unsigned long input_len,
                                   unsigned long output_limit,
                                   const char *output_path) {
    if (!input_path || !output_path) return -1;

    FILE *input = fopen(input_path, "rb");
    if (!input) return -2;

    FILE *output = fopen(output_path, "wb");
    if (!output) {
        fclose(input);
        return -3;
    }

    if (fseeko(input, (off_t)input_offset, SEEK_SET) != 0) {
        fclose(output);
        fclose(input);
        return -4;
    }

    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (inflateInit2(&stream, -15) != Z_OK) {
        fclose(output);
        fclose(input);
        return -5;
    }

    unsigned char input_buffer[65536];
    unsigned char output_buffer[65536];
    unsigned long remaining = input_len;
    unsigned long total_written = 0;
    int ret = Z_OK;
    int result = 0;

    while (remaining > 0 && ret != Z_STREAM_END) {
        size_t next_read = remaining < sizeof(input_buffer)
            ? (size_t)remaining
            : sizeof(input_buffer);
        size_t bytes_read = fread(input_buffer, 1, next_read, input);
        if (bytes_read != next_read) {
            result = -6;
            break;
        }
        remaining -= (unsigned long)bytes_read;

        stream.next_in = input_buffer;
        stream.avail_in = (uInt)bytes_read;

        do {
            stream.next_out = output_buffer;
            stream.avail_out = (uInt)sizeof(output_buffer);

            ret = inflate(&stream, Z_NO_FLUSH);
            if (ret != Z_OK && ret != Z_STREAM_END) {
                result = -7;
                break;
            }

            size_t produced = sizeof(output_buffer) - stream.avail_out;
            if (total_written > output_limit
                    || (unsigned long)produced > output_limit - total_written) {
                result = -11;
                break;
            }
            if (produced > 0 && fwrite(output_buffer, 1, produced, output) != produced) {
                result = -8;
                break;
            }
            total_written += (unsigned long)produced;
        } while (stream.avail_in > 0 && ret != Z_STREAM_END);

        if (result != 0) break;
    }

    if (result == 0 && (ret != Z_STREAM_END || remaining != 0 || stream.avail_in != 0)) {
        result = -9;
    }

    inflateEnd(&stream);
    if (fclose(output) != 0 && result == 0) {
        result = -10;
    }
    fclose(input);
    return result;
}

void gunzip_free(unsigned char *buffer) {
    free(buffer);
}
