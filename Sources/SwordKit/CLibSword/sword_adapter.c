// sword_adapter.c — Bridge between simplified API and real SWORD library
//
// When USE_REAL_SWORD is defined, implements our simplified flatapi.h functions
// by calling through to the real org_crosswire_sword_* functions from libsword.
// Otherwise, provides stub implementations for development without libsword.

#include "include/flatapi.h"
#include <stdlib.h>
#include <string.h>

#ifdef USE_REAL_SWORD

// ============================================================
// REAL SWORD IMPLEMENTATION
// ============================================================

#include "sword_real_api.h"

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

int InstallMgr_installModule(void *installMgr, void *mgr,
                              const char *sourceName, const char *moduleName) {
    if (!installMgr || !mgr) return -1;
    int result = org_crosswire_sword_InstallMgr_remoteInstallModule(
        (SWHANDLE)(uintptr_t)installMgr,
        (SWHANDLE)(uintptr_t)mgr,
        sourceName, moduleName);
    // Invalidate module list cache since a new module was installed
    cached_mod_count = -1;
    return result;
}

int InstallMgr_uninstallModule(void *installMgr, void *mgr,
                                const char *moduleName) {
    if (!installMgr || !mgr) return -1;
    int result = org_crosswire_sword_InstallMgr_uninstallModule(
        (SWHANDLE)(uintptr_t)installMgr,
        (SWHANDLE)(uintptr_t)mgr,
        moduleName);
    cached_mod_count = -1;
    return result;
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
int InstallMgr_installModule(void *installMgr, void *mgr,
                              const char *sourceName, const char *moduleName) { return -1; }
int InstallMgr_uninstallModule(void *installMgr, void *mgr,
                                const char *moduleName) { return -1; }

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

void gunzip_free(unsigned char *buffer) {
    free(buffer);
}
