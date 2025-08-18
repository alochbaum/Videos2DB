#!/bin/bash
//  Video2DB.sh
//  
//
//  Created by Andrew Lochbaum on 7/25/25.
//


# Check if directory is provided as an argument
if [ $# -ne 1 ]; then
    echo "Usage: $0 <directory_path>"
    exit 1
fi

DIRECTORY=$1
DB_FILE="/tmp/VidIndex.db"

# Check if directory exists
if [ ! -d "$DIRECTORY" ]; then
    echo "Error: Directory '$DIRECTORY' does not exist."
    exit 1
fi

# Check if mediainfo is installed
if ! command -v /opt/homebrew/bin/mediainfo &> /dev/null; then
    echo "Error: /opt/homebrew/bin/mediainfo is not installed. Install it using 'brew install mediainfo'."
    exit 1
fi

# Create SQLite database and table if not exists
sqlite3 /tmp/VidIndex.db <<EOF
CREATE TABLE IF NOT EXISTS videos (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    filename TEXT NOT NULL,
    title TEXT NOT NULL,
    directory TEXT NOT NULL,
    size INTEGER NOT NULL,
    mod_date INTEGER NOT NULL,
    resolution TEXT,
    duration TEXT
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
EOF

function clear_directory() {
    sqlite3 /tmp/VidIndex.db <<EOF
    DELETE FROM videos WHERE directory = '$DIRECTORY';
EOF
echo "DELETE FROM videos WHERE directory = '$DIRECTORY';"
}

# Function to process video files
function process_videos() {
# Loop through common video file extensions
for file in "$DIRECTORY"/*.{mp4,mov,avi,mpg,flv,mkv,wmv}; do
    # Check if file exists (handles case when no files match extension)
    if [[ -f "$file" ]]; then
        # Get file size in bytes
        size=$(stat -f %z "$file") # macOS-specific stat command for file size in bytes

        # Get file modified date using stat as long integer
        mod_date=$(stat -f %m "$file")
    
        
        # Get video resolution using mediainfo
        resolution=$(mediainfo --Inform="Video;%Width%x%Height%" "$file" 2>/dev/null)
        if [ -z "$resolution" ]; then
            resolution="Unknown"
        fi

        # Get video duration using mediainfo
        duration=$(mediainfo --Inform="General;%Duration/String3%" "$file" 2>/dev/null)
        if [ -z "$duration" ]; then
            duration="0"
        fi

        # Get video title using mediainfo
        title=$(mediainfo --Inform="General;%Title%" "$file" 2>/dev/null)
        if [ -z "$title" ]; then
            title="_"
        fi


        # Escape single quotes in filename for SQLite
        filename=$(basename "$file")
        escaped_filename=$(echo "$filename" | sed "s/'/''/g")

        # Insert into SQLite database
        sqlite3 /tmp/VidIndex.db <<EOF
        INSERT INTO videos (filename, title, directory, size, mod_date, resolution, duration) VALUES ('$escaped_filename', '$title', '$DIRECTORY', $size, $mod_date, '$resolution', '$duration');
EOF
        echo "Added: $filename Title: $title Dir: $DIRECTORY Sz: $size bytes, Res: $resolution Dur: $duration"
    fi
done
}

# Run the functions
echo "Deleting any record with a directory of $DIRECTORY"
clear_directory
echo starting to run process_videos
process_videos
echo finished running process_videos

# Report success
echo "Database updated: $DB_FILE"
echo "To view the data, use: sqlite3 $DB_FILE 'SELECT * FROM videos;'"

