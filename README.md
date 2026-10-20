# Videos2DB
Using MacOS this bash script scans all clips in a directory and creates an index sqlite DB entries.
Each time it scans in a table called dsize, the bash script updates or creates a row with directory name in field called directory, field called free_MB type Integer with free megabytes on that directory's volume, and field called scanned with a Timestamp of the current date and time.
free_MB is whole megabytes reported by df (1,048,576-byte blocks), not a raw byte count.
