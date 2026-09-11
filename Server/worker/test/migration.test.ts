import { env, applyD1Migrations } from "cloudflare:test";
import { expect, it } from "vitest";
import { handleChanges } from "../src/changes";
import { handlePush } from "../src/push";

it("removes populated history while preserving rows and cursor continuity", async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS.slice(0, 1));
  await env.DB.batch([
    env.DB.prepare("INSERT INTO collections VALUES ('collection', 'Reading', '1', 1, '{}', 'created', 'updated', NULL, 1)"),
    env.DB.prepare("INSERT INTO bookmarks VALUES ('bookmark', 'collection', 'Kept', 'https://example.com', 0, 0, NULL, 0, NULL, '1', '{}', 'created', 'updated', 'deleted', 2)"),
    env.DB.prepare("INSERT INTO usage_events VALUES ('usage', 'bookmark', 'device', 'occurred', 'created', 3)"),
    env.DB.prepare("INSERT INTO browser_history_events VALUES ('visit', 'device', 'safari', 'Default', 'Discard', 'https://example.com', 'visited', 'created', 98)"),
    env.DB.prepare("INSERT INTO browser_history_settings VALUES ('settings', 'safari', '{}', 'created', 'updated', 99)"),
    env.DB.prepare("INSERT INTO browser_history_tombstones VALUES ('removed', 'deleted', 100)"),
    env.DB.prepare("UPDATE sync_meta SET seq = 100 WHERE id = 1"),
  ]);
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  const bookmark = await env.DB.prepare("SELECT * FROM bookmarks").first<Record<string, unknown>>();
  expect(bookmark?.title).toBe("Kept");
  expect(bookmark?.title_optimization_state).toBe("not_attempted");
  expect(bookmark).not.toHaveProperty("is_pinned");
  expect(bookmark).not.toHaveProperty("title_optimized");
  const collection = await env.DB.prepare("SELECT * FROM collections").first<Record<string, unknown>>();
  expect(collection?.name).toBe("Reading");
  expect(collection).not.toHaveProperty("show_in_menu");
  expect((await env.DB.prepare("SELECT COUNT(*) AS count FROM usage_events").first<{ count: number }>())?.count).toBe(1);
  const migratedCursor = (await env.DB.prepare("SELECT seq FROM sync_meta WHERE id = 1").first<{ seq: number }>())?.seq ?? 0;
  expect(migratedCursor).toBeGreaterThan(100);
  const leftovers = await env.DB.prepare("SELECT name FROM sqlite_master WHERE name GLOB 'browser_history*'").all();
  expect(leftovers.results).toEqual([]);

  const feed = async (since: number) => {
    const response = await handleChanges(new Request(`https://test/v1/changes?since=${since}`), env.DB);
    return response.json() as Promise<Record<string, any>>;
  };
  const empty = await feed(migratedCursor);
  expect(empty).toEqual({ cursor: migratedCursor, hasMore: false, bookmarks: [], collections: [], usageEvents: [] });
  expect((await feed(0)).bookmarks).toHaveLength(1);

  const response = await handlePush(new Request("https://test/v1/push", {
    method: "POST",
    body: JSON.stringify({ rows: [{
      table: "usage_events",
      id: "33333333-3333-4333-8333-333333333333",
      values: {
        bookmark_id: "11111111-1111-4111-8111-111111111111",
        device_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        occurred_at: "2026-07-01T00:00:00.000Z",
        created_at: "2026-07-01T00:00:00.000Z",
      },
    }] }),
  }), env.DB);
  expect(response.status).toBe(200);
  const next = await feed(100);
  expect(next.cursor).toBeGreaterThan(100);
  expect(next.usageEvents).toHaveLength(1);

  await env.DB.batch([
    env.DB.prepare(`
      WITH RECURSIVE numbers(n) AS (
        SELECT 103 UNION ALL SELECT n + 1 FROM numbers WHERE n < 1103
      )
      INSERT INTO collections (
        id, name, position_key, field_versions, created_at, updated_at, deleted_at, seq
      )
      SELECT 'page-' || n, 'Reading', CAST(n AS TEXT), '{}', 'created', 'updated', NULL, n
      FROM numbers
    `),
    env.DB.prepare("UPDATE sync_meta SET seq = 1103 WHERE id = 1"),
  ]);
  const firstPage = await feed(migratedCursor);
  expect(firstPage.hasMore).toBe(true);
  expect(firstPage.cursor).toBe(1102);
  expect(firstPage.collections).toHaveLength(1000);
  const lastPage = await feed(firstPage.cursor);
  expect(lastPage.hasMore).toBe(false);
  expect(lastPage.cursor).toBe(1103);
  expect(lastPage.collections.map((row: { id: string }) => row.id)).toEqual(["page-1103"]);
});
