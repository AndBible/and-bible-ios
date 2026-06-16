#include "include/flatapi.h"

#ifdef USE_REAL_SWORD

#include <swmodule.h>
#include <versekey.h>

namespace {

struct FlatAPIHandleSWModule {
    // Mirrors the first field of SWORD flatapi's HandleSWModule wrapper.
    sword::SWModule *mod;
};

sword::VerseKey *verseKeyForModule(void *moduleHandle) {
    if (!moduleHandle) {
        return nullptr;
    }

    auto *handle = reinterpret_cast<FlatAPIHandleSWModule *>(moduleHandle);
    auto *swordModule = handle->mod;
    if (!swordModule) {
        return nullptr;
    }

    auto *key = swordModule->getKey();
    return SWDYNAMIC_CAST(sword::VerseKey, key);
}

}

extern "C" long SWModule_getVerseKeyIndex(void *module) {
    auto *verseKey = verseKeyForModule(module);
    if (!verseKey) {
        return -1;
    }
    return verseKey->getIndex();
}

extern "C" int SWModule_setVerseKeyIndex(void *module, long index) {
    auto *verseKey = verseKeyForModule(module);
    if (!verseKey) {
        return 1;
    }

    verseKey->setIndex(index);
    return verseKey->getError();
}

#endif
