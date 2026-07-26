-- Obelisk sync schema. One private account per deployment; identity is the
-- bearer access key, so rows carry no owner column.

CREATE TABLE sync_meta (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    seq INTEGER NOT NULL
);
INSERT INTO sync_meta (id, seq) VALUES (1, 0);

CREATE TABLE collections (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    position_key TEXT NOT NULL,
    show_in_menu INTEGER NOT NULL,
    field_versions TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    seq INTEGER NOT NULL
);
CREATE INDEX collections_seq ON collections (seq);

CREATE TABLE bookmarks (
    id TEXT PRIMARY KEY,
    collection_id TEXT,
    title TEXT NOT NULL,
    url TEXT NOT NULL,
    title_optimized INTEGER NOT NULL,
    is_hidden INTEGER NOT NULL,
    archived_at TEXT,
    is_pinned INTEGER NOT NULL,
    original_title TEXT,
    position_key TEXT NOT NULL,
    field_versions TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    seq INTEGER NOT NULL
);
CREATE INDEX bookmarks_seq ON bookmarks (seq);

CREATE TABLE usage_events (
    id TEXT PRIMARY KEY,
    bookmark_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    occurred_at TEXT NOT NULL,
    created_at TEXT NOT NULL,
    seq INTEGER NOT NULL
);
CREATE INDEX usage_events_seq ON usage_events (seq);

CREATE TABLE browser_history_events (
    id TEXT PRIMARY KEY,
    source_device_id TEXT NOT NULL,
    browser TEXT NOT NULL,
    profile_name TEXT NOT NULL,
    title TEXT NOT NULL,
    url TEXT NOT NULL,
    visited_at TEXT NOT NULL,
    created_at TEXT NOT NULL,
    seq INTEGER NOT NULL
);
CREATE INDEX browser_history_events_seq ON browser_history_events (seq);
CREATE INDEX browser_history_events_device ON browser_history_events (source_device_id);

CREATE TABLE browser_history_tombstones (
    id TEXT PRIMARY KEY,
    deleted_at TEXT NOT NULL,
    seq INTEGER NOT NULL
);
CREATE INDEX browser_history_tombstones_seq ON browser_history_tombstones (seq);

CREATE TABLE browser_history_settings (
    id TEXT PRIMARY KEY,
    enabled_sources TEXT NOT NULL,
    field_versions TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    seq INTEGER NOT NULL
);
CREATE INDEX browser_history_settings_seq ON browser_history_settings (seq);
