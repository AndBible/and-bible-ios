#include "include/flatapi.h"

#ifdef USE_REAL_SWORD

#include <cstring>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include <listkey.h>
#include <rawld.h>
#include <rawld4.h>
#include <swbuf.h>
#include <swkey.h>
#include <swmodule.h>
#include <sysdata.h>
#include <treekey.h>
#include <versekey.h>
#include <versetreekey.h>
#include <zld.h>
#include <zverse.h>
#include <zverse4.h>

namespace {

struct FlatAPIHandleSWModule {
    // Mirrors the first field of SWORD flatapi's HandleSWModule wrapper.
    sword::SWModule *mod;
};

thread_local std::string decodedSourceStorage;
thread_local std::string currentKeyNameStorage;
thread_local std::string currentDecodedSourceStorage;
thread_local std::string currentOSISRefStorage;
thread_local std::string resolvedOSISRefStorage;

/**
 Reads one exact byte range without applying libsword display preprocessing.

 @param path Absolute source file path.
 @param offset Zero-based byte offset.
 @param size Exact byte count.
 @param buffer Output replaced with the requested bytes on success.
 @return True only when the file opens, seeks, and supplies the complete range.
 @sideeffect Performs one bounded filesystem read and mutates only `buffer`.
 @failure Returns false for every filesystem/short-read failure; never throws across the C boundary.
 */
bool readFileRegion(
    const std::string &path,
    unsigned long offset,
    unsigned long size,
    sword::SWBuf &buffer
) {
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        return false;
    }
    input.seekg(static_cast<std::streamoff>(offset));
    if (!input) {
        return false;
    }
    std::vector<char> bytes(size, '\0');
    input.read(bytes.data(), static_cast<std::streamsize>(size));
    if (input.gcount() != static_cast<std::streamsize>(size)) {
        return false;
    }
    buffer = sword::SWBuf(bytes.data(), size);
    return true;
}

/**
 Extracts one RawText/RawCom-family record from its fixed-width verse index.

 @param module Current native module supplying filters and absolute storage metadata.
 @param key Current exact VerseKey.
 @param sizeWidth Two for RawText/RawCom or four for their `4` variants.
 @param source Output receiving decrypted raw record bytes without `prepText`.
 @return True when the index and complete data record are readable, including an empty record.
 @sideeffect Reads index/data files and runs the module's raw decryption filters.
 @failure Returns false for missing metadata, malformed indexes, or incomplete files.
 */
bool extractUncompressedVerseSource(
    sword::SWModule *module,
    const sword::VerseKey *key,
    unsigned int sizeWidth,
    sword::SWBuf &source
) {
    const char *absoluteDataPath = module->getConfigEntry("AbsoluteDataPath");
    if (!absoluteDataPath || !*absoluteDataPath || !key) {
        return false;
    }
    const std::string testament = key->getTestament() == 2 ? "nt" : "ot";
    const std::string dataPath = std::string(absoluteDataPath) + testament;
    const std::string indexPath = dataPath + ".vss";
    const unsigned long recordSize = 4 + sizeWidth;
    std::ifstream index(indexPath, std::ios::binary);
    if (!index) {
        return false;
    }
    index.seekg(static_cast<std::streamoff>(key->getTestamentIndex() * recordSize));
    if (!index) {
        return false;
    }
    SW_u32 encodedOffset = 0;
    index.read(reinterpret_cast<char *>(&encodedOffset), sizeof(encodedOffset));
    if (!index) {
        return false;
    }
    const unsigned long offset = swordtoarch32(encodedOffset);
    unsigned long size = 0;
    if (sizeWidth == 2) {
        SW_u16 encodedSize = 0;
        index.read(reinterpret_cast<char *>(&encodedSize), sizeof(encodedSize));
        size = swordtoarch16(encodedSize);
    } else {
        SW_u32 encodedSize = 0;
        index.read(reinterpret_cast<char *>(&encodedSize), sizeof(encodedSize));
        size = swordtoarch32(encodedSize);
    }
    if (!index) {
        return false;
    }
    if (size == 0) {
        source = "";
        return true;
    }
    if (!readFileRegion(dataPath, offset, size, source)) {
        return false;
    }
    module->rawFilter(source, nullptr);
    module->rawFilter(source, key);
    return true;
}

/**
 Extracts one zText/zCom-family record through its decompressor without `prepText`.

 @param module Current native module supplying compressed backend and raw filters.
 @param key Current exact VerseKey.
 @param source Output receiving decompressed/decrypted source bytes.
 @return True for recognized two- or four-byte compressed verse backends.
 @sideeffect Reads/decompresses the current block and runs native raw decryption filters.
 @failure Returns false for missing keys or an unrecognized compressed backend.
 */
bool extractCompressedVerseSource(
    sword::SWModule *module,
    const sword::VerseKey *key,
    sword::SWBuf &source
) {
    if (!key) {
        return false;
    }
    if (auto *compressed = dynamic_cast<sword::zVerse *>(module)) {
        long start = 0;
        unsigned short size = 0;
        unsigned long block = 0;
        compressed->findOffset(
            key->getTestament(),
            key->getTestamentIndex(),
            &start,
            &size,
            &block
        );
        compressed->zReadText(key->getTestament(), start, size, block, source);
        module->rawFilter(source, key);
        return true;
    }
    if (auto *compressed = dynamic_cast<sword::zVerse4 *>(module)) {
        long start = 0;
        unsigned long size = 0;
        unsigned long block = 0;
        compressed->findOffset(
            key->getTestament(),
            key->getTestamentIndex(),
            &start,
            &size,
            &block
        );
        compressed->zReadText(key->getTestament(), start, size, block, source);
        module->rawFilter(source, key);
        return true;
    }
    return false;
}

/**
 Extracts one exact RawLD/RawLD4/zLD record after native key/link snapping.

 @param module Current native dictionary module.
 @param key Requested native dictionary key; refreshed after the snap load.
 @param source Output receiving decrypted source bytes without `prepText`.
 @return True for recognized dictionary drivers whose selected physical record can be read.
 @sideeffect Performs the native snap/link load, rereads the physical record, and runs raw filters.
 @failure Returns false for absent keys, unreadable index/data records, or unsupported drivers.
 */
bool extractRawDictionarySource(
    sword::SWModule *module,
    const sword::SWKey *key,
    sword::SWBuf &source
) {
    if (!key) {
        return false;
    }
    // RawLD-family drivers finalize their snapped key and link target only while loading an entry.
    // Discard that display-prepared buffer, then reread the selected physical record below.
    module->getRawEntryBuf();
    key = module->getKey();
    if (auto *dictionary = dynamic_cast<sword::RawLD *>(module)) {
        const long entry = dictionary->getEntryForKey(key->getText());
        char *canonicalKey = dictionary->getKeyForEntry(entry);
        SW_u32 start = 0;
        SW_u16 size = 0;
        char *storedKey = nullptr;
        const signed char error = canonicalKey
            ? dictionary->findOffset(canonicalKey, &start, &size)
            : -1;
        std::free(canonicalKey);
        if (error) {
            return false;
        }
        dictionary->readText(start, &size, &storedKey, source);
        std::free(storedKey);
        module->rawFilter(source, nullptr);
        module->rawFilter(source, key);
        return true;
    }
    if (auto *dictionary = dynamic_cast<sword::RawLD4 *>(module)) {
        const long entry = dictionary->getEntryForKey(key->getText());
        char *canonicalKey = dictionary->getKeyForEntry(entry);
        SW_u32 start = 0;
        SW_u32 size = 0;
        char *storedKey = nullptr;
        const signed char error = canonicalKey
            ? dictionary->findOffset(canonicalKey, &start, &size)
            : -1;
        std::free(canonicalKey);
        if (error) {
            return false;
        }
        dictionary->readText(start, &size, &storedKey, source);
        std::free(storedKey);
        module->rawFilter(source, nullptr);
        module->rawFilter(source, key);
        return true;
    }
    if (auto *dictionary = dynamic_cast<sword::zLD *>(module)) {
        const long entry = dictionary->getEntryForKey(key->getText());
        char *storedKey = nullptr;
        char *body = nullptr;
        dictionary->getText(entry * 8, &storedKey, &body);
        if (body) {
            source = body;
        }
        std::free(storedKey);
        std::free(body);
        module->rawFilter(source, key);
        return true;
    }
    return false;
}

/**
 Extracts one RawGenBook record using the current TreeKey's physical offset and size.

 @param module Current native general-book module.
 @param key Current TreeKey or VerseTreeKey.
 @param source Output receiving decrypted source bytes without `prepText`.
 @return True only for an exact readable RawGenBook physical record.
 @sideeffect Finalizes the lazy TreeKey through one discarded native load, rereads the `.bdt`
 range, and runs native raw decryption filters.
 @failure Returns false for missing/malformed TreeKey metadata, paths, or record bytes.
 */
bool extractRawGenBookSource(
    sword::SWModule *module,
    const sword::SWKey *key,
    sword::SWBuf &source
) {
    const char *driver = module->getConfigEntry("ModDrv");
    if (!driver || std::strcmp(driver, "RawGenBook") != 0 || !key) {
        return false;
    }
    // TreeKeyIdx applies an assigned textual path lazily. Trigger the native driver once so the
    // current TreeKey owns the exact physical node/userData, discard its display-prepared buffer,
    // then reread that record below without `prepText`.
    module->getRawEntryBuf();
    key = module->getKey();
    const sword::TreeKey *treeKey = dynamic_cast<const sword::TreeKey *>(key);
    if (!treeKey) {
        const auto *verseTreeKey = dynamic_cast<const sword::VerseTreeKey *>(key);
        treeKey = verseTreeKey ? verseTreeKey->getTreeKey() : nullptr;
    }
    int dataSize = 0;
    const char *userData = treeKey ? treeKey->getUserData(&dataSize) : nullptr;
    const char *absoluteDataPath = module->getConfigEntry("AbsoluteDataPath");
    if (!userData || dataSize <= 7 || !absoluteDataPath || !*absoluteDataPath) {
        return false;
    }
    SW_u32 encodedOffset = 0;
    SW_u32 encodedSize = 0;
    std::memcpy(&encodedOffset, userData, sizeof(encodedOffset));
    std::memcpy(&encodedSize, userData + 4, sizeof(encodedSize));
    const unsigned long offset = swordtoarch32(encodedOffset);
    const unsigned long size = swordtoarch32(encodedSize);
    std::string dataPrefix = absoluteDataPath;
    // SWORD 1.9.0 deliberately strips the final DataPath component from AbsoluteDataPath for
    // RawGenBook. Reattach that exact configured component; a slash-terminated DataPath was
    // already normalized to the complete constructor prefix and must not be duplicated.
    const char *configuredDataPath = module->getConfigEntry("DataPath");
    if (configuredDataPath && *configuredDataPath) {
        const std::string configured = configuredDataPath;
        if (!configured.empty() && configured.back() != '/') {
            const std::string::size_type separator = configured.find_last_of('/');
            const std::string leaf = separator == std::string::npos
                ? configured
                : configured.substr(separator + 1);
            if (!leaf.empty()) {
                dataPrefix += "/" + leaf;
            }
        }
    }
    if (!readFileRegion(dataPrefix + ".bdt", offset, size, source)) {
        return false;
    }
    module->rawFilter(source, nullptr);
    module->rawFilter(source, key);
    return true;
}

/**
 Selects the physical driver extractor and applies native character decoding exactly once.

 @param module Current native module positioned on the requested entry.
 @param source Output receiving decoded source bytes for the Swift JSword-format filter.
 @return True when one Android-supported physical driver supplied its unmodified source record.
 @sideeffect Reads the current entry and may perform driver-defined key snapping/decryption.
 @failure Unsupported drivers and physical extraction failures produce empty source; no display-
 prepared compatibility path or exception crosses the native boundary.
 */
bool extractDecodedSource(sword::SWModule *module, sword::SWBuf &source) {
    const sword::SWKey *key = module ? module->getKey() : nullptr;
    const auto *verseKey = dynamic_cast<const sword::VerseKey *>(key);
    const char *driverValue = module ? module->getConfigEntry("ModDrv") : nullptr;
    const std::string driver = driverValue ? driverValue : "";
    bool extracted = false;
    if (driver == "RawText" || driver == "RawCom" || driver == "HREFCom") {
        extracted = extractUncompressedVerseSource(module, verseKey, 2, source);
    } else if (driver == "RawText4" || driver == "RawCom4") {
        extracted = extractUncompressedVerseSource(module, verseKey, 4, source);
    } else if (driver == "zText" || driver == "zCom"
               || driver == "zText4" || driver == "zCom4") {
        extracted = extractCompressedVerseSource(module, verseKey, source);
    } else if (driver == "RawLD" || driver == "RawLD4" || driver == "zLD") {
        extracted = extractRawDictionarySource(module, key, source);
    } else if (driver == "RawGenBook") {
        extracted = extractRawGenBookSource(module, key, source);
    } else if (driver == "RawFiles") {
        source = module->getRawEntryBuf();
        extracted = true;
    } else {
        source = "";
    }
    if (!extracted) {
        source = "";
    }
    module->encodingFilter(source, key);
    return extracted;
}

} // namespace

extern "C" const char *SWModule_getDecodedSourceFragment(void *moduleHandle) {
    currentDecodedSourceStorage.clear();
    if (!moduleHandle) {
        return currentDecodedSourceStorage.c_str();
    }

    auto *handle = reinterpret_cast<FlatAPIHandleSWModule *>(moduleHandle);
    auto *module = handle->mod;
    if (!module) {
        return currentDecodedSourceStorage.c_str();
    }

    sword::SWBuf source;
    extractDecodedSource(module, source);
    currentDecodedSourceStorage.assign(source.c_str(), source.size());
    return currentDecodedSourceStorage.c_str();
}

extern "C" const char *SWModule_getCurrentOSISRef(void *moduleHandle) {
    currentOSISRefStorage.clear();
    if (!moduleHandle) {
        return currentOSISRefStorage.c_str();
    }

    auto *handle = reinterpret_cast<FlatAPIHandleSWModule *>(moduleHandle);
    auto *module = handle->mod;
    const auto *verseKey = module ? dynamic_cast<const sword::VerseKey *>(module->getKey()) : nullptr;
    if (verseKey) {
        currentOSISRefStorage = verseKey->getOSISRef();
    }
    return currentOSISRefStorage.c_str();
}

extern "C" const char *SWModule_resolveOSISReference(
    void *moduleHandle,
    const char *reference
) {
    resolvedOSISRefStorage.clear();
    if (!moduleHandle || !reference || !*reference) {
        return resolvedOSISRefStorage.c_str();
    }

    auto *handle = reinterpret_cast<FlatAPIHandleSWModule *>(moduleHandle);
    auto *module = handle->mod;
    if (!module) {
        return resolvedOSISRefStorage.c_str();
    }

    const auto *verseKey = dynamic_cast<const sword::VerseKey *>(module->getKey());
    sword::VerseKey parser = verseKey ? *verseKey : sword::VerseKey();
    sword::ListKey parsed = parser.parseVerseList(
        reference,
        verseKey ? verseKey->getText() : nullptr,
        false
    );
    for (int index = 0; index < parsed.getCount(); ++index) {
        const auto *parsedVerse = dynamic_cast<const sword::VerseKey *>(parsed.getElement(index));
        if (!parsedVerse || parsedVerse->getError()) {
            resolvedOSISRefStorage.clear();
            break;
        }
        const char *osisReference = parsedVerse->getOSISRefRangeText();
        if (!osisReference || !*osisReference) {
            continue;
        }
        if (!resolvedOSISRefStorage.empty()) {
            resolvedOSISRefStorage += " ";
        }
        resolvedOSISRefStorage += osisReference;
    }
    return resolvedOSISRefStorage.c_str();
}

extern "C" const char *SWModule_getRawDictionaryDecodedSourceAtIndex(
    void *moduleHandle,
    long index,
    const unsigned char *rawRecord,
    unsigned long rawRecordLength
) {
    decodedSourceStorage.clear();
    if (!moduleHandle || index < 0) {
        return decodedSourceStorage.c_str();
    }

    auto *handle = reinterpret_cast<FlatAPIHandleSWModule *>(moduleHandle);
    auto *module = handle->mod;
    if (!module) {
        return decodedSourceStorage.c_str();
    }

    sword::SWBuf source;
    bool sourceWasFiltered = false;
    if (auto *compressedDictionary = dynamic_cast<sword::zLD *>(module)) {
        char *storedKey = nullptr;
        char *entry = nullptr;
        compressedDictionary->getText(index * 8, &storedKey, &entry);
        if (entry) {
            source = entry;
        }
        std::free(storedKey);
        std::free(entry);
    } else {
        if (!rawRecord || rawRecordLength == 0) {
            return decodedSourceStorage.c_str();
        }
        unsigned long bodyStart = rawRecordLength;
        for (unsigned long cursor = 0; cursor < rawRecordLength; ++cursor) {
            if (rawRecord[cursor] == 0x0A) {
                bodyStart = cursor + 1;
                break;
            }
        }
        source = sword::SWBuf(
            reinterpret_cast<const char *>(rawRecord),
            rawRecordLength
        );

        const char *body = source.c_str() + bodyStart;
        if (bodyStart < rawRecordLength && std::strncmp(body, "@LINK", 5) == 0) {
            const char *targetStart = body + std::min<unsigned long>(6, rawRecordLength - bodyStart);
            std::string target(targetStart);
            const std::string::size_type lineEnd = target.find_first_of("\r\n");
            if (lineEnd != std::string::npos) {
                target.erase(lineEnd);
            }
            module->setKey(sword::SWKey(target.c_str()));
            const sword::SWBuf targetBody = module->getRawEntryBuf();
            source = module->getKeyText();
            source += "\n";
            source += targetBody;
            sourceWasFiltered = true;
        }
    }

    const sword::SWKey *key = module->getKey();
    if (!sourceWasFiltered) {
        if (rawRecord && rawRecordLength > 0) {
            module->rawFilter(source, nullptr);
        }
        module->rawFilter(source, key);
        unsigned long start = 0;
        unsigned long end = source.size();
        while (start < end && static_cast<unsigned char>(source[start]) <= 0x20) {
            ++start;
        }
        while (end > start && static_cast<unsigned char>(source[end - 1]) <= 0x20) {
            --end;
        }
        source = sword::SWBuf(source.c_str() + start, end - start);
    }

    module->encodingFilter(source, key);
    decodedSourceStorage = source.c_str();
    return decodedSourceStorage.c_str();
}

extern "C" const char *SWModule_getCurrentKeyName(void *moduleHandle) {
    currentKeyNameStorage.clear();
    if (!moduleHandle) {
        return currentKeyNameStorage.c_str();
    }

    auto *handle = reinterpret_cast<FlatAPIHandleSWModule *>(moduleHandle);
    auto *module = handle->mod;
    if (!module || !module->getKey()) {
        return currentKeyNameStorage.c_str();
    }

    sword::SWKey *key = module->getKey();
    if (auto *treeKey = dynamic_cast<sword::TreeKey *>(key)) {
        currentKeyNameStorage = treeKey->getLocalName();
    } else {
        currentKeyNameStorage = key->getShortText();
    }
    return currentKeyNameStorage.c_str();
}

extern "C" void *SWModule_cloneCurrentKey(void *moduleHandle) {
    if (!moduleHandle) {
        return nullptr;
    }

    auto *handle = reinterpret_cast<FlatAPIHandleSWModule *>(moduleHandle);
    auto *module = handle->mod;
    if (!module || !module->getKey()) {
        return nullptr;
    }

    sword::SWKey *clone = module->getKey()->clone();
    if (clone) {
        clone->setPersist(false);
    }
    return clone;
}

extern "C" int SWModule_restoreClonedKey(void *moduleHandle, void *clonedKeyHandle) {
    std::unique_ptr<sword::SWKey> clonedKey(
        reinterpret_cast<sword::SWKey *>(clonedKeyHandle)
    );
    if (!moduleHandle || !clonedKey) {
        return 1;
    }

    auto *handle = reinterpret_cast<FlatAPIHandleSWModule *>(moduleHandle);
    auto *module = handle->mod;
    if (!module || !module->getKey()) {
        return 1;
    }

    sword::SWKey *restoredKey = module->getKey();
    restoredKey->positionFrom(*clonedKey);
    const char *restoredText = restoredKey->getText();
    const char *clonedText = clonedKey->getText();
    const bool textMatches = std::strcmp(
        restoredText ? restoredText : "",
        clonedText ? clonedText : ""
    ) == 0;
    return restoredKey->getIndex() == clonedKey->getIndex()
        && textMatches
        ? 0
        : 1;
}

#else

extern "C" const char *SWModule_getDecodedSourceFragment(void *module) {
    static const char *empty = "";
    return empty;
}

extern "C" const char *SWModule_getCurrentOSISRef(void *module) {
    static const char *empty = "";
    return empty;
}

extern "C" const char *SWModule_resolveOSISReference(void *module, const char *reference) {
    static const char *empty = "";
    return empty;
}

extern "C" const char *SWModule_getRawDictionaryDecodedSourceAtIndex(
    void *module,
    long index,
    const unsigned char *rawRecord,
    unsigned long rawRecordLength
) {
    static const char *empty = "";
    return empty;
}

extern "C" const char *SWModule_getCurrentKeyName(void *module) {
    static const char *empty = "";
    return empty;
}

extern "C" void *SWModule_cloneCurrentKey(void *module) {
    return nullptr;
}

extern "C" int SWModule_restoreClonedKey(void *module, void *clonedKey) {
    return 1;
}

#endif
