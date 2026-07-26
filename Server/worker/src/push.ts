// POST /v1/push — state-based upload. Every row is merged independently and
// idempotently; a rejected row never blocks the rest of the batch.

import { parseStoredVersions } from "./hlc";
import {
  enforceBookmarkInvariants,
  insertRow,
  mergeRow,
  parseIncomingRow,
  versionedTables,
  type IncomingRow,
  type VersionedTable,
} from "./merge";
import {
  requiredTime,
  requiredUUIDString,
  ValidationError,
  type ColumnValue,
} from "./validate";

const maximumRows = 500;
const maximumWriteAttempts = 3;

interface PushRowRequest {
  table: string;
  id: string;
  values: unknown;
  fieldVersions?: unknown;
}

export interface PushRowResult {
  table: string;
  id: string;
  status: "applied" | "rejected";
  error?: string;
}

export async function handlePush(request: Request, db: D1Database): Promise<Response> {
  let body: { rows?: unknown };
  try {
    body = await request.json();
  } catch {
    return jsonError(400, "request body must be JSON");
  }
  if (!Array.isArray(body.rows) || body.rows.length === 0 || body.rows.length > maximumRows) {
    return jsonError(400, `rows must contain 1 to ${maximumRows} entries`);
  }

  const results: PushRowResult[] = [];
  for (const raw of body.rows as PushRowRequest[]) {
    const table = typeof raw?.table === "string" ? raw.table : "";
    const id = typeof raw?.id === "string" ? raw.id.toLowerCase() : "";
    try {
      requiredUUIDString(raw?.id);
      if (table === "usage_events") {
        await applyUsageEvent(db, id, raw.values);
      } else if (table in versionedTables) {
        const spec = versionedTables[table];
        const incoming = parseIncomingRow(spec, raw.values, raw.fieldVersions);
        await applyVersionedRow(db, spec, id, incoming);
      } else {
        throw new ValidationError(`unsupported table ${table}`);
      }
      results.push({ table, id, status: "applied" });
    } catch (error) {
      if (error instanceof ValidationError) {
        results.push({ table, id, status: "rejected", error: error.message });
      } else {
        throw error;
      }
    }
  }

  const cursor = await currentCursor(db);
  return Response.json({ results, cursor });
}

async function applyUsageEvent(db: D1Database, id: string, values: unknown): Promise<void> {
  if (typeof values !== "object" || values === null) {
    throw new ValidationError("values must be an object");
  }
  const raw = values as Record<string, unknown>;
  const bookmarkID = requiredUUIDString(raw.bookmark_id);
  const deviceID = requiredUUIDString(raw.device_id);
  const occurredAt = requiredTime(raw.occurred_at);
  const createdAt = raw.created_at === undefined ? occurredAt : requiredTime(raw.created_at);

  const existing = await db
    .prepare("SELECT id FROM usage_events WHERE id = ?")
    .bind(id)
    .first();
  if (existing !== null) {
    return;
  }
  await db.batch([
    bumpSeq(db),
    db
      .prepare(
        `INSERT INTO usage_events (id, bookmark_id, device_id, occurred_at, created_at, seq)
         VALUES (?, ?, ?, ?, ?, (SELECT seq FROM sync_meta WHERE id = 1))
         ON CONFLICT (id) DO NOTHING`
      )
      .bind(id, bookmarkID, deviceID, occurredAt, createdAt),
  ]);
}

async function applyVersionedRow(
  db: D1Database,
  table: VersionedTable,
  id: string,
  incoming: IncomingRow
): Promise<void> {
  for (let attempt = 0; attempt < maximumWriteAttempts; attempt += 1) {
    const stored = await db
      .prepare(`SELECT * FROM ${table.name} WHERE id = ?`)
      .bind(id)
      .first<Record<string, unknown>>();

    if (stored === null) {
      if (await insertVersionedRow(db, table, id, incoming)) {
        return;
      }
      continue;
    }
    if (await updateVersionedRow(db, table, id, incoming, stored)) {
      return;
    }
  }
  throw new Error(`could not apply ${table.name} row ${id} after retries`);
}

async function insertVersionedRow(
  db: D1Database,
  table: VersionedTable,
  id: string,
  incoming: IncomingRow
): Promise<boolean> {
  let { columns, encodedVersions } = insertRow(table, incoming);
  if (table.name === "bookmarks") {
    const adjusted = enforceBookmarkInvariants(
      columns,
      { is_hidden: 0, archived_at: null, deleted_at: null, is_pinned: 0 },
      incoming.versions
    );
    if (adjusted !== null) {
      columns = adjusted.columns;
      encodedVersions = adjusted.encodedVersions;
    }
  }

  const createdAt =
    typeof incoming.values.created_at === "string" ? incoming.values.created_at : isoNow();
  const names = [...columns.keys()];
  const statement = `INSERT INTO ${table.name} (${["id", ...names, "field_versions", "created_at", "updated_at", "seq"].join(", ")})
     VALUES (${["?", ...names.map(() => "?"), "?", "?", "?", "(SELECT seq FROM sync_meta WHERE id = 1)"].join(", ")})
     ON CONFLICT (id) DO NOTHING`;
  const outcome = await db.batch([
    bumpSeq(db),
    db
      .prepare(statement)
      .bind(id, ...names.map((name) => columns.get(name) as ColumnValue), encodedVersions, createdAt, isoNow()),
  ]);
  return (outcome[1].meta.changes ?? 0) > 0;
}

async function updateVersionedRow(
  db: D1Database,
  table: VersionedTable,
  id: string,
  incoming: IncomingRow,
  stored: Record<string, unknown>
): Promise<boolean> {
  const storedVersionsText = stored.field_versions as string;
  const currentVersions = parseStoredVersions(storedVersionsText);
  const merged = mergeRow(table, incoming, currentVersions);
  if (!merged.changed) {
    return true;
  }
  let columns = merged.columns;
  let encodedVersions = merged.encodedVersions;

  if (table.name === "bookmarks") {
    const adjusted = enforceBookmarkInvariants(
      columns,
      {
        is_hidden: stored.is_hidden as number,
        archived_at: stored.archived_at as string | null,
        deleted_at: stored.deleted_at as string | null,
        is_pinned: stored.is_pinned as number,
      },
      parseStoredVersions(encodedVersions)
    );
    if (adjusted !== null) {
      columns = adjusted.columns;
      encodedVersions = adjusted.encodedVersions;
    }
  }

  const names = [...columns.keys()];
  const sets = [
    ...names.map((name) => `${name} = ?`),
    "field_versions = ?",
    "updated_at = ?",
    "seq = (SELECT seq FROM sync_meta WHERE id = 1)",
  ];
  const statement = `UPDATE ${table.name} SET ${sets.join(", ")} WHERE id = ? AND field_versions = ?`;
  const outcome = await db.batch([
    bumpSeq(db),
    db
      .prepare(statement)
      .bind(
        ...names.map((name) => columns.get(name) as ColumnValue),
        encodedVersions,
        isoNow(),
        id,
        storedVersionsText
      ),
  ]);
  return (outcome[1].meta.changes ?? 0) > 0;
}

export function bumpSeq(db: D1Database): D1PreparedStatement {
  return db.prepare("UPDATE sync_meta SET seq = seq + 1 WHERE id = 1");
}

export async function currentCursor(db: D1Database): Promise<number> {
  const row = await db.prepare("SELECT seq FROM sync_meta WHERE id = 1").first<{ seq: number }>();
  return row?.seq ?? 0;
}

export function isoNow(): string {
  return new Date().toISOString();
}

export function jsonError(status: number, message: string): Response {
  return Response.json({ error: message }, { status });
}
