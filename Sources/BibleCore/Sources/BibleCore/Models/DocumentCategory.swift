// DocumentCategory.swift — Document type categories

import Foundation

/// Category of a Bible study document.
public enum DocumentCategory: String, Codable, Sendable {
    case bible = "BIBLE"
    case commentary = "COMMENTARY"
    case generalBook = "GENERAL_BOOK"
    case dictionary = "DICTIONARY"
    case map = "MAP"
    case epub = "EPUB"
    case dailyDevotion = "DAILY_DEVOTION"

    /// The page manager key used for persistence.
    public var pageManagerKey: String {
        switch self {
        case .bible: return "bible"
        case .commentary: return "commentary"
        case .dictionary: return "dictionary"
        case .generalBook: return "general_book"
        case .map: return "map"
        case .epub: return "epub"
        case .dailyDevotion: return "daily_devotion"
        }
    }
}

/// Text direction for document rendering.
public enum TextDirection: String, Codable, Sendable {
    case ltr
    case rtl
}

/// Versification system used by a Bible module.
public enum Versification: String, Codable, Sendable {
    case kjv = "KJV"
    case kjva = "KJVA"
    case nrsv = "NRSV"
    case nrsva = "NRSVA"
    case mt = "MT"
    case leningrad = "Leningrad"
    case synodal = "Synodal"
    case synodalProt = "SynodalProt"
    case vulg = "Vulg"
    case luther = "Luther"
    case german = "German"
    case catholic = "Catholic"
    case catholic2 = "Catholic2"
    case lxx = "LXX"
    case orthodox = "Orthodox"
    case calvin = "Calvin"
    case darbyFr = "DarbyFr"
    case segond = "Segond"
    case custom = "Custom"

    public init(string: String) {
        self = Versification(rawValue: string) ?? .kjva
    }
}
