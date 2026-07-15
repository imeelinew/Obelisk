DELETE FROM browser_history_events
WHERE browser NOT IN ('dia', 'chrome', 'safari');

UPDATE browser_history_settings
SET enabled_sources = concat_ws(
    ',',
    CASE WHEN 'dia' = ANY(string_to_array(enabled_sources, ',')) THEN 'dia' END,
    CASE WHEN 'chrome' = ANY(string_to_array(enabled_sources, ',')) THEN 'chrome' END,
    CASE WHEN 'safari' = ANY(string_to_array(enabled_sources, ',')) THEN 'safari' END
);

ALTER TABLE browser_history_events
    ADD CONSTRAINT browser_history_events_browser_check
    CHECK (browser IN ('dia', 'chrome', 'safari'));

ALTER TABLE browser_history_settings
    ADD CONSTRAINT browser_history_settings_enabled_sources_check
    CHECK (
        enabled_sources IN (
            '', 'dia', 'chrome', 'safari', 'dia,chrome', 'dia,safari',
            'chrome,safari', 'dia,chrome,safari'
        )
    );

UPDATE schema_version SET version = 4 WHERE version = 3;
