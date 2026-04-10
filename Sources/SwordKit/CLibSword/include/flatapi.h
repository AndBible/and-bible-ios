// flatapi.h — SWORD library flat C API bindings
// From the CrossWire SWORD Project: https://crosswire.org/sword/
//
// This header declares the flat (non-OOP) C API for libsword, suitable for
// bridging into Swift via a C module map. The actual implementation lives in
// the pre-built libsword.xcframework.
//
// NOTE: This is a subset of the full flatapi.h from SWORD. Additional
// functions can be added as needed from the SWORD source.

#ifndef FLATAPI_H
#define FLATAPI_H

#ifdef __cplusplus
extern "C" {
#endif

// --- SWMgr (Module Manager) ---

/// Create a new SWMgr instance with the given config path.
/// Returns an opaque handle. Pass NULL for default path.
void *SWMgr_new(const char *path);

/// Destroy an SWMgr instance.
void SWMgr_delete(void *mgr);

/// Get the number of installed modules.
int SWMgr_getModuleCount(void *mgr);

/// Get module info at index. Returns module name.
const char *SWMgr_getModuleNameByIndex(void *mgr, int index);

/// Get a module handle by name. Returns NULL if not found.
void *SWMgr_getModuleByName(void *mgr, const char *name);

/// Set a global option (e.g., "Strong's Numbers", "Morphology").
void SWMgr_setGlobalOption(void *mgr, const char *option, const char *value);

/// Get a global option value.
const char *SWMgr_getGlobalOption(void *mgr, const char *option);

/// Get the config path used by the manager.
const char *SWMgr_getConfigPath(void *mgr);

/// Get the prefix path (module install root).
const char *SWMgr_getPrefixPath(void *mgr);

// --- SWModule (Bible Module) ---

/// Get the module name (abbreviation, e.g., "KJV").
const char *SWModule_getName(void *module);

/// Get the module description (e.g., "King James Version").
const char *SWModule_getDescription(void *module);

/// Get the module type (e.g., "Biblical Texts", "Commentaries").
const char *SWModule_getType(void *module);

/// Get the module language (e.g., "en").
const char *SWModule_getLanguage(void *module);

/// Set the current key/position (e.g., "Gen 1:1").
void SWModule_setKeyText(void *module, const char *keyText);

/// Get the current key text.
const char *SWModule_getKeyText(void *module);

/// Get parsed entry attributes for the current position.
/// Returns a NULL-terminated array of strings.
/// Use "-" to enumerate keys at a level, or NULL/empty to fetch all values.
const char **SWModule_getEntryAttribute(void *module,
                                        const char *level1,
                                        const char *level2,
                                        const char *level3,
                                        char filteredBool);

/// Parse a verse key list into concrete OSIS references.
/// Returns a NULL-terminated array of strings.
const char **SWModule_parseKeyList(void *module, const char *keyText);

/// Get rendered text at the current position (with markup applied).
const char *SWModule_getRenderText(void *module);

/// Get raw entry text at the current position (no markup).
const char *SWModule_getRawEntry(void *module);

/// Get rendered text as HTML header (for chapter/book intros).
const char *SWModule_getRenderHeader(void *module);

/// Get strip (plain) text at the current position.
const char *SWModule_getStripText(void *module);

/// Navigate to the next entry/verse. Returns 0 on success.
int SWModule_next(void *module);

/// Navigate to the previous entry/verse. Returns 0 on success.
int SWModule_previous(void *module);

/// Navigate to the beginning of the module.
void SWModule_begin(void *module);

/// Check if we're at the end of the module.
int SWModule_isEnd(void *module);

/// Search the module. Returns a list key handle with results.
/// searchType: 0=regex, 1=phrase, -1=multiword, -2=entryAttr, -3=lucene
/// flags: REG_ICASE=2 for case-insensitive
/// scope: key handle to limit search scope, or NULL for whole module
void *SWModule_search(void *module, const char *searchString,
                      int searchType, int flags, const char *scope,
                      void *progressCallback);

/// Get the number of results from the last search.
int SWModule_searchResultCount(void *module);

/// Get search result key text at index.
const char *SWModule_getSearchResultKeyText(void *module, int index);

/// Check if the module has a feature (e.g., "StrongsNumbers").
int SWModule_hasFeature(void *module, const char *feature);

/// Get a config entry value for the module.
const char *SWModule_getConfigEntry(void *module, const char *key);

/// Set the module's cipher key (for encrypted modules).
void SWModule_setCipherKey(void *module, const char *key);

/// Get key children for VerseKey modules.
/// Returns a NULL-terminated array of strings:
/// [testament, book, chapter, verse, chapterMax, verseMax, bookName, osisRef, ...]
const char **SWModule_getKeyChildren(void *module);

/// Pop the last error code. Returns 0 if no error.
char SWModule_popError(void *module);

// --- SWMgr (Additional) ---

/// Enable/disable JavaScript mode for word-level markup.
void SWMgr_setJavascript(void *mgr, int enabled);

// --- InstallMgr (Module Installation) ---

/// Create a new InstallMgr instance.
void *InstallMgr_new(const char *basePath);

/// Destroy an InstallMgr instance.
void InstallMgr_delete(void *installMgr);

/// Set user disclaimer accepted (required before remote operations).
void InstallMgr_setUserDisclaimerConfirmed(void *installMgr);

/// Refresh the remote source catalog. Returns 0 on success.
int InstallMgr_refreshRemoteSource(void *installMgr, const char *sourceName);

/// Get the number of remote sources configured.
int InstallMgr_getRemoteSourceCount(void *installMgr);

/// Get the name of a remote source by index.
const char *InstallMgr_getRemoteSourceName(void *installMgr, int index);

/// Get the number of modules available from a remote source.
int InstallMgr_getRemoteModuleCount(void *installMgr, const char *sourceName);

/// Get module name from a remote source at index.
const char *InstallMgr_getRemoteModuleName(void *installMgr,
                                            const char *sourceName, int index);

/// Get module description from a remote source at index.
const char *InstallMgr_getRemoteModuleDescription(void *installMgr,
                                                    const char *sourceName,
                                                    int index);

/// Get module type from a remote source at index.
const char *InstallMgr_getRemoteModuleType(void *installMgr,
                                            const char *sourceName, int index);

/// Get module language from a remote source at index.
const char *InstallMgr_getRemoteModuleLanguage(void *installMgr,
                                                const char *sourceName,
                                                int index);

/// Install a module from a remote source. Returns 0 on success.
int InstallMgr_installModule(void *installMgr, void *mgr,
                              const char *sourceName, const char *moduleName);

/// Uninstall a module. Returns 0 on success.
int InstallMgr_uninstallModule(void *installMgr, void *mgr,
                                const char *moduleName);

// --- Gzip Decompression (uses zlib, always available) ---

/// Compress data into gzip format. Caller must free result with gunzip_free().
/// Returns NULL on error. Sets *output_len to compressed size.
unsigned char *gzip_data(const unsigned char *input, unsigned long input_len,
                         unsigned long *output_len);

/// Decompress gzip data. Caller must free result with gunzip_free().
/// Returns NULL on error. Sets *output_len to decompressed size.
unsigned char *gunzip_data(const unsigned char *input, unsigned long input_len,
                           unsigned long *output_len);

/// Decompress raw deflate data (no header). Caller must free result with gunzip_free().
/// Returns NULL on error. Sets *output_len to decompressed size.
unsigned char *inflate_raw_data(const unsigned char *input, unsigned long input_len,
                                unsigned long expected_len, unsigned long *output_len);

/// Free buffer allocated by gunzip_data or inflate_raw_data.
void gunzip_free(unsigned char *buffer);

// --- SWConfig ---

/// Create a new SWConfig from a file path.
void *SWConfig_new(const char *filename);

/// Destroy an SWConfig instance.
void SWConfig_delete(void *config);

/// Get a config value by section and key.
const char *SWConfig_getValue(void *config, const char *section,
                               const char *key);

/// Set a config value by section and key.
void SWConfig_setValue(void *config, const char *section, const char *key,
                        const char *value);

/// Save config changes to disk.
void SWConfig_save(void *config);

#ifdef __cplusplus
}
#endif

#endif // FLATAPI_H
