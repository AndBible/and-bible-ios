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

/// Set the cipher key for a named encrypted module through its owning manager.
void SWMgr_setCipherKey(void *mgr, const char *moduleName, const char *key);

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

/// Clone the complete current native key, including unpositioned and subclass-specific state.
/// The returned token must be consumed exactly once by SWModule_restoreClonedKey.
void *SWModule_cloneCurrentKey(void *module);

/// Restore and destroy a token returned by SWModule_cloneCurrentKey.
/// Returns 0 only when native key text and index match the clone.
int SWModule_restoreClonedKey(void *module, void *clonedKey);

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

/// Get the current entry after native option and encoding filters without source-format conversion.
/// Swift's JSword-compatible ThML filter consumes this exact decoded source representation.
/// The returned pointer is thread-local and remains valid until the next call on that thread.
const char *SWModule_getFilteredSourceFragment(void *module);

/// Get the current VerseKey as a canonical OSIS reference, or an empty string for other key types.
/// The returned pointer is thread-local and remains valid until the next call on that thread.
const char *SWModule_getCurrentOSISRef(void *module);

/// Resolve one human-readable passage against the current VerseKey and return its OSIS reference.
/// Invalid references and non-VerseKey modules return an empty string. The returned pointer is
/// thread-local and remains valid until the next call on that thread.
const char *SWModule_resolveOSISReference(void *module, const char *reference);

/// Convert the current non-ThML entry from its declared source format to canonical OSIS XML.
/// ThML deliberately returns an empty string so callers cannot reintroduce libsword's malformed
/// `ThMLOSIS` path instead of the shared JSword-compatible Swift filter. The returned pointer is
/// thread-local and remains valid until the next call on that thread.
const char *SWModule_getNativeSourceOSISFragment(void *module);

/// Read one physical RawLD-family index record through its source-family filter boundary.
/// RawLD/RawLD4 callers provide fixed-record bytes; zLD reads/decompresses by index. Non-ThML
/// source is canonical OSIS; ThML is decoded/option-filtered source for Swift's JSword converter.
/// The returned pointer is thread-local.
const char *SWModule_getRawDictionarySourceFragmentAtIndex(void *module,
                                                          long index,
                                                          const unsigned char *rawRecord,
                                                          unsigned long rawRecordLength);

/// Get the current key's Android-equivalent display name. TreeKey modules return the local node
/// name while other modules return the key's short text. The pointer is thread-local.
const char *SWModule_getCurrentKeyName(void *module);

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

/// Get key children for VerseKey and tree-key modules.
/// VerseKey modules return a NULL-terminated array of copied strings:
/// [testament, book, chapter, verse, chapterMax, verseMax, bookName, osisRef, shortText, bookAbbreviation, osisBookName].
/// Module and testament intro positions keep numeric fields but leave text fields empty.
const char **SWModule_getKeyChildren(void *module);

/// Get the current VerseKey intro-inclusive index, or -1 when the module key is not a VerseKey.
long SWModule_getVerseKeyIndex(void *module);

/// Set the current VerseKey intro-inclusive index. Returns 0 on success and nonzero on failure.
int SWModule_setVerseKeyIndex(void *module, long index);

/// Map an OSIS book/chapter/verse between versifications using SWORD's VersificationMgr (the same
/// av11n family used by JSword). Writes the target OSIS book id, chapter, and verse
/// to the out parameters. The returned book string is owned by the callee and remains valid until
/// the next call on the same thread. Empty source and target versification names are treated as
/// KJV. An unknown source name follows SWORD module loading and falls back to KJV; an unknown
/// target is rejected. Returns 0 on success and nonzero when inputs or the target are invalid.
int SWVersification_mapVerse(const char *sourceVersification,
                             const char *targetVersification,
                             const char *osisBookName,
                             int chapter,
                             int verse,
                             const char **targetOsisBookOut,
                             int *targetChapterOut,
                             int *targetVerseOut);

/// Convenience wrapper that maps an OSIS book/chapter/verse from a source versification into KJVA.
int SWVersification_mapVerseToKJVA(const char *sourceVersification,
                                   const char *osisBookName,
                                   int chapter,
                                   int verse,
                                   const char **kjvaOsisBookOut,
                                   int *kjvaChapterOut,
                                   int *kjvaVerseOut);

/// Convenience wrapper that maps an OSIS book/chapter/verse from KJVA into a target
/// versification. Unknown targets are rejected rather than relabeled as KJV.
int SWVersification_mapVerseFromKJVA(const char *targetVersification,
                                     const char *kjvaOsisBookName,
                                     int chapter,
                                     int verse,
                                     const char **targetOsisBookOut,
                                     int *targetChapterOut,
                                     int *targetVerseOut);

/// Resolve a valid verse reference to its intro-inclusive index in the named versification.
/// Verse 0 is accepted for chapter introductions. Empty versification names mean KJV; unknown
/// names and out-of-range references are rejected. Returns 0 on success and nonzero on failure.
int SWVersification_getReferenceIndex(const char *versification,
                                      const char *osisBookName,
                                      int chapter,
                                      int verse,
                                      long *indexOut);

/// Resolve an intro-inclusive index to a chapter or verse reference in the named versification.
/// Module, testament, and book heading indexes are rejected. The returned book string is owned by
/// the callee and remains valid until the next call on the same thread. Returns 0 on success and
/// nonzero on failure.
int SWVersification_getReferenceForIndex(const char *versification,
                                         long index,
                                         const char **osisBookOut,
                                         int *chapterOut,
                                         int *verseOut);

/// Compatibility alias for resolving a positive intro-inclusive ordinal. Unknown systems fail.
int SWVersification_decodeOrdinal(const char *versification,
                                  long ordinal,
                                  const char **osisBookOut,
                                  int *chapterOut,
                                  int *verseOut);

/// Return 1 when the named SWORD versification exists and 0 otherwise. Empty names mean KJV.
int SWVersification_hasSystem(const char *versification);

/// Compatibility alias for SWVersification_hasSystem.
int SWVersification_isSystemDefined(const char *versification);

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

/// Create a streaming raw-DEFLATE encoder for ZIP payloads. Returns NULL on allocation/init error.
void *raw_deflater_create(void);

/// Consume one raw input slice and produce at most output_capacity bytes. Pass finish=1 only after
/// the final input slice has been supplied. Returns 1 at stream end, 0 while more calls are needed,
/// and a negative value on invalid arguments or zlib failure.
int raw_deflater_process(void *context,
                         const unsigned char *input,
                         unsigned int input_len,
                         int finish,
                         unsigned char *output,
                         unsigned int output_capacity,
                         unsigned int *consumed,
                         unsigned int *produced);

/// Return finalized ZIP CRC32 and cumulative uncompressed/compressed byte counts.
int raw_deflater_metadata(void *context,
                          unsigned int *crc32_value,
                          unsigned long long *input_byte_count,
                          unsigned long long *output_byte_count);

/// Release a streaming raw-DEFLATE encoder.
void raw_deflater_destroy(void *context);

/// Create a streaming raw-DEFLATE decoder for cancellable ZIP extraction.
void *raw_inflater_create(void);

/// Consume one compressed slice and produce at most output_capacity bytes. Returns 1 at stream end,
/// 0 while more calls are needed, and a negative value on invalid arguments or zlib failure.
int raw_inflater_process(void *context,
                         const unsigned char *input,
                         unsigned int input_len,
                         unsigned char *output,
                         unsigned int output_capacity,
                         unsigned int *consumed,
                         unsigned int *produced);

/// Return finalized compressed and expanded byte counts after stream end.
int raw_inflater_metadata(void *context,
                          unsigned long long *input_byte_count,
                          unsigned long long *output_byte_count);

/// Release a streaming raw-DEFLATE decoder.
void raw_inflater_destroy(void *context);

/// Decompress raw deflate bytes from a file range into an output file without writing more than
/// output_limit bytes. Returns 0 on success and nonzero on I/O, zlib, or limit failure.
int inflate_raw_file_range_to_file(const char *input_path,
                                   unsigned long input_offset,
                                   unsigned long input_len,
                                   unsigned long output_limit,
                                   const char *output_path);

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
