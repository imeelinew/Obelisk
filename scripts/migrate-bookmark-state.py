#!/usr/bin/env python3
import argparse
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path


def load_json(path, default):
    if not path.exists():
        return default
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def dump_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")


def unique_sorted(values):
    return sorted(set(values))


def main():
    parser = argparse.ArgumentParser(
        description="Migrate legacy Obelisk bookmark state out of bookmarks.json."
    )
    parser.add_argument(
        "root",
        nargs="?",
        default=str(Path.home() / "Documents" / "Obelisk"),
        help="Obelisk storage root. Defaults to ~/Documents/Obelisk.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the planned migration without writing files.",
    )
    args = parser.parse_args()

    root = Path(args.root).expanduser()
    bookmarks_path = root / "bookmarks.json"
    state_path = root / "bookmark_state.json"

    if not bookmarks_path.exists():
        raise SystemExit(f"bookmarks.json not found: {bookmarks_path}")

    database = load_json(bookmarks_path, {})
    if database.get("format") == "obelisk.encrypted-json.v1":
        raise SystemExit("Refusing to modify encrypted bookmarks.json; run the app migration instead.")

    bookmarks = database.get("bookmarks", [])
    state = load_json(
        state_path,
        {
            "version": 1,
            "hiddenIds": [],
            "manualArchivedIds": [],
            "createdAtById": {},
            "titleOptimizedIds": [],
        },
    )

    hidden_ids = set(state.get("hiddenIds", []))
    manual_archived_ids = set(state.get("manualArchivedIds", []))
    created_at_by_id = dict(state.get("createdAtById", {}))
    title_optimized_ids = set(state.get("titleOptimizedIds", []))
    cleaned_bookmarks = []
    discarded_archived = 0

    for bookmark in bookmarks:
        bookmark_id = bookmark.get("id")
        if not bookmark_id:
            cleaned_bookmarks.append(bookmark)
            continue

        if bookmark.get("isHidden") is True:
            hidden_ids.add(bookmark_id)
        if bookmark.get("titleOptimized") is True:
            title_optimized_ids.add(bookmark_id)
        if "createdAt" in bookmark and bookmark_id not in created_at_by_id:
            created_at_by_id[bookmark_id] = bookmark["createdAt"]
        if "archivedAt" in bookmark:
            discarded_archived += 1

        cleaned_bookmarks.append(
            {
                "id": bookmark_id,
                "title": bookmark.get("title", ""),
                "url": bookmark.get("url", ""),
            }
        )

    valid_ids = {bookmark["id"] for bookmark in cleaned_bookmarks if "id" in bookmark}
    next_state = {
        "version": max(1, int(state.get("version", 1))),
        "hiddenIds": unique_sorted(hidden_ids & valid_ids),
        "manualArchivedIds": unique_sorted(manual_archived_ids & valid_ids),
        "createdAtById": {
            key: value
            for key, value in sorted(created_at_by_id.items())
            if key in valid_ids
        },
        "titleOptimizedIds": unique_sorted(title_optimized_ids & valid_ids),
    }
    next_database = {
        "version": database.get("version", 1),
        "bookmarks": cleaned_bookmarks,
    }

    print(f"bookmarks: {len(bookmarks)}")
    print(f"hidden ids: {len(next_state['hiddenIds'])}")
    print(f"title optimized ids: {len(next_state['titleOptimizedIds'])}")
    print(f"createdAt entries: {len(next_state['createdAtById'])}")
    print(f"discarded archivedAt entries: {discarded_archived}")

    if args.dry_run:
        return

    stamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    shutil.copy2(bookmarks_path, bookmarks_path.with_suffix(f".json.{stamp}.bak"))
    if state_path.exists():
        shutil.copy2(state_path, state_path.with_suffix(f".json.{stamp}.bak"))

    dump_json(bookmarks_path, next_database)
    dump_json(state_path, next_state)


if __name__ == "__main__":
    main()
