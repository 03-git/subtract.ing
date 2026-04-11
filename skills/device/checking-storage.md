---
aliases: check storage, disk full, free space, how much space, storage left
tags: disk, storage, space
---

CHECKING STORAGE

Steps:
1. Overall disk space: df -h
2. Current folder size: du -sh .
3. Largest items here: du -sh * | sort -rh | head -10
4. Find big files system-wide: find / -type f -size +100M 2>/dev/null

Notes:
- df shows mounted filesystems. Look at the Use% column.
- du -sh * shows size of each item in the current directory.
- USB drives usually mount under /mnt/ or /media/.
