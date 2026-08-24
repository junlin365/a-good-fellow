#!/usr/bin/env bash
# Cross-skill receipts bind owner coverage to an exact GitHub notification thread
# version. Receipts remain for at most about one day so a later tick can finish
# cleanup after a crash without creating a multi-day stale-coverage window.
set -Eeuo pipefail

export GH_PROMPT_DISABLED=1
export NO_COLOR=1

STATE_DIR="${GOOD_FELLOW_STATE_DIR:-$HOME/.good-fellow}"
RUN_ID="${GOOD_FELLOW_RUN_STARTED_AT_EPOCH:-manual-$$}"
TAB=$(printf '\t')
TEMP_FILE=''
PROOF_ONE=''
PROOF_TWO=''

case "$RUN_ID" in ''|*[!A-Za-z0-9_-]*) printf 'notification-receipts: invalid run id\n' >&2; exit 64 ;; esac

cleanup() {
  [ -z "$TEMP_FILE" ] || rm -f "$TEMP_FILE"
  [ -z "$PROOF_ONE" ] || rm -f "$PROOF_ONE"
  [ -z "$PROOF_TWO" ] || rm -f "$PROOF_TWO"
}
trap cleanup EXIT

usage() {
  printf '%s\n' \
    'usage: notification-receipts.sh observe TYPE REPO_URL NUMBER THREAD_ID' \
    '       notification-receipts.sh record TYPE REPO_URL NUMBER THREAD_ID UPDATED_AT LAST_READ_AT OUTCOME HEAD PROOF' \
    '       notification-receipts.sh lookup TYPE REPO_URL NUMBER THREAD_ID UPDATED_AT LAST_READ_AT' \
    '       notification-receipts.sh consume TYPE REPO_URL NUMBER THREAD_ID UPDATED_AT LAST_READ_AT' \
    '       notification-receipts.sh subject-proof TYPE REPO_URL NUMBER' \
    '       notification-receipts.sh prune' >&2
  exit 64
}

# Keep the URL grammar identical to pr-queue.sh validate_key: both key files in
# the shared state dir, and reply-notifications reconciles against process-prs
# coverage, so the accepted key space must match. Update the twin together.
validate_key() {
  local rest owner name
  case "$1" in pr|issue|discussion) ;; *) printf 'notification-receipts: invalid type\n' >&2; return 64 ;; esac
  case "$2" in https://api.github.com/repos/*/*) ;; *) printf 'notification-receipts: invalid repository URL\n' >&2; return 64 ;; esac
  rest=${2#https://api.github.com/repos/}
  owner=${rest%%/*}
  name=${rest#*/}
  case "$owner" in ''|*[!A-Za-z0-9_.-]*) printf 'notification-receipts: invalid owner\n' >&2; return 64 ;; esac
  case "$name" in ''|*/*|*[!A-Za-z0-9_.-]*) printf 'notification-receipts: invalid repository\n' >&2; return 64 ;; esac
  case "$3" in ''|0|*[!0-9]*) printf 'notification-receipts: invalid number\n' >&2; return 64 ;; esac
}

validate_thread() {
  case "$1" in ''|0|*[!0-9]*) printf 'notification-receipts: invalid thread id\n' >&2; return 64 ;; esac
}

validate_updated_at() {
  case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;; *) printf 'notification-receipts: invalid updated_at\n' >&2; return 64 ;; esac
}

capture_subject() {
  local type=$1 repo_url=$2 number=$3 output=$4 repo_path rest owner repo_name discussion_query discussion_filter
  repo_path=${repo_url#https://api.github.com/}
  case "$type" in
    issue)
      gh api "$repo_path/issues/$number" --jq '
        if .pull_request then error("subject is a pull request") else
        ["issue",.id,.number,.state,.state_reason,.title,.body,.locked,
         .active_lock_reason,.user.login,
         ([.assignees[].login] | sort),
         ([.labels[].name] | sort)] | @json end' > "$output"
      gh api "$repo_path/issues/$number/comments?per_page=100" --paginate --jq '
        .[] | ["comment",.id,.user.login,.body,.created_at,.updated_at,
        .author_association] | @json' | LC_ALL=C sort >> "$output"
      ;;
    discussion)
      rest=${repo_url#https://api.github.com/repos/}
      owner=${rest%%/*}
      repo_name=${rest#*/}
      discussion_query='query($o:String!,$r:String!,$n:Int!){
        repository(owner:$o,name:$r){discussion(number:$n){
          id number title body closed locked createdAt updatedAt category{id} answer{id}
          comments(first:100){pageInfo{hasNextPage} nodes{
            id author{login} body createdAt updatedAt lastEditedAt isAnswer isMinimized minimizedReason
            replies(first:100){pageInfo{hasNextPage} nodes{
              id author{login} body createdAt updatedAt lastEditedAt isAnswer isMinimized minimizedReason replyTo{id}
            }}
          }}
        }}
      }'
      discussion_filter='.data.repository.discussion as $d |
        if $d == null then error("discussion not found")
        elif $d.comments.pageInfo.hasNextPage then error("discussion exceeds 100 comments")
        elif ([ $d.comments.nodes[] | select(.replies.pageInfo.hasNextPage) ] | length) > 0
          then error("a discussion comment exceeds 100 replies")
        else ["discussion",$d.id,$d.number,$d.title,$d.body,$d.closed,$d.locked,
          $d.createdAt,$d.updatedAt,($d.category.id // null),($d.answer.id // null),
          ([ $d.comments.nodes[] | [
            .id,(.author.login // null),.body,.createdAt,.updatedAt,.lastEditedAt,
            .isAnswer,.isMinimized,.minimizedReason,
            ([ .replies.nodes[] | [
              .id,(.author.login // null),.body,.createdAt,.updatedAt,.lastEditedAt,
              .isAnswer,.isMinimized,.minimizedReason,(.replyTo.id // null)
            ]] | sort_by(.[0]))
          ]] | sort_by(.[0]))] | @json end'
      gh api graphql -f query="$discussion_query" -f o="$owner" -f r="$repo_name" \
        -F n="$number" --jq "$discussion_filter" > "$output"
      ;;
    *) printf 'notification-receipts: subject proof supports issue/discussion only\n' >&2; return 64 ;;
  esac
}

# Digest scheme twin of pr-review-guard.sh digest_string: proofs and guard
# tokens are cross-validated by each other's 64-hex checks, so a change to the
# probe order, algorithm, or output shape must land in both.
hash_file() {
  local value
  if command -v sha256sum >/dev/null 2>&1; then
    value=$(sha256sum "$1" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    value=$(shasum -a 256 "$1" | awk '{print $1}')
  else
    printf 'notification-receipts: sha256sum or shasum is required\n' >&2
    return 64
  fi
  case "$value" in ''|*[!0-9a-f]*) printf 'notification-receipts: invalid subject proof\n' >&2; return 64 ;; esac
  [ "${#value}" -eq 64 ] || return 64
  printf '%s\n' "$value"
}

mode=${1:-}
case "$mode" in
  subject-proof)
    [ "$#" -eq 4 ] || usage
    validate_key "$2" "$3" "$4"
    [ "$2" != pr ] || { printf 'notification-receipts: PR proof is owned by pr-review-guard\n' >&2; exit 64; }
    umask 077
    PROOF_ONE=$(mktemp "${TMPDIR:-/tmp}/good-fellow-subject-proof.XXXXXX")
    PROOF_TWO=$(mktemp "${TMPDIR:-/tmp}/good-fellow-subject-proof.XXXXXX")
    capture_subject "$2" "$3" "$4" "$PROOF_ONE"
    capture_subject "$2" "$3" "$4" "$PROOF_TWO"
    cmp -s "$PROOF_ONE" "$PROOF_TWO" || {
      printf 'notification-receipts: subject changed while proving coverage\n' >&2
      exit 3
    }
    hash_file "$PROOF_ONE"
    ;;
  observe)
    [ "$#" -eq 5 ] || usage
    validate_key "$2" "$3" "$4"
    validate_thread "$5"
    case "$2" in
      pr) subject_type=PullRequest; subject_url="$3/pulls/$4" ;;
      issue) subject_type=Issue; subject_url="$3/issues/$4" ;;
      discussion) subject_type=Discussion; subject_url="$3/discussions/$4" ;;
    esac
    # The notifications API has returned subject.url = null for Discussion
    # subjects; identity then rests on thread id + repository + type, and the
    # caller is responsible for having resolved the discussion number from the
    # subject title. A non-null URL must still match exactly.
    if [ "$2" = discussion ]; then
      url_mismatch='((.subject.url != null) and (.subject.url != "'"$subject_url"'"))'
    else
      url_mismatch='(.subject.url != "'"$subject_url"'")'
    fi
    observe_filter='if ((.id|tostring) != "'"$5"'") or
      (.repository.url != "'"$3"'") or
      (.subject.type != "'"$subject_type"'") or
      '"$url_mismatch"'
      or (.unread != true) then error("notification identity/state mismatch")
      else [.updated_at,(.last_read_at // "-")] | @tsv end'
    observed=$(gh api "/notifications/threads/$5" --jq "$observe_filter")
    IFS=$'\t' read -r updated_at last_read_at <<< "$observed"
    validate_updated_at "$updated_at"
    if [ "$last_read_at" != - ]; then validate_updated_at "$last_read_at"; fi
    printf '%s\t%s\n' "$updated_at" "$last_read_at"
    ;;
  record)
    [ "$#" -eq 10 ] || usage
    validate_key "$2" "$3" "$4"
    validate_thread "$5"
    validate_updated_at "$6"
    if [ "$7" != - ]; then validate_updated_at "$7"; fi
    case "$2:$8" in
      pr:ready|pr:waiting-author|pr:ci-waiting|pr:commented|pr:approved|pr:fixed) ;;
      issue:fixed|issue:answered|issue:clarified|issue:needs-split) ;;
      discussion:answered|discussion:no-response-needed) ;;
      *) printf 'notification-receipts: invalid covered outcome\n' >&2; exit 64 ;;
    esac
    if [ "$9" != - ]; then
      case "$9" in ''|*[!0-9a-f]*) printf 'notification-receipts: invalid head\n' >&2; exit 64 ;; esac
      [ "${#9}" -eq 40 ] || { printf 'notification-receipts: invalid head\n' >&2; exit 64; }
    fi
    case "${10}" in ''|*[!0-9a-f]*) printf 'notification-receipts: invalid subject proof\n' >&2; exit 64 ;; esac
    [ "${#10}" -eq 64 ] || { printf 'notification-receipts: invalid subject proof\n' >&2; exit 64; }
    current_observed=$("$0" observe "$2" "$3" "$4" "$5")
    [ "$current_observed" = "$6$TAB$7" ] || {
      printf 'notification-receipts: notification changed before receipt write\n' >&2
      exit 3
    }
    mkdir -p "$STATE_DIR"
    umask 077
    rest=${3#https://api.github.com/repos/}
    receipt_owner=${rest%%/*}
    receipt_repo=${rest#*/}
    RECEIPT_FILE="$STATE_DIR/notification-receipts-$RUN_ID-$2-$receipt_owner-$receipt_repo-$4-$5.tsv"
    TEMP_FILE=$(mktemp "$STATE_DIR/notification-receipts.XXXXXX")
    [ ! -L "$RECEIPT_FILE" ] || { printf 'notification-receipts: receipt file must not be a symlink\n' >&2; exit 64; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TEMP_FILE"
    chmod 600 "$TEMP_FILE"
    mv -f "$TEMP_FILE" "$RECEIPT_FILE"
    TEMP_FILE=''
    ;;
  lookup|consume)
    [ "$#" -eq 7 ] || usage
    validate_key "$2" "$3" "$4"
    validate_thread "$5"
    validate_updated_at "$6"
    if [ "$7" != - ]; then validate_updated_at "$7"; fi
    # lookup and consume share one match predicate so a receipt that matches
    # for reading always matches for deletion, and vice versa.
    rest=${3#https://api.github.com/repos/}
    receipt_owner=${rest%%/*}
    receipt_repo=${rest#*/}
    receipt_suffix="-$2-$receipt_owner-$receipt_repo-$4-$5.tsv"
    found=''
    for file in "$STATE_DIR"/notification-receipts-*"$receipt_suffix"; do
      [ -f "$file" ] && [ ! -L "$file" ] || continue
      match_out=$(awk -F "$TAB" -v t="$2" -v r="$3" -v n="$4" -v i="$5" -v u="$6" -v l="$7" \
        '$1==t && $2==r && $3==n && $4==i && $5==u && $6==l {count++; row=$0}
         END {print count+0; if (count) print row}' "$file")
      match_count=${match_out%%$'\n'*}
      case "$match_count" in
        0) ;;
        1)
          if [ "$mode" = consume ]; then
            find "$file" -type f -delete
          else
            found=${match_out#*$'\n'}
          fi
          ;;
        *) printf 'notification-receipts: malformed duplicate receipt\n' >&2; exit 64 ;;
      esac
    done
    [ "$mode" = consume ] || [ -z "$found" ] || printf '%s\n' "$found"
    ;;
  prune)
    [ "$#" -eq 1 ] || usage
    for file in "$STATE_DIR"/notification-receipts-*.tsv; do
      [ -f "$file" ] && [ ! -L "$file" ] || continue
      find "$file" -type f -mtime +0 -delete 2>/dev/null || true
    done
    ;;
  *) usage ;;
esac
