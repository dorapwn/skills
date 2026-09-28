# hermes-backup-sync

Encrypted backup of a local data tree (default: `/opt/data`) to a **private** GitHub repo. Sensitive files are age-encrypted in-transit, large binaries ride Git LFS, every run emits a `MANIFEST.json` for verification. Pure bash + small Python helpers — safe for `cronjob` (no LLM tokens burned).

A skill for the [Hermes Agent](https://hermes-agent.nousresearch.com). See [`SKILL.md`](./SKILL.md) for the agent-facing usage and triggers; this README is for you, the human, when you need to install, run, recover, or troubleshoot.

---

## Install

### 1. Prerequisites

```bash
# Debian / Ubuntu
sudo apt-get install -y git-lfs age jq rsync python3
git lfs install

# macOS
brew install git-lfs age jq rsync python3
git lfs install
```

### 2. Generate an age keypair

```bash
mkdir -p ~/.config/hermes-backup-sync
age-keygen -o ~/.config/hermes-backup-sync/key.txt
# Prints: Public key: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

**Save `key.txt` somewhere outside this machine.** USB stick, password manager, second host — anywhere. Without it, every encrypted blob in the backup repo is unrecoverable. The script intentionally does *not* store the private key in the backup repo.

### 3. Create the GitHub side

1. Create a **private** repo (suggested name: `hermes-backup-sync-store`). Don't initialize with README/license/.gitignore.
2. Create a fine-grained PAT scoped to that one repo, with **Contents: Read & Write** + **LFS: Read & Write**. (Classic `repo` works too, just broader.)
3. Export:
   ```bash
   export GITHUB_TOKEN="ghp_..."
   export GITHUB_USER="your-github-handle"
   ```

### 4. Edit `config.yml`

Set the four values that matter:

```yaml
data_path: /opt/data
workdir:   /var/tmp/hermes-backup-sync
remote:    https://github.com/<your-handle>/hermes-backup-sync-store.git
branch:    main
```

The rest (`include:`, `exclude:`, `encrypt:`, `lfs:`, retention) has sane defaults — review them before your first sync.

### 5. First run

```bash
# Dry run (no writes, no push) — review the plan
bash scripts/hermes-backup-sync.sh --dry-run

# Real sync
bash scripts/hermes-backup-sync.sh --real
```

---

## Daily use

```bash
bash scripts/hermes-backup-sync.sh --real      # push to remote
bash scripts/hermes-backup-sync.sh --dry-run   # show plan only
bash scripts/hermes-backup-sync.sh verify      # diff local vs latest remote
bash scripts/hermes-backup-sync.sh prune --keep 7   # prune local snapshots
```

### Cron

```bash
cp scripts/hermes-backup-sync.sh /opt/data/cron/scripts/

cronjob action=create \
  name=hermes-backup-sync \
  schedule="0 16 * * *" \
  script="hermes-backup-sync.sh" \
  no_agent=true \
  deliver=local
```

See `SKILL.md` → "Cron wiring" for the canonical recipe.

---

## Restoring From a Backup

The repo holds: plaintext config (`config.yaml`, `SOUL.md`, `skills/`, etc.), `*.age` files (secrets), LFS objects (large files), and `MANIFEST.json` (sha256 + size per file). Recovery is two parts: clone the repo, then decrypt the `.age` blobs with the **age private key** — which lives *outside* the backup repo by design.

### Step 1 — locate your private key

```bash
test -f ~/.config/hermes-backup-sync/key.txt && echo OK || echo MISSING
head -1 ~/.config/hermes-backup-sync/key.txt
grep "^AGE-SECRET-KEY" ~/.config/hermes-backup-sync/key.txt
```

If `MISSING`, get the key from your off-machine backup first. The rest of this guide assumes the key is on disk.

### Step 2 — clone the backup repo

```bash
git clone https://github.com/<your-handle>/hermes-backup-sync-store.git /restore/repo
cd /restore/repo
git lfs install --local
git lfs pull              # downloads LFS objects (large files)
ls *.age                  # encrypted secrets waiting for the key
```

If the repo is private and you don't have a credential helper, pass the PAT inline:

```bash
git clone https://oauth2:$GITHUB_TOKEN@github.com/<your-handle>/hermes-backup-sync-store.git /restore/repo
```

### Step 3 — decrypt the secrets

**Script path** (one command, requires the key on disk):

```bash
export AGE_KEY=~/.config/hermes-backup-sync/key.txt
bash scripts/hermes-backup-sync.sh restore --to /restore/combined
# /restore/combined now has config.yaml, skills/, AND decrypted .env / auth.json
```

The script clones into a tmpdir, rsyncs everything except `_snapshots/` and `.git/`, finds every `*.age`, runs `age -d -i $AGE_KEY` on each, and deletes the `.age` on success. On failure it leaves the `.age` in place and prints `decrypt failed: <path>`.

**Manual path** (no script needed, useful when restoring to a machine that doesn't have hermes-backup-sync installed):

```bash
cd /restore/repo
export AGE_KEY=~/.config/hermes-backup-sync/key.txt
find . -name '*.age' | while read f; do
    age -d -i "$AGE_KEY" -o "${f%.age}" "$f" && rm "$f"
done
ls    # .env, auth.json, install_id, key.txt, hosts.yml now in plaintext
```

To decrypt one file at a time:

```bash
age -d -i ~/.config/hermes-backup-sync/key.txt< .env.age
# or
age -d -i ~/.config/hermes-backup-sync/key.txt .env.age
```

### Step 4 — verify against MANIFEST.json

```bash
cd /restore/repo
jq -r '.entries | to_entries[] | "\(.value.sha256)  \(.key)"' MANIFEST.json | \
    while read sha path; do
        actual=$(sha256sum "$path" 2>/dev/null | awk '{print $1}')
        [[ "$sha" == "$actual" ]] || echo "MISMATCH $path"
    done
```

Any output means corruption. LFS files show only a tiny pointer in the regular tree; `git lfs ls-files` confirms they materialised locally.

### Step 5 — drop into place

For a hermes data dir on a fresh machine:

```bash
rsync -a /restore/combined/config.yaml /restore/combined/SOUL.md /opt/data/
rsync -a /restore/combined/skills/ /restore/combined/memories/ /restore/combined/cron/ /opt/data/
# Install age + jq + rsync + git-lfs (see Prerequisites) before re-running the skill.
```

### What if I lost the private key?

There is no recovery for old `.age` blobs. The script intentionally does **not** store the private key in the backup repo — that's the threat model. If you lose the key:

1. Pull the current `/opt/data` directly (you can still read it).
2. Generate a new keypair: `age-keygen -o ~/.config/hermes-backup-sync/key.txt`.
3. Update `AGE_RECIPIENT` in `.env` to the new public key.
4. Run a real sync to re-encrypt everything with the new key.

Old `.age` blobs on the remote are unrecoverable but harmless — they'll be replaced on the next push.

---

## Files

```
hermes-backup-sync/
├── README.md                              # this file (you are here)
├── SKILL.md                               # agent-facing: triggers, prereqs, procedure
├── config.yml                             # your data_path / include / exclude / encrypt
├── scripts/
│   └── hermes-backup-sync.sh              # main script
└── tests/
    └── test_hermes_backup_sync.sh         # 14-test smoke suite
```

---

## Security notes

- **The script refuses to push to a public repo.** It checks the target repo's visibility via the GitHub API before every sync and aborts if the repo is public.
- **No private keys in the backup repo.** The age keypair lives at `~/.config/hermes-backup-sync/key.txt` and is *never* included in `config.yml` — only its public-key counterpart (`AGE_RECIPIENT`) is used.
- **The PAT lives in the clone's `.git/config`.** The script `chmod`s the workdir to `700` so other local users can't read it. Don't move the workdir to `/tmp` on shared hosts.
- **LFS bandwidth is metered.** GitHub gives 1 GB/month free; large binary backups burn it. Keep `lfs.patterns` narrow or use S3 + rclone for bulk data.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `ERROR missing required binary: rsync` | Prereqs not installed | Install via apt/brew (see Prerequisites) |
| `visibility=public repo=...` | Remote is public | Make repo private on GitHub |
| `git push` fails with HTTP 408 | LFS upload too large or slow | Narrow `lfs.patterns`, or use S3 instead |
| `age: failed to decrypt` | Wrong key | Verify `$AGE_KEY` points at the right `key.txt` |
| `decrypt failed: <path>` in restore | One `.age` blob corrupted or wrong recipient | Restore that single file by hand from the matching `key.txt` |
| Backup is huge | `include:` is grabbing too much | Add patterns to `exclude:`; remember comments start with `#` |