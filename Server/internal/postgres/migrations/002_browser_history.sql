CREATE TABLE browser_history_events (
    id uuid PRIMARY KEY,
    owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    source_device_id uuid NOT NULL,
    browser text NOT NULL,
    profile_name text NOT NULL,
    title text NOT NULL,
    url text NOT NULL,
    visited_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_id, source_device_id) REFERENCES devices(owner_id, id)
);

CREATE INDEX browser_history_events_owner_visited_idx
    ON browser_history_events(owner_id, visited_at DESC);

ALTER PUBLICATION powersync ADD TABLE browser_history_events;

UPDATE schema_version SET version = 2 WHERE version = 1;
