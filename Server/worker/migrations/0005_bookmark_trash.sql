-- Republish existing rows with a baseline HLC for the new nullable field
CREATE TABLE _migration_0005_state (base_seq INTEGER NOT NULL, bookmark_count INTEGER NOT NULL);
INSERT INTO _migration_0005_state
SELECT seq, (SELECT COUNT(*) FROM bookmarks) FROM sync_meta WHERE id = 1;
ALTER TABLE bookmarks ADD COLUMN trashed_at TEXT;
UPDATE bookmarks SET
    field_versions = json_set(field_versions, '$.trashed_at',
        json('{"milliseconds":0,"counter":0,"deviceID":"00000000-0000-0000-0000-000000000000"}')),
    seq = (SELECT base_seq FROM _migration_0005_state)
        + (SELECT COUNT(*) FROM bookmarks AS ordered WHERE ordered.id <= bookmarks.id);
UPDATE sync_meta SET seq = (SELECT base_seq + bookmark_count FROM _migration_0005_state) WHERE id = 1;
DROP TABLE _migration_0005_state;
