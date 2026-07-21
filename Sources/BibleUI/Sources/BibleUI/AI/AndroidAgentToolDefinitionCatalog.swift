// AndroidAgentToolDefinitionCatalog.swift -- Exact Android agent tool definitions

import BibleCore
import Foundation

/**
 Immutable provider-facing definition catalog copied from Android's production tool sources.

 The JSON snapshot preserves every description, property, enum, default, and required-parameter
 list. Keeping the snapshot independent from execution parsing makes schema drift visible in tests
 while the typed dispatcher remains free to enforce stricter runtime invariants.

 - Side effects: Parses the bundled source literal once on first access.
 - Failure modes: A malformed checked-in literal is a programmer error and terminates immediately.
 */
public enum AndroidAgentToolDefinitionCatalog {
    private static let encodedDefinitions = ####"""
{
  "GET_ALL_LABELS": {
    "description": "Get all available labels (tags/categories).\nLabels are used to organize bookmarks and create StudyPads.\nEach label can be used as a StudyPad for collecting related bookmarks and notes.",
    "parameters": {
      "type": "object",
      "properties": {
      }
    }
  },
  "GET_BOOKMARKS_FOR_VERSE": {
    "description": "Get all bookmarks associated with a verse or verse range.\nReturns bookmark details including notes and associated labels.\nUseful for finding user annotations and notes for specific passages.",
    "parameters": {
      "type": "object",
      "properties": {
        "verseRef": {
          "type": "string",
          "description": "OSIS verse reference, e.g., 'Matt.5.3', 'Gen.1.1-3'. Can be a single verse or range."
        }
      },
      "required": [
        "verseRef"
      ]
    }
  },
  "GET_BOOKMARKS_WITH_LABEL": {
    "description": "Get all bookmarks that have a specific label assigned.\nA label acts as a StudyPad - a collection of related bookmarks and notes.\nUse getAllLabels first to find available labels and their IDs.",
    "parameters": {
      "type": "object",
      "properties": {
        "labelId": {
          "type": "string",
          "description": "The ID of the label to query. Get label IDs from getAllLabels."
        },
        "maxResults": {
          "type": "integer",
          "description": "Maximum number of bookmarks to return (default: 100)"
        },
        "fields": {
          "type": "array",
          "items": {
            "type": "string",
            "enum": [
              "verseRange",
              "verseName",
              "notes",
              "createdAt"
            ]
          },
          "description": "Fields to include in the response. Default: [verseRange, verseName, createdAt]. Notes can be large, only include if needed."
        }
      },
      "required": [
        "labelId"
      ]
    }
  },
  "GET_COMMENTARIES": {
    "description": "Get commentary entries for a verse or verse range from installed commentaries.\nReturns readable text by default. Use format='xml' for raw OSIS XML (rarely needed for commentaries).\nSupports verse ranges (e.g. 'Matt.5.1-10') — iterates through each verse and deduplicates\nidentical content that commentaries repeat across consecutive verses.\nEach entry includes 'linkUrl' (already URL-encoded base path for the entry).\nTo cite content, append an anchor fragment (#oN or #oN-M) to linkUrl as described\nin the system instructions. Commentary text includes anchor markers like [§N]\nat sentence boundaries — use these ordinal numbers in the anchor fragment.",
    "parameters": {
      "type": "object",
      "properties": {
        "verseRef": {
          "type": "string",
          "description": "OSIS verse reference or range, e.g., 'Matt.5.3', 'Matt.5.1-10', 'Gen.1.1-3', 'Rom.8.28'"
        },
        "commentaries": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "Optional list of commentary initials to query. If not specified, queries all installed commentaries."
        },
        "format": {
          "type": "string",
          "enum": [
            "text",
            "xml"
          ],
          "description": "Output format: 'text' (default) returns readable text. 'xml' returns raw OSIS XML.",
          "default": "text"
        }
      },
      "required": [
        "verseRef"
      ]
    }
  },
  "GET_DICTIONARY_ENTRY": {
    "description": "Look up an entry in a Bible dictionary, including Strong's dictionaries. Returns readable text by default.\nUse format='xml' for raw OSIS XML (useful for Strong's to see original language markup).\nUseful for looking up definitions of biblical terms, places, people, and Strong's numbers.\nFor Strong's numbers, use H prefix for Hebrew (e.g., 'H430' for Elohim) or G prefix for Greek (e.g., 'G2316' for Theos).\nIMPORTANT: The result includes a 'linkUrl' field (already properly URL-encoded).\nWhen referencing dictionary entries in your response, ALWAYS use the linkUrl value\ndirectly in clickable links. Example: [G2316](strongs://G2316)\nCRITICAL: Convert ALL Strong's number references to clickable links in your response:\n- With prefix: G1234 → [G1234](strongs://G1234), H5678 → [H5678](strongs://H5678)\n- Without prefix (in dictionary content): If you're working with a Greek dictionary,\n  bare numbers like \"575\" or \"4724\" refer to Greek entries → [G575](strongs://G575)\n  Similarly for Hebrew dictionary → [H575](strongs://H575)\n- Example: \"Derived from 575 and 4724\" → \"Derived from [G575](strongs://G575) and [G4724](strongs://G4724)\"",
    "parameters": {
      "type": "object",
      "properties": {
        "dictionary": {
          "type": "string",
          "description": "Dictionary initials, e.g., 'StrongsHebrew', 'StrongsGreek', 'Eastons'. Use getInstalledDocuments to find available dictionaries."
        },
        "key": {
          "type": "string",
          "description": "The dictionary key/term to look up. For Strong's dictionaries use format like 'H430', 'G2316'. For regular dictionaries use terms like 'Moses', 'Jerusalem'."
        },
        "format": {
          "type": "string",
          "enum": [
            "text",
            "xml"
          ],
          "description": "Output format: 'text' (default) returns readable text. 'xml' returns raw OSIS XML with original language markup.",
          "default": "text"
        }
      },
      "required": [
        "dictionary",
        "key"
      ]
    }
  },
  "GET_GENBOOK_CONTENT": {
    "description": "Read the content of a specific entry in a general book (reference material, handbook, My Document, etc.).\nUse getGenBookKeys first to find available keys and their osisRef values.\nReturns readable text by default with anchor markers like [§5] at sentence boundaries,\nor raw OSIS XML with format='xml'.\nEach result includes a 'linkUrl' field (already URL-encoded).\nText content includes anchor markers [§N] — use these for precise citations\nby appending #oN or #oN-M to the linkUrl (e.g., sword://Westminster/Chapter1#o5-10).",
    "parameters": {
      "type": "object",
      "properties": {
        "book": {
          "type": "string",
          "description": "Book initials (e.g., 'Westminster', 'AIDocuments'). Use getInstalledDocuments with category=GENERAL_BOOK to find available books."
        },
        "key": {
          "type": "string",
          "description": "The osisRef of the entry to read (from getGenBookKeys result)."
        },
        "format": {
          "type": "string",
          "enum": [
            "text",
            "xml"
          ],
          "description": "Output format: 'text' (default) returns readable text with anchor markers. 'xml' returns raw OSIS XML.",
          "default": "text"
        }
      },
      "required": [
        "book",
        "key"
      ]
    }
  },
  "GET_GENBOOK_KEYS": {
    "description": "List table of contents / navigation keys for a general book (reference material, handbook, My Document, etc.).\nReturns key names, osisRef values, and linkUrl for each entry.\nUse getInstalledDocuments with category=GENERAL_BOOK to find available general books first.\nUse getGenBookContent to read the content of a specific key.\nFor large books, use offset and limit for pagination.",
    "parameters": {
      "type": "object",
      "properties": {
        "book": {
          "type": "string",
          "description": "Book initials (e.g., 'Westminster', 'AIDocuments'). Use getInstalledDocuments with category=GENERAL_BOOK to find available books."
        },
        "offset": {
          "type": "integer",
          "description": "Number of keys to skip (for pagination). Default: 0.",
          "default": 0
        },
        "limit": {
          "type": "integer",
          "description": "Maximum number of keys to return. Default: 100, max: 500.",
          "default": 100
        }
      },
      "required": [
        "book"
      ]
    }
  },
  "GET_INSTALLED_DOCUMENTS": {
    "description": "Get a list of installed documents (Bibles, commentaries, dictionaries, etc.).\nUse this to find available documents before reading content.\nCan filter by category: BIBLE, COMMENTARY, DICTIONARY, GENERAL_BOOK, MAPS.\nEach document includes an isIndexed field — only indexed documents can be searched.\nBible documents also include a hasStrongsNumbers field indicating whether the module\ncontains Strong's concordance number annotations (useful for original language word studies).\nA Bible must be both indexed and have Strong's numbers to support Strong's number search.",
    "parameters": {
      "type": "object",
      "properties": {
        "category": {
          "type": "string",
          "enum": [
            "BIBLE",
            "COMMENTARY",
            "DICTIONARY",
            "GENERAL_BOOK",
            "MAPS"
          ],
          "description": "Optional category filter. If not specified, returns all documents."
        }
      }
    }
  },
  "GET_MY_DOCUMENT_PAGES": {
    "description": "List pages of a My Documents book. Identify the document by documentId or initials.\nSet includeContent=true to also return raw page content (default: titles only).\nUse getMyDocuments first to find document IDs and initials.\nNOTE: This tool returns raw source content (Markdown/HTML/OSIS) without anchor markers.\nUse this when you need raw content for editing (with editMyDocumentPage).\nTo READ formatted content with ordinal anchors ([§N]) for citation, use getGenBookContent instead\n— My Documents are general books and work with getGenBookKeys/getGenBookContent.",
    "parameters": {
      "type": "object",
      "properties": {
        "documentId": {
          "type": "string",
          "description": "ID of the document (from getMyDocuments result)"
        },
        "initials": {
          "type": "string",
          "description": "Document initials (alternative to documentId), e.g. 'AIDocuments'"
        },
        "includeContent": {
          "type": "boolean",
          "description": "If true, include page content in the response. Default: false (titles only).",
          "default": false
        }
      }
    }
  },
  "GET_MY_DOCUMENTS": {
    "description": "List all My Documents books (user-created and AI-generated document collections).\nReturns document metadata including page counts.\nThe 'AI Documents' book (where AI-generated pages are stored) is highlighted\nwith aiDocumentId and aiDocumentInitials at the top level for easy access.",
    "parameters": {
      "type": "object",
      "properties": {
      }
    }
  },
  "GET_STUDY_PAD_CONTENT": {
    "description": "Get the content of a StudyPad (label).\nStudyPads contain ordered entries: text notes and bookmark references.\nSupports multiple read modes:\n- 'info': metadata only (entry counts, estimated size). Use first to check StudyPad size.\n- 'index': lightweight overview with type, position, and ~80-char preview for each entry.\n- 'page': paginated full content (use offset/limit to read in chunks).\n- 'full': all entries with full content (default). May be large for big StudyPads.\nUse 'info' first, then depending on size, 'full' or 'index' / 'page' to read selectively.",
    "parameters": {
      "type": "object",
      "properties": {
        "labelId": {
          "type": "string",
          "description": "The ID of the label/StudyPad. Get label IDs from getAllLabels."
        },
        "mode": {
          "type": "string",
          "enum": [
            "full",
            "info",
            "index",
            "page"
          ],
          "description": "'info': metadata only (entry counts, size). 'index': lightweight overview (type, position, preview). 'page': paginated full content (use offset/limit). 'full': all entries with full content (default).\n"
        },
        "offset": {
          "type": "integer",
          "description": "Start position (0-based). Only used in 'page' mode."
        },
        "limit": {
          "type": "integer",
          "description": "Max entries to return. Only used in 'page' mode. Default 20."
        }
      },
      "required": [
        "labelId"
      ]
    }
  },
  "GET_VERSE_CONTENT": {
    "description": "Get verse content from a Bible translation. Returns readable text by default.\nUse format='xml' for raw OSIS XML with Strong's numbers and morphology (for word studies).\nUse OSIS format references like 'Matt.5.3', 'Gen.1.1-3', 'Gen.1' for entire chapter, or 'Gen.1-Gen.3' for multiple chapters.",
    "parameters": {
      "type": "object",
      "properties": {
        "book": {
          "type": "string",
          "description": "Book initials, e.g., 'KJV', 'ESV', 'NASB'. Use getInstalledDocuments to find available books."
        },
        "verseRef": {
          "type": "string",
          "description": "OSIS verse reference, e.g., 'Matt.5.3', 'Gen.1.1-3', 'Rom.8.28-30'."
        },
        "format": {
          "type": "string",
          "enum": [
            "text",
            "xml"
          ],
          "description": "Output format: 'text' (default) returns readable text with light annotations (headings, footnotes). 'xml' returns raw OSIS XML with Strong's numbers, morphology, etc. Use 'xml' only for word studies or Strong's analysis.",
          "default": "text"
        }
      },
      "required": [
        "book",
        "verseRef"
      ]
    }
  },
  "GET_WINDOWS": {
    "description": "Get a list of all windows in the current workspace.\nReturns each window's state (VISIBLE or MINIMISED), the document it displays,\nits current position (verse/key), and other properties.\nUse this to understand the current workspace layout before creating or managing windows.",
    "parameters": {
      "type": "object",
      "properties": {
      }
    }
  },
  "SEARCH_BIBLE": {
    "description": "Search for words or phrases in Bible translations using a Lucene full-text index.\nReturns a list of verses matching the query. Only indexed books can be searched.\ngetInstalledDocuments isIndexed tells which documents can be used for searching.\nSupports pagination via offset parameter.\nIMPORTANT: This is a keyword index, NOT a semantic/thematic search. Queries must use\nwords that literally appear in the text. Multi-word queries use OR logic by default\n(matching ANY word), which returns many irrelevant results. Use exact phrases (\"...\")\nor AND/+operators for precision. The search language must match the indexed Bible's language.\nFor thematic studies, prefer using your Bible knowledge to identify relevant passages\nby reference, then retrieve them with getVerseContent. Use searchBible only when you\nneed to find specific words or phrases in the text.\nQuery syntax:\n- Single word: love\n- Exact phrase: \"the Lord is my shepherd\"\n- Boolean: love AND truth, mercy OR grace, love NOT hate\n- Prefix wildcard: redeem* (matches redeem, redeemed, redeemer, etc.)\n- Required/excluded: +faith -works",
    "parameters": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "Search query. Supports Lucene syntax: single words, \"exact phrases\" in quotes, boolean operators (AND, OR, NOT), prefix wildcards (redeem*), and required/excluded terms (+word, -word)."
        },
        "books": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "Optional list of book initials to search in. If not specified, searches the first available indexed Bible."
        },
        "maxResults": {
          "type": "integer",
          "description": "Maximum number of results to return per page (default: 50)"
        },
        "offset": {
          "type": "integer",
          "description": "Number of results to skip for pagination (default: 0). Use with maxResults to page through results."
        }
      },
      "required": [
        "query"
      ]
    }
  },
  "SEARCH_BY_STRONGS": {
    "description": "Search for verses containing a specific Strong's concordance number.\nStrong's numbers identify original Hebrew/Greek words.\nUse H prefix for Hebrew (e.g. H7225 for \"reshith\"/beginning) and G prefix for Greek (e.g. G26 for \"agape\"/love).\nReturns matching verse references from a Strong's-enabled, indexed Bible.\nIf no book is specified, automatically selects the best available Strong's-enabled Bible.\nSupports pagination via offset parameter.",
    "parameters": {
      "type": "object",
      "properties": {
        "strongsNumber": {
          "type": "string",
          "description": "Strong's concordance number with H (Hebrew) or G (Greek) prefix, e.g. H7225, G26"
        },
        "book": {
          "type": "string",
          "description": "Optional Bible module initials to search in. If not specified, automatically selects a Strong's-enabled Bible."
        },
        "maxResults": {
          "type": "integer",
          "description": "Maximum number of results to return per page (default: 50)"
        },
        "offset": {
          "type": "integer",
          "description": "Number of results to skip for pagination (default: 0)"
        }
      },
      "required": [
        "strongsNumber"
      ]
    }
  },
  "SEARCH_STUDY_PADS": {
    "description": "Search for text across all StudyPads.\nSearches in StudyPad text entries and bookmark notes.\nReturns matching StudyPads with text snippets showing where matches were found.",
    "parameters": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "The text to search for"
        }
      },
      "required": [
        "query"
      ]
    }
  },
  "ADD_BOOKMARK_NOTE": {
    "description": "Add a note to an existing bookmark that doesn't have a note yet.\nIf the bookmark already has a note, use updateBookmarkNote instead.\nThe note will be marked as AI-generated.",
    "parameters": {
      "type": "object",
      "properties": {
        "bookmarkId": {
          "type": "string",
          "description": "The ID of the bookmark to add the note to"
        },
        "note": {
          "type": "string",
          "description": "The note text to add"
        },
        "contentType": {
          "type": "string",
          "enum": [
            "HTML",
            "MARKDOWN"
          ],
          "description": "Content type of the note. Default: MARKDOWN for AI-generated content."
        }
      },
      "required": [
        "bookmarkId",
        "note"
      ]
    }
  },
  "ADD_LABEL_TO_BOOKMARK": {
    "description": "Add a label to an existing bookmark.\nThis associates the bookmark with the label/StudyPad.\nA bookmark can have multiple labels.",
    "parameters": {
      "type": "object",
      "properties": {
        "bookmarkId": {
          "type": "string",
          "description": "The ID of the bookmark"
        },
        "labelId": {
          "type": "string",
          "description": "The ID of the label to add"
        }
      },
      "required": [
        "bookmarkId",
        "labelId"
      ]
    }
  },
  "ADD_MY_DOCUMENT_PAGE": {
    "description": "Add a new page to a My Documents book.\nIdentify the target document by documentId or initials.\nUse initials='AIDocuments' to add to the 'AI Documents' book (no permission needed).\nContent type defaults to MARKDOWN.",
    "parameters": {
      "type": "object",
      "properties": {
        "documentId": {
          "type": "string",
          "description": "ID of the target document"
        },
        "initials": {
          "type": "string",
          "description": "Document initials (alternative to documentId), e.g. 'AIDocuments'"
        },
        "title": {
          "type": "string",
          "description": "Page title"
        },
        "content": {
          "type": "string",
          "description": "Page content (markdown by default)"
        },
        "contentType": {
          "type": "string",
          "enum": [
            "MARKDOWN",
            "HTML",
            "OSIS"
          ],
          "description": "Content type. Default: MARKDOWN.",
          "default": "MARKDOWN"
        }
      },
      "required": [
        "title",
        "content"
      ]
    }
  },
  "ADD_STUDY_PAD_ENTRY": {
    "description": "Add a text entry to a StudyPad (label).\nStudyPads can contain both bookmarks and standalone text notes.\nThis creates a new text entry at the end of the StudyPad.\nThe entry will be marked as AI-generated.",
    "parameters": {
      "type": "object",
      "properties": {
        "labelId": {
          "type": "string",
          "description": "The ID of the label/StudyPad to add the entry to"
        },
        "text": {
          "type": "string",
          "description": "The text content of the entry"
        },
        "contentType": {
          "type": "string",
          "enum": [
            "HTML",
            "MARKDOWN"
          ],
          "description": "Content type. Default: MARKDOWN for AI-generated content."
        },
        "orderNumber": {
          "type": "integer",
          "description": "Optional position in the StudyPad. Default: add to end."
        }
      },
      "required": [
        "labelId",
        "text"
      ]
    }
  },
  "CREATE_BOOKMARK": {
    "description": "Create a new bookmark at a verse or verse range.\nBookmarks can include notes and be assigned to labels (categories/StudyPads).",
    "parameters": {
      "type": "object",
      "properties": {
        "verseRef": {
          "type": "string",
          "description": "OSIS verse reference, e.g., 'Matt.5.3' or 'Gen.1.1-3'"
        },
        "note": {
          "type": "string",
          "description": "Optional note text to attach to the bookmark"
        },
        "noteContentType": {
          "type": "string",
          "enum": [
            "HTML",
            "MARKDOWN"
          ],
          "description": "Content type of the note. Default: MARKDOWN"
        },
        "labelIds": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "description": "Optional list of label IDs to assign to the bookmark. Get IDs from getAllLabels."
        },
        "primaryLabelId": {
          "type": "string",
          "description": "Optional label ID to set as primary. Must be one of the labelIds. Defaults to the first label in labelIds."
        },
        "bookInitials": {
          "type": "string",
          "description": "Bible module initials (e.g., 'KJV', 'ESV'). Required for sub-verse bookmarks. Defaults to the active document if omitted."
        },
        "startOffset": {
          "type": "integer",
          "description": "Character offset from the start of the verse text where the bookmark begins. 0 = start of verse. Offsets are specific to the bookInitials translation. Both startOffset and endOffset must be provided together for a sub-verse bookmark."
        },
        "endOffset": {
          "type": "integer",
          "description": "Character offset from the start of the verse text where the bookmark ends. Offsets are specific to the bookInitials translation. Both startOffset and endOffset must be provided together for a sub-verse bookmark."
        }
      },
      "required": [
        "verseRef"
      ]
    }
  },
  "CREATE_LABEL": {
    "description": "Create a new label (category/StudyPad).\nLabels are used to organize bookmarks into categories.\nEach label can also function as a StudyPad for collecting related notes.",
    "parameters": {
      "type": "object",
      "properties": {
        "name": {
          "type": "string",
          "description": "The name of the label"
        },
        "color": {
          "type": "integer",
          "description": "Optional color as ARGB integer. Default: blue highlight color."
        }
      },
      "required": [
        "name"
      ]
    }
  },
  "CREATE_MY_DOCUMENT": {
    "description": "Create a new My Documents book. Use this to create a new document collection\nfor organizing pages. For adding pages to the existing 'AI Documents' book,\nuse addMyDocumentPage directly with initials='AIDocuments'.",
    "parameters": {
      "type": "object",
      "properties": {
        "name": {
          "type": "string",
          "description": "Name of the new document"
        },
        "description": {
          "type": "string",
          "description": "Optional description of the document"
        }
      },
      "required": [
        "name"
      ]
    }
  },
  "CREATE_STUDY_PAD": {
    "description": "Create a complete StudyPad with text entries and Bible verse bookmarks in a single call.\nThis is the preferred way to create a StudyPad — it creates the label and all items at once.\nItems are displayed in the order they appear in the array.\nEach item is either a text entry (markdown/HTML) or a bookmark to a Bible verse (with optional note).\nAfter creating the StudyPad, call finishWithStudyPad with the returned labelId to open it.",
    "parameters": {
      "type": "object",
      "properties": {
        "name": {
          "type": "string",
          "description": "Name for the StudyPad"
        },
        "color": {
          "type": "integer",
          "description": "Optional ARGB color integer. Default: blue highlight color."
        },
        "items": {
          "type": "array",
          "description": "Ordered list of items. Each is either a text entry or a bookmark.",
          "items": {
            "type": "object",
            "properties": {
              "type": {
                "type": "string",
                "enum": [
                  "text",
                  "bookmark"
                ],
                "description": "'text' for a markdown/HTML entry, 'bookmark' for a Bible verse reference"
              },
              "text": {
                "type": "string",
                "description": "Text content (required for type=text, optional note for type=bookmark)"
              },
              "verseRef": {
                "type": "string",
                "description": "OSIS verse reference, e.g. 'Matt.5.3' or 'Gen.1.1-3' (required for type=bookmark)"
              },
              "indentLevel": {
                "type": "integer",
                "description": "Indent level for hierarchy (0-3). Default: 0"
              },
              "contentType": {
                "type": "string",
                "enum": [
                  "HTML",
                  "MARKDOWN"
                ],
                "description": "Content type for text or bookmark note. Default: MARKDOWN"
              }
            },
            "required": [
              "type"
            ]
          }
        }
      },
      "required": [
        "name",
        "items"
      ]
    }
  },
  "CREATE_WINDOW": {
    "description": "Create a new window in the current workspace.\nOptionally specify a document and verse/key to display.\nIf no document is specified, the new window copies the active window's document and position.\nUse getInstalledDocuments to find available documents and getWindows to see existing windows.",
    "parameters": {
      "type": "object",
      "properties": {
        "documentInitials": {
          "type": "string",
          "description": "Document initials (e.g., 'KJV', 'ESV', 'MHC'). If omitted, copies the active window's document."
        },
        "key": {
          "type": "string",
          "description": "OSIS reference to navigate to (e.g., 'Gen.1.1', 'Matt.5'). If omitted, uses the active window's current position."
        },
        "minimized": {
          "type": "boolean",
          "description": "If true, create the window minimized (hidden). Default: false."
        }
      }
    }
  },
  "DELETE_BOOKMARK": {
    "description": "Delete a bookmark by its ID.\nThis permanently removes the bookmark and its associated notes.\nWorks for both Bible bookmarks and generic bookmarks.",
    "parameters": {
      "type": "object",
      "properties": {
        "bookmarkId": {
          "type": "string",
          "description": "The ID of the bookmark to delete"
        }
      },
      "required": [
        "bookmarkId"
      ]
    }
  },
  "DELETE_LABEL": {
    "description": "Delete a label by its ID.\nThis permanently removes the label. Bookmarks with this label will lose the association.\nSet deleteOrphanedBookmarks to true to also delete bookmarks that would have no remaining labels.\nCannot delete special internal labels (AI, Speak, Unlabeled, etc.).",
    "parameters": {
      "type": "object",
      "properties": {
        "labelId": {
          "type": "string",
          "description": "The ID of the label to delete"
        },
        "deleteOrphanedBookmarks": {
          "type": "boolean",
          "description": "If true, also delete bookmarks that would have no remaining labels after this label is removed. Default: false"
        }
      },
      "required": [
        "labelId"
      ]
    }
  },
  "DELETE_MY_DOCUMENT_PAGE": {
    "description": "Delete a page from a My Documents book. This action is irreversible.\nAlways requires user permission.",
    "parameters": {
      "type": "object",
      "properties": {
        "pageId": {
          "type": "string",
          "description": "ID of the page to delete (from getMyDocumentPages result)"
        }
      },
      "required": [
        "pageId"
      ]
    }
  },
  "EDIT_MY_DOCUMENT_PAGE": {
    "description": "Edit an existing My Documents page. Can update the title, content, and/or order number.\nAt least one of title, content, or orderNumber must be provided.\nPages created in the same session can be edited without permission.",
    "parameters": {
      "type": "object",
      "properties": {
        "pageId": {
          "type": "string",
          "description": "ID of the page to edit (from getMyDocumentPages result)"
        },
        "title": {
          "type": "string",
          "description": "New title for the page (optional)"
        },
        "content": {
          "type": "string",
          "description": "New content for the page (optional)"
        },
        "orderNumber": {
          "type": "integer",
          "description": "New position/order number for the page (optional, 0-based)"
        }
      },
      "required": [
        "pageId"
      ]
    }
  },
  "FINISH_WITH_MY_DOCUMENT_PAGE": {
    "description": "Finish the current task and open a My Documents page.\nUse this when you have created or edited a My Documents page and want to show it to the user.\nThe page must already exist — create or edit it first using addMyDocumentPage or editMyDocumentPage.\nCall this tool as your final action when:\n- You've created a new page with addMyDocumentPage\n- You've edited an existing page with editMyDocumentPage\n- The user should see the result in a My Documents page",
    "parameters": {
      "type": "object",
      "properties": {
        "pageId": {
          "type": "string",
          "description": "ID of the My Documents page to open (from addMyDocumentPage or getMyDocumentPages result)"
        },
        "message": {
          "type": "string",
          "description": "A brief message confirming what was done (shown in the agent log)"
        }
      },
      "required": [
        "pageId",
        "message"
      ]
    }
  },
  "FINISH_WITH_STUDY_PAD": {
    "description": "Finish the current task and open a StudyPad.\nUse this when you have created or modified a StudyPad and want to show it to the user.\nThe StudyPad must already exist — create it first using createLabel + addStudyPadEntry tools.\nYou can also add bookmarks to a StudyPad by assigning the StudyPad's label to a bookmark using addBookmarkLabels.\nCall this tool as your final action when:\n- You've created a new StudyPad with content for the user\n- You've added entries to an existing StudyPad\n- You've added bookmarks to a StudyPad via label assignment\n- The user asked for study notes organized as a StudyPad",
    "parameters": {
      "type": "object",
      "properties": {
        "labelId": {
          "type": "string",
          "description": "ID of the StudyPad (label) to open"
        },
        "scrollToEntryId": {
          "type": "string",
          "description": "Optional ID of a bookmark or text entry to scroll to within the StudyPad"
        },
        "message": {
          "type": "string",
          "description": "A brief message confirming what was done (shown in the agent log)"
        }
      },
      "required": [
        "labelId",
        "message"
      ]
    }
  },
  "FINISH_WITHOUT_DOCUMENT": {
    "description": "Finish the current task without creating an AI document.\nUse this when you have completed an action (like creating a bookmark, adding a label, etc.)\nand there is no need to generate a document with your response.\nCall this tool as your final action when:\n- You've successfully completed a task that doesn't need a written explanation\n- The user asked for a simple action (bookmark, label, note) not an analysis\n- You want to confirm the action was completed without opening a new document",
    "parameters": {
      "type": "object",
      "properties": {
        "message": {
          "type": "string",
          "description": "A brief message confirming what was done (shown in the agent log)"
        }
      },
      "required": [
        "message"
      ]
    }
  },
  "MANAGE_WINDOW": {
    "description": "Manage a window: close, minimize, or restore it.\nUse getWindows first to get window IDs and their current states.\n- CLOSE: Permanently remove a window (cannot close the last window)\n- MINIMIZE: Hide a window without removing it (cannot minimize the last visible window)\n- RESTORE: Make a minimized window visible again",
    "parameters": {
      "type": "object",
      "properties": {
        "windowId": {
          "type": "string",
          "description": "The window ID to act on. Get IDs from getWindows."
        },
        "action": {
          "type": "string",
          "enum": [
            "CLOSE",
            "MINIMIZE",
            "RESTORE"
          ],
          "description": "Action: CLOSE (remove), MINIMIZE (hide), or RESTORE (show)."
        }
      },
      "required": [
        "windowId",
        "action"
      ]
    }
  },
  "REMOVE_LABEL_FROM_BOOKMARK": {
    "description": "Remove a label from a bookmark without deleting either.\nThis only removes the association between the bookmark and the label.",
    "parameters": {
      "type": "object",
      "properties": {
        "bookmarkId": {
          "type": "string",
          "description": "The ID of the bookmark"
        },
        "labelId": {
          "type": "string",
          "description": "The ID of the label to remove"
        }
      },
      "required": [
        "bookmarkId",
        "labelId"
      ]
    }
  },
  "SET_DOCUMENT_TITLE": {
    "description": "Set the title for your AI document and finish the task.\nYou MUST use this tool to give your document a proper title.\n**How to use:**\n1. Output your complete markdown content as text in the same response\n2. Use this tool to set a short, plain text title (no markdown, no links)\n**CRITICAL:**\n- The title must be plain text only — NO markdown, NO links, NO formatting\n- Output content as TEXT in the same response, not as a tool argument",
    "parameters": {
      "type": "object",
      "properties": {
        "title": {
          "type": "string",
          "description": "Plain text title for the document (shown in table of contents, max 60 chars, NO markdown)"
        }
      },
      "required": [
        "title"
      ]
    }
  },
  "SET_WINDOW_DOCUMENT": {
    "description": "Change the document displayed in a window.\nIf windowId is omitted, changes the active window.\nUse getInstalledDocuments to find available document initials.\nUse getWindows to find window IDs.",
    "parameters": {
      "type": "object",
      "properties": {
        "windowId": {
          "type": "string",
          "description": "Window ID to change. If omitted, uses the active window. Get IDs from getWindows."
        },
        "documentInitials": {
          "type": "string",
          "description": "Document initials to display (e.g., 'KJV', 'ESV', 'MHC'). Use getInstalledDocuments to find available documents."
        },
        "key": {
          "type": "string",
          "description": "OSIS reference to navigate to (e.g., 'Gen.1.1', 'Matt.5.3-5'). If omitted, keeps the window's current position."
        }
      },
      "required": [
        "documentInitials"
      ]
    }
  },
  "UPDATE_BOOKMARK_NOTE": {
    "description": "Update the note text of an existing bookmark.\nThis replaces the entire note content. For appending, get the current note first and combine.",
    "parameters": {
      "type": "object",
      "properties": {
        "bookmarkId": {
          "type": "string",
          "description": "The ID of the bookmark to update"
        },
        "note": {
          "type": "string",
          "description": "The new note text"
        }
      },
      "required": [
        "bookmarkId",
        "note"
      ]
    }
  },
  "UPDATE_STUDYPAD_TEXT_ENTRY": {
    "description": "Update the text content of an existing StudyPad journal text entry.\nThis replaces the entire text content.",
    "parameters": {
      "type": "object",
      "properties": {
        "entryId": {
          "type": "string",
          "description": "The ID of the StudyPad text entry to update"
        },
        "text": {
          "type": "string",
          "description": "The new text content"
        }
      },
      "required": [
        "entryId",
        "text"
      ]
    }
  }
}
"""####

    private static let definitions: [String: JSONValue] = {
        guard let root = try? JSONValue.decode(data: Data(encodedDefinitions.utf8)),
              case .object(let values) = root,
              values.count == AgentTool.allCases.count else {
            preconditionFailure("Invalid Android agent tool definition snapshot")
        }
        return values
    }()

    /**
     Returns the exact Android-facing description and JSON Schema for one registered tool.

     - Parameter tool: Complete typed Android tool identity.
     - Returns: Provider-neutral definition with the matching tool identity.
     - Side effects: Initializes the immutable snapshot on first access.
     - Failure modes: Missing or malformed checked-in entries terminate as programmer errors.
     */
    public static func definition(for tool: AgentTool) -> LLMToolDefinition {
        guard let entry = definitions[tool.rawValue]?.objectValue,
              let description = entry["description"]?.stringValue,
              let parameters = entry["parameters"]?.objectValue else {
            preconditionFailure("Missing Android definition for \(tool.rawValue)")
        }
        return LLMToolDefinition(tool: tool, description: description, parameters: parameters)
    }
}
