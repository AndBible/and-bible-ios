# CLAUDE.md - BibleCore

## Module Purpose
Shared business logic and data persistence layer. Contains domain models
(SwiftData), database stores, and service classes used by all other modules.

## Architecture
```
BibleCore
  ├── Models/       # SwiftData @Model classes + value types
  ├── Database/     # Store classes (CRUD operations)
  ├── Services/     # Business logic services
  └── Formats/      # Non-SWORD format readers (MySword, MyBible, EPUB)
```

## Key Patterns

### SwiftData Models
- All entities use `UUID` primary keys (matching Android's IdType)
- Settings use inheritance chain: Window → Workspace → App defaults
- Use `@Model` for persisted types, plain structs for value types
- Relationships use SwiftData `@Relationship` with cascade delete rules

### Database Stores
Each store wraps SwiftData ModelContext operations for a domain:
- `BookmarkStore`: Bible + Generic bookmarks, labels, StudyPad entries
- `WorkspaceStore`: Workspaces, windows, page managers, history
- `ReadingPlanStore`: Reading plans and daily progress
- `RepoStore`: Module repository metadata
- `SettingsStore`: App-level settings (key-value)

### Services
Services contain business logic and coordinate between stores and SwordKit:
- `BookmarkService`: Bookmark CRUD, label management, StudyPad operations
- `WindowManager`: Window lifecycle, split-screen layout, sync groups
- `NavigationService`: Book/chapter/verse navigation, history stack
- `SearchService`: Full-text search via SwordKit, result formatting
- `DownloadService`: Module download/install orchestration
- `SpeakService`: TTS integration via AVSpeechSynthesizer
- `BackupService`: Export/import app data
- `SyncService`: iCloud/CloudKit sync

### Format Readers
- `MySwordReader`: Reads MySword .bbl/.cmt/.dct SQLite files
- `MyBibleReader`: Reads MyBible .SQLite3 files
- `EpubReader`: Reads .epub files with SQLite index

## Testing
```bash
swift test --filter BibleCoreTests
```

## Reference (Android equivalents)
- Models: `WorkspaceEntities.kt`, `BookmarkEntities.kt`
- Database: `DatabaseContainer.kt`, DAOs
- BookmarkService: `BookmarkControl.kt`
- WindowManager: `WindowRepository.kt`, `WindowControl.kt`
- Formats: `app/src/main/java/net/bible/service/sword/mysword/`, `mybible/`, `epub/`
