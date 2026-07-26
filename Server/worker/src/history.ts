// PUT /v1/browser-history — device-scoped set reconciliation. The client
// sends the complete desired set of history rows for one device; the server
// converges its copy, writing tombstones for rows other devices must drop.
// Replaying the same set is a no-op.

import { bumpSeq, currentCursor, isoNow, jsonError } from "./push";
import {
  requiredBrowser,
  requiredString,
  requiredTime,
  requiredUUIDString,
  requiredWebURL,
  ValidationError,
} from "./validate";

const maximumRecords = 2000;
const retentionDays = 30;
const tombstoneRetentionDays = 45;

interface HistoryRecord {
  id: string;
  browser: string;
  profileName: string;
  title: string;
  url: string;
  visitedAt: string;
  createdAt: string;
}

export async function handleHistoryReconcile(request: Request, db: D1Database): Promise<Response> {
  let body: { deviceId?: unknown; records?: unknown };
  try {
    body = await request.json();
  } catch {
    return jsonError(400, "request body must be JSON");
  }

  let deviceID: string;
  let records: HistoryRecord[];
  try {
    deviceID = requiredUUIDString(body.deviceId) as string;
    if (!Array.isArray(body.records) || body.records.length > maximumRecords) {
      throw new ValidationError(`records must contain 0 to ${maximumRecords} entries`);
    }
    records = body.records.map(parseRecord);
  } catch (error) {
    if (error instanceof ValidationError) {
      return jsonError(400, error.message);
    }
    throw error;
  }

  const cutoff = new Date(Date.now() - retentionDays * 86_400_000).toISOString();
  const desired = new Map<string, HistoryRecord>();
  for (const record of records) {
    if (record.visitedAt >= cutoff && !desired.has(record.id)) {
      desired.set(record.id, record);
    }
  }

  const existingRows = await db
    .prepare(
      `SELECT id, browser, profile_name, title, url, visited_at
       FROM browser_history_events WHERE source_device_id = ?`
    )
    .bind(deviceID)
    .all<Record<string, unknown>>();
  const existing = new Map(
    (existingRows.results ?? []).map((row) => [row.id as string, row])
  );

  const statements: D1PreparedStatement[] = [];
  const now = isoNow();

  for (const [id] of existing) {
    if (!desired.has(id)) {
      statements.push(
        bumpSeq(db),
        db
          .prepare(
            `INSERT INTO browser_history_tombstones (id, deleted_at, seq)
             VALUES (?, ?, (SELECT seq FROM sync_meta WHERE id = 1))
             ON CONFLICT (id) DO UPDATE SET deleted_at = excluded.deleted_at, seq = excluded.seq`
          )
          .bind(id, now),
        db.prepare("DELETE FROM browser_history_events WHERE id = ?").bind(id)
      );
    }
  }

  for (const [id, record] of desired) {
    const stored = existing.get(id);
    if (stored !== undefined && recordMatchesStored(record, stored)) {
      continue;
    }
    statements.push(
      bumpSeq(db),
      db
        .prepare(
          `INSERT INTO browser_history_events (
             id, source_device_id, browser, profile_name, title, url, visited_at, created_at, seq
           ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, (SELECT seq FROM sync_meta WHERE id = 1))
           ON CONFLICT (id) DO UPDATE SET
             browser = excluded.browser,
             profile_name = excluded.profile_name,
             title = excluded.title,
             url = excluded.url,
             visited_at = excluded.visited_at,
             seq = excluded.seq
           WHERE browser_history_events.source_device_id = excluded.source_device_id`
        )
        .bind(
          id,
          deviceID,
          record.browser,
          record.profileName,
          record.title,
          record.url,
          record.visitedAt,
          record.createdAt,
        ),
      db.prepare("DELETE FROM browser_history_tombstones WHERE id = ?").bind(id)
    );
  }

  // Server-side retention: expired rows disappear without tombstones because
  // every client filters by the same cutoff locally.
  statements.push(
    db.prepare("DELETE FROM browser_history_events WHERE visited_at < ?").bind(cutoff),
    db
      .prepare("DELETE FROM browser_history_tombstones WHERE deleted_at < ?")
      .bind(new Date(Date.now() - tombstoneRetentionDays * 86_400_000).toISOString())
  );

  for (let offset = 0; offset < statements.length; offset += 90) {
    await db.batch(statements.slice(offset, offset + 90));
  }

  return Response.json({ cursor: await currentCursor(db) });
}

function parseRecord(raw: unknown): HistoryRecord {
  if (typeof raw !== "object" || raw === null) {
    throw new ValidationError("record must be an object");
  }
  const record = raw as Record<string, unknown>;
  const visitedAt = requiredTime(record.visitedAt) as string;
  return {
    id: requiredUUIDString(record.id) as string,
    browser: requiredBrowser(record.browser) as string,
    profileName: requiredString(record.profileName) as string,
    title: requiredString(record.title) as string,
    url: requiredWebURL(record.url) as string,
    visitedAt,
    createdAt:
      record.createdAt === undefined ? visitedAt : (requiredTime(record.createdAt) as string),
  };
}

function recordMatchesStored(record: HistoryRecord, stored: Record<string, unknown>): boolean {
  return (
    stored.browser === record.browser &&
    stored.profile_name === record.profileName &&
    stored.title === record.title &&
    stored.url === record.url &&
    stored.visited_at === record.visitedAt
  );
}
