// Hybrid logical clock timestamps. Field versions travel as JSON objects:
// { milliseconds: number, counter: number, deviceID: uuid-string }.
//
// Ordering must match the Swift client (`LogicalTimestamp.<`), which breaks
// ties by comparing UUID strings. Hex characters preserve relative order in
// either letter case, so canonical lowercase comparison is equivalent.

export interface LogicalTimestamp {
  milliseconds: number;
  counter: number;
  deviceID: string;
}

export function parseTimestamp(value: unknown): LogicalTimestamp | null {
  if (typeof value !== "object" || value === null) {
    return null;
  }
  const raw = value as Record<string, unknown>;
  const milliseconds = raw.milliseconds;
  const counter = raw.counter;
  const deviceID = raw.deviceID;
  if (
    typeof milliseconds !== "number" ||
    !Number.isSafeInteger(milliseconds) ||
    milliseconds < 0 ||
    typeof counter !== "number" ||
    !Number.isSafeInteger(counter) ||
    counter < 0 ||
    typeof deviceID !== "string" ||
    !isUUID(deviceID)
  ) {
    return null;
  }
  return { milliseconds, counter, deviceID: deviceID.toLowerCase() };
}

export function isAfter(a: LogicalTimestamp, b: LogicalTimestamp): boolean {
  if (a.milliseconds !== b.milliseconds) {
    return a.milliseconds > b.milliseconds;
  }
  if (a.counter !== b.counter) {
    return a.counter > b.counter;
  }
  return a.deviceID > b.deviceID;
}

export function parseVersions(value: unknown): Map<string, LogicalTimestamp> | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return null;
  }
  const versions = new Map<string, LogicalTimestamp>();
  for (const [field, raw] of Object.entries(value)) {
    const timestamp = parseTimestamp(raw);
    if (timestamp === null) {
      return null;
    }
    versions.set(field, timestamp);
  }
  return versions;
}

export function parseStoredVersions(encoded: string): Map<string, LogicalTimestamp> {
  const versions = parseVersions(JSON.parse(encoded));
  if (versions === null) {
    throw new Error("stored field_versions are invalid");
  }
  return versions;
}

/// Serializes with sorted keys so stored versions are deterministic and can
/// be used as an optimistic concurrency guard.
export function encodeVersions(versions: Map<string, LogicalTimestamp>): string {
  const output: Record<string, LogicalTimestamp> = {};
  for (const field of [...versions.keys()].sort()) {
    const timestamp = versions.get(field)!;
    output[field] = {
      milliseconds: timestamp.milliseconds,
      counter: timestamp.counter,
      deviceID: timestamp.deviceID,
    };
  }
  return JSON.stringify(output);
}

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUUID(value: string): boolean {
  return uuidPattern.test(value);
}
