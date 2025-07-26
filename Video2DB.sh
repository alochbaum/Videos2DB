#
//  Video2DB.sh
//  
//
//  Created by Andrew Lochbaum on 7/25/25.
//
#!/bin/bash

# Check if directory is provided as an argument
if [ $# -ne 1 ]; then
    echo "Usage: $0 <directory_path>"
    exit 1
fi

DIRECTORY=$1
DB_FILE="video_info.db"

# Check if directory exists
if [ ! -d "$DIRECTORY" ]; then
    echo "Error: Directory '$DIRECTORY' does not exist."
    exit 1
fi

# Check if mediainfo is installed
if ! command -v mediainfo &> /dev/null; then
    echo "Error: mediainfo is not installed. Install it using 'brew install mediainfo'."
    exit 1
fi

# Create SQLite database and table if not exists
sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS videos (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    filename TEXT NOT NULL,
    size INTEGER NOT NULL,
    resolution TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
EOF

# Function to process video files
process_videos() {
    # Use find to iterate through video files (common video extensions)
    while IFS= read -r file; do
        # Get file name and size
        filename=$(basename "$file")
        size=$(stat -f %z "$file") # macOS-specific stat command for file size in bytes

        # Get video resolution using mediainfo
        resolution=$(mediainfo --Inform="Video;%Width%x%Height%" "$file" 2>/dev/null)
        if [ -z "$resolution" ]; then
            resolution="Unknown"
        fi

        # Escape single quotes in filename for SQLite
        escaped_filename=$(echo "$filename" | sed "s/'/''/g")

        # Insert into SQLite database
        sqlite3 "$DB_FILE" "INSERT INTO videos (filename, size, resolution) VALUES ('$escaped_filename', $size, '$resolution');"
        echo "Added: $filename (Size: $size bytes, Resolution: $resolution)"
    done < <(find "$DIRECTORY" -type f \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.wmv" \))
}
