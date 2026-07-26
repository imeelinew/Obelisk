// Per-field HLC merge for the versioned tables. Pure functions so the rules
// can be unit-tested without a database.

import {
  encodeVersions,
  isAfter,
  parseVersions,
  type LogicalTimestamp,
} from "./hlc";
import {
  optionalString,
  optionalTime,
  optionalUUIDString,
  requiredBoolean,
  requiredBrowserSources,
  requiredString,
  requiredTime,
  requiredWebURL,
  ValidationError,
  type ColumnValue,
  type FieldDecoder,
} from "./validate";

export interface VersionedTable {
  name: string;
  fields: Record<string, FieldDecoder>;
}

export const collectionsTable: VersionedTable = {
  name: "collections",
  fields: {
    name: requiredString,
    position_key: requiredString,
    show_in_menu: requiredBoolean,
    deleted_at: optionalTime,
  },
};

export const bookmarksTable: VersionedTable = {
  name: "bookmarks",
  fields: {
    collection_id: optionalUUIDString,
    title: requiredString,
    url: requiredWebURL,
    title_optimized: requiredBoolean,
    is_hidden: requiredBoolean,
    archived_at: optionalTime,
    is_pinned: requiredBoolean,
    original_title: optionalString,
    position_key: requiredString,
    deleted_at: optionalTime,
  },
};

export const browserHistorySettingsTable: VersionedTable = {
  name: "browser_history_settings",
  fields: {
    enabled_sources: requiredBrowserSources,
  },
};

export const versionedTables: Record<string, VersionedTable> = {
  collections: collectionsTable,
  bookmarks: bookmarksTable,
  browser_history_settings: browserHistorySettingsTable,
};

export interface IncomingRow {
  values: Record<string, unknown>;
  versions: Map<string, LogicalTimestamp>;
}

export function parseIncomingRow(
  table: VersionedTable,
  values: unknown,
  fieldVersions: unknown
): IncomingRow {
  if (typeof values !== "object" || values === null || Array.isArray(values)) {
    throw new ValidationError("values must be an object");
  }
  const versions = parseVersions(fieldVersions);
  if (versions === null) {
    throw new ValidationError("fieldVersions are invalid");
  }
  const raw = values as Record<string, unknown>;
  for (const field of Object.keys(raw)) {
    if (!(field in table.fields) && field !== "created_at") {
      throw new ValidationError(`unsupported ${table.name} field ${field}`);
    }
  }
  for (const field of Object.keys(table.fields)) {
    if (field in raw && !versions.has(field)) {
      throw new ValidationError(`missing field version for ${field}`);
    }
  }
  return { values: raw, versions };
}

export interface MergeResult {
  /// Column values to write, including merged `field_versions`. Empty
  /// `changed` means the incoming row is fully superseded; nothing to write.
  changed: boolean;
  columns: Map<string, ColumnValue>;
  encodedVersions: string;
}

/// Field-wise merge of an incoming row against the currently stored versions.
/// Only fields with strictly newer HLC versions are accepted; ties lose, so
/// replay and full-state re-push are idempotent.
export function mergeRow(
  table: VersionedTable,
  incoming: IncomingRow,
  currentVersions: Map<string, LogicalTimestamp>
): MergeResult {
  const merged = new Map(currentVersions);
  const columns = new Map<string, ColumnValue>();
  let changed = false;

  for (const [field, decode] of Object.entries(table.fields)) {
    if (!(field in incoming.values)) {
      continue;
    }
    const version = incoming.versions.get(field);
    if (version === undefined) {
      throw new ValidationError(`missing field version for ${field}`);
    }
    const current = currentVersions.get(field);
    if (current !== undefined && !isAfter(version, current)) {
      continue;
    }
    const value = decode(incoming.values[field]);
    columns.set(field, value);
    merged.set(field, version);
    changed = true;
  }

  return {
    changed,
    columns,
    encodedVersions: encodeVersions(merged),
  };
}

/// Column values for inserting a brand-new row. Missing optional fields
/// decode from null; a missing field version gets the zero timestamp so any
/// future write on that field wins.
export function insertRow(table: VersionedTable, incoming: IncomingRow): MergeResult {
  const columns = new Map<string, ColumnValue>();
  const versions = new Map(incoming.versions);
  for (const [field, decode] of Object.entries(table.fields)) {
    const raw = field in incoming.values ? incoming.values[field] : null;
    if (!versions.has(field)) {
      versions.set(field, {
        milliseconds: 0,
        counter: 0,
        deviceID: "00000000-0000-0000-0000-000000000000",
      });
    }
    columns.set(field, decode(raw));
  }
  return {
    changed: true,
    columns,
    encodedVersions: encodeVersions(versions),
  };
}

/// Bookmark invariant shared with the client: hidden, archived, or deleted
/// bookmarks cannot stay pinned. Applied after a merge so devices converge on
/// the same outcome regardless of arrival order.
export function enforceBookmarkInvariants(
  columns: Map<string, ColumnValue>,
  stored: { is_hidden: number; archived_at: string | null; deleted_at: string | null; is_pinned: number },
  versions: Map<string, LogicalTimestamp>
): { columns: Map<string, ColumnValue>; encodedVersions: string } | null {
  const hidden = (columns.get("is_hidden") ?? stored.is_hidden) === 1;
  const archived = (columns.has("archived_at") ? columns.get("archived_at") : stored.archived_at) !== null;
  const deleted = (columns.has("deleted_at") ? columns.get("deleted_at") : stored.deleted_at) !== null;
  const pinned = (columns.get("is_pinned") ?? stored.is_pinned) === 1;
  if (!pinned || (!hidden && !archived && !deleted)) {
    return null;
  }

  let maximum = versions.get("is_pinned");
  for (const field of ["is_hidden", "archived_at", "deleted_at"]) {
    const candidate = versions.get(field);
    if (candidate !== undefined && (maximum === undefined || isAfter(candidate, maximum))) {
      maximum = candidate;
    }
  }
  const adjustedVersions = new Map(versions);
  if (maximum !== undefined) {
    adjustedVersions.set("is_pinned", maximum);
  }
  const adjustedColumns = new Map(columns);
  adjustedColumns.set("is_pinned", 0);
  return {
    columns: adjustedColumns,
    encodedVersions: encodeVersions(adjustedVersions),
  };
}
