// GET /v1/changes?since=N — cursor-based incremental download, tombstones
// included. Rows may be re-sent across pages; the client merge is idempotent.

import { currentCursor, jsonError } from "./push";

const pageLimit = 1000;

const rowQueries: Record<string, string> = {
  collections: `SELECT id, name, position_key, show_in_menu, field_versions, created_at, updated_at, deleted_at, seq
       FROM collections WHERE seq > ? ORDER BY seq LIMIT ${pageLimit}`,
  bookmarks: `SELECT id, collection_id, title, url, title_optimized, is_hidden, archived_at, is_pinned,
       original_title, position_key, field_versions, created_at, updated_at, deleted_at, seq
       FROM bookmarks WHERE seq > ? ORDER BY seq LIMIT ${pageLimit}`,
  usage_events: `SELECT id, bookmark_id, device_id, occurred_at, created_at, seq
       FROM usage_events WHERE seq > ? ORDER BY seq LIMIT ${pageLimit}`,
  browser_history_events: `SELECT id, source_device_id, browser, profile_name, title, url, visited_at, created_at, seq
       FROM browser_history_events WHERE seq > ? ORDER BY seq LIMIT ${pageLimit}`,
  browser_history_tombstones: `SELECT id, deleted_at, seq
       FROM browser_history_tombstones WHERE seq > ? ORDER BY seq LIMIT ${pageLimit}`,
  browser_history_settings: `SELECT id, enabled_sources, field_versions, created_at, updated_at, seq
       FROM browser_history_settings WHERE seq > ? ORDER BY seq LIMIT ${pageLimit}`,
};

export async function handleChanges(request: Request, db: D1Database): Promise<Response> {
  const sinceRaw = new URL(request.url).searchParams.get("since") ?? "0";
  const since = Number(sinceRaw);
  if (!Number.isSafeInteger(since) || since < 0) {
    return jsonError(400, "since must be a non-negative integer");
  }

  const tables = Object.keys(rowQueries);
  const outcomes = await db.batch(
    tables.map((table) => db.prepare(rowQueries[table]).bind(since))
  );

  const rowsByTable = new Map<string, Record<string, unknown>[]>();
  let hasMore = false;
  let limitedCursor = Number.MAX_SAFE_INTEGER;
  for (const [index, table] of tables.entries()) {
    const rows = (outcomes[index].results ?? []) as Record<string, unknown>[];
    rowsByTable.set(table, rows);
    if (rows.length === pageLimit) {
      hasMore = true;
      limitedCursor = Math.min(limitedCursor, rows[rows.length - 1].seq as number);
    }
  }

  const cursor = hasMore ? limitedCursor : await currentCursor(db);

  return Response.json({
    cursor,
    hasMore,
    collections: (rowsByTable.get("collections") ?? []).map(decodeVersioned),
    bookmarks: (rowsByTable.get("bookmarks") ?? []).map(decodeVersioned),
    usageEvents: (rowsByTable.get("usage_events") ?? []).map(stripSeq),
    browserHistoryEvents: (rowsByTable.get("browser_history_events") ?? []).map(stripSeq),
    browserHistoryDeletions: (rowsByTable.get("browser_history_tombstones") ?? []).map(
      (row) => row.id as string
    ),
    browserHistorySettings: (rowsByTable.get("browser_history_settings") ?? []).map(decodeVersioned),
  });
}

function decodeVersioned(row: Record<string, unknown>): Record<string, unknown> {
  const output = stripSeq(row);
  output.fieldVersions = JSON.parse(row.field_versions as string);
  delete output.field_versions;
  return output;
}

function stripSeq(row: Record<string, unknown>): Record<string, unknown> {
  const output = { ...row };
  delete output.seq;
  return output;
}
