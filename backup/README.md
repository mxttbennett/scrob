# Nightly backups

A small container that backs up Scrob every night at `BACKUP_HOUR` (default 3, in `TZ`) and keeps the last `KEEP_DAYS` (default 14) database dumps. On the first of each month it restores the newest dump into a scratch database and compares row counts with the live one, writing the result to `last-restore-test.txt`.

Each run writes:

- `database/scrob-YYYY-MM-DD.dump.enc`: an encrypted `pg_dump`
- `files/`: a copy of Scrob's data volume, without caches
- `config/env.enc`: the encrypted `.env`, when one is mounted

The dumps and `.env` hold password hashes and API keys, so the script encrypts them with `backup.key` and refuses to run without it. Keep a copy of the key somewhere other than the server; the backups can't be restored without it.

## Setup

1. Create the key next to your compose file:

   ```sh
   openssl rand -base64 48 > backup.key && chmod 600 backup.key
   ```

2. Add the service to your compose file, using your own database credentials:

   ```yaml
   scrob-backup:
     container_name: scrob-backup
     build: ./backup
     restart: unless-stopped
     depends_on:
       scrob-db:
         condition: service_healthy
     environment:
       PGHOST: scrob-db
       PGUSER: scrob
       PGPASSWORD: ${POSTGRES_PASSWORD}
       PGDATABASE: scrob
       TZ: America/New_York
       KEEP_DAYS: "14"
       BACKUP_HOUR: "3"
     volumes:
       - scrob_data:/data:ro
       - ./backup.key:/config/backup.key:ro
       - ./.env:/config/.env:ro
       - ./backups/nightly:/out
   ```

3. Start it with `docker compose up -d --build scrob-backup`. It takes one backup right away.

Run a restore test at any time:

```sh
docker exec scrob-backup sh /usr/local/bin/backup.sh test
```

`/out/README.txt` in the backup folder explains how to restore.
