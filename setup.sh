#!/usr/bin/env bash
# Author: Paulo Jeronimo
# Git source: https://github.com/paulojeronimo/setup-github-ssh-key
# Open source license: MIT License
set -euo pipefail

if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ]; then
  echo "Error: unsupported Bash version: ${BASH_VERSION:-unknown}. Bash 5 or newer is required." >&2
  exit 1
fi

umask 077

VERSION="1"
SCRIPT_SHA256="66372168a603373caf566b87a27bad598a8e0884aa4b3f60932db17a0672101b"
BLOB_SHA256="53489c3595f960d3054373a54ae449256fedcc68d179c203a21cafd596a72380"
KEY_PUBLIC_SHA256=""
UPDATED_AT="2026-02-24T09:03:32+00:00"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
self_path="${BASH_SOURCE[0]:-$0}"
invoked_as="${0:-setup.sh}"
platform_warning_emitted=0

hash_cmd_select() {
  if command -v sha256sum >/dev/null 2>&1; then
    echo "sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    echo "shasum -a 256"
  else
    return 1
  fi
}

calc_blob_hash() {
  local file="$1"
  local hash_cmd="$2"
  awk 'BEGIN{f=0} /^-----BEGIN PGP MESSAGE-----$/{f=1} {if(f) print} /^-----END PGP MESSAGE-----$/{exit}' "$file" | $hash_cmd | awk '{print $1}'
}

calc_script_hash() {
  local file="$1"
  local hash_cmd="$2"
  awk '!/^SCRIPT_SHA256=/{print}' "$file" | $hash_cmd | awk '{print $1}'
}

read_version() {
  local file="$1"
  awk -F\" '/^VERSION="[0-9]+"/{print $2; exit}' "$file"
}

read_key_public_sha256() {
  local file="$1"
  awk -F\" '/^KEY_PUBLIC_SHA256="[0-9a-f]*"/{print $2; exit}' "$file"
}

is_openssh_key() {
  local file="$1"
  grep -q 'BEGIN OPENSSH PRIVATE KEY' "$file" && grep -q 'END OPENSSH PRIVATE KEY' "$file"
}

expand_tilde() {
  local path="$1"
  if [[ "$path" == "~"* ]]; then
    echo "${path/#\~/$HOME}"
  else
    echo "$path"
  fi
}

calc_public_key_hash_from_private_key() {
  local file="$1"
  local hash_cmd="$2"
  ssh-keygen -y -f "$file" | tr -d '\r' | $hash_cmd | awk '{print $1}'
}

set_key_public_sha256() {
  local file="$1"
  local value="$2"
  local tmp_out="$3"
  if grep -q '^KEY_PUBLIC_SHA256=\"[0-9a-f]*\"' "$file"; then
    sed -E "s/^KEY_PUBLIC_SHA256=\\\"[0-9a-f]*\\\"/KEY_PUBLIC_SHA256=\\\"$value\\\"/" "$file" > "$tmp_out"
    return 0
  fi
  awk -v value="$value" '
    BEGIN {inserted=0}
    {
      print
      if (!inserted && $0 ~ /^BLOB_SHA256="/) {
        print "KEY_PUBLIC_SHA256=\"" value "\""
        inserted=1
      }
    }
    END {
      if (!inserted) print "KEY_PUBLIC_SHA256=\"" value "\""
    }
  ' "$file" > "$tmp_out"
}

set_updated_at() {
  local file="$1"
  local value="$2"
  local tmp_out="$3"
  if grep -q '^UPDATED_AT=\".*\"' "$file"; then
    sed -E "s#^UPDATED_AT=\\\".*\\\"#UPDATED_AT=\\\"$value\\\"#" "$file" > "$tmp_out"
    return 0
  fi
  awk -v value="$value" '
    BEGIN {inserted=0}
    {
      print
      if (!inserted && $0 ~ /^KEY_PUBLIC_SHA256="/) {
        print "UPDATED_AT=\"" value "\""
        inserted=1
      }
    }
    END {
      if (!inserted) print "UPDATED_AT=\"" value "\""
    }
  ' "$file" > "$tmp_out"
}

calc_self_sha256() {
  local hash_cmd="$1"
  awk 'BEGIN{skip=0} {if ($0 ~ /^SCRIPT_SHA256=/) next} {print}' "$self_path" | $hash_cmd | awk '{print $1}'
}

calc_self_blob_sha256() {
  local hash_cmd="$1"
  awk 'BEGIN{f=0} /^-----BEGIN PGP MESSAGE-----$/{f=1} {if(f) print} /^-----END PGP MESSAGE-----$/{exit}' "$self_path" | $hash_cmd | awk '{print $1}'
}

require_hash_cmd() {
  local hash_cmd
  hash_cmd="$(hash_cmd_select || true)"
  if [ -z "$hash_cmd" ]; then
    echo "Error: sha256sum or shasum not found." >&2
    exit 1
  fi
  printf '%s\n' "$hash_cmd"
}

detect_platform_label() {
  if [ -n "${PREFIX:-}" ] && [[ "${PREFIX:-}" == /data/data/com.termux/files/usr* ]]; then
    echo "Termux on Android"
    return 0
  fi
  if [ -r /etc/os-release ]; then
    local os_id=""
    local os_version_id=""
    os_id="$(awk -F= '/^ID=/{gsub(/"/, "", $2); print $2; exit}' /etc/os-release)"
    os_version_id="$(awk -F= '/^VERSION_ID=/{gsub(/"/, "", $2); print $2; exit}' /etc/os-release)"
    if [ "$os_id" = "ubuntu" ] && [ "$os_version_id" = "25.10" ]; then
      echo "Ubuntu 25.10"
      return 0
    fi
    if [ -n "$os_id" ] && [ -n "$os_version_id" ]; then
      echo "$os_id $os_version_id"
      return 0
    fi
  fi
  if command -v uname >/dev/null 2>&1; then
    echo "Unknown ($(uname -s 2>/dev/null || echo unknown))"
    return 0
  fi
  echo "Unknown"
}

platform_is_tested() {
  local label="$1"
  case "$label" in
    "Ubuntu 25.10"|"Termux on Android")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

warn_if_untested_platform() {
  local label
  if [ "$platform_warning_emitted" -eq 1 ]; then
    return 0
  fi
  label="$(detect_platform_label)"
  if ! platform_is_tested "$label"; then
    echo "Warning: this script has not been tested on the current platform: $label" >&2
  fi
  platform_warning_emitted=1
}

verify_self_integrity() {
  local hash_cmd="$1"
  if [ "$SCRIPT_SHA256" = "__SCRIPT_SHA256__" ] || [ "$BLOB_SHA256" = "__BLOB_SHA256__" ]; then
    echo "Error: hashes not configured in the script." >&2
    exit 1
  fi
  if [ -z "${self_path:-}" ] || [ ! -f "$self_path" ]; then
    echo "Error: this script must be executed from a local file for integrity verification." >&2
    echo "Hint: use 'curl -fsSL URL -o /tmp/setup.sh && bash /tmp/setup.sh' instead of 'curl ... | bash'." >&2
    exit 1
  fi
  if [ "$(calc_self_sha256 "$hash_cmd")" != "$SCRIPT_SHA256" ]; then
    echo "Error: script integrity check failed (hash mismatch)." >&2
    exit 1
  fi
  if [ "$(calc_self_blob_sha256 "$hash_cmd")" != "$BLOB_SHA256" ]; then
    echo "Error: GPG blob integrity check failed (hash mismatch)." >&2
    exit 1
  fi
  if [ -v DEBUG ]; then
    echo "DEBUG: script_path=$self_path" >&2
    echo "DEBUG: hash_cmd=$hash_cmd" >&2
    echo "DEBUG: script_sha256_calc=$(calc_self_sha256 "$hash_cmd")" >&2
    echo "DEBUG: script_sha256_exp=$SCRIPT_SHA256" >&2
    echo "DEBUG: blob_sha256_calc=$(calc_self_blob_sha256 "$hash_cmd")" >&2
    echo "DEBUG: blob_sha256_exp=$BLOB_SHA256" >&2
  fi
}

usage_install() {
  cat <<USAGE
Usage: $invoked_as [--overwrite] [-h|--help] [-v|--version]

Options:
  --overwrite  Overwrite ~/.ssh/id_ed25519_gh if it already exists and rewrite Host github.com in ~/.ssh/config
  -h, --help   Show help
  -v, --version  Print VERSION and SCRIPT_SHA256

Modes:
  default      Install the SSH key (this mode)
  --update     Update embedded GPG blob, VERSION, and hashes
  --lib        Load/provide functions only (no execution)
USAGE
}

usage_update() {
  cat <<USAGE
Usage: $invoked_as --update [-k /path/to/id_rsa] [-s /path/to/script] [--no-version-bump] [--metadata-only]

Options:
  -k               OpenSSH private key path (BEGIN OPENSSH PRIVATE KEY)
  -s               Script path to update (default: current script path)
  --no-version-bump  Keep VERSION unchanged even if the key appears to change
  --metadata-only  Update only UPDATED_AT and SCRIPT_SHA256 (no key/blob/version changes)
  -h               Help

Default variable sources:
  1. ./.env (if present)
  2. ./.env.sample (fallback)
  3. Built-in defaults
USAGE
}

main_install() {
  local overwrite=0
  local hash_cmd
  local key_dir
  local key_priv
  local key_pub
  local ssh_config
  local tmp_key
  local tmp_pgp
  local tmp_cfg=""
  local passphrase

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --overwrite)
        overwrite=1
        shift
        ;;
      -h|--help)
        usage_install
        exit 0
        ;;
      *)
        echo "Error: unknown argument: $1" >&2
        usage_install
        exit 1
        ;;
    esac
  done

  if ! command -v gpg >/dev/null 2>&1; then
    echo "Error: gpg not found. Install GPG." >&2
    exit 1
  fi

  if ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "Error: ssh-keygen not found. Install OpenSSH." >&2
    exit 1
  fi

  hash_cmd="$(require_hash_cmd)"
  warn_if_untested_platform
  verify_self_integrity "$hash_cmd"

  key_dir="$HOME/.ssh"
  key_priv="$key_dir/id_ed25519_gh"
  key_pub="$key_dir/id_ed25519_gh.pub"
  ssh_config="$key_dir/config"

  if [ -f "$key_priv" ] && [ "$overwrite" -ne 1 ]; then
    echo "Error: $key_priv already exists. Use --overwrite to replace it." >&2
    exit 1
  fi

  tmp_key="$(mktemp)"
  tmp_pgp="$(mktemp)"
  trap 'rm -f "${tmp_key:-}" "${tmp_pgp:-}" "${tmp_cfg:-}"' EXIT

  read -r -s -p "GPG passphrase: " passphrase
  printf '\n'

  cat > "$tmp_pgp" <<'GPG_KEY'
-----BEGIN PGP MESSAGE-----

jA0ECQMKAJqA3lqoJUL/0sCLAb3ra8zgETUoKijRDhuPTinQJSDeBwMeSKMb8SjU
W+wzyOIsK05BXq+9PqqAKILtoDvv+ZkoPnCK24wFtSPsUhktKYSIPRfnlZSDdQqk
r065wFIldXI0N9C03lff7HSVf/xR1uwdAXljjxSwNr86IlKRWApIYwdVAyzD8H8g
lO4EyPmrca2V98X5o26xKLavI7+e5wVUj+NA0SLdaszao1O3IO76yUVkwqxSgAeq
14qdBxqPsDxCuJCK5vXQIswN6NbcunfO7tf3UYexPzjUMUh8hwqP/oOUpqxFsfwb
vuFBD1kP1950AkqMTOdFtNDduYOwZHul5V3WSeRNmfUMNvHsGbJ9a/wQc+bYPIiC
zlJU0pifbYt9AzbgF9rQJ+MaPiwIhoA763aVCAjCaT/H8HcZ8Z/zwqqOd2UWgn2q
26imfz8HoE/0gavoJw==
=DOq0
-----END PGP MESSAGE-----
GPG_KEY

  printf '%s' "$passphrase" | gpg --batch --yes --pinentry-mode loopback \
    --passphrase-fd 0 --decrypt "$tmp_pgp" | tr -d '\r' > "$tmp_key"

  if ! grep -q 'BEGIN OPENSSH PRIVATE KEY' "$tmp_key"; then
    if grep -q 'END OPENSSH PRIVATE KEY' "$tmp_key"; then
      { echo "-----BEGIN OPENSSH PRIVATE KEY-----"; cat "$tmp_key"; } > "${tmp_key}.fixed"
      mv "${tmp_key}.fixed" "$tmp_key"
    else
      echo "Error: decrypted key does not look like a valid OpenSSH key." >&2
      if [ -v DEBUG ]; then
        echo "DEBUG: bytes=$(wc -c < "$tmp_key")" >&2
        echo "DEBUG: lines=$(wc -l < "$tmp_key")" >&2
        echo "DEBUG: first_line=$(head -n 1 "$tmp_key" | tr -d '\r')" >&2
        echo "DEBUG: second_line=$(sed -n '2p' "$tmp_key" | tr -d '\r')" >&2
        echo "DEBUG: last_line=$(tail -n 1 "$tmp_key" | tr -d '\r')" >&2
      fi
      exit 1
    fi
  fi

  if ! grep -q 'END OPENSSH PRIVATE KEY' "$tmp_key"; then
    echo "Error: decrypted key is incomplete (missing footer)." >&2
    if [ -v DEBUG ]; then
      echo "DEBUG: bytes=$(wc -c < "$tmp_key")" >&2
      echo "DEBUG: lines=$(wc -l < "$tmp_key")" >&2
      echo "DEBUG: first_line=$(head -n 1 "$tmp_key" | tr -d '\r')" >&2
      echo "DEBUG: second_line=$(sed -n '2p' "$tmp_key" | tr -d '\r')" >&2
      echo "DEBUG: last_line=$(tail -n 1 "$tmp_key" | tr -d '\r')" >&2
    fi
    exit 1
  fi

  mkdir -p "$key_dir"
  chmod 700 "$key_dir"

  if [ ! -f "$ssh_config" ]; then
    : > "$ssh_config"
    chmod 600 "$ssh_config"
  fi

  if [ "$overwrite" -eq 1 ]; then
    tmp_cfg="$(mktemp)"
    awk '
      function host_has_github(    i) {
        for (i = 2; i <= NF; i++) if ($i == "github.com") return 1
        return 0
      }
      /^[[:space:]]*[Hh][Oo][Ss][Tt][[:space:]]+/ {
        skip = host_has_github()
      }
      !skip { print }
    ' "$ssh_config" > "$tmp_cfg"
    mv "$tmp_cfg" "$ssh_config"
  fi

  if ! awk 'tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i == "github.com") found = 1 } END { exit found ? 0 : 1 }' "$ssh_config"; then
    {
      if awk 'END { exit (NR > 0 && $0 ~ /[^[:space:]]/) ? 0 : 1 }' "$ssh_config"; then
        printf '\n'
      fi
      printf '%s\n' 'Host github.com'
      printf '%s\n' '  HostName github.com'
      printf '%s\n' '  User git'
      printf '%s\n' '  IdentityFile ~/.ssh/id_ed25519_gh'
      printf '%s\n' '  IdentitiesOnly yes'
      printf '%s\n' '  AddKeysToAgent yes'
    } >> "$ssh_config"
  fi

  chmod 600 "$ssh_config"

  cat "$tmp_key" > "$key_priv"
  chmod 600 "$key_priv"

  ssh-keygen -y -f "$key_priv" > "$key_pub"
  chmod 644 "$key_pub"

  echo "Key installed at $key_priv"
  echo "Public key created at $key_pub (version $VERSION)"
  echo "SSH config ensured at $ssh_config for Host github.com"
}

main_update() {
  local cli_key_path=""
  local cli_script_path=""
  local no_version_bump=0
  local metadata_only=0
  local env_file=""
  local key_path
  local script_path
  local hash_cmd
  local passphrase
  local passphrase_confirm
  local tmp_pgp=""
  local tmp_script=""
  local tmp_script2=""
  local current_version
  local next_version
  local current_key_public_sha256
  local new_key_public_sha256
  local key_changed=1
  local updated_at
  local blob_hash
  local script_hash

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -k)
        if [ "$#" -lt 2 ]; then
          echo "Error: missing value for -k" >&2
          usage_update
          exit 1
        fi
        cli_key_path="$2"
        shift 2
        ;;
      -s)
        if [ "$#" -lt 2 ]; then
          echo "Error: missing value for -s" >&2
          usage_update
          exit 1
        fi
        cli_script_path="$2"
        shift 2
        ;;
      --no-version-bump)
        no_version_bump=1
        shift
        ;;
      --metadata-only)
        metadata_only=1
        shift
        ;;
      -h|--help)
        usage_update
        exit 0
        ;;
      *)
        echo "Error: unknown argument: $1" >&2
        usage_update
        exit 1
        ;;
    esac
  done

  if [ -f "$script_dir/.env" ]; then
    env_file="$script_dir/.env"
  elif [ -f "$script_dir/.env.sample" ]; then
    env_file="$script_dir/.env.sample"
  fi

  if [ -n "$env_file" ]; then
    set -a
    # shellcheck source=.env.sample
    # shellcheck disable=SC1091
    . "$env_file"
    set +a
  fi

  script_path="${cli_script_path:-${SCRIPT_PATH:-$self_path}}"

  script_path="$(expand_tilde "$script_path")"

  if [ ! -f "$script_path" ]; then
    echo "Error: script not found: $script_path" >&2
    exit 1
  fi

  hash_cmd="$(require_hash_cmd)"
  warn_if_untested_platform
  verify_self_integrity "$hash_cmd"

  if [ "$metadata_only" -eq 1 ]; then
    trap 'rm -f "${tmp_script:-}" "${tmp_script2:-}"' EXIT
    tmp_script="$(mktemp)"
    tmp_script2="$(mktemp)"
    cp "$script_path" "$tmp_script"

    current_version="$(read_version "$tmp_script" || true)"
    if [ -z "$current_version" ]; then
      current_version=0
    fi
    if ! [ "$current_version" -ge 0 ] 2>/dev/null; then
      echo "Error: invalid VERSION in script (expected integer). Value: $current_version" >&2
      exit 1
    fi

    updated_at="$(date -Is)"
    set_updated_at "$tmp_script" "$updated_at" "$tmp_script2"
    mv "$tmp_script2" "$tmp_script"

    script_hash="$(calc_script_hash "$tmp_script" "$hash_cmd")"
    sed -E "s/^SCRIPT_SHA256=\"[0-9a-f]{64}\"/SCRIPT_SHA256=\"$script_hash\"/" "$tmp_script" > "$tmp_script2"

    chmod --reference "$script_path" "$tmp_script2" 2>/dev/null || chmod 700 "$tmp_script2"
    mv "$tmp_script2" "$script_path"

    echo "Update completed:"
    echo "- Script: $script_path"
    echo "- Metadata only: 1"
    echo "- No version bump override: $no_version_bump"
    echo "- Key changed: 0"
    echo "- VERSION: $current_version"
    echo "- UPDATED_AT: $updated_at"
    echo "- KEY_PUBLIC_SHA256: $(read_key_public_sha256 "$script_path" || true)"
    echo "- BLOB_SHA256: $(awk -F\\\" '/^BLOB_SHA256=\"[0-9a-f]+\"/{print $2; exit}' "$script_path")"
    echo "- SCRIPT_SHA256: $script_hash"
    return 0
  fi

  key_path="${cli_key_path:-${KEY_PATH:-~/.ssh/id_ed25519_gh}}"
  key_path="$(expand_tilde "$key_path")"

  if [ ! -f "$key_path" ]; then
    echo "Error: key file not found: $key_path" >&2
    exit 1
  fi

  if ! command -v gpg >/dev/null 2>&1; then
    echo "Error: gpg not found. Install GPG." >&2
    exit 1
  fi

  if ! is_openssh_key "$key_path"; then
    echo "Error: the provided key does not look like a valid OpenSSH key." >&2
    exit 1
  fi

  new_key_public_sha256="$(calc_public_key_hash_from_private_key "$key_path" "$hash_cmd")"

  read -r -s -p "New GPG passphrase: " passphrase
  printf '\n'
  read -r -s -p "Confirm passphrase: " passphrase_confirm
  printf '\n'

  if [ "$passphrase" != "$passphrase_confirm" ]; then
    echo "Error: passphrases do not match." >&2
    exit 1
  fi

  trap 'rm -f "${tmp_pgp:-}" "${tmp_script:-}" "${tmp_script2:-}"' EXIT

  tmp_pgp="$(mktemp)"
  tmp_script="$(mktemp)"
  tmp_script2="$(mktemp)"

  printf '%s' "$passphrase" | gpg --batch --yes --pinentry-mode loopback \
    --passphrase-fd 0 --armor --output "$tmp_pgp" --symmetric "$key_path"

  if ! grep -q 'BEGIN PGP MESSAGE' "$tmp_pgp" || ! grep -q 'END PGP MESSAGE' "$tmp_pgp"; then
    echo "Error: failed to generate GPG blob." >&2
    exit 1
  fi

  if ! awk -v newfile="$tmp_pgp" '
    BEGIN {inside=0; replaced=0}
    {
      if ($0 == "-----BEGIN PGP MESSAGE-----") {
        inside=1
        if (!replaced) {
          while ((getline line < newfile) > 0) print line
          close(newfile)
          replaced=1
        }
        next
      }
      if (inside) {
        if ($0 == "-----END PGP MESSAGE-----") {inside=0}
        next
      }
      print
    }
    END { if (!replaced) exit 2 }
  ' "$script_path" > "$tmp_script"; then
    echo "Error: could not replace the PGP block (markers not found)." >&2
    exit 1
  fi

  current_version="$(read_version "$tmp_script" || true)"
  if [ -z "$current_version" ]; then
    current_version=0
  fi
  if ! [ "$current_version" -ge 0 ] 2>/dev/null; then
    echo "Error: invalid VERSION in script (expected integer). Value: $current_version" >&2
    exit 1
  fi
  current_key_public_sha256="$(read_key_public_sha256 "$tmp_script" || true)"
  if [ "$no_version_bump" -eq 1 ]; then
    key_changed=0
    next_version="$current_version"
  elif [ -n "$current_key_public_sha256" ] && [ "$current_key_public_sha256" = "$new_key_public_sha256" ]; then
    key_changed=0
    next_version="$current_version"
  else
    next_version=$((current_version + 1))
  fi

  sed -E "s/^VERSION=\"[0-9]+\"/VERSION=\"$next_version\"/" "$tmp_script" > "$tmp_script2"
  mv "$tmp_script2" "$tmp_script"

  set_key_public_sha256 "$tmp_script" "$new_key_public_sha256" "$tmp_script2"
  mv "$tmp_script2" "$tmp_script"

  updated_at="$(date -Is)"
  set_updated_at "$tmp_script" "$updated_at" "$tmp_script2"
  mv "$tmp_script2" "$tmp_script"

  blob_hash="$(calc_blob_hash "$tmp_script" "$hash_cmd")"
  sed -E "s/^BLOB_SHA256=\"[0-9a-f]{64}\"/BLOB_SHA256=\"$blob_hash\"/" "$tmp_script" > "$tmp_script2"
  mv "$tmp_script2" "$tmp_script"

  script_hash="$(calc_script_hash "$tmp_script" "$hash_cmd")"
  sed -E "s/^SCRIPT_SHA256=\"[0-9a-f]{64}\"/SCRIPT_SHA256=\"$script_hash\"/" "$tmp_script" > "$tmp_script2"

  chmod --reference "$script_path" "$tmp_script2" 2>/dev/null || chmod 700 "$tmp_script2"
  mv "$tmp_script2" "$script_path"

  echo "Update completed:"
  echo "- Script: $script_path"
  echo "- Metadata only: 0"
  echo "- No version bump override: $no_version_bump"
  echo "- Key changed: $key_changed"
  echo "- VERSION: $next_version"
  echo "- UPDATED_AT: $updated_at"
  echo "- KEY_PUBLIC_SHA256: $new_key_public_sha256"
  echo "- BLOB_SHA256: $blob_hash"
  echo "- SCRIPT_SHA256: $script_hash"
}

main_lib() {
  return 0
}

print_version_info() {
  sed -n '/^VERSION="/p; /^SCRIPT_SHA256="/p; /^UPDATED_AT="/p' "$self_path"
}

setup_main() {
  if [ "$#" -gt 0 ]; then
    case "$1" in
      -v|--version)
        if [ "$#" -ne 1 ]; then
          echo "Error: $1 does not accept additional arguments." >&2
          exit 1
        fi
        print_version_info
        return 0
        ;;
      --lib)
        shift
        if [ "$#" -gt 0 ]; then
          case "$1" in
            -h|--help)
              echo "Usage: $invoked_as --lib" >&2
              exit 0
              ;;
            *)
              echo "Error: unknown argument: $1" >&2
              exit 1
              ;;
          esac
        fi
        main_lib
        return 0
        ;;
      --update)
        shift
        main_update "$@"
        return 0
        ;;
    esac
  fi
  main_install "$@"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  setup_main "$@"
fi
