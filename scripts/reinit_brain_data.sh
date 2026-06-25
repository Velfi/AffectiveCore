#!/usr/bin/env sh
set -eu

include_test=false
brain=default
while [ "$#" -gt 0 ]; do
  case "$1" in
    --include-test)
      include_test=true
      shift
      ;;
    --brain=*)
      brain=${1#--brain=}
      shift
      ;;
    --brain)
      shift
      if [ "$#" -eq 0 ]; then
        printf 'Missing value for --brain.\n' >&2
        printf 'Usage: %s [--brain <name>] [--include-test]\n' "$0" >&2
        exit 2
      fi
      brain=$1
      shift
      ;;
    --profile=*)
      brain=${1#--profile=}
      shift
      ;;
    --profile)
      shift
      if [ "$#" -eq 0 ]; then
        printf 'Missing value for --profile.\n' >&2
        printf 'Usage: %s [--brain <name>] [--include-test]\n' "$0" >&2
        exit 2
      fi
      brain=$1
      shift
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      printf 'Usage: %s [--brain <name>] [--include-test]\n' "$0" >&2
      exit 2
      ;;
  esac
done

case "$brain" in
  ""|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-]*)
    printf 'Invalid brain: %s\n' "$brain" >&2
    exit 2
    ;;
esac

: "${HOME:?HOME is required to reinitialize AffectiveCore brain data}"
: "${TMPDIR:?TMPDIR is required to reinitialize AffectiveCore scratch data}"

brain_root="$HOME/Library/Application Support/AffectiveCore/brains/$brain"
scratch_root="$TMPDIR/affective-core/brains/$brain"

rm -f data/events.jsonl
rm -f data/maintenance.md data/maintenance_state.json
rm -f data/memory/*.json data/memory/*.sqlite data/memory/*.sqlite-shm data/memory/*.sqlite-wal

rm -rf data/captures
rm -rf data/audio/input data/audio/output

mkdir -p data/memory data/captures data/audio/input data/audio/output
touch data/memory/.gitkeep

rm -f "$brain_root/events.jsonl"
rm -f "$brain_root/maintenance.md" "$brain_root/maintenance_state.json" "$brain_root/runtime_options.json"
rm -f "$brain_root/memory/people.sqlite" "$brain_root/memory/people.sqlite-shm" "$brain_root/memory/people.sqlite-wal"
rm -f "$brain_root/memory/relationships.sqlite" "$brain_root/memory/relationships.sqlite-shm" "$brain_root/memory/relationships.sqlite-wal"
rm -rf "$brain_root/memory/face_embeddings"
rm -rf "$brain_root/captures" "$brain_root/generated/images"
rm -rf "$scratch_root/captures" "$scratch_root/audio/input" "$scratch_root/audio/output"

mkdir -p "$brain_root/memory" "$brain_root/captures" "$brain_root/generated/images"
mkdir -p "$scratch_root/captures" "$scratch_root/audio/input" "$scratch_root/audio/output"

if [ "$include_test" = true ]; then
  rm -f data/test/*.json data/test/*.jsonl data/test/*.log
fi

printf 'AffectiveCore data reinitialized for brain %s' "$brain"
if [ "$include_test" = true ]; then
  printf ' (including generated test data)'
fi
printf '.\n'
