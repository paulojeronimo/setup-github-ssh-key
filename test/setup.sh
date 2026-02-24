#!/usr/bin/env bash
set -euo pipefail

umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=../setup.sh
# shellcheck disable=SC1091
. "$repo_root/setup.sh"

usage() {
  cat <<'USAGE'
Usage:
  ./test/setup.sh

Vars:
  KEY_PATH        OpenSSH private key path (required)
  GPG_PASSPHRASE  Passphrase for encryption (required)
  SCRIPT_PATH     Path to setup.sh (default: ./setup.sh)

Var sources:
  1. test/.env (if present)
  2. test/.env.sample (fallback)
  3. already exported environment variables
USAGE
}

env_file=""
if [ -f "$repo_root/test/.env" ]; then
  env_file="$repo_root/test/.env"
elif [ -f "$repo_root/test/.env.sample" ]; then
  env_file="$repo_root/test/.env.sample"
fi

if [ -n "$env_file" ]; then
  set -a
  # shellcheck source=./test/.env.sample
  # shellcheck disable=SC1091
  . "$env_file"
  set +a
fi

key_path="${KEY_PATH:-}"
passphrase="${GPG_PASSPHRASE:-}"
script_path="${SCRIPT_PATH:-$repo_root/setup.sh}"

key_path="$(expand_tilde "$key_path")"
script_path="$(expand_tilde "$script_path")"

if [ -z "$key_path" ] || [ -z "$passphrase" ]; then
  echo "Error: KEY_PATH and GPG_PASSPHRASE are required." >&2
  usage
  exit 1
fi

if [ ! -f "$key_path" ]; then
  mkdir -p "$(dirname "$key_path")"
  ssh-keygen -t ed25519 -N '' -f "$key_path" -q
fi

if [ ! -f "$script_path" ]; then
  echo "Error: script not found: $script_path" >&2
  exit 1
fi

if ! command -v gpg >/dev/null 2>&1; then
  echo "Error: gpg not found." >&2
  exit 1
fi

hash_cmd="$(hash_cmd_select || true)"
if [ -z "$hash_cmd" ]; then
  echo "Error: sha256sum or shasum not found." >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

tmp_script="$tmp_dir/setup.sh"
tmp_script_no_bump="$tmp_dir/setup-no-bump.sh"
tmp_script_metadata_only="$tmp_dir/setup-metadata-only.sh"
cp "$script_path" "$tmp_script"
cp "$script_path" "$tmp_script_no_bump"
cp "$script_path" "$tmp_script_metadata_only"

current_version="$(read_version "$tmp_script" || true)"
if [ -z "$current_version" ]; then
  echo "Error: VERSION not found in script." >&2
  exit 1
fi

current_key_public_sha256="$(read_key_public_sha256 "$tmp_script" || true)"
new_key_public_sha256="$(calc_public_key_hash_from_private_key "$key_path" "$hash_cmd")"
expected_version=$((current_version + 1))
if [ -n "$current_key_public_sha256" ] && [ "$current_key_public_sha256" = "$new_key_public_sha256" ]; then
  expected_version="$current_version"
fi

printf '%s\n%s\n' "$passphrase" "$passphrase" | "$repo_root/setup.sh" --update -k "$key_path" -s "$tmp_script"

next_version="$(read_version "$tmp_script" || true)"
if [ -z "$next_version" ]; then
  echo "Error: VERSION not found after update." >&2
  exit 1
fi

if [ "$next_version" -ne "$expected_version" ] 2>/dev/null; then
  echo "Error: VERSION not updated as expected. Before=$current_version Expected=$expected_version After=$next_version" >&2
  exit 1
fi

calc_script_hash="$(calc_script_hash "$tmp_script" "$hash_cmd")"
calc_blob_hash="$(calc_blob_hash "$tmp_script" "$hash_cmd")"

exp_script_hash=$(awk -F\" '/^SCRIPT_SHA256=\"[0-9a-f]+\"/{print $2; exit}' "$tmp_script")
exp_blob_hash=$(awk -F\" '/^BLOB_SHA256=\"[0-9a-f]+\"/{print $2; exit}' "$tmp_script")
exp_key_public_sha256=$(awk -F\" '/^KEY_PUBLIC_SHA256=\"[0-9a-f]*\"/{print $2; exit}' "$tmp_script")
updated_at=$(awk -F\" '/^UPDATED_AT=\".*\"/{print $2; exit}' "$tmp_script")

if [ "$calc_script_hash" != "$exp_script_hash" ]; then
  echo "Error: SCRIPT_SHA256 mismatch." >&2
  exit 1
fi

if [ "$calc_blob_hash" != "$exp_blob_hash" ]; then
  echo "Error: BLOB_SHA256 mismatch." >&2
  exit 1
fi

if [ "$new_key_public_sha256" != "$exp_key_public_sha256" ]; then
  echo "Error: KEY_PUBLIC_SHA256 mismatch." >&2
  exit 1
fi

if [ -z "$updated_at" ]; then
  echo "Error: UPDATED_AT is empty after update." >&2
  exit 1
fi

if ! printf '%s\n' "$updated_at" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
  echo "Error: UPDATED_AT does not look like ISO 8601. Value=$updated_at" >&2
  exit 1
fi

current_version_no_bump="$(read_version "$tmp_script_no_bump" || true)"
if [ -z "$current_version_no_bump" ]; then
  echo "Error: VERSION not found in no-bump script." >&2
  exit 1
fi

printf '%s\n%s\n' "$passphrase" "$passphrase" | "$repo_root/setup.sh" --update --no-version-bump -k "$key_path" -s "$tmp_script_no_bump"

next_version_no_bump="$(read_version "$tmp_script_no_bump" || true)"
if [ -z "$next_version_no_bump" ]; then
  echo "Error: VERSION not found after no-bump update." >&2
  exit 1
fi

if [ "$next_version_no_bump" -ne "$current_version_no_bump" ] 2>/dev/null; then
  echo "Error: VERSION changed with --no-version-bump. Before=$current_version_no_bump After=$next_version_no_bump" >&2
  exit 1
fi

calc_script_hash_no_bump="$(calc_script_hash "$tmp_script_no_bump" "$hash_cmd")"
calc_blob_hash_no_bump="$(calc_blob_hash "$tmp_script_no_bump" "$hash_cmd")"
exp_script_hash_no_bump=$(awk -F\" '/^SCRIPT_SHA256=\"[0-9a-f]+\"/{print $2; exit}' "$tmp_script_no_bump")
exp_blob_hash_no_bump=$(awk -F\" '/^BLOB_SHA256=\"[0-9a-f]+\"/{print $2; exit}' "$tmp_script_no_bump")
exp_key_public_sha256_no_bump=$(awk -F\" '/^KEY_PUBLIC_SHA256=\"[0-9a-f]*\"/{print $2; exit}' "$tmp_script_no_bump")
updated_at_no_bump=$(awk -F\" '/^UPDATED_AT=\".*\"/{print $2; exit}' "$tmp_script_no_bump")

if [ "$calc_script_hash_no_bump" != "$exp_script_hash_no_bump" ]; then
  echo "Error: SCRIPT_SHA256 mismatch in no-bump update." >&2
  exit 1
fi

if [ "$calc_blob_hash_no_bump" != "$exp_blob_hash_no_bump" ]; then
  echo "Error: BLOB_SHA256 mismatch in no-bump update." >&2
  exit 1
fi

if [ "$new_key_public_sha256" != "$exp_key_public_sha256_no_bump" ]; then
  echo "Error: KEY_PUBLIC_SHA256 mismatch in no-bump update." >&2
  exit 1
fi

if [ -z "$updated_at_no_bump" ]; then
  echo "Error: UPDATED_AT is empty in no-bump update." >&2
  exit 1
fi

if ! printf '%s\n' "$updated_at_no_bump" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
  echo "Error: UPDATED_AT does not look like ISO 8601 in no-bump update. Value=$updated_at_no_bump" >&2
  exit 1
fi

current_version_metadata_only="$(read_version "$tmp_script_metadata_only" || true)"
if [ -z "$current_version_metadata_only" ]; then
  echo "Error: VERSION not found in metadata-only script." >&2
  exit 1
fi

current_blob_hash_metadata_only=$(awk -F\" '/^BLOB_SHA256=\"[0-9a-f]+\"/{print $2; exit}' "$tmp_script_metadata_only")
current_key_public_sha256_metadata_only=$(awk -F\" '/^KEY_PUBLIC_SHA256=\"[0-9a-f]*\"/{print $2; exit}' "$tmp_script_metadata_only")

"$repo_root/setup.sh" --update --metadata-only -s "$tmp_script_metadata_only"

next_version_metadata_only="$(read_version "$tmp_script_metadata_only" || true)"
if [ -z "$next_version_metadata_only" ]; then
  echo "Error: VERSION not found after metadata-only update." >&2
  exit 1
fi

if [ "$next_version_metadata_only" -ne "$current_version_metadata_only" ] 2>/dev/null; then
  echo "Error: VERSION changed in metadata-only update. Before=$current_version_metadata_only After=$next_version_metadata_only" >&2
  exit 1
fi

calc_script_hash_metadata_only="$(calc_script_hash "$tmp_script_metadata_only" "$hash_cmd")"
exp_script_hash_metadata_only=$(awk -F\" '/^SCRIPT_SHA256=\"[0-9a-f]+\"/{print $2; exit}' "$tmp_script_metadata_only")
exp_blob_hash_metadata_only=$(awk -F\" '/^BLOB_SHA256=\"[0-9a-f]+\"/{print $2; exit}' "$tmp_script_metadata_only")
exp_key_public_sha256_metadata_only=$(awk -F\" '/^KEY_PUBLIC_SHA256=\"[0-9a-f]*\"/{print $2; exit}' "$tmp_script_metadata_only")
updated_at_metadata_only=$(awk -F\" '/^UPDATED_AT=\".*\"/{print $2; exit}' "$tmp_script_metadata_only")

if [ "$calc_script_hash_metadata_only" != "$exp_script_hash_metadata_only" ]; then
  echo "Error: SCRIPT_SHA256 mismatch in metadata-only update." >&2
  exit 1
fi

if [ "$exp_blob_hash_metadata_only" != "$current_blob_hash_metadata_only" ]; then
  echo "Error: BLOB_SHA256 changed in metadata-only update." >&2
  exit 1
fi

if [ "$exp_key_public_sha256_metadata_only" != "$current_key_public_sha256_metadata_only" ]; then
  echo "Error: KEY_PUBLIC_SHA256 changed in metadata-only update." >&2
  exit 1
fi

if [ -z "$updated_at_metadata_only" ]; then
  echo "Error: UPDATED_AT is empty in metadata-only update." >&2
  exit 1
fi

if ! printf '%s\n' "$updated_at_metadata_only" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
  echo "Error: UPDATED_AT does not look like ISO 8601 in metadata-only update. Value=$updated_at_metadata_only" >&2
  exit 1
fi

echo "OK: setup update non-interactive validation passed."
