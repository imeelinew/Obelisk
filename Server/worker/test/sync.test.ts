import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    DB: D1Database;
    TEST_MIGRATIONS: D1Migration[];
    SYNC_ACCESS_KEY: string;
  }
}

const accessKey = "test-access-key-0123456789abcdef";
const deviceA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const deviceB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const bookmarkID = "11111111-1111-4111-8111-111111111111";

function version(milliseconds: number, counter = 0, deviceID = deviceA) {
  return { milliseconds, counter, deviceID };
}

function bookmarkValues(overrides: Record<string, unknown> = {}) {
  return {
    collection_id: null,
    title: "Example",
    url: "https://example.com",
    title_optimization_state: "not_attempted",
    is_hidden: false,
    archived_at: null,
    original_title: "Example",
    position_key: "00000000000000000001-x",
    deleted_at: null,
    created_at: "2026-07-01T00:00:00.000Z",
    ...overrides,
  };
}

function allVersions(milliseconds: number, deviceID = deviceA) {
  const fields = [
    "collection_id",
    "title",
    "url",
    "title_optimization_state",
    "is_hidden",
    "archived_at",
    "original_title",
    "position_key",
    "deleted_at",
  ];
  return Object.fromEntries(fields.map((field) => [field, version(milliseconds, 0, deviceID)]));
}

async function request(path: string, init: RequestInit = {}) {
  return SELF.fetch(`https://sync.test${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${accessKey}`,
      "Content-Type": "application/json",
      ...init.headers,
    },
  });
}

async function push(rows: unknown[]) {
  const response = await request("/v1/push", {
    method: "POST",
    body: JSON.stringify({ rows }),
  });
  expect(response.status).toBe(200);
  return response.json() as Promise<{
    results: { table: string; id: string; status: string; error?: string }[];
    cursor: number;
  }>;
}

async function changes(since = 0) {
  const response = await request(`/v1/changes?since=${since}`);
  expect(response.status).toBe(200);
  return response.json() as Promise<Record<string, any>>;
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  const tables = [
    "collections",
    "bookmarks",
    "usage_events",
  ];
  for (const table of tables) {
    await env.DB.prepare(`DELETE FROM ${table}`).run();
  }
  await env.DB.prepare("UPDATE sync_meta SET seq = 0 WHERE id = 1").run();
});

describe("auth", () => {
  it("rejects requests without the access key", async () => {
    const response = await SELF.fetch("https://sync.test/v1/changes?since=0");
    expect(response.status).toBe(401);
  });

  it("answers health checks without auth", async () => {
    const response = await SELF.fetch("https://sync.test/healthz");
    expect(response.status).toBe(200);
  });
});

describe("push and pull", () => {
  it("round-trips a bookmark through push and changes", async () => {
    const result = await push([
      {
        table: "bookmarks",
        id: bookmarkID,
        values: bookmarkValues(),
        fieldVersions: allVersions(1000),
      },
    ]);
    expect(result.results[0].status).toBe("applied");
    expect(result.cursor).toBeGreaterThan(0);

    const feed = await changes(0);
    expect(feed.bookmarks).toHaveLength(1);
    expect(feed.bookmarks[0].title).toBe("Example");
    expect(feed.bookmarks[0].fieldVersions.title.milliseconds).toBe(1000);
    expect(feed.hasMore).toBe(false);
  });

  it("is idempotent for replayed pushes", async () => {
    const row = {
      table: "bookmarks",
      id: bookmarkID,
      values: bookmarkValues(),
      fieldVersions: allVersions(1000),
    };
    const first = await push([row]);
    const second = await push([row]);
    expect(second.results[0].status).toBe("applied");
    expect(second.cursor).toBe(first.cursor);

    const feed = await changes(first.cursor);
    expect(feed.bookmarks).toHaveLength(0);
  });

  it("merges concurrent edits to different fields from two devices", async () => {
    await push([
      {
        table: "bookmarks",
        id: bookmarkID,
        values: bookmarkValues(),
        fieldVersions: allVersions(1000),
      },
    ]);
    await push([
      {
        table: "bookmarks",
        id: bookmarkID,
        values: bookmarkValues({ title: "Renamed by A" }),
        fieldVersions: { ...allVersions(1000), title: version(2000, 0, deviceA) },
      },
    ]);
    await push([
      {
        table: "bookmarks",
        id: bookmarkID,
        values: bookmarkValues({ is_hidden: true }),
        fieldVersions: { ...allVersions(1000), is_hidden: version(2001, 0, deviceB) },
      },
    ]);

    const feed = await changes(0);
    expect(feed.bookmarks[0].title).toBe("Renamed by A");
    expect(feed.bookmarks[0].is_hidden).toBe(1);
  });

  it("lets the same field converge on the newer version and ignores older writes", async () => {
    await push([
      {
        table: "bookmarks",
        id: bookmarkID,
        values: bookmarkValues({ title: "Newer" }),
        fieldVersions: { ...allVersions(1000), title: version(3000, 0, deviceB) },
      },
    ]);
    const result = await push([
      {
        table: "bookmarks",
        id: bookmarkID,
        values: bookmarkValues({ title: "Older" }),
        fieldVersions: { ...allVersions(1000), title: version(2000, 0, deviceA) },
      },
    ]);
    expect(result.results[0].status).toBe("applied");

    const feed = await changes(0);
    expect(feed.bookmarks[0].title).toBe("Newer");
  });

  it("keeps processing a batch when one row is invalid", async () => {
    const result = await push([
      {
        table: "bookmarks",
        id: bookmarkID,
        values: bookmarkValues({ url: "ftp://bad" }),
        fieldVersions: allVersions(1000),
      },
      {
        table: "collections",
        id: "22222222-2222-4222-8222-222222222222",
        values: {
          name: "Reading",
          position_key: "00000000000000000000",
          deleted_at: null,
        },
        fieldVersions: {
          name: version(1000),
          position_key: version(1000),
          deleted_at: version(1000),
        },
      },
    ]);
    expect(result.results[0].status).toBe("rejected");
    expect(result.results[1].status).toBe("applied");

    const feed = await changes(0);
    expect(feed.bookmarks).toHaveLength(0);
    expect(feed.collections).toHaveLength(1);
  });

  it("persists failed title optimization state", async () => {
    await push([
      {
        table: "bookmarks",
        id: bookmarkID,
        values: bookmarkValues(),
        fieldVersions: allVersions(1000),
      },
    ]);
    await push([
      {
        table: "bookmarks",
        id: bookmarkID,
        values: bookmarkValues({ title_optimization_state: "failed" }),
        fieldVersions: {
          ...allVersions(1000),
          title_optimization_state: version(2000, 0, deviceB),
        },
      },
    ]);

    const feed = await changes(0);
    expect(feed.bookmarks[0].title_optimization_state).toBe("failed");
  });

  it("stores usage events exactly once", async () => {
    const eventID = "33333333-3333-4333-8333-333333333333";
    const row = {
      table: "usage_events",
      id: eventID,
      values: {
        bookmark_id: bookmarkID,
        device_id: deviceA,
        occurred_at: "2026-07-01T10:00:00.000Z",
        created_at: "2026-07-01T10:00:00.000Z",
      },
    };
    await push([row]);
    await push([row]);

    const feed = await changes(0);
    expect(feed.usageEvents).toHaveLength(1);
  });

  it("soft-deletes via tombstoned deleted_at", async () => {
    await push([
      {
        table: "bookmarks",
        id: bookmarkID,
        values: bookmarkValues(),
        fieldVersions: allVersions(1000),
      },
    ]);
    const before = await changes(0);
    await push([
      {
        table: "bookmarks",
        id: bookmarkID,
        values: bookmarkValues({ deleted_at: "2026-07-03T00:00:00.000Z" }),
        fieldVersions: { ...allVersions(1000), deleted_at: version(2000) },
      },
    ]);

    const feed = await changes(before.cursor);
    expect(feed.bookmarks).toHaveLength(1);
    expect(feed.bookmarks[0].deleted_at).toBe("2026-07-03T00:00:00.000Z");
  });
});
