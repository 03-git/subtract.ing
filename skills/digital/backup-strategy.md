---
aliases: back up my files, backup strategy, 3-2-1 backup, how to back up computer, don't want to lose my files, backup plan
tags: digital-hygiene, backup, data, storage
verified: true
---

CREATE A BACKUP STRATEGY (3-2-1 RULE)

Steps:
1. The 3-2-1 rule: keep 3 copies of your data, on 2 different types of storage, with 1 copy offsite.
2. COPY 1 — Your working files (already on your computer). This is copy one.
3. COPY 2 — Local external backup:
   - Get an external hard drive (at least 2x your data size).
   - Mac: use Time Machine (built-in). Plug in drive, System Settings > Time Machine > select drive.
   - Windows: use File History or Backup Settings. Settings > Update & Security > Backup.
   - Linux: use rsync, Deja Dup, or Timeshift for system backups.
4. COPY 3 — Offsite/cloud backup:
   - Use a cloud backup service (Backblaze, iCloud, Google Drive, OneDrive).
   - OR: a second external drive stored at a different physical location, updated monthly.
5. Test your backups. Actually try restoring a file. A backup you've never tested is not a backup.
6. Automate everything. Backups should run on a schedule, not require you to remember.

Notes:
- Photos and documents are irreplaceable. Software and settings can be reinstalled.
- Syncing (Dropbox, Google Drive) is not the same as backup. If you delete a file, sync deletes it everywhere.
- Encrypt your backups, especially the offsite copy.

