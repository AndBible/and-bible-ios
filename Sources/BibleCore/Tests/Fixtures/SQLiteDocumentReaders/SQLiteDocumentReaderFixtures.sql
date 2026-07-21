-- Reproducible, minimal Android-schema SQLite fixtures for SQLiteDocumentReaderParityTests.

ATTACH DATABASE 'mybible-bible.SQLite3' AS mybible_bible;
CREATE TABLE mybible_bible.info (name TEXT PRIMARY KEY, value TEXT);
INSERT INTO mybible_bible.info (name, value) VALUES
    ('description', 'MyBible Bible Fixture'),
    ('language', 'en'),
    ('strong_numbers', 'true');
CREATE TABLE mybible_bible.books (
    book_number INTEGER PRIMARY KEY,
    long_name TEXT NOT NULL,
    short_name TEXT NOT NULL
);
INSERT INTO mybible_bible.books VALUES (10, 'Genesis', 'Gen');
CREATE TABLE mybible_bible.verses (
    book_number INTEGER NOT NULL,
    chapter INTEGER NOT NULL,
    verse INTEGER NOT NULL,
    text TEXT
);
INSERT INTO mybible_bible.verses VALUES
    (10, 1, 1, 'In the <J>beginning</J>'),
    (10, 1, 2, 'The earth was formless');
CREATE TABLE mybible_bible.stories (
    book_number INTEGER NOT NULL,
    chapter INTEGER NOT NULL,
    verse INTEGER NOT NULL,
    title TEXT NOT NULL
);
INSERT INTO mybible_bible.stories VALUES (10, 1, 1, 'Creation');
DETACH DATABASE mybible_bible;

ATTACH DATABASE 'mybible-commentary.SQLite3' AS mybible_commentary;
CREATE TABLE mybible_commentary.info (name TEXT PRIMARY KEY, value TEXT);
INSERT INTO mybible_commentary.info VALUES
    ('description', 'MyBible Commentary Fixture'),
    ('language', 'de');
CREATE TABLE mybible_commentary.commentaries (
    book_number INTEGER NOT NULL,
    chapter_number_from INTEGER NOT NULL,
    verse_number_from INTEGER NOT NULL,
    chapter_number_to INTEGER,
    verse_number_to INTEGER,
    text TEXT NOT NULL
);
INSERT INTO mybible_commentary.commentaries VALUES
    (10, 1, 1, 1, 2, 'Range commentary'),
    (10, 1, 1, NULL, NULL, 'Exact commentary');
DETACH DATABASE mybible_commentary;

ATTACH DATABASE 'mybible-dictionary.SQLite3' AS mybible_dictionary;
CREATE TABLE mybible_dictionary.info (name TEXT PRIMARY KEY, value TEXT);
INSERT INTO mybible_dictionary.info VALUES
    ('description', 'MyBible Dictionary Fixture'),
    ('language', 'he'),
    ('is_strong', 'true');
CREATE TABLE mybible_dictionary.dictionary (
    topic TEXT PRIMARY KEY,
    definition TEXT NOT NULL,
    lexeme TEXT
);
INSERT INTO mybible_dictionary.dictionary VALUES
    ('G0001', 'Greek definition', NULL),
    ('H0430', 'Hebrew definition', NULL);
DETACH DATABASE mybible_dictionary;

ATTACH DATABASE 'sample.bbl.mybible' AS mysword_bible;
CREATE TABLE mysword_bible.Details (
    Title TEXT,
    Description TEXT,
    Abbreviation TEXT,
    Version TEXT,
    RightToLeft INTEGER,
    Strong INTEGER,
    Language TEXT
);
INSERT INTO mysword_bible.Details VALUES
    ('MySword Bible', 'MySword Bible Fixture', 'MSB', '1.2', 0, 1, 'eng');
CREATE TABLE mysword_bible.Bible (
    Book INTEGER NOT NULL,
    Chapter INTEGER NOT NULL,
    Verse INTEGER NOT NULL,
    Scripture TEXT
);
INSERT INTO mysword_bible.Bible VALUES
    (1, 1, 1, 'Word<WG123><WTN-NSM>'),
    (1, 1, 2, 'Plain verse');
DETACH DATABASE mysword_bible;

ATTACH DATABASE 'sample.cmt.mybible' AS mysword_commentary;
CREATE TABLE mysword_commentary.Details (
    Title TEXT,
    Description TEXT,
    Abbreviation TEXT,
    Version TEXT,
    RightToLeft INTEGER,
    Strong INTEGER,
    Language TEXT
);
INSERT INTO mysword_commentary.Details VALUES
    ('MySword Commentary', 'MySword Commentary Fixture', 'MSC', '2.0', 0, 0, 'eng');
CREATE TABLE mysword_commentary.Commentary (
    Book INTEGER NOT NULL,
    Chapter INTEGER NOT NULL,
    FromVerse INTEGER NOT NULL,
    ToVerse INTEGER,
    Data TEXT NOT NULL
);
INSERT INTO mysword_commentary.Commentary VALUES
    (1, 1, 1, 2, 'Range<CM>'),
    (1, 1, 1, NULL, 'Exact');
DETACH DATABASE mysword_commentary;

ATTACH DATABASE 'sample.dct.mybible' AS mysword_dictionary;
CREATE TABLE mysword_dictionary.Details (
    Title TEXT,
    Description TEXT,
    Abbreviation TEXT,
    Version TEXT,
    RightToLeft INTEGER,
    Strong INTEGER,
    Language TEXT
);
INSERT INTO mysword_dictionary.Details VALUES
    ('MySword Dictionary', 'MySword Dictionary Fixture', 'MSD', '3.0', 1, 1, 'heb');
CREATE TABLE mysword_dictionary.Dictionary (
    Word TEXT PRIMARY KEY,
    Data TEXT NOT NULL
);
INSERT INTO mysword_dictionary.Dictionary VALUES
    ('Elohim', 'term<WH430>'),
    ('Logos', 'word<WG3056>');
DETACH DATABASE mysword_dictionary;

ATTACH DATABASE 'sample.bblx' AS esword_rich;
CREATE TABLE esword_rich.Details (
    Description TEXT,
    Abbreviation TEXT,
    RightToLeft INTEGER,
    Strong INTEGER
);
INSERT INTO esword_rich.Details VALUES ('e-Sword RTF Fixture', 'ESR', 0, 1);
CREATE TABLE esword_rich.Bible (
    Book INTEGER NOT NULL,
    Chapter INTEGER NOT NULL,
    Verse INTEGER NOT NULL,
    Scripture TEXT
);
INSERT INTO esword_rich.Bible VALUES
    (1, 1, 1, '\viewkind4\uc1\cf1\lang1033\f0 In the \b beginning\b0  God created. \cf0\i0\ulnone\nosupersub'),
    (1, 1, 2, '\cf1 a < b & c > d');
DETACH DATABASE esword_rich;

ATTACH DATABASE 'sample.bbli' AS esword_plain;
CREATE TABLE esword_plain.Details (
    Title TEXT,
    Abbreviation TEXT,
    RightToLeft INTEGER,
    Strongs INTEGER
);
INSERT INTO esword_plain.Details VALUES ('e-Sword Plain Fixture', 'ESP', 1, 0);
CREATE TABLE esword_plain.Bible (
    Book INTEGER NOT NULL,
    Chapter INTEGER NOT NULL,
    Verse INTEGER NOT NULL,
    Scripture TEXT
);
INSERT INTO esword_plain.Bible VALUES (1, 1, 1, 'Plain <text> stays unchanged & readable');
DETACH DATABASE esword_plain;

ATTACH DATABASE 'mybible-null-content.SQLite3' AS mybible_null_content;
CREATE TABLE mybible_null_content.info (name TEXT PRIMARY KEY, value TEXT);
INSERT INTO mybible_null_content.info VALUES
    ('description', 'MyBible Nullable Verse Fixture'),
    ('language', 'en');
CREATE TABLE mybible_null_content.books (
    book_number INTEGER PRIMARY KEY,
    display_name TEXT
);
INSERT INTO mybible_null_content.books VALUES (10, 'Malformed optional metadata');
CREATE TABLE mybible_null_content.verses (
    book_number INTEGER NOT NULL,
    chapter INTEGER NOT NULL,
    verse INTEGER NOT NULL,
    text TEXT
);
INSERT INTO mybible_null_content.verses VALUES
    (10, 1, 1, NULL),
    (10, 1, 2, 'First duplicate'),
    (10, 1, 2, 'Second duplicate');
DETACH DATABASE mybible_null_content;

ATTACH DATABASE 'mybible-cross-chapter.SQLite3' AS mybible_cross_chapter;
CREATE TABLE mybible_cross_chapter.info (name TEXT PRIMARY KEY, value TEXT);
INSERT INTO mybible_cross_chapter.info VALUES
    ('description', 'MyBible Cross Chapter Fixture'),
    ('language', 'en');
CREATE TABLE mybible_cross_chapter.commentaries (
    book_number INTEGER NOT NULL,
    chapter_number_from INTEGER NOT NULL,
    verse_number_from INTEGER NOT NULL,
    chapter_number_to INTEGER,
    verse_number_to INTEGER,
    text TEXT NOT NULL
);
INSERT INTO mybible_cross_chapter.commentaries VALUES
    (10, 1, 31, 2, 2, 'Across chapters'),
    (10, 2, 1, NULL, NULL, 'Exact at chapter start'),
    (10, 2, 2, 2, 3, 'Second range');
DETACH DATABASE mybible_cross_chapter;

ATTACH DATABASE 'esword-numeric-storage.bblx' AS esword_numeric_storage;
CREATE TABLE esword_numeric_storage.Details (
    Description TEXT,
    Abbreviation TEXT,
    Version REAL,
    RightToLeft REAL,
    Strong REAL
);
INSERT INTO esword_numeric_storage.Details VALUES
    ('e-Sword Numeric Storage Fixture', 'ESN', 1.5, 1.0, 1.0);
CREATE TABLE esword_numeric_storage.Bible (
    Book INTEGER NOT NULL,
    Chapter INTEGER NOT NULL,
    Verse INTEGER NOT NULL,
    Scripture TEXT
);
INSERT INTO esword_numeric_storage.Bible VALUES
    (1, 1, 1, NULL),
    (
        1,
        1,
        2,
        char(92) || char(39) || '3c' ||
        char(92) || char(39) || '3e' ||
        char(92) || char(39) || '26'
    ),
    (1, 1, 3, '\u60?\u62?\u38?');
DETACH DATABASE esword_numeric_storage;

ATTACH DATABASE 'invalid-mybible-missing-info.SQLite3' AS invalid_mybible;
CREATE TABLE invalid_mybible.verses (
    book_number INTEGER,
    chapter INTEGER,
    verse INTEGER,
    text TEXT
);
INSERT INTO invalid_mybible.verses VALUES (10, 1, 1, 'Missing info');
DETACH DATABASE invalid_mybible;

ATTACH DATABASE 'mysword-lazy-missing-scripture.bbl.mybible' AS lazy_mysword_content;
CREATE TABLE lazy_mysword_content.Details (Description TEXT);
INSERT INTO lazy_mysword_content.Details VALUES ('Invalid MySword');
CREATE TABLE lazy_mysword_content.Bible (
    Book INTEGER,
    Chapter INTEGER,
    Verse INTEGER,
    Text TEXT
);
INSERT INTO lazy_mysword_content.Bible VALUES (1, 1, 1, 'Wrong content column');
DETACH DATABASE lazy_mysword_content;

ATTACH DATABASE 'esword-multiple-details-first-row.bblx' AS multiple_esword_details;
CREATE TABLE multiple_esword_details.Details (Description TEXT);
INSERT INTO multiple_esword_details.Details VALUES ('First'), ('Second');
CREATE TABLE multiple_esword_details.Bible (
    Book INTEGER,
    Chapter INTEGER,
    Verse INTEGER,
    Scripture TEXT
);
INSERT INTO multiple_esword_details.Bible VALUES (1, 1, 1, 'First metadata row wins');
DETACH DATABASE multiple_esword_details;
