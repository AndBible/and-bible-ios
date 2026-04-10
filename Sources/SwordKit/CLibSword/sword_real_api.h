// sword_real_api.h — Declarations for real SWORD flatapi functions
//
// This header declares the org_crosswire_sword_* functions from the real
// libsword library, without importing the full SWORD headers (which use
// C++ macros, SWDLLEXPORT, and defs.h that cause issues with Swift module maps).
//
// These declarations are used only by sword_adapter.c to call the real library.

#ifndef SWORD_REAL_API_H
#define SWORD_REAL_API_H

#include <inttypes.h>

#define SWHANDLE intptr_t

// Module info struct returned by getModInfoList
struct org_crosswire_sword_ModInfo {
    char *name;
    char *description;
    char *category;
    char *language;
    char *version;
    char *delta;
    char *cipherKey;
    const char **features;
};

// Search hit struct returned by search
struct org_crosswire_sword_SearchHit {
    const char *modName;
    char *key;
    long score;
};

// Search callback type
typedef void (*org_crosswire_sword_SWModule_SearchCallback)(int);

// --- SWMgr ---

SWHANDLE org_crosswire_sword_SWMgr_new(void);
SWHANDLE org_crosswire_sword_SWMgr_newWithPath(const char *path);
void org_crosswire_sword_SWMgr_delete(SWHANDLE hSWMgr);
const struct org_crosswire_sword_ModInfo *
    org_crosswire_sword_SWMgr_getModInfoList(SWHANDLE hSWMgr);
SWHANDLE org_crosswire_sword_SWMgr_getModuleByName(
    SWHANDLE hSWMgr, const char *moduleName);
void org_crosswire_sword_SWMgr_setGlobalOption(
    SWHANDLE hSWMgr, const char *option, const char *value);
const char *org_crosswire_sword_SWMgr_getGlobalOption(
    SWHANDLE hSWMgr, const char *option);
const char *org_crosswire_sword_SWMgr_getConfigPath(SWHANDLE hSWMgr);
const char *org_crosswire_sword_SWMgr_getPrefixPath(SWHANDLE hSWMgr);
void org_crosswire_sword_SWMgr_setCipherKey(
    SWHANDLE hSWMgr, const char *modName, const char *key);
void org_crosswire_sword_SWMgr_setJavascript(
    SWHANDLE hSWMgr, char valueBool);

// --- SWModule ---

const char *org_crosswire_sword_SWModule_getName(SWHANDLE hSWModule);
const char *org_crosswire_sword_SWModule_getDescription(SWHANDLE hSWModule);
const char *org_crosswire_sword_SWModule_getCategory(SWHANDLE hSWModule);
void org_crosswire_sword_SWModule_setKeyText(
    SWHANDLE hSWModule, const char *key);
const char *org_crosswire_sword_SWModule_getKeyText(SWHANDLE hSWModule);
const char **org_crosswire_sword_SWModule_getEntryAttribute(
    SWHANDLE hSWModule, const char *level1, const char *level2, const char *level3,
    char filteredBool);
const char **org_crosswire_sword_SWModule_parseKeyList(
    SWHANDLE hSWModule, const char *keyText);
const char *org_crosswire_sword_SWModule_renderText(SWHANDLE hSWModule);
const char *org_crosswire_sword_SWModule_getRawEntry(SWHANDLE hSWModule);
const char *org_crosswire_sword_SWModule_getRenderHeader(SWHANDLE hSWModule);
const char *org_crosswire_sword_SWModule_stripText(SWHANDLE hSWModule);
void org_crosswire_sword_SWModule_next(SWHANDLE hSWModule);
void org_crosswire_sword_SWModule_previous(SWHANDLE hSWModule);
void org_crosswire_sword_SWModule_begin(SWHANDLE hSWModule);
char org_crosswire_sword_SWModule_popError(SWHANDLE hSWModule);
const char *org_crosswire_sword_SWModule_getConfigEntry(
    SWHANDLE hSWModule, const char *key);
const char **org_crosswire_sword_SWModule_getKeyChildren(SWHANDLE hSWModule);
const struct org_crosswire_sword_SearchHit *
    org_crosswire_sword_SWModule_search(
        SWHANDLE hSWModule, const char *searchString,
        int searchType, long flags, const char *scope,
        org_crosswire_sword_SWModule_SearchCallback progressReporter);
void org_crosswire_sword_SWModule_terminateSearch(SWHANDLE hSWModule);

// --- SWConfig (path-based, no handle) ---

const char *org_crosswire_sword_SWConfig_getKeyValue(
    const char *confPath, const char *section, const char *key);
void org_crosswire_sword_SWConfig_setKeyValue(
    const char *confPath, const char *section,
    const char *key, const char *value);

// --- InstallMgr ---

SWHANDLE org_crosswire_sword_InstallMgr_new(
    const char *baseDir, void *statusReporter);
void org_crosswire_sword_InstallMgr_delete(SWHANDLE hInstallMgr);
void org_crosswire_sword_InstallMgr_setUserDisclaimerConfirmed(
    SWHANDLE hInstallMgr);
const char **org_crosswire_sword_InstallMgr_getRemoteSources(
    SWHANDLE hInstallMgr);
int org_crosswire_sword_InstallMgr_refreshRemoteSource(
    SWHANDLE hInstallMgr, const char *sourceName);
const struct org_crosswire_sword_ModInfo *
    org_crosswire_sword_InstallMgr_getRemoteModInfoList(
        SWHANDLE hInstallMgr, SWHANDLE hSWMgr_deltaCompareTo,
        const char *sourceName);
int org_crosswire_sword_InstallMgr_remoteInstallModule(
    SWHANDLE hInstallMgr_from, SWHANDLE hSWMgr_to,
    const char *sourceName, const char *modName);
int org_crosswire_sword_InstallMgr_uninstallModule(
    SWHANDLE hInstallMgr, SWHANDLE hSWMgr_removeFrom, const char *modName);

#endif // SWORD_REAL_API_H
