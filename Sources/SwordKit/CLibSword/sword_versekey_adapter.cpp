#include "include/flatapi.h"

#ifdef USE_REAL_SWORD

#include <array>
#include <string>

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

struct VerseKeyChildrenStorage {
    std::array<std::string, 11> values;
    std::array<const char *, 12> pointers;
};

const char *safeCString(const char *value) {
    return value ? value : "";
}

thread_local VerseKeyChildrenStorage verseKeyChildrenStorage;

}

extern "C" const char **SWModule_getVerseKeyChildrenDirect(void *module) {
    auto *verseKey = verseKeyForModule(module);
    if (!verseKey || verseKey->getError()) {
        return nullptr;
    }

    int testament = verseKey->getTestament();
    int book = verseKey->getBook();
    int chapter = verseKey->getChapter();
    int verse = verseKey->getVerse();
    bool hasBook = testament > 0 && book > 0;
    bool hasChapter = hasBook && chapter > 0;

    auto &storage = verseKeyChildrenStorage;
    storage.values[0] = std::to_string(testament);
    storage.values[1] = std::to_string(book);
    storage.values[2] = std::to_string(chapter);
    storage.values[3] = std::to_string(verse);
    storage.values[4] = hasBook ? std::to_string(verseKey->getChapterMax()) : "0";
    storage.values[5] = hasChapter ? std::to_string(verseKey->getVerseMax()) : "0";
    storage.values[6] = hasBook ? safeCString(verseKey->getBookName()) : "";
    storage.values[7] = hasBook ? safeCString(verseKey->getOSISRef()) : "";
    storage.values[8] = hasBook ? safeCString(verseKey->getShortText()) : "";
    storage.values[9] = hasBook ? safeCString(verseKey->getBookAbbrev()) : "";
    storage.values[10] = hasBook ? safeCString(verseKey->getOSISBookName()) : "";

    for (std::size_t index = 0; index < storage.values.size(); ++index) {
        storage.pointers[index] = storage.values[index].c_str();
    }
    storage.pointers[storage.values.size()] = nullptr;
    return storage.pointers.data();
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
