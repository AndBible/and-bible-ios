#include "include/flatapi.h"

#ifdef USE_REAL_SWORD

#include <algorithm>
#include <cctype>
#include <cstring>
#include <cstdlib>
#include <string>

#include <gbfosis.h>
#include <swbuf.h>
#include <swkey.h>
#include <swmodule.h>
#include <thmlosis.h>
#include <treekey.h>
#include <zld.h>

namespace {

struct FlatAPIHandleSWModule {
    // Mirrors the first field of SWORD flatapi's HandleSWModule wrapper.
    sword::SWModule *mod;
};

thread_local std::string osisFragmentStorage;
thread_local std::string currentKeyNameStorage;

std::string escapeXMLText(const char *value) {
    std::string result;
    if (!value) {
        return result;
    }

    for (const char *cursor = value; *cursor; ++cursor) {
        switch (*cursor) {
        case '&':
            result.append("&amp;");
            break;
        case '<':
            result.append("&lt;");
            break;
        case '>':
            result.append("&gt;");
            break;
        default:
            result.push_back(*cursor);
            break;
        }
    }
    return result;
}

void convertSourceToOSIS(sword::SWModule *module, sword::SWBuf &source) {
    const sword::SWKey *key = module->getKey();
    module->optionFilter(source, key);

    const char *configuredSourceType = module->getConfigEntry("SourceType");
    std::string sourceType = configuredSourceType ? configuredSourceType : "";
    std::transform(sourceType.begin(), sourceType.end(), sourceType.begin(), [](unsigned char value) {
        return static_cast<char>(std::tolower(value));
    });

    if (sourceType == "osis") {
        // Raw OSIS is already the semantic source representation. SWORD's OSISOSIS render filter
        // intentionally drops unrecognized elements such as dictionary entryFree/orth nodes.
    } else if (sourceType == "thml") {
        sword::ThMLOSIS converter;
        converter.processText(source, key, module);
    } else if (sourceType == "gbf") {
        sword::GBFOSIS converter;
        converter.processText(source, key, module);
    } else if (sourceType == "tei") {
        // JSword registers TEI with its OSIS source filter. TEI dictionary elements such as
        // entryFree and orth are already XML and must remain structural for Android parity.
    } else {
        // JSword routes unknown and plain source types through PlainTextFilter. Escaping the raw
        // bytes produces the same XML text-node semantics without rendering HTML first.
        const std::string escaped = escapeXMLText(source.c_str());
        source = escaped.c_str();
    }

    module->encodingFilter(source, key);
}

} // namespace

extern "C" const char *SWModule_getOSISFragment(void *moduleHandle) {
    osisFragmentStorage.clear();
    if (!moduleHandle) {
        return osisFragmentStorage.c_str();
    }

    auto *handle = reinterpret_cast<FlatAPIHandleSWModule *>(moduleHandle);
    auto *module = handle->mod;
    if (!module) {
        return osisFragmentStorage.c_str();
    }

    sword::SWBuf source = module->getRawEntryBuf();
    if (source.size() == 0) {
        return osisFragmentStorage.c_str();
    }

    convertSourceToOSIS(module, source);
    osisFragmentStorage = source.c_str();
    return osisFragmentStorage.c_str();
}

extern "C" const char *SWModule_getRawDictionaryOSISFragmentAtIndex(
    void *moduleHandle,
    long index,
    const unsigned char *rawRecord,
    unsigned long rawRecordLength
) {
    osisFragmentStorage.clear();
    if (!moduleHandle || index < 0) {
        return osisFragmentStorage.c_str();
    }

    auto *handle = reinterpret_cast<FlatAPIHandleSWModule *>(moduleHandle);
    auto *module = handle->mod;
    if (!module) {
        return osisFragmentStorage.c_str();
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
            return osisFragmentStorage.c_str();
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

    convertSourceToOSIS(module, source);
    osisFragmentStorage = source.c_str();
    return osisFragmentStorage.c_str();
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

#else

extern "C" const char *SWModule_getOSISFragment(void *module) {
    static const char *empty = "";
    return empty;
}

extern "C" const char *SWModule_getRawDictionaryOSISFragmentAtIndex(
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

#endif
