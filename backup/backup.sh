#!/bin/sh
# Nightly encrypted backup of the Scrob database, data folder and .env, with a
# monthly restore test. Adapted from wogsurfer/watchd (GPL-3.0).
#
# Mounts:
#   /out                  where backups go (database/, files/, config/)
#   /config/backup.key    encryption key; nothing is written without it
#   /config/.env          optional; encrypted into config/env.enc
#   /data                 optional; Scrob's data volume, read-only
#
# Run a restore test on demand:
#   docker exec scrob-backup sh /usr/local/bin/backup.sh test
set -u

KEEP_DAYS="${KEEP_DAYS:-14}"
BACKUP_HOUR="${BACKUP_HOUR:-3}"
KEY=/config/backup.key
TEST_TABLES="users media shows watch_events ratings lists list_items user_settings"

encrypt() { openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "file:$KEY" "$@"; }
decrypt() { openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "file:$KEY" "$@"; }

backup() {
    stamp=$(date +%Y-%m-%d)
    mkdir -p /out/database /out/files /out/config
    echo "backup: starting $stamp"
    if [ ! -f "$KEY" ] || [ ! -s "$KEY" ]; then
        echo "backup: no key at $KEY, so nothing was backed up"
        return 1
    fi

    # A temporary name keeps a half-written dump from looking complete.
    set -o pipefail
    if pg_dump -Fc | encrypt -out "/out/database/scrob-$stamp.dump.enc.part"; then
        mv "/out/database/scrob-$stamp.dump.enc.part" "/out/database/scrob-$stamp.dump.enc"
    else
        rm -f "/out/database/scrob-$stamp.dump.enc.part"
        echo "backup: database dump FAILED"
        set +o pipefail
        return 1
    fi
    set +o pipefail

    if [ -d /data ]; then
        rsync -a --delete --exclude 'cache/' --exclude 'image_cache/' /data/ /out/files/
    fi
    if [ -f /config/.env ]; then
        encrypt -in /config/.env -out /out/config/env.enc
    fi

    find /out/database -name 'scrob-*.dump.enc' -mtime +"$KEEP_DAYS" -delete

    cat > /out/README.txt <<'TXT'
Scrob backup
============

database/  One encrypted pg_dump per night (scrob-YYYY-MM-DD.dump.enc).
files/     A copy of Scrob's data folder, without caches.
config/    env.enc: the encrypted .env file, when one was mounted.

Restoring needs backup.key, which is kept out of these backups.

Restore
-------
1. Decrypt the newest dump:
     openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass file:backup.key \
       -in database/scrob-YYYY-MM-DD.dump.enc -out restore.dump
2. Decrypt the settings, if needed:
     openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass file:backup.key \
       -in config/env.enc -out .env
3. Stop the scrob service, leaving scrob-db running.
4. Load the dump:
     docker exec -i scrob-db pg_restore -U scrob -d scrob --clean --if-exists < restore.dump
5. Copy files/ into the scrob data volume, start scrob, then delete restore.dump.
TXT
    date '+%Y-%m-%d %H:%M' > /out/last-backup.txt
    echo "backup: done ($(du -h "/out/database/scrob-$stamp.dump.enc" | cut -f1) database)"
}

restore_test() {
    newest=$(ls -1 /out/database/scrob-*.dump.enc 2>/dev/null | sort | tail -n 1)
    out=/out/last-restore-test.txt
    if [ -z "$newest" ]; then
        echo "FAILED $(date '+%Y-%m-%d %H:%M'): no backup to test" | tee "$out"
        return 1
    fi
    scratch=scrob_restore_test
    tmp=/tmp/restore-test.dump
    if ! { dropdb --if-exists "$scratch" && createdb "$scratch"; }; then
        echo "FAILED $(date '+%Y-%m-%d %H:%M'): couldn't create the scratch database" | tee "$out"
        return 1
    fi
    if ! decrypt -in "$newest" -out "$tmp"; then
        echo "FAILED $(date '+%Y-%m-%d %H:%M'): $(basename "$newest") wouldn't decrypt" | tee "$out"
        dropdb --if-exists "$scratch"
        return 1
    fi
    pg_restore -d "$scratch" --no-owner "$tmp" 2>/tmp/restore-test.log
    rm -f "$tmp"
    result=PASSED
    report=""
    for t in $TEST_TABLES; do
        live=$(psql -At -c "SELECT count(*) FROM $t" 2>/dev/null)
        restored=$(psql -At -d "$scratch" -c "SELECT count(*) FROM $t" 2>/dev/null)
        # The live database keeps changing after the dump, so allow up to a tenth missing.
        if [ -z "$restored" ] || [ $((restored * 10)) -lt $((${live:-0} * 9)) ]; then result=FAILED; fi
        report="$report
  $t: live ${live:-?}, restored ${restored:-?}"
    done
    dropdb --if-exists "$scratch"
    echo "$result $(date '+%Y-%m-%d %H:%M'): restored $(basename "$newest")$report" | tee "$out"
    [ "$result" = PASSED ]
}

if [ "${1:-}" = test ]; then
    restore_test
    exit $?
fi

backup
while true; do
    now=$(date +%s)
    next=$(date -d "$(date +%Y-%m-%d) $(printf '%02d' "$BACKUP_HOUR"):00" +%s)
    [ "$next" -le "$now" ] && next=$((next + 86400))
    sleep $((next - now))
    backup && [ "$(date +%d)" = 01 ] && restore_test
done
