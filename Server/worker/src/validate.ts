import { isUUID } from "./hlc";

export type ColumnValue = string | number | null;

export type FieldDecoder = (value: unknown) => ColumnValue;

export class ValidationError extends Error {}

function fail(message: string): never {
  throw new ValidationError(message);
}

export function requiredString(value: unknown): ColumnValue {
  if (typeof value !== "string" || value === "") {
    fail("required string is missing");
  }
  return value;
}

export function optionalString(value: unknown): ColumnValue {
  if (value === null || value === undefined) {
    return null;
  }
  return requiredString(value);
}

export function requiredBoolean(value: unknown): ColumnValue {
  if (typeof value === "boolean") {
    return value ? 1 : 0;
  }
  if (value === 0 || value === 1) {
    return value;
  }
  fail("required boolean is missing");
}

export function requiredUUIDString(value: unknown): ColumnValue {
  const raw = requiredString(value) as string;
  if (!isUUID(raw)) {
    fail("invalid uuid");
  }
  return raw.toLowerCase();
}

export function optionalUUIDString(value: unknown): ColumnValue {
  if (value === null || value === undefined) {
    return null;
  }
  return requiredUUIDString(value);
}

export function requiredTime(value: unknown): ColumnValue {
  const raw = requiredString(value) as string;
  if (Number.isNaN(Date.parse(raw))) {
    fail("invalid timestamp");
  }
  return raw;
}

export function optionalTime(value: unknown): ColumnValue {
  if (value === null || value === undefined) {
    return null;
  }
  return requiredTime(value);
}

export function requiredWebURL(value: unknown): ColumnValue {
  const raw = requiredString(value) as string;
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    fail("url must use http or https");
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    fail("url must use http or https");
  }
  return raw;
}

const supportedBrowsers = ["dia", "chrome", "safari"] as const;

export function isSupportedBrowser(value: string): boolean {
  return (supportedBrowsers as readonly string[]).includes(value);
}

export function requiredBrowser(value: unknown): ColumnValue {
  const raw = requiredString(value) as string;
  if (!isSupportedBrowser(raw)) {
    fail("browser is invalid");
  }
  return raw;
}

/// Comma-joined canonical browser list, or empty. Mirrors the client encoding
/// of `BrowserHistorySettings.enabledSources`.
export function requiredBrowserSources(value: unknown): ColumnValue {
  if (typeof value !== "string") {
    fail("enabled_sources must be a string");
  }
  if (value === "") {
    return value;
  }
  const parts = value.split(",");
  const seen = new Set<string>();
  for (const part of parts) {
    if (!isSupportedBrowser(part) || seen.has(part)) {
      fail("enabled_sources is invalid");
    }
    seen.add(part);
  }
  const canonical = supportedBrowsers.filter((browser) => seen.has(browser)).join(",");
  if (canonical !== value) {
    fail("enabled_sources is invalid");
  }
  return value;
}
