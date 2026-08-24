#!/usr/bin/env bash
# Persist bounded, real code progress for one assigned issue between sweeps.
set -Eeuo pipefail

export GH_PROMPT_DISABLED=1
export NO_COLOR=1

STATE_DIR="${GOOD_FELLOW_STATE_DIR:-$HOME/.good-fellow}"
WORKTREE_ROOT="${GOOD_FELLOW_WORKTREE_ROOT:-$STATE_DIR/worktrees}"
MAX_ATTEMPTS="${GOOD_FELLOW_ISSUE_HANDOFF_MAX_ATTEMPTS:-3}"
MAX_AGE_SECONDS="${GOOD_FELLOW_ISSUE_HANDOFF_MAX_AGE_SECONDS:-86400}"
MAX_PAYLOAD_BYTES=1048576
MAGIC='good-fellow-issue-handoff-v1'
TEMP_FILE=''
PAYLOAD_COPY=''

cleanup() {
  [ -z "$TEMP_FILE" ] || rm -f "$TEMP_FILE"
  [ -z "$PAYLOAD_COPY" ] || rm -f "$PAYLOAD_COPY"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

usage() {
  printf '%s\n' \
    'usage: issue-handoff.sh save OWNER REPO NUMBER ISSUE_PROOF BASE_SHA PHASE PROGRESS_FILE' \
    '       issue-handoff.sh match OWNER REPO NUMBER ISSUE_PROOF BASE_SHA' \
    '       issue-handoff.sh payload OWNER REPO NUMBER' \
    '       issue-handoff.sh clear OWNER REPO NUMBER' \
    '       issue-handoff.sh show' \
    '       issue-handoff.sh resume-key' >&2
  exit 64
}

die() {
  printf 'issue-handoff: %s\n' "$*" >&2
  exit 64
}

validate_component() {
  case "$2" in ''|*[!A-Za-z0-9_.-]*) die "invalid $1" ;; esac
}

validate_number() {
  case "$1" in ''|0|*[!0-9]*) die 'invalid issue number' ;; esac
}

validate_oid() {
  case "$2" in ''|*[!0-9a-f]*) die "invalid $1" ;; esac
  [ "${#2}" -eq 40 ] || die "invalid $1"
}

validate_proof() {
  case "$1" in ''|*[!0-9a-f]*) die 'invalid issue proof' ;; esac
  [ "${#1}" -eq 64 ] || die 'invalid issue proof'
}

validate_phase() {
  case "$1" in implementing|testing) ;; *) die 'phase must be implementing or testing' ;; esac
}

validate_positive() {
  case "$2" in ''|0|*[!0-9]*) die "invalid $1" ;; esac
}

validate_target() {
  validate_component owner "$1"
  validate_component repository "$2"
  validate_number "$3"
}

validate_config() {
  validate_positive GOOD_FELLOW_ISSUE_HANDOFF_MAX_ATTEMPTS "$MAX_ATTEMPTS"
  validate_positive GOOD_FELLOW_ISSUE_HANDOFF_MAX_AGE_SECONDS "$MAX_AGE_SECONDS"
}

ensure_state_dir() {
  if [ -e "$STATE_DIR" ] || [ -L "$STATE_DIR" ]; then
    [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || die 'state directory must be a real directory'
  else
    umask 077
    mkdir -p "$STATE_DIR"
  fi
}

handoff_path() {
  printf '%s/fix-assigned-issues-handoff-%s-%s-%s-%s-%s.state\n' \
    "$STATE_DIR" "${#1}" "$1" "${#2}" "$2" "$3"
}

expected_worktree() {
  printf '%s/%s-issue-%s\n' "$WORKTREE_ROOT" "$2" "$3"
}

read_line() {
  sed -n "$2"'p;'"$2"'q' "$1"
}

validate_regular_file() {
  [ -f "$1" ] && [ ! -L "$1" ] || die "$2 must be a regular file"
}

load_handoff() {
  local file=$1 actual_size expected
  validate_regular_file "$file" 'handoff file'
  STORED_MAGIC=$(read_line "$file" 1)
  STORED_OWNER=$(read_line "$file" 2)
  STORED_REPO=$(read_line "$file" 3)
  STORED_NUMBER=$(read_line "$file" 4)
  STORED_PROOF=$(read_line "$file" 5)
  STORED_BASE=$(read_line "$file" 6)
  STORED_HEAD=$(read_line "$file" 7)
  STORED_PHASE=$(read_line "$file" 8)
  STORED_ATTEMPTS=$(read_line "$file" 9)
  STORED_CREATED=$(read_line "$file" 10)
  STORED_UPDATED=$(read_line "$file" 11)
  STORED_WORKTREE=$(read_line "$file" 12)
  STORED_SIZE=$(read_line "$file" 13)
  [ "$STORED_MAGIC" = "$MAGIC" ] || die 'invalid handoff format'
  validate_target "$STORED_OWNER" "$STORED_REPO" "$STORED_NUMBER"
  validate_proof "$STORED_PROOF"
  validate_oid 'stored base SHA' "$STORED_BASE"
  validate_oid 'stored work HEAD' "$STORED_HEAD"
  validate_phase "$STORED_PHASE"
  validate_positive 'stored attempt count' "$STORED_ATTEMPTS"
  validate_positive 'stored creation time' "$STORED_CREATED"
  validate_positive 'stored update time' "$STORED_UPDATED"
  expected=$(expected_worktree "$STORED_OWNER" "$STORED_REPO" "$STORED_NUMBER")
  [ "$STORED_WORKTREE" = "$expected" ] || die 'stored worktree path is not canonical'
  case "$STORED_SIZE" in ''|*[!0-9]*) die 'invalid stored payload size' ;; esac
  [ "$STORED_SIZE" -le "$MAX_PAYLOAD_BYTES" ] || die 'stored payload exceeds 1 MiB'
  actual_size=$(tail -n +14 "$file" | wc -c | tr -d ' ')
  [ "$actual_size" = "$STORED_SIZE" ] || die 'stored payload size mismatch'
}

load_handoff_for_scan() {
  local file=$1
  if ! (load_handoff "$file") >/dev/null 2>&1; then
    printf 'issue-handoff: ignoring invalid state file %s\n' "$file" >&2
    return 1
  fi
  load_handoff "$file"
}

require_key_match() {
  [ "$STORED_OWNER" = "$1" ] && [ "$STORED_REPO" = "$2" ] && [ "$STORED_NUMBER" = "$3" ] ||
    die 'handoff key does not match file contents'
}

inspect_worktree() {
  local owner=$1 repo=$2 number=$3 base=$4 expected real branch dirty
  expected=$(expected_worktree "$owner" "$repo" "$number")
  [ -d "$expected" ] && [ ! -L "$expected" ] || die 'issue worktree is missing or unsafe'
  real=$(CDPATH='' cd "$expected" && pwd -P)
  [ "$real" = "$expected" ] || die 'issue worktree path is not canonical'
  [ "$(git -C "$expected" rev-parse --show-toplevel)" = "$expected" ] || die 'issue worktree root mismatch'
  branch=$(git -C "$expected" symbolic-ref --quiet --short HEAD) || die 'issue worktree is detached'
  [ "$branch" = "good-fellow/issue-$number" ] || die 'issue worktree is on the wrong branch'
  dirty=$(git -C "$expected" status --porcelain=v1)
  [ -z "$dirty" ] || die 'checkpoint requires a clean issue worktree'
  WORKTREE_HEAD=$(git -C "$expected" rev-parse HEAD)
  validate_oid 'worktree HEAD' "$WORKTREE_HEAD"
  git -C "$expected" merge-base --is-ancestor "$base" "$WORKTREE_HEAD" ||
    die 'saved base is not an ancestor of the worktree HEAD'
  WORKTREE_PATH=$expected
}

validate_config
mode=${1:-}
case "$mode" in
  save)
    [ "$#" -eq 8 ] || usage
    validate_target "$2" "$3" "$4"
    validate_proof "$5"
    validate_oid 'base SHA' "$6"
    validate_phase "$7"
    validate_regular_file "$8" 'progress file'
    inspect_worktree "$2" "$3" "$4" "$6"
    [ "$WORKTREE_HEAD" != "$6" ] || die 'handoff requires at least one local checkpoint commit'
    payload_size=$(wc -c < "$8" | tr -d ' ')
    case "$payload_size" in ''|*[!0-9]*) die 'invalid payload size' ;; esac
    [ "$payload_size" -le "$MAX_PAYLOAD_BYTES" ] || die 'payload exceeds 1 MiB'
    umask 077
    PAYLOAD_COPY=$(mktemp "${TMPDIR:-/tmp}/good-fellow-issue-handoff-payload.XXXXXX")
    dd if="$8" of="$PAYLOAD_COPY" bs=65536 2>/dev/null
    cmp -s "$8" "$PAYLOAD_COPY" || { printf 'issue-handoff: progress changed while copying\n' >&2; exit 3; }
    ensure_state_dir
    file=$(handoff_path "$2" "$3" "$4")
    now=$(date +%s)
    attempts=1
    created=$now
    if [ -e "$file" ] || [ -L "$file" ]; then
      load_handoff "$file"
      require_key_match "$2" "$3" "$4"
      [ "$STORED_PROOF" = "$5" ] && [ "$STORED_BASE" = "$6" ] || {
        printf 'issue-handoff: issue or base changed; do not overwrite the old handoff\n' >&2
        exit 3
      }
      [ "$STORED_HEAD" != "$WORKTREE_HEAD" ] || die 'handoff save made no checkpoint progress'
      git -C "$WORKTREE_PATH" merge-base --is-ancestor "$STORED_HEAD" "$WORKTREE_HEAD" ||
        die 'new checkpoint does not descend from the saved work HEAD'
      attempts=$((STORED_ATTEMPTS + 1))
      created=$STORED_CREATED
    else
      other_count=0
      for other in "$STATE_DIR"/fix-assigned-issues-handoff-*.state; do
        [ -e "$other" ] || [ -L "$other" ] || continue
        load_handoff_for_scan "$other" || continue
        other_count=$((other_count + 1))
      done
      [ "$other_count" -eq 0 ] || die 'another assigned issue already owns the continuation slot'
    fi
    [ "$attempts" -le "$MAX_ATTEMPTS" ] || {
      printf 'issue-handoff: continuation attempt limit reached\n' >&2
      exit 4
    }
    TEMP_FILE=$(mktemp "$STATE_DIR/fix-assigned-issues-handoff.XXXXXX")
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      "$MAGIC" "$2" "$3" "$4" "$5" "$6" "$WORKTREE_HEAD" "$7" \
      "$attempts" "$created" "$now" "$WORKTREE_PATH" "$payload_size" > "$TEMP_FILE"
    dd if="$PAYLOAD_COPY" bs=65536 2>/dev/null >> "$TEMP_FILE"
    chmod 600 "$TEMP_FILE"
    mv -f "$TEMP_FILE" "$file"
    TEMP_FILE=''
    ;;
  match)
    [ "$#" -eq 6 ] || usage
    validate_target "$2" "$3" "$4"
    validate_proof "$5"
    validate_oid 'base SHA' "$6"
    file=$(handoff_path "$2" "$3" "$4")
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then exit 1; fi
    load_handoff "$file"
    require_key_match "$2" "$3" "$4"
    inspect_worktree "$2" "$3" "$4" "$STORED_BASE"
    if [ "$STORED_PROOF" != "$5" ] || [ "$STORED_BASE" != "$6" ] ||
       [ "$STORED_HEAD" != "$WORKTREE_HEAD" ]; then
      printf 'issue-handoff: issue, base, or worktree changed; re-evaluation required\n' >&2
      exit 3
    fi
    now=$(date +%s)
    age=$((now - STORED_CREATED))
    if [ "$STORED_ATTEMPTS" -ge "$MAX_ATTEMPTS" ] || [ "$age" -gt "$MAX_AGE_SECONDS" ]; then
      printf 'issue-handoff: bounded continuation expired\n' >&2
      exit 4
    fi
    printf '%s\t%s\t%s\n' "$STORED_PHASE" "$STORED_ATTEMPTS" "$STORED_WORKTREE"
    ;;
  payload)
    [ "$#" -eq 4 ] || usage
    validate_target "$2" "$3" "$4"
    file=$(handoff_path "$2" "$3" "$4")
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then exit 1; fi
    load_handoff "$file"
    require_key_match "$2" "$3" "$4"
    tail -n +14 "$file"
    ;;
  clear)
    [ "$#" -eq 4 ] || usage
    validate_target "$2" "$3" "$4"
    file=$(handoff_path "$2" "$3" "$4")
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then exit 0; fi
    validate_regular_file "$file" 'handoff file'
    find "$file" -type f -delete
    ;;
  show)
    [ "$#" -eq 1 ] || usage
    for file in "$STATE_DIR"/fix-assigned-issues-handoff-*.state; do
      [ -e "$file" ] || [ -L "$file" ] || continue
      load_handoff_for_scan "$file" || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$STORED_OWNER" "$STORED_REPO" "$STORED_NUMBER" "$STORED_PROOF" \
        "$STORED_BASE" "$STORED_HEAD" "$STORED_PHASE" "$STORED_ATTEMPTS" \
        "$STORED_CREATED" "$STORED_UPDATED" "$STORED_WORKTREE"
    done
    ;;
  resume-key)
    [ "$#" -eq 1 ] || usage
    found=''
    for file in "$STATE_DIR"/fix-assigned-issues-handoff-*.state; do
      [ -e "$file" ] || [ -L "$file" ] || continue
      load_handoff_for_scan "$file" || continue
      [ -z "$found" ] || die 'multiple assigned-issue handoffs violate serial continuation'
      found=$file
    done
    if [ -n "$found" ]; then
      load_handoff "$found"
      printf '%s\t%s\n' "https://api.github.com/repos/$STORED_OWNER/$STORED_REPO" "$STORED_NUMBER"
    fi
    ;;
  *) usage ;;
esac
