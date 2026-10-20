#!/bin/bash
# Video2DB.sh
#
# Index the video files in one directory into a SQLite database.
# Running the script again for the same directory replaces that
# directory's rows, so the index matches the files currently on disk.
#
# Written for macOS (Homebrew mediainfo and BSD stat). GNU stat is
# accepted too, so the same script can be checked on Linux.
#
# Created by Andrew Lochbaum on 7/25/25.
#
# Usage:
#   Video2DB.sh <directory_path>
#
# Database:
#   /tmp/VidIndex.db    table: videos

set -euo pipefail

DB_FILE="/tmp/VidIndex.db"

# Compared case-insensitively, so Clip.MP4 and clip.mp4 are both indexed.
VIDEO_EXTS=(mp4 mov avi mpg flv mkv wmv)

# mediainfo template:
#   A real newline switches from the General section to the Video section.
#   0x1e (unit separator) splits title, duration, and resolution in the
#   output, so a title may safely contain spaces or the letter x.
#   The trailing \n is the two-character sequence mediainfo prints as a
#   newline between video streams. Only the first stream is stored.
MEDIAINFO_TEMPLATE=$(printf '%b' 'General;%Title%\x1e%Duration/String3%\x1e\nVideo;%Width%x%Height%\\n')

usage() {
    echo "Usage: $0 <directory_path>" >&2
    exit 1
}

# Single-quoted SQL literal. Quotes inside the value are doubled,
# which is how SQL escapes a quote. Size and mtime are not passed
# through here; they are checked to be plain integers first.
sql_quote() {
    local value=$1
    value=${value//$'\r'/ }
    value=${value//$'\n'/ }
    value=${value//\'/\'\'}
    printf "'%s'" "$value"
}

require_tools() {
    # Prefer whichever mediainfo is on PATH. Fall back to the usual
    # Homebrew locations (Apple silicon, then Intel) when PATH is minimal.
    if command -v mediainfo >/dev/null 2>&1; then
        MEDIAINFO=$(command -v mediainfo)
    elif [[ -x /opt/homebrew/bin/mediainfo ]]; then
        MEDIAINFO=/opt/homebrew/bin/mediainfo
    elif [[ -x /usr/local/bin/mediainfo ]]; then
        MEDIAINFO=/usr/local/bin/mediainfo
    else
        echo "Error: mediainfo is not installed. Install it with 'brew install mediainfo'." >&2
        exit 1
    fi

    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo "Error: sqlite3 is not installed." >&2
        exit 1
    fi

    # One stat call returns size and mtime. BSD and GNU flags differ.
    # `stat -f` exits non-zero on GNU stat, so the probe selects the dialect.
    if stat -f '%z %m' / >/dev/null 2>&1; then
        STAT_FMT=(-f '%z %m')
    else
        STAT_FMT=(-c '%s %Y')
    fi
}

init_db() {
    # duration and created_at must be separated by a comma. The previous
    # CREATE TABLE omitted it, so a brand-new database failed to build.
    sqlite3 "$DB_FILE" <<'EOF'
CREATE TABLE IF NOT EXISTS videos (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    filename TEXT NOT NULL,
    title TEXT NOT NULL,
    directory TEXT NOT NULL,
    size INTEGER NOT NULL,
    mod_date INTEGER NOT NULL,
    resolution TEXT,
    duration TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
-- Every refresh deletes by directory, so keep that lookup indexed.
CREATE INDEX IF NOT EXISTS idx_videos_directory ON videos(directory);
EOF

    # CREATE TABLE IF NOT EXISTS does not alter a database that already
    # exists. Add mod_date when this file was created by an older script.
    local has_mod_date
    has_mod_date=$(sqlite3 "$DB_FILE" \
        "SELECT COUNT(*) FROM pragma_table_info('videos') WHERE name = 'mod_date';")
    if [[ "$has_mod_date" -eq 0 ]]; then
        sqlite3 "$DB_FILE" \
            "ALTER TABLE videos ADD COLUMN mod_date INTEGER NOT NULL DEFAULT 0;"
    fi
}

# Sets the globals title, duration, and resolution for one file.
# Missing metadata keeps the same placeholders the original script used.
read_media_fields() {
    local file=$1
    local meta raw_title raw_duration raw_resolution

    meta=$("$MEDIAINFO" --Inform="$MEDIAINFO_TEMPLATE" "$file" 2>/dev/null || true)
    IFS=$'\x1e' read -r raw_title raw_duration raw_resolution <<< "${meta%%$'\n'*}"

    if [[ -n "${raw_title:-}" ]]; then
        title=$raw_title
    else
        title="_"
    fi

    if [[ -n "${raw_duration:-}" ]]; then
        duration=$raw_duration
    else
        duration="0"
    fi

    if [[ "${raw_resolution:-}" =~ ^[0-9]+x[0-9]+$ ]]; then
        resolution=$raw_resolution
    else
        resolution="Unknown"
    fi
}

# Write one transaction for this directory: delete the old rows, then
# insert the files that are there now. A single sqlite3 process applies
# the whole batch, instead of launching sqlite3 once per file.
# Progress lines go to stderr because this function's stdout is the count.
build_batch() {
    local file ext filename size mod_date
    local count=0

    # nullglob drops patterns that match nothing, instead of leaving the
    # literal "*.mp4" string. nocaseglob covers uppercase extensions.
    # The nested loop avoids an empty array, which bash 3.2 (the macOS
    # default) rejects under `set -u`.
    shopt -s nullglob nocaseglob

    {
        echo "BEGIN IMMEDIATE;"
        echo "DELETE FROM videos WHERE directory = $(sql_quote "$DIRECTORY");"

        for ext in "${VIDEO_EXTS[@]}"; do
            for file in "$DIRECTORY"/*."$ext"; do
                [[ -f "$file" ]] || continue

                read -r size mod_date <<< "$(stat "${STAT_FMT[@]}" "$file")"
                if [[ ! "$size" =~ ^[0-9]+$ || ! "$mod_date" =~ ^[0-9]+$ ]]; then
                    echo "Error: Could not read size or modification time for '$file'." >&2
                    exit 1
                fi

                read_media_fields "$file"
                filename=$(basename "$file")

                # size and mod_date are interpolated only after the integer
                # check above, so they cannot change the statement shape.
                printf 'INSERT INTO videos (filename, title, directory, size, mod_date, resolution, duration) VALUES (%s, %s, %s, %s, %s, %s, %s);\n' \
                    "$(sql_quote "$filename")" \
                    "$(sql_quote "$title")" \
                    "$(sql_quote "$DIRECTORY")" \
                    "$size" \
                    "$mod_date" \
                    "$(sql_quote "$resolution")" \
                    "$(sql_quote "$duration")"

                echo "Added: $filename Title: $title Dir: $DIRECTORY Sz: $size bytes, Mod: $mod_date Res: $resolution Dur: $duration" >&2
                count=$((count + 1))
            done
        done

        echo "COMMIT;"
    } >"$SQL_BATCH"

    printf '%s\n' "$count"
}

[[ $# -eq 1 ]] || usage

DIRECTORY=$1
if [[ ! -d "$DIRECTORY" ]]; then
    echo "Error: Directory '$DIRECTORY' does not exist." >&2
    exit 1
fi

# Store one canonical path so "/clips" and "/clips/" share the same rows.
if ! DIRECTORY=$(cd -- "$DIRECTORY" && pwd -P); then
    echo "Error: Cannot access directory '$1'." >&2
    exit 1
fi

require_tools
init_db

SQL_BATCH=$(mktemp "${TMPDIR:-/tmp}/vidindex.XXXXXX.sql")
trap 'rm -f "$SQL_BATCH"' EXIT

echo "Replacing index rows for $DIRECTORY"
indexed_count=$(build_batch)

# Wait briefly if another index run still holds the database.
sqlite3 -cmd ".timeout 5000" "$DB_FILE" <"$SQL_BATCH"

echo "Finished indexing $indexed_count file(s)."
echo "Database updated: $DB_FILE"
echo "To view the data, use: sqlite3 $DB_FILE 'SELECT * FROM videos;'"
