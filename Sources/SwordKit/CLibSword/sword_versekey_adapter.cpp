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
thread_local std::string versificationReferenceBookStorage;

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

extern "C" int SWVersification_mapVerse(
    const char *sourceVersification,
    const char *targetVersification,
    const char *osisBookName,
    int chapter,
    int verse,
    const char **targetOsisBookOut,
    int *targetChapterOut,
    int *targetVerseOut) {
    if (!osisBookName || !targetOsisBookOut || !targetChapterOut || !targetVerseOut ||
        chapter <= 0 || verse < 0) {
        return 1;
    }

    sword::VersificationMgr *versificationMgr = sword::VersificationMgr::getSystemVersificationMgr();
    if (!versificationMgr) {
        return 1;
    }

    // An absent versification defaults to KJV on both platforms. A present-but-unrecognized name
    // must fail: Android rejects that module, and relabeling its coordinates as KJV would create a
    // valid-looking reference in the wrong canon.
    const char *sourceName =
        (sourceVersification && *sourceVersification) ? sourceVersification : "KJV";
    const sword::VersificationMgr::System *sourceSystem =
        versificationMgr->getVersificationSystem(sourceName);
    const char *targetName =
        (targetVersification && *targetVersification) ? targetVersification : "KJV";
    const sword::VersificationMgr::System *targetSystem =
        versificationMgr->getVersificationSystem(targetName);
    if (!sourceSystem || !targetSystem) {
        return 1;
    }

    // translateVerse mutates book/chapter/verse in place using SWORD's compiled av11n tables. The
    // book string is copied into separate thread-local storage so the returned pointer stays valid
    // after this call and cannot alias the input buffer.
    thread_local std::string inputBookStorage;
    thread_local std::string mappedBookStorage;
    inputBookStorage = osisBookName;
    const char *book = inputBookStorage.c_str();
    int mappedChapter = chapter;
    int mappedVerse = verse;
    int mappedVerseEnd = verse;
    sourceSystem->translateVerse(targetSystem, &book, &mappedChapter, &mappedVerse, &mappedVerseEnd);
    if (!book) {
        return 1;
    }

    mappedBookStorage = book;
    *targetOsisBookOut = mappedBookStorage.c_str();
    *targetChapterOut = mappedChapter;
    *targetVerseOut = mappedVerse;
    return 0;
}

extern "C" int SWVersification_mapVerseToKJVA(
    const char *sourceVersification,
    const char *osisBookName,
    int chapter,
    int verse,
    const char **kjvaOsisBookOut,
    int *kjvaChapterOut,
    int *kjvaVerseOut) {
    return SWVersification_mapVerse(
        sourceVersification,
        "KJVA",
        osisBookName,
        chapter,
        verse,
        kjvaOsisBookOut,
        kjvaChapterOut,
        kjvaVerseOut);
}

extern "C" int SWVersification_mapVerseFromKJVA(
    const char *targetVersification,
    const char *kjvaOsisBookName,
    int chapter,
    int verse,
    const char **targetOsisBookOut,
    int *targetChapterOut,
    int *targetVerseOut) {
    return SWVersification_mapVerse(
        "KJVA",
        targetVersification,
        kjvaOsisBookName,
        chapter,
        verse,
        targetOsisBookOut,
        targetChapterOut,
        targetVerseOut);
}

extern "C" int SWVersification_getReferenceIndex(
    const char *versification,
    const char *osisBookName,
    int chapter,
    int verse,
    long *indexOut) {
    if (!osisBookName || !*osisBookName || !indexOut || chapter <= 0 || verse < 0) {
        return 1;
    }

    sword::VersificationMgr *versificationMgr = sword::VersificationMgr::getSystemVersificationMgr();
    if (!versificationMgr) {
        return 1;
    }
    const char *name = (versification && *versification) ? versification : "KJV";
    const sword::VersificationMgr::System *system =
        versificationMgr->getVersificationSystem(name);
    if (!system) {
        return 1;
    }

    const int oneBasedBook = system->getBookNumberByOSISName(osisBookName);
    if (oneBasedBook <= 0) {
        return 1;
    }
    const sword::VersificationMgr::Book *book = system->getBook(oneBasedBook - 1);
    if (!book || chapter > book->getChapterMax() ||
        verse > book->getVerseMax(chapter)) {
        return 1;
    }

    const long index = system->getOffsetFromVerse(oneBasedBook - 1, chapter, verse);
    if (index < 0) {
        return 1;
    }
    *indexOut = index;
    return 0;
}

extern "C" int SWVersification_getReferenceForIndex(
    const char *versification,
    long index,
    const char **osisBookOut,
    int *chapterOut,
    int *verseOut) {
    if (!osisBookOut || !chapterOut || !verseOut || index < 0) {
        return 1;
    }

    sword::VersificationMgr *versificationMgr = sword::VersificationMgr::getSystemVersificationMgr();
    if (!versificationMgr) {
        return 1;
    }
    const char *name = (versification && *versification) ? versification : "KJV";
    const sword::VersificationMgr::System *system =
        versificationMgr->getVersificationSystem(name);
    if (!system) {
        return 1;
    }

    int oneBasedBook = 0;
    int chapter = 0;
    int verse = 0;
    if (system->getVerseFromOffset(index, &oneBasedBook, &chapter, &verse) != 0 ||
        oneBasedBook <= 0 || chapter <= 0 || verse < 0) {
        return 1;
    }
    const sword::VersificationMgr::Book *book = system->getBook(oneBasedBook - 1);
    if (!book || chapter > book->getChapterMax() || verse > book->getVerseMax(chapter)) {
        return 1;
    }

    versificationReferenceBookStorage = book->getOSISName();
    *osisBookOut = versificationReferenceBookStorage.c_str();
    *chapterOut = chapter;
    *verseOut = verse;
    return 0;
}

extern "C" int SWVersification_hasSystem(const char *versification) {
    sword::VersificationMgr *versificationMgr = sword::VersificationMgr::getSystemVersificationMgr();
    if (!versificationMgr) {
        return 0;
    }
    const char *name = (versification && *versification) ? versification : "KJV";
    return versificationMgr->getVersificationSystem(name) ? 1 : 0;
}

extern "C" int SWVersification_decodeOrdinal(
    const char *versification,
    long ordinal,
    const char **osisBookOut,
    int *chapterOut,
    int *verseOut) {
    if (ordinal <= 0) {
        return 1;
    }
    return SWVersification_getReferenceForIndex(
        versification,
        ordinal,
        osisBookOut,
        chapterOut,
        verseOut);
}

extern "C" int SWVersification_isSystemDefined(const char *versification) {
    return SWVersification_hasSystem(versification);
}

#endif
