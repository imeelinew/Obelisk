-- Give every collection a synchronized sidebar color and publish every
-- migrated row above the current cursor

CREATE TABLE _migration_0004_state (
    base_seq INTEGER NOT NULL,
    collection_count INTEGER NOT NULL
);

INSERT INTO _migration_0004_state (base_seq, collection_count)
SELECT seq, (SELECT COUNT(*) FROM collections)
FROM sync_meta
WHERE id = 1;

ALTER TABLE collections
ADD COLUMN color TEXT NOT NULL DEFAULT 'blue';

UPDATE collections
SET
    field_versions = json_set(
        field_versions,
        '$.color',
        json('{"milliseconds":1789344000000,"counter":0,"deviceID":"00000000-0000-0000-0000-000000000001"}')
    ),
    updated_at = '2026-09-14T00:00:00.000Z',
    seq = (
        SELECT base_seq FROM _migration_0004_state
    ) + (
        SELECT COUNT(*)
        FROM collections AS ordered
        WHERE ordered.id <= collections.id
    );

UPDATE sync_meta
SET seq = (
    SELECT base_seq + collection_count
    FROM _migration_0004_state
)
WHERE id = 1;

DROP TABLE _migration_0004_state;
