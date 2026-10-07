---
name: hermes-backup-sync
description: Back up configurable paths to a private GitHub repo with LFS and age encryption. Supports dry run, cron triggers, and a manifest-verify round trip.
version: 0.1.0
author: Neoalienson, Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [backup, github, lfs, encryption, cron, sync, devops]
    related_skills: []
---

# Backup Sync

Pushes a configurable subset of a local data tree to a **private** GitHub repo. Sensitive files are age-encrypted in-transit; large binaries ride on Git LFS; every run emits a `MANIFEST.json` you can diff on restore. Pure bash + small Python helpers, safe for `cronjob` (no LLM tokens burned).

## When to Use

- Nightly/hourly snapshot of `/opt/data` (or any tree) into a private GitHub repo you control.
- You want diff-able, browse-able config backups — `config.yaml` etc. are plain text in the repo so you can grep history.
- You need secrets encrypted before leaving the box but still restorable.
- A `cronjob` skill invocation needs to be safe to run unattended.

## Don't Use For

- Database-only backups (use `pg_dump` / `sqlite3 .backup` instead — this skill snapshots files).
- Pushing to a **public** repo. Refused at runtime.
- Backing up private keys. Encrypt first with a separate age identity; do not commit that identity to the backup repo.

## Prerequisites

Install once on the host:

```bash
# Debian/Ubuntu
sudo apt-get install -y git-lfs age jq rsync python3
git lfs install

# macOS
brew install git-lfs age jq rsync python3
git lfs install
```

Create an age keypair (or reuse one). The script auto-generates one if `AGE_RECIPIENT` is unset, but reusing an existing key is recommended:

```bash
mkdir -p ~/.config/hermes-backup-sync
age-keygen -o ~/.config/hermes-backup-sync/key.txt    # public key printed to stdout
export AGE_RECIPIENT="age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# Optionally also keep the private key for restore:
# cp ~/.config/hermes-backup-sync/key.txt somewhere safe (NOT the backup repo)
```

GitHub side:

1. Create a **private** repo (e.g. `hermes-backup-sync-store`).
2. Create a fine-grained PAT scoped to that one repo with **Contents: Read & Write** + **LFS: Read & Write** (or classic `repo` if you must).
3. Export:
   ```bash
   export GITHUB_TOKEN="ghp_..."
   export GITHUB_USER="your-handle"
   ```

## Configuration

All behaviour is driven by `config.yml` next to the script. Path resolution precedence (highest wins):

1. `--config PATH` flag passed on the command line
2. `HERMES_BACKUP_SYNC_CONFIG` environment variable (when explicitly set by your wrapper)
3. `config.yml` sitting next to the running script (the default for any installed version)

The third path is what makes persistent installs work: the script ignores any stale `HERMES_BACKUP_SYNC_CONFIG` exported from the host environment and always loads the config that ships with the install. A complete example:

```yaml
# config.yml — hermes-backup-sync
data_path: /opt/data                       # root tree to back up
workdir:   /var/tmp/hermes-backup-sync     # local clone + staging area
remote:    https://github.com/<user>/hermes-backup-sync-store.git
branch:    main

# What to copy (relative to data_path). Each entry is either a directory
# (copied recursively) or a file (copied verbatim).
include:
  - config.yaml
  - SOUL.md
  - skills
  - memories
  - cron
  - home

# Patterns to exclude (rsync globs, matched against any path component).
exclude:
  - ".cache/**"
  - ".npm/**"
  - "node_modules/**"
  - "*.lock"
  - "__pycache__/**"
  - "*.pyc"
  - ".venv/**"
  - "audio_cache/**"
  - "image_cache/**"
  - "cache/**"
  - ".curator_backups/**"

# Files to encrypt with age before pushing. The plaintext NEVER lands in
# the repo. Only `*.age` files do. Keys listed here must match files that
# would otherwise be copied verbatim.
encrypt:
  - .env
  - auth.json
  - install_id

# File globs routed through git-lfs. Keep this narrow; LFS is not free.
lfs:
  patterns:
    - "*.bin"
    - "*.sqlite"
    - "*.db"
    - "*.tar"
    - "*.tgz"
    - "*.zip"

# Public-repo safety check (uses GITHUB_TOKEN). Disable only if you
# truly know what you're doing.
verify_remote_private: true

# Cron / retention: keep the last N local snapshots, prune older.
retention:
  keep_local: 7

# Optional notifications — webhook URL or a script to invoke.
notify:
  on_success: false
  on_failure: true
  telegram:
    bot_token_env: TELEGRAM_BOT_TOKEN
    chat_id_env:    TELEGRAM_HOME_CHAT_ID
  script: null          # e.g. /opt/data/scripts/notify.sh

# Dry run does no writes, no push, no encryption — just prints the plan.
dry_run: false
```

## How to Run

```bash
# From a Hermes terminal:
terminal(command="bash {baseDir}/scripts/hermes-backup-sync.sh", timeout=300)

# Dry run (no writes, no push):
terminal(command="bash {baseDir}/scripts/hermes-backup-sync.sh --dry-run", timeout=60)

# Verify a remote snapshot against local source:
terminal(command="bash {baseDir}/scripts/hermes-backup-sync.sh verify", timeout=120)

# Prune old local snapshots:
terminal(command="bash {baseDir}/scripts/hermes-backup-sync.sh prune --keep 7", timeout=30)

# Restore (decrypts into a target dir):
terminal(command="bash {baseDir}/scripts/hermes-backup-sync.sh restore --to /restore/path", timeout=300)
```

> **Recovery flow** — see [`README.md` → Restoring From a Backup](./README.md#restoring-from-a-backup) for the full step-by-step. SKILL.md is for the agent; README.md is for you.

## Quick Reference

| Command | Effect |
|---|---|
| `hermes-backup-sync.sh` | Sync per config |
| `hermes-backup-sync.sh --dry-run` | Plan only, no writes |
| `hermes-backup-sync.sh verify` | Compare local vs remote manifest |
| `hermes-backup-sync.sh prune --keep N` | Keep N most recent snapshots |
| `hermes-backup-sync.sh restore --to DIR` | Clone + decrypt into DIR |
| `hermes-backup-sync.sh init` | One-time setup: LFS track, age recipient |

### Cron wiring

```bash
# Place the script where your Hermes cron can find it:
cp scripts/hermes-backup-sync.sh /opt/data/cron/scripts/

cronjob action=create \
  name=hermes-backup-sync \
  schedule="0 16 * * *" \
  script="hermes-backup-sync.sh" \
  no_agent=true \
  deliver=local
```

## Procedure

1. **Pre-flight**: load config; check `git-lfs`, `age`, `jq`, `rsync`, `python3`; ensure `GITHUB_TOKEN` and `AGE_RECIPIENT` resolve. Hard-fail otherwise.
2. **Visibility check**: GET `https://api.github.com/repos/<owner>/<repo>`; abort if `private != true` (unless `verify_remote_private: false`).
3. **Clone or pull** the remote into `workdir`, branch checked out, `chmod 700`.
4. **Stage**: rsync each `include` entry from `data_path` into the workdir, applying `exclude` and `lfs.patterns`. Tag LFS paths so the next `git add` uploads via LFS.
5. **Encrypt**: for each path in `encrypt:`, age-encrypt into `<path>.age`; remove the plaintext from the staging area.
6. **Manifest**: write `MANIFEST.json` with `{path: {sha256, size, mode, lfs, encrypted}}`.
7. **Commit + push**: `git add -A && git commit -m "hermes-backup-sync: <UTC ts>" && git push origin HEAD`. If `--dry-run`, stop here.
8. **Notify**: on success/failure per `notify:` policy.
9. **Retention**: prune `workdir/_snapshots/` (one timestamped copy kept per run) to `keep_local` entries.

Completion criterion: each numbered step has a single side effect you can grep for (`[OK] visibility=private`, `[OK] staged N paths`, `[OK] committed <sha>`, `[OK] pushed to <remote>`, `[OK] notify=...`). `--dry-run` prints the same lines with `[DRY]` prefix.

## Pitfalls

- **Public-repo push is refused.** If you accidentally point at a public repo, the script exits non-zero before staging. Set `verify_remote_private: false` only on private networks where you've already verified by hand.
- **PAT in `~/.git/config`.** The remote URL embeds the token. `workdir` is `chmod 700`; don't move it to `/tmp` on shared hosts — use `workdir:` under your home.
- **LFS quota.** GitHub gives 1 GB free LFS bandwidth/month; large binary backups will burn it. Keep `lfs.patterns` narrow, or use S3 + rclone instead.
- **SQLite WAL files.** `.db-shm` / `.db-wal` are silently excluded; on restore the database may need a `sqlite3 foo.db ".recover"` if it was mid-transaction. Prefer `sqlite3 .backup` for critical DBs.
- **Age key loss = data loss.** The repo holds `*.age` files, useless without the private key. Store `~/.config/hermes-backup-sync/key.txt` somewhere *outside* the backup repo (password manager, USB, etc.).
- **Idempotency.** Each run creates a timestamped commit; the remote grows ~1 commit per run. Use `prune` for local snapshots; remote history needs a separate GC if you care.
- **`--dry-run` skips encryption.** If your config has typos in `encrypt:`, you won't notice until a real run. Read the `[DRY] would encrypt` line.

## Verification

- **After every run:** `git log -1 --oneline` in `workdir` shows the new commit; `[OK] pushed` line in the log; `MANIFEST.json` updated.
- **Round trip:** `verify` subcommand downloads the latest remote manifest and prints per-file `OK`/`MISSING`/`MODIFIED` against local.
- **Cron proof:** the `cronjob` entry below invokes the script with `no_agent: true`; the next scheduled fire produces a commit within `timeout`.