-- Retire history without resetting sync_meta.seq or renumbering surviving rows.
-- Existing clients retain their cursors, including cursors last advanced by history.
DROP TABLE IF EXISTS browser_history_events;
DROP TABLE IF EXISTS browser_history_tombstones;
DROP TABLE IF EXISTS browser_history_settings;
