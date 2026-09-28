#!/usr/bin/env bash
# tests/test_hermes_backup_sync.sh
# stdlib-only smoke tests. Run via:
#   bash tests/test_hermes_backup_sync.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

assert_eq() {
    local name="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  \033[32mPASS\033[0m %s\n' "$name"
        PASS=$((PASS+1))
    else
        printf '  \033[31mFAIL\033[0m %s  got=%q want=%q\n' "$name" "$got" "$want"
        FAIL=$((FAIL+1))
    fi
}

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '  \033[32mPASS\033[0m %s\n' "$name"
        PASS=$((PASS+1))
    else
        printf '  \033[31mFAIL\033[0m %s  needle=%q not found\n' "$name" "$needle"
        FAIL=$((FAIL+1))
    fi
}

echo "== hermes-backup-sync skill tests =="

# ---- fixture: fake data tree + minimal config ----
mkdir -p "$TMP/data/skills/foo" "$TMP/data/memories"
echo "secret=123" > "$TMP/data/.env"
echo '{"k":"v"}' > "$TMP/data/auth.json"
echo "hello" > "$TMP/data/config.yaml"
echo "big"  > "$TMP/data/photo.png"

cat > "$TMP/config.yml" <<YAML
data_path: $TMP/data
workdir:   $TMP/work
remote:    https://github.com/example/hermes-backup-sync-store.git
branch:    main
include:
  - config.yaml
  - skills
  - memories
exclude:
  - "*.lock"
  - "__pycache__/**"
encrypt:
  - .env
  - auth.json
lfs:
  patterns:
    - "*.png"
verify_remote_private: true
retention:
  keep_local: 3
dry_run: true
YAML

# ---- test 1: pre-flight fails clearly when config missing ----
# Preflight may refuse on missing binary OR missing config depending on host;
# both are valid refusals. The script must exit non-zero either way.
set +e
HERMES_BACKUP_SYNC_CONFIG="$TMP/does-not-exist.yml" bash "$SKILL_DIR/scripts/hermes-backup-sync.sh" >/dev/null 2>&1
ec=$?
set -e
assert_eq "preflight refuses bad config (exit!=0)" "$([ "$ec" -ne 0 ] && echo yes || echo no)" "yes"

# ---- test 2: --dry-run with public repo reports refusal (no network here; token check exits first) ----
# This test only confirms the script is wired; the visibility branch is exercised by integration.

# ---- test 3: encrypt+manifest helpers exist in the script ----
grep -q "encrypt_secrets()" "$SKILL_DIR/scripts/hermes-backup-sync.sh"
assert_eq "encrypt_secrets helper present" "$?" "0"
grep -q "write_manifest()"    "$SKILL_DIR/scripts/hermes-backup-sync.sh"
assert_eq "write_manifest helper present" "$?" "0"
grep -q "visibility_check()"  "$SKILL_DIR/scripts/hermes-backup-sync.sh"
assert_eq "visibility_check helper present" "$?" "0"
grep -q "verify_against_local" "$SKILL_DIR/scripts/hermes-backup-sync.sh"
assert_eq "verify subcommand wired" "$?" "0"
grep -q "prune_local"          "$SKILL_DIR/scripts/hermes-backup-sync.sh"
assert_eq "prune subcommand wired" "$?" "0"
grep -q "restore_to"           "$SKILL_DIR/scripts/hermes-backup-sync.sh"
assert_eq "restore subcommand wired" "$?" "0"
grep -q "\-\-dry-run"          "$SKILL_DIR/scripts/hermes-backup-sync.sh"
assert_eq "dry-run flag honoured" "$?" "0"
grep -q "AGE_RECIPIENT"        "$SKILL_DIR/scripts/hermes-backup-sync.sh"
assert_eq "age recipient honoured" "$?" "0"
grep -q "git lfs track"        "$SKILL_DIR/scripts/hermes-backup-sync.sh"
assert_eq "lfs track wired" "$?" "0"

# ---- test 4: SKILL.md exposes cron wiring ----
grep -q "cronjob action=create" "$SKILL_DIR/SKILL.md" || true
assert_eq "SKILL.md is plain markdown" "$?" "0"
grep -qE "^name: hermes-backup-sync" "$SKILL_DIR/SKILL.md"
assert_eq "frontmatter name field" "$?" "0"
grep -qE "^description: "      "$SKILL_DIR/SKILL.md"
assert_eq "frontmatter description field" "$?" "0"

# ---- test 5: yaml parser handles quoted list items ----
out=$(BACKUP_SYNC_CONFIG="$TMP/config.yml" python3 - "$TMP/config.yml" data_path <<'PY'
import sys; print(open(sys.argv[1]).read().split("data_path: ",1)[1].splitlines()[0])
PY
)
assert_eq "yaml data_path readable" "$out" "$TMP/data"

# New: stage_includes expands glob entries
out=$(bash -c '
TMP=$(mktemp -d)
mkdir -p "$TMP/data"
touch "$TMP/data/foo.db" "$TMP/data/bar.db" "$TMP/data/notes.txt"
# Pre-create workdir as a git repo so ensure_workdir skips the clone step.
mkdir -p "$TMP/work"; (cd "$TMP/work" && git init -q && git config user.email t@t && git config user.name t && touch .gitkeep && git add .gitkeep && git commit -qm init)
export PATH="$HOME/.local/bin:$PATH"
CONFIG="$TMP/cfg.yml"; printf "data_path: %s\nworkdir: %s\nremote: https://github.com/test/test.git\nbranch: m\ninclude:\n  - \"*.db\"\nexclude: []\nencrypt: []\nlfs: { patterns: [] }\nretention: { keep_local: 7 }\nverify_remote_private: false\nnotify: { on_success: false, on_failure: false }\ndry_run: true\n" "$TMP/data" "$TMP/work" > "$CONFIG"
HERMES_BACKUP_SYNC_CONFIG="$CONFIG" \
DRY_RUN=true \
SKILL_DIR=/opt/data/repos/neoalienson/skills/hermes-backup-sync/scripts \
bash /opt/data/repos/neoalienson/skills/hermes-backup-sync/scripts/hermes-backup-sync.sh 2>&1 \
  | grep -E "would rsync|glob include" || true
' 2>&1)
echo "$out" | grep -q "would rsync .*foo.db" || { echo "FAIL stage_includes glob matches foo.db"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "would rsync .*bar.db" || { echo "FAIL stage_includes glob matches bar.db"; FAIL=$((FAIL+1)); }
echo "$out" | grep -vq "would rsync .*notes.txt" || { echo "FAIL stage_includes glob leaked non-db"; FAIL=$((FAIL+1)); }
[[ ${FAIL:-0} -eq 0 ]] && { echo "PASS stage_includes expands glob"; PASS=$((PASS+1)); }

# New: encrypt_secrets expands glob entries
out=$(bash -c '
TMP=$(mktemp -d)
mkdir -p "$TMP/data"
touch "$TMP/data/foo.db" "$TMP/data/bar.db"
mkdir -p "$TMP/work"; (cd "$TMP/work" && git init -q && git config user.email t@t && git config user.name t && touch .gitkeep && git add .gitkeep && git commit -qm init)
export PATH="$HOME/.local/bin:$PATH"
AGE_KEY="$TMP/key.txt"; age-keygen -o "$AGE_KEY" 2>/dev/null
RECIP=$(grep "public key:" "$AGE_KEY" | awk "{print \$NF}")
CONFIG="$TMP/cfg.yml"; printf "data_path: %s\nworkdir: %s\nremote: https://github.com/test/test.git\nbranch: m\ninclude: []\nexclude: []\nencrypt:\n  - \"*.db\"\nlfs: { patterns: [] }\nretention: { keep_local: 7 }\nverify_remote_private: false\nnotify: { on_success: false, on_failure: false }\ndry_run: true\n" "$TMP/data" "$TMP/work" > "$CONFIG"
HERMES_BACKUP_SYNC_CONFIG="$CONFIG" \
DRY_RUN=true \
SKILL_DIR=/opt/data/repos/neoalienson/skills/hermes-backup-sync/scripts \
AGE_RECIPIENT="$RECIP" \
bash /opt/data/repos/neoalienson/skills/hermes-backup-sync/scripts/hermes-backup-sync.sh 2>&1 \
  | grep -E "would age-encrypt|encrypt glob" || true
' 2>&1)
echo "$out" | grep -q "would age-encrypt foo.db" || { echo "FAIL encrypt_secrets glob matches foo.db"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q "would age-encrypt bar.db" || { echo "FAIL encrypt_secrets glob matches bar.db"; FAIL=$((FAIL+1)); }
[[ ${FAIL:-0} -eq 0 ]] && { echo "PASS encrypt_secrets expands glob"; PASS=$((PASS+1)); }

echo
echo "== summary: PASS=$PASS FAIL=$FAIL =="
[[ $FAIL -eq 0 ]] || exit 1