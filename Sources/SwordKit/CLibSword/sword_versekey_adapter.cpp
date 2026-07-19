#include "include/flatapi.h"

#ifdef USE_REAL_SWORD

#include <array>
#include <string>

#include <swmodule.h>
#include <versekey.h>
#include <versificationmgr.h>

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

extern "C" int SWVersification_mapVerseToKJVA(
    const char *sourceVersification,
    const char *osisBookName,
    int chapter,
    int verse,
    const char **kjvaOsisBookOut,
    int *kjvaChapterOut,
    int *kjvaVerseOut) {
    if (!osisBookName || !kjvaOsisBookOut || !kjvaChapterOut || !kjvaVerseOut) {
        return 1;
    }

    sword::VersificationMgr *versificationMgr = sword::VersificationMgr::getSystemVersificationMgr();
    if (!versificationMgr) {
        return 1;
    }

    // SWORD and Android treat an empty versification name as the KJV default. A present-but-
    // unrecognized name is NOT defaulted: it returns failure, matching Android — which rejects an
    // unsupported module versification during metadata load — and the flatapi.h contract.
    const char *sourceName =
        (sourceVersification && *sourceVersification) ? sourceVersification : "KJV";
    const sword::VersificationMgr::System *sourceSystem =
        versificationMgr->getVersificationSystem(sourceName);
    const sword::VersificationMgr::System *kjvaSystem =
        versificationMgr->getVersificationSystem("KJVA");
    if (!sourceSystem || !kjvaSystem) {
        return 1;
    }

    // translateVerse mutates book/chapter/verse in place, mapping the source-versification
    // reference onto its KJVA counterpart using SWORD's av11n mapping tables (the same data
    // JSword uses on Android). The book string is copied into a separate thread-local so the
    // returned pointer stays valid after this call and cannot alias the input buffer.
    thread_local std::string inputBookStorage;
    thread_local std::string mappedBookStorage;
    inputBookStorage = osisBookName;
    const char *book = inputBookStorage.c_str();
    int mappedChapter = chapter;
    int mappedVerse = verse;
    int mappedVerseEnd = verse;
    sourceSystem->translateVerse(kjvaSystem, &book, &mappedChapter, &mappedVerse, &mappedVerseEnd);
    if (!book) {
        return 1;
    }

    mappedBookStorage = book;
    *kjvaOsisBookOut = mappedBookStorage.c_str();
    *kjvaChapterOut = mappedChapter;
    *kjvaVerseOut = mappedVerse;
    return 0;
}

extern "C" int SWVersification_mapVerseFromKJVA(
    const char *targetVersification,
    const char *kjvaOsisBookName,
    int chapter,
    int verse,
    const char **targetOsisBookOut,
    int *targetChapterOut,
    int *targetVerseOut) {
    if (!kjvaOsisBookName || !targetOsisBookOut || !targetChapterOut || !targetVerseOut) {
        return 1;
    }

    sword::VersificationMgr *versificationMgr = sword::VersificationMgr::getSystemVersificationMgr();
    if (!versificationMgr) {
        return 1;
    }

    // Reverse of SWVersification_mapVerseToKJVA: an empty target name defaults to KJV; a present-
    // but-unrecognized name returns failure (matching the forward direction and Android).
    const char *targetName =
        (targetVersification && *targetVersification) ? targetVersification : "KJV";
    const sword::VersificationMgr::System *kjvaSystem =
        versificationMgr->getVersificationSystem("KJVA");
    const sword::VersificationMgr::System *targetSystem =
        versificationMgr->getVersificationSystem(targetName);
    if (!kjvaSystem || !targetSystem) {
        return 1;
    }

    // translateVerse is directional: calling it on the KJVA system with the target as destination
    // maps a KJVA reference back onto the target versification (e.g. KJVA Ps 11:1 -> Vulg Ps 10:1).
    thread_local std::string inputBookStorage;
    thread_local std::string mappedBookStorage;
    inputBookStorage = kjvaOsisBookName;
    const char *book = inputBookStorage.c_str();
    int mappedChapter = chapter;
    int mappedVerse = verse;
    int mappedVerseEnd = verse;
    kjvaSystem->translateVerse(targetSystem, &book, &mappedChapter, &mappedVerse, &mappedVerseEnd);
    if (!book) {
        return 1;
    }

    mappedBookStorage = book;
    *targetOsisBookOut = mappedBookStorage.c_str();
    *targetChapterOut = mappedChapter;
    *targetVerseOut = mappedVerse;
    return 0;
}

extern "C" int SWVersification_decodeOrdinal(
    const char *versification,
    long ordinal,
    const char **osisBookOut,
    int *chapterOut,
    int *verseOut) {
    if (!osisBookOut || !chapterOut || !verseOut || ordinal <= 0) {
        return 1;
    }

    // An empty name defaults to KJV; a present-but-unrecognized name returns failure.
    const char *name = (versification && *versification) ? versification : "KJV";
    sword::VersificationMgr *versificationMgr = sword::VersificationMgr::getSystemVersificationMgr();
    if (!versificationMgr || !versificationMgr->getVersificationSystem(name)) {
        return 1;
    }

    // Decode the intro-inclusive VerseKey index within `name`'s versification without an installed
    // module — the same scheme SWModule_setVerseKeyIndex uses, but standalone — so a restored
    // bookmark's original source ordinal resolves from versification metadata alone (as Android's
    // Verse(v11n, ordinal) does).
    sword::VerseKey key;
    key.setVersificationSystem(name);
    key.setIndex(ordinal);
    if (key.getError() || key.getChapter() <= 0 || key.getVerse() <= 0 || key.getIndex() != ordinal) {
        return 1;
    }

    thread_local std::string bookStorage;
    bookStorage = safeCString(key.getOSISBookName());
    if (bookStorage.empty()) {
        return 1;
    }

    *osisBookOut = bookStorage.c_str();
    *chapterOut = key.getChapter();
    *verseOut = key.getVerse();
    return 0;
}

#endif
