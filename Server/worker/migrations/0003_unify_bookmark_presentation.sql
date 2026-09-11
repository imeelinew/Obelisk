-- Replace pinning with a normal Common collection and make title optimization
-- state explicit. Every migrated row receives a fresh sequence so clients
-- with an existing cursor download the canonical post-migration state.

CREATE TABLE _migration_0003_state (
    base_seq INTEGER NOT NULL,
    common_id TEXT NOT NULL,
    has_pinned INTEGER NOT NULL DEFAULT 0,
    collection_count INTEGER NOT NULL DEFAULT 0,
    bookmark_count INTEGER NOT NULL DEFAULT 0
);

INSERT INTO _migration_0003_state (base_seq, common_id, has_pinned)
SELECT
    seq,
    COALESCE(
        (
            SELECT id FROM collections
            WHERE deleted_at IS NULL AND name = '常用' COLLATE NOCASE
            ORDER BY created_at, id
            LIMIT 1
        ),
        '65b1a579-07c4-4f0c-97ee-3dd4af479cc3'
    ),
    EXISTS(SELECT 1 FROM bookmarks WHERE is_pinned = 1 AND deleted_at IS NULL)
FROM sync_meta
WHERE id = 1;

INSERT INTO collections (
    id, name, position_key, show_in_menu, field_versions,
    created_at, updated_at, deleted_at, seq
)
SELECT
    common_id,
    '常用',
    '00000000000000000000',
    0,
    '{"name":{"milliseconds":1789112631000,"counter":0,"deviceID":"00000000-0000-0000-0000-000000000001"},"position_key":{"milliseconds":1789112631000,"counter":0,"deviceID":"00000000-0000-0000-0000-000000000001"},"show_in_menu":{"milliseconds":1789112631000,"counter":0,"deviceID":"00000000-0000-0000-0000-000000000001"},"deleted_at":{"milliseconds":1789112631000,"counter":0,"deviceID":"00000000-0000-0000-0000-000000000001"}}',
    '2026-09-11T07:43:51.000Z',
    '2026-09-11T07:43:51.000Z',
    NULL,
    base_seq
FROM _migration_0003_state
WHERE has_pinned = 1
  AND NOT EXISTS (
    SELECT 1 FROM collections
    WHERE deleted_at IS NULL AND name = '常用' COLLATE NOCASE
);

UPDATE _migration_0003_state
SET collection_count = (SELECT COUNT(*) FROM collections),
    bookmark_count = (SELECT COUNT(*) FROM bookmarks);

CREATE TABLE collections_next (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    position_key TEXT NOT NULL,
    field_versions TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    seq INTEGER NOT NULL
);

INSERT INTO collections_next (
    id, name, position_key, field_versions,
    created_at, updated_at, deleted_at, seq
)
SELECT
    c.id,
    c.name,
    CASE
        WHEN c.deleted_at IS NOT NULL THEN c.position_key
        ELSE printf('%020d', (
            SELECT COUNT(*)
            FROM collections AS earlier
            WHERE earlier.deleted_at IS NULL
              AND (
                CASE WHEN earlier.id = (SELECT common_id FROM _migration_0003_state) THEN 0 ELSE 1 END
                    < CASE WHEN c.id = (SELECT common_id FROM _migration_0003_state) THEN 0 ELSE 1 END
                OR (
                    CASE WHEN earlier.id = (SELECT common_id FROM _migration_0003_state) THEN 0 ELSE 1 END
                        = CASE WHEN c.id = (SELECT common_id FROM _migration_0003_state) THEN 0 ELSE 1 END
                    AND (earlier.position_key < c.position_key OR (earlier.position_key = c.position_key AND earlier.id < c.id))
                )
              )
        ))
    END,
    json_remove(
        json_set(
            c.field_versions,
            '$.position_key',
            json('{"milliseconds":1789112631000,"counter":0,"deviceID":"00000000-0000-0000-0000-000000000001"}')
        ),
        '$.show_in_menu'
    ),
    c.created_at,
    c.updated_at,
    c.deleted_at,
    (SELECT base_seq FROM _migration_0003_state) + ROW_NUMBER() OVER (
        ORDER BY
            CASE WHEN id = (SELECT common_id FROM _migration_0003_state) THEN 0 ELSE 1 END,
            position_key,
            id
    )
FROM collections AS c;

CREATE TABLE bookmarks_next (
    id TEXT PRIMARY KEY,
    collection_id TEXT,
    title TEXT NOT NULL,
    url TEXT NOT NULL,
    title_optimization_state TEXT NOT NULL,
    is_hidden INTEGER NOT NULL,
    archived_at TEXT,
    original_title TEXT,
    position_key TEXT NOT NULL,
    field_versions TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    seq INTEGER NOT NULL
);

INSERT INTO bookmarks_next (
    id, collection_id, title, url, title_optimization_state,
    is_hidden, archived_at, original_title, position_key,
    field_versions, created_at, updated_at, deleted_at, seq
)
SELECT
    id,
    CASE
        WHEN is_pinned = 1 AND deleted_at IS NULL THEN (SELECT common_id FROM _migration_0003_state)
        ELSE collection_id
    END,
    title,
    url,
    CASE WHEN title_optimized = 1 THEN 'succeeded' ELSE 'not_attempted' END,
    is_hidden,
    archived_at,
    original_title,
    position_key,
    json_remove(
        json_remove(
            CASE
                WHEN is_pinned = 1 AND deleted_at IS NULL THEN json_set(
                    json_set(
                        field_versions,
                        '$.title_optimization_state',
                        json(COALESCE(
                            json_extract(field_versions, '$.title_optimized'),
                            '{"milliseconds":1789112631000,"counter":0,"deviceID":"00000000-0000-0000-0000-000000000001"}'
                        ))
                    ),
                    '$.collection_id',
                    json('{"milliseconds":1789112631000,"counter":0,"deviceID":"00000000-0000-0000-0000-000000000001"}')
                )
                ELSE json_set(
                    field_versions,
                    '$.title_optimization_state',
                    json(COALESCE(
                        json_extract(field_versions, '$.title_optimized'),
                        '{"milliseconds":1789112631000,"counter":0,"deviceID":"00000000-0000-0000-0000-000000000001"}'
                    ))
                )
            END,
            '$.title_optimized'
        ),
        '$.is_pinned'
    ),
    created_at,
    updated_at,
    deleted_at,
    (SELECT base_seq + collection_count FROM _migration_0003_state) + ROW_NUMBER() OVER (
        ORDER BY seq, id
    )
FROM bookmarks;

DROP TABLE bookmarks;
ALTER TABLE bookmarks_next RENAME TO bookmarks;
CREATE INDEX bookmarks_seq ON bookmarks (seq);

DROP TABLE collections;
ALTER TABLE collections_next RENAME TO collections;
CREATE INDEX collections_seq ON collections (seq);

UPDATE sync_meta
SET seq = (
    SELECT base_seq + collection_count + bookmark_count
    FROM _migration_0003_state
)
WHERE id = 1;

DROP TABLE _migration_0003_state;
