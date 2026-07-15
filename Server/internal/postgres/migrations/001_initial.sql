CREATE TABLE accounts (
    id uuid PRIMARY KEY,
    email text NOT NULL UNIQUE,
    password_hash text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE devices (
    id uuid PRIMARY KEY,
    owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_id, id)
);

CREATE TABLE sessions (
    id uuid PRIMARY KEY,
    owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    device_id uuid NOT NULL,
    refresh_token_hash bytea NOT NULL,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    rotated_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    FOREIGN KEY (owner_id, device_id) REFERENCES devices(owner_id, id) ON DELETE CASCADE
);

CREATE INDEX sessions_owner_id_idx ON sessions(owner_id);

CREATE TABLE collections (
    id uuid PRIMARY KEY,
    owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    name text NOT NULL,
    position_key text NOT NULL,
    show_in_menu boolean NOT NULL DEFAULT false,
    field_versions jsonb NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    deleted_at timestamptz,
    UNIQUE (owner_id, id)
);

CREATE INDEX collections_owner_position_idx
    ON collections(owner_id, position_key)
    WHERE deleted_at IS NULL;

CREATE TABLE bookmarks (
    id uuid PRIMARY KEY,
    owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    collection_id uuid,
    title text NOT NULL,
    url text NOT NULL,
    title_optimized boolean NOT NULL DEFAULT false,
    is_hidden boolean NOT NULL DEFAULT false,
    archived_at timestamptz,
    is_pinned boolean NOT NULL DEFAULT false,
    original_title text,
    position_key text NOT NULL,
    field_versions jsonb NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    deleted_at timestamptz,
    UNIQUE (owner_id, id),
    FOREIGN KEY (owner_id, collection_id) REFERENCES collections(owner_id, id)
);

CREATE INDEX bookmarks_owner_position_idx
    ON bookmarks(owner_id, position_key)
    WHERE deleted_at IS NULL;

CREATE INDEX bookmarks_owner_collection_idx
    ON bookmarks(owner_id, collection_id)
    WHERE deleted_at IS NULL;

CREATE TABLE usage_events (
    id uuid PRIMARY KEY,
    owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    bookmark_id uuid NOT NULL,
    device_id uuid NOT NULL,
    occurred_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_id, bookmark_id) REFERENCES bookmarks(owner_id, id),
    FOREIGN KEY (owner_id, device_id) REFERENCES devices(owner_id, id)
);

CREATE INDEX usage_events_owner_bookmark_idx
    ON usage_events(owner_id, bookmark_id, occurred_at DESC);

CREATE TABLE browser_history_events (
    id uuid PRIMARY KEY,
    owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    source_device_id uuid NOT NULL,
    browser text NOT NULL CHECK (browser IN ('dia', 'chrome', 'safari')),
    profile_name text NOT NULL,
    title text NOT NULL,
    url text NOT NULL,
    visited_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_id, source_device_id) REFERENCES devices(owner_id, id)
);

CREATE INDEX browser_history_events_owner_visited_idx
    ON browser_history_events(owner_id, visited_at DESC);

CREATE TABLE browser_history_settings (
    id uuid NOT NULL,
    owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    enabled_sources text NOT NULL CHECK (
        enabled_sources IN (
            '', 'dia', 'chrome', 'safari', 'dia,chrome', 'dia,safari',
            'chrome,safari', 'dia,chrome,safari'
        )
    ),
    field_versions jsonb NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    PRIMARY KEY (owner_id, id)
);

CREATE TABLE applied_mutations (
    owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    device_id uuid NOT NULL,
    mutation_id uuid NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_id, device_id, mutation_id),
    FOREIGN KEY (owner_id, device_id) REFERENCES devices(owner_id, id)
);

CREATE TABLE schema_version (
    version integer PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO schema_version(version) VALUES (4);

CREATE PUBLICATION powersync
    FOR TABLE collections, bookmarks, usage_events, browser_history_events, browser_history_settings;
