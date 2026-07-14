import PowerSync

public enum ObeliskSchema {
    public static let syncState = Table(
        name: "sync_state",
        columns: [.text("value")],
        localOnly: true
    )

    public static let collections = Table(
        name: "collections",
        columns: [
            .text("name"),
            .text("position_key"),
            .integer("show_in_menu"),
            .text("field_versions"),
            .text("created_at"),
            .text("updated_at"),
            .text("deleted_at"),
        ],
        indexes: [
            Index(
                name: "collections_position",
                columns: [IndexedColumn.ascending("position_key")]
            ),
        ],
        trackMetadata: true
    )

    public static let bookmarks = Table(
        name: "bookmarks",
        columns: [
            .text("collection_id"),
            .text("title"),
            .text("url"),
            .integer("title_optimized"),
            .integer("is_hidden"),
            .text("archived_at"),
            .integer("is_pinned"),
            .text("original_title"),
            .text("position_key"),
            .text("field_versions"),
            .text("created_at"),
            .text("updated_at"),
            .text("deleted_at"),
        ],
        indexes: [
            Index(
                name: "bookmarks_position",
                columns: [IndexedColumn.ascending("position_key")]
            ),
            Index(
                name: "bookmarks_collection",
                columns: [IndexedColumn.ascending("collection_id")]
            ),
        ],
        trackMetadata: true
    )

    public static let usageEvents = Table(
        name: "usage_events",
        columns: [
            .text("bookmark_id"),
            .text("device_id"),
            .text("occurred_at"),
            .text("created_at"),
        ],
        indexes: [
            Index(
                name: "usage_events_bookmark",
                columns: [
                    IndexedColumn.ascending("bookmark_id"),
                    IndexedColumn.descending("occurred_at"),
                ]
            ),
        ],
        trackMetadata: true
    )

    public static let current = Schema(syncState, collections, bookmarks, usageEvents)
}
