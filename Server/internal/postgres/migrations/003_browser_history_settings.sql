CREATE TABLE browser_history_settings (
    id uuid NOT NULL,
    owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    enabled_sources text NOT NULL,
    field_versions jsonb NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    PRIMARY KEY (owner_id, id)
);

ALTER PUBLICATION powersync ADD TABLE browser_history_settings;

UPDATE schema_version SET version = 3 WHERE version = 2;
