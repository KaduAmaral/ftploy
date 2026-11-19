#!/usr/bin/env bash
# Incremental FTP deploy for any git repository.
#
# Default: download a marker from the server, upload only files changed since
# that commit, then write an updated marker.
# --full: upload every file that is not excluded.
#
# Config lives outside this script (env vars or .env.deploy). Nothing here is
# tied to a specific site.
#
# Required: bash, git, curl, python3
#
# Install (see README.md):
#   curl -fsSL https://raw.githubusercontent.com/KaduAmaral/ftploy/main/install.sh | bash
#
# Example .env.deploy:
#
#   FTP_HOST=ftp.example.com
#   FTP_USER=user
#   FTP_PASSWORD=secret
#   FTP_REMOTE_PATH=/public_html
#   FTP_PORT=21
#   FTP_SSL=0
#
#   DEPLOY_ROOT=/path/to/repo
#   DEPLOY_INFO=.deploy-info.json
#   DEPLOY_EXCLUDE=".git .env .env.* vendor node_modules tmp tests"
#   DEPLOY_PUBLISH="config/production.ini=>config/application.ini"
#   DEPLOY_REQUIRE="index.php"
#
set -euo pipefail

VERSION="0.1.0"
FULL_DEPLOY=0
UNINSTALL=0
CLI_ENV=""
CLI_ROOT=""
ORIG_PWD="$PWD"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<EOF
Usage: ${0##*/} [options]

  (default)  Incremental deploy. Reads the remote marker file, uploads files
             changed since that commit, then updates the marker.

  --full     Upload every file that is not excluded. Also used automatically
  --all, -f  when the server has no marker or the recorded commit is missing.

  -e, --env FILE   Config file (FTP_* / DEPLOY_*). Default: .env.deploy in
                   the current directory, git root, or this script's directory.
                   If none exists, an interactive terminal asks for the FTP
                   connection and writes .env.deploy in the current directory.
  --root DIR       Project root to publish. Default: DEPLOY_ROOT, git root, or cwd.

  --uninstall      Remove the installed ftploy command and its PATH block.
  -h, --help       Show this help.
  -V, --version    Show version.

Config keys are documented at the top of this script.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --full | --all | -f)
      FULL_DEPLOY=1
      shift
      ;;
    -e | --env)
      CLI_ENV="${2:?--env requires a file path}"
      shift 2
      ;;
    --env=*)
      CLI_ENV="${1#--env=}"
      shift
      ;;
    --root)
      CLI_ROOT="${2:?--root requires a directory}"
      shift 2
      ;;
    --root=*)
      CLI_ROOT="${1#--root=}"
      shift
      ;;
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -V | --version)
      echo "${0##*/} ${VERSION}"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

uninstall_ftploy() {
  local marker_begin="# >>> ftploy >>>"
  local marker_end="# <<< ftploy <<<"
  local self="" name profile seen=" " removed=0 tmp

  case "$0" in
    */*) self="$0" ;;
    *) self="$(command -v "$0" 2>/dev/null || true)" ;;
  esac
  if [ -n "$self" ] && [ -e "$self" ]; then
    self="$(cd "$(dirname "$self")" && pwd)/$(basename "$self")"
  else
    self=""
  fi

  name="${0##*/}"
  if [ "$name" = "deploy.sh" ]; then
    name="ftploy"
  fi

  display_path() {
    case "$1" in
      "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;;
      *) printf '%s\n' "$1" ;;
    esac
  }

  remove_installed() {
    local target="$1"
    [ -n "$target" ] && [ -f "$target" ] || return 0
    if [ "$(basename "$target")" = "deploy.sh" ]; then
      return 0
    fi
    rm -f "$target"
    echo "Removido $(display_path "$target")"
    removed=1
  }

  remove_installed "$self"
  remove_installed "${HOME}/.local/bin/${name}"

  strip_path_block() {
    local file="$1"
    [ -f "$file" ] || return 0
    tmp="$(mktemp)"
    awk -v begin="$marker_begin" -v end="$marker_end" '
      $0 == begin { skip = 1; next }
      $0 == end { skip = 0; next }
      skip { next }
      { print }
    ' "$file" >"$tmp"
    cat "$tmp" >"$file"
    rm -f "$tmp"
  }

  while IFS= read -r profile; do
    [ -n "$profile" ] || continue
    case "$seen" in
      *" $profile "*) continue ;;
    esac
    seen="${seen}${profile} "
    if [ -f "$profile" ] && grep -qF "$marker_begin" "$profile"; then
      strip_path_block "$profile"
      echo "PATH removido de $(display_path "$profile")"
      removed=1
    fi
  done <<EOF
$HOME/.bashrc
$HOME/.bash_profile
$HOME/.profile
$HOME/.zshrc
${ZDOTDIR:-$HOME}/.zshrc
${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish
EOF

  if [ "$removed" -eq 0 ]; then
    echo "Nada para remover."
  fi
}

if [ "$UNINSTALL" -eq 1 ]; then
  uninstall_ftploy
  exit 0
fi

resolve_path() {
  local path="$1"
  local base="${2:-$ORIG_PWD}"
  if [ -z "$path" ]; then
    return 1
  fi
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s\n' "$base/$path" ;;
  esac
}

load_env_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      '' | \#*) continue ;;
    esac
    local key="${line%%=*}"
    local value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    case "$key" in
      FTP_* | DEPLOY_*) ;;
      *) continue ;;
    esac
    value="$(decode_env_value "$value")"
    printf -v "$key" '%s' "$value"
    export "$key"
  done <"$file"
}

trim_ws() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

decode_env_value() {
  local value="$1"
  if [[ "$value" == \"*\" ]]; then
    value="${value:1:${#value}-2}"
    value="${value//\\\\/\\}"
    value="${value//\\\"/\"}"
    value="${value//\\\$/\$}"
    value="${value//\\\`/\`}"
  elif [[ "$value" == \'*\' ]]; then
    value="${value:1:${#value}-2}"
    value="${value//\'\\\'\'/\'}"
  else
    value="${value%% #*}"
    value="$(trim_ws "$value")"
  fi
  printf '%s' "$value"
}

quote_env_value() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

tty_available() {
  (: </dev/tty) >/dev/null 2>&1
}

ask_tty() {
  local prompt="$1"
  local secret="${2:-0}"
  local value=""
  if [ "$secret" = 1 ]; then
    read -r -s -p "$prompt" value </dev/tty || exit 1
    printf '\n' >&2
  else
    read -r -p "$prompt" value </dev/tty || exit 1
  fi
  trim_ws "$value"
}

ask_required() {
  local prompt="$1"
  local secret="${2:-0}"
  local value=""
  while [ -z "$value" ]; do
    value="$(ask_tty "$prompt" "$secret")"
    if [ -z "$value" ]; then
      echo "Esse campo é obrigatório." >&2
    fi
  done
  printf '%s' "$value"
}

ask_default() {
  local prompt="$1"
  local default="$2"
  local value
  value="$(ask_tty "$prompt [$default]: ")"
  if [ -z "$value" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$value"
  fi
}

connection_is_complete() {
  [ -n "${FTP_HOST:-}" ] && [ -n "${FTP_USER:-}" ] && [ -n "${FTP_PASSWORD:-}" ] && [ -n "${FTP_REMOTE_PATH:-}" ]
}

ignore_env_deploy() {
  local dir="$1"
  local root ignore
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  ignore="${root:-$dir}/.gitignore"
  [ -f "$ignore" ] || return 0
  if grep -Eq '^[[:space:]]*(\.env\.deploy|\.env\.\*|\.env)[[:space:]]*(#.*)?$' "$ignore"; then
    return 0
  fi
  printf '\n.env.deploy\n' >>"$ignore"
  echo "Incluí .env.deploy em ${ignore}." >&2
}

init_env_file() {
  local dest="$1"
  local host user password remote port ssl_answer ssl

  if ! tty_available; then
    echo "Não encontrei .env.deploy e não há um terminal interativo para criar." >&2
    echo "Crie o arquivo ou defina FTP_HOST, FTP_USER, FTP_PASSWORD e FTP_REMOTE_PATH." >&2
    exit 1
  fi

  echo "Não encontrei .env.deploy nesta pasta." >&2
  echo "Informe a conexão FTP. Vou gravar em ${dest}." >&2

  if [ -n "${FTP_HOST:-}" ]; then
    host="$(ask_default "Host FTP" "$FTP_HOST")"
  else
    host="$(ask_required "Host FTP: ")"
  fi
  if [ -n "${FTP_USER:-}" ]; then
    user="$(ask_default "Usuário" "$FTP_USER")"
  else
    user="$(ask_required "Usuário: ")"
  fi
  password="$(ask_required "Senha: " 1)"
  remote="$(ask_default "Pasta remota" "${FTP_REMOTE_PATH:-/public_html}")"
  while true; do
    port="$(ask_default "Porta" "${FTP_PORT:-21}")"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
      break
    fi
    echo "Porta inválida. Use um número de 1 a 65535." >&2
  done
  if [ "${FTP_SSL:-0}" = 1 ]; then
    ssl_answer="$(ask_tty "Usar FTPS (SSL)? [S/n]: ")"
    case "${ssl_answer,,}" in
      '' | s | sim | y | yes | 1) ssl=1 ;;
      *) ssl=0 ;;
    esac
  else
    ssl_answer="$(ask_tty "Usar FTPS (SSL)? [s/N]: ")"
    case "${ssl_answer,,}" in
      s | sim | y | yes | 1) ssl=1 ;;
      *) ssl=0 ;;
    esac
  fi

  mkdir -p "$(dirname "$dest")"
  if [ -e "$dest" ]; then
    echo "Arquivo já existe: ${dest}" >&2
    exit 1
  fi
  (
    umask 077
    {
      printf '%s\n' '# Gerado por ftploy. Não commite este arquivo (contém a senha).'
      printf '%s\n' ''
      printf '%s\n' '# --- FTP ---'
      printf 'FTP_HOST=%s\n' "$(quote_env_value "$host")"
      printf 'FTP_USER=%s\n' "$(quote_env_value "$user")"
      printf 'FTP_PASSWORD=%s\n' "$(quote_env_value "$password")"
      printf 'FTP_REMOTE_PATH=%s\n' "$(quote_env_value "$remote")"
      printf 'FTP_PORT=%s\n' "$(quote_env_value "$port")"
      printf 'FTP_SSL=%s\n' "$(quote_env_value "$ssl")"
      printf '%s\n' ''
      printf '%s\n' '# --- Projeto ---'
      printf '%s\n' '# DEPLOY_ROOT=                 # default: raiz do git do diretório atual'
      printf '%s\n' '# DEPLOY_INFO=.deploy-info.json'
      printf '%s\n' '# DEPLOY_EXCLUDE=".git .env .env.* vendor node_modules tmp tests"'
      printf '%s\n' '# DEPLOY_PUBLISH="config/production.ini=>config/application.ini"'
      printf '%s\n' '# DEPLOY_REQUIRE="index.php"'
    } >"$dest"
  )
  chmod 600 "$dest"
  ignore_env_deploy "$(dirname "$dest")"
  echo "Configuração gravada em ${dest}." >&2

  FTP_HOST="$host"
  FTP_USER="$user"
  FTP_PASSWORD="$password"
  FTP_REMOTE_PATH="$remote"
  FTP_PORT="$port"
  FTP_SSL="$ssl"
  export FTP_HOST FTP_USER FTP_PASSWORD FTP_REMOTE_PATH FTP_PORT FTP_SSL
}

find_env_file() {
  local candidate git_cwd git_script
  if [ -n "$CLI_ENV" ]; then
    candidate="$(resolve_path "$CLI_ENV")"
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
    fi
    return 0
  fi
  git_cwd="$(git -C "$ORIG_PWD" rev-parse --show-toplevel 2>/dev/null || true)"
  git_script="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  for candidate in \
    "$ORIG_PWD/.env.deploy" \
    ${git_cwd:+"$git_cwd/.env.deploy"} \
    "$SCRIPT_DIR/.env.deploy" \
    ${git_script:+"$git_script/.env.deploy"}; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 0
}

ENV_FILE="$(find_env_file)"
if [ -n "$ENV_FILE" ]; then
  load_env_file "$ENV_FILE"
elif ! connection_is_complete; then
  if [ -n "$CLI_ENV" ]; then
    ENV_FILE="$(resolve_path "$CLI_ENV")"
  else
    ENV_FILE="${ORIG_PWD}/.env.deploy"
  fi
  init_env_file "$ENV_FILE"
fi

: "${FTP_HOST:?Set FTP_HOST (env or .env.deploy)}"
: "${FTP_USER:?Set FTP_USER (env or .env.deploy)}"
: "${FTP_PASSWORD:?Set FTP_PASSWORD (env or .env.deploy)}"
: "${FTP_REMOTE_PATH:?Set FTP_REMOTE_PATH (env or .env.deploy)}"

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

resolve_root() {
  local git_cwd git_script
  if [ -n "$CLI_ROOT" ]; then
    resolve_path "$CLI_ROOT"
    return 0
  fi
  if [ -n "${DEPLOY_ROOT:-}" ]; then
    resolve_path "$DEPLOY_ROOT"
    return 0
  fi
  git_cwd="$(git -C "$ORIG_PWD" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$git_cwd" ]; then
    printf '%s\n' "$git_cwd"
    return 0
  fi
  git_script="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$git_script" ]; then
    printf '%s\n' "$git_script"
    return 0
  fi
  printf '%s\n' "$ORIG_PWD"
}

ROOT="$(cd "$(resolve_root)" && pwd)"
cd "${ROOT}"
git rev-parse --is-inside-work-tree >/dev/null

DEPLOY_INFO_NAME="${DEPLOY_INFO:-.deploy-info.json}"
DEPLOY_INFO_NAME="${DEPLOY_INFO_NAME#/}"

parse_list() {
  local raw="${1//,/ }"
  local -n _out=$2
  _out=()
  if [ -z "${raw//[[:space:]]/}" ]; then
    return 0
  fi
  read -r -a _out <<< "$raw"
}

EXCLUDE_PATTERNS=()
parse_list ".git .env .env.* .DS_Store ${DEPLOY_EXCLUDE:-}" EXCLUDE_PATTERNS

PUBLISH_SPECS=()
parse_list "${DEPLOY_PUBLISH:-}" PUBLISH_SPECS

REQUIRE_FILES=()
parse_list "${DEPLOY_REQUIRE:-}" REQUIRE_FILES

for required in "${REQUIRE_FILES[@]+"${REQUIRE_FILES[@]}"}"; do
  if [ ! -e "${ROOT}/${required}" ]; then
    echo "Required path not found: ${required}" >&2
    exit 1
  fi
done

ENV_FILE_REL=""
if [ -n "$ENV_FILE" ]; then
  ENV_FILE="$(cd "$(dirname "$ENV_FILE")" && pwd)/$(basename "$ENV_FILE")"
  case "$ENV_FILE" in
    "$ROOT"/*) ENV_FILE_REL="${ENV_FILE#"$ROOT"/}" ;;
  esac
fi

FTP_HOST="${FTP_HOST//[[:space:]]/}"
FTP_USER="${FTP_USER//[[:space:]]/}"
FTP_PASSWORD="$(printf '%s' "$FTP_PASSWORD" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
FTP_PORT="${FTP_PORT:-21}"
FTP_PORT="${FTP_PORT//[[:space:]]/}"
REMOTE_ROOT="${FTP_REMOTE_PATH%/}"
REMOTE_ROOT="${REMOTE_ROOT:-/}"

ftp_url() {
  local path="$1"
  if [ "$path" = "/" ] || [ -z "$path" ]; then
    printf 'ftp://%s:%s/' "$FTP_HOST" "$FTP_PORT"
  elif [ "${path#/}" != "$path" ]; then
    printf 'ftp://%s:%s/%%2F%s' "$FTP_HOST" "$FTP_PORT" "${path#/}"
  else
    printf 'ftp://%s:%s/%s' "$FTP_HOST" "$FTP_PORT" "$path"
  fi
}

remote_path_for() {
  local rel="$1"
  if [ "$REMOTE_ROOT" = "/" ]; then
    printf '/%s' "$rel"
  else
    printf '%s/%s' "$REMOTE_ROOT" "$rel"
  fi
}

SSL_ARGS=()
if [ "${FTP_SSL:-0}" = "1" ]; then
  SSL_ARGS=(--ssl-reqd --insecure)
fi

count=0
deleted_count=0
copied_sources=()

ftp_put() {
  local local_file="$1"
  local remote_path="$2"
  curl -sS --fail --ftp-create-dirs --disable-epsv \
    "${SSL_ARGS[@]}" \
    --user "${FTP_USER}:${FTP_PASSWORD}" \
    -T "${local_file}" \
    "$(ftp_url "$remote_path")"
  count=$((count + 1))
}

ftp_get() {
  local remote_path="$1"
  local local_file="$2"
  curl -s --fail --disable-epsv \
    "${SSL_ARGS[@]}" \
    --user "${FTP_USER}:${FTP_PASSWORD}" \
    -o "${local_file}" \
    "$(ftp_url "$remote_path")"
}

ftp_delete() {
  local rel="$1"
  local remote
  remote="$(remote_path_for "$rel")"
  if curl -s --disable-epsv \
    "${SSL_ARGS[@]}" \
    --user "${FTP_USER}:${FTP_PASSWORD}" \
    -Q "*DELE ${rel}" \
    -o /dev/null \
    "$(ftp_url "$REMOTE_ROOT")"; then
    deleted_count=$((deleted_count + 1))
    echo "  deleted ${rel}"
  else
    echo "  warn: could not delete ${rel} (${remote})" >&2
  fi
}

should_skip() {
  local rel="${1#./}"
  local base="${rel##*/}"
  local pat
  [ "$rel" = "$DEPLOY_INFO_NAME" ] && return 0
  [ "$base" = "$DEPLOY_INFO_NAME" ] && return 0
  case "$rel" in
    node_modules | node_modules/* | */node_modules | */node_modules/*) return 0 ;;
  esac
  if [ -n "$ENV_FILE_REL" ] && [ "$rel" = "$ENV_FILE_REL" ]; then
    return 0
  fi
  for pat in "${EXCLUDE_PATTERNS[@]}"; do
    case "$rel" in
      $pat | $pat/*) return 0 ;;
    esac
    case "$base" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

upload_rel() {
  local rel="$1"
  if [ ! -f "${ROOT}/${rel}" ]; then
    echo "  skip missing ${rel}" >&2
    return 0
  fi
  echo "  upload ${rel}"
  ftp_put "${ROOT}/${rel}" "$(remote_path_for "$rel")"
  copied_sources+=("$rel")
}

source_was_uploaded() {
  local src="$1"
  local rel
  for rel in "${copied_sources[@]+"${copied_sources[@]}"}"; do
    [ "$rel" = "$src" ] && return 0
  done
  return 1
}

list_all_deployable_files() {
  local pat
  local prune=()
  for pat in "${EXCLUDE_PATTERNS[@]}"; do
    case "$pat" in
      *[\*\?\[]*) continue ;;
    esac
    prune+=(-path "./$pat" -o)
  done
  if [ "${#prune[@]}" -gt 0 ]; then
    unset 'prune[-1]'
    find . \( -name node_modules -o "${prune[@]}" \) -prune -o -type f -print0
  else
    find . -name node_modules -prune -o -type f -print0
  fi
}

apply_publish_maps() {
  local spec src dst
  for spec in "${PUBLISH_SPECS[@]+"${PUBLISH_SPECS[@]}"}"; do
    case "$spec" in
      *'=>'*) ;;
      *)
        echo "  warn: invalid DEPLOY_PUBLISH entry (use src=>dst): ${spec}" >&2
        continue
        ;;
    esac
    src="${spec%%=>*}"
    dst="${spec#*=>}"
    src="${src#"${src%%[![:space:]]*}"}"
    src="${src%"${src##*[![:space:]]}"}"
    dst="${dst#"${dst%%[![:space:]]*}"}"
    dst="${dst%"${dst##*[![:space:]]}"}"
    if [ ! -f "${ROOT}/${src}" ]; then
      echo "  skip missing publish source ${src}" >&2
      continue
    fi
    if [ "$MODE" = "full" ] || source_was_uploaded "$src"; then
      echo "  publish ${src} as ${dst}"
      ftp_put "${ROOT}/${src}" "$(remote_path_for "$dst")"
    fi
  done
}

TMPDIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMPDIR}"
}
trap cleanup EXIT

HEAD_COMMIT="$(git rev-parse HEAD)"
HEAD_SHORT="$(git rev-parse --short HEAD)"
HEAD_TITLE="$(git log -1 --format=%s HEAD)"
HEAD_DESCRIPTION="$(git log -1 --format=%b HEAD)"
HEAD_AUTHOR="$(git log -1 --format=%an HEAD)"
HEAD_EMAIL="$(git log -1 --format=%ae HEAD)"
HEAD_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
COMMITS_SINCE=0
MODE="full"
LAST_COMMIT=""
PREVIOUS_COMMIT=""

INFO_REMOTE="$(remote_path_for "$DEPLOY_INFO_NAME")"
INFO_LOCAL="${TMPDIR}/deploy-info.json"

if [ -n "$ENV_FILE" ]; then
  echo "Config: ${ENV_FILE}"
fi
echo "Root: ${ROOT}"

if [ "$FULL_DEPLOY" -eq 0 ]; then
  if ftp_get "$INFO_REMOTE" "$INFO_LOCAL"; then
    LAST_COMMIT="$(python3 -c 'import json,sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print((data.get("commit") or data.get("id") or "").strip())
' "$INFO_LOCAL" 2>/dev/null || true)"
    PREVIOUS_COMMIT="$LAST_COMMIT"
  else
    echo "No ${DEPLOY_INFO_NAME} on the server; doing a full upload."
    FULL_DEPLOY=1
  fi
fi

if [ "$FULL_DEPLOY" -eq 0 ] && [ -z "$LAST_COMMIT" ]; then
  echo "Remote ${DEPLOY_INFO_NAME} has no commit id; doing a full upload."
  FULL_DEPLOY=1
fi

if [ "$FULL_DEPLOY" -eq 0 ] && ! git cat-file -e "${LAST_COMMIT}^{commit}" 2>/dev/null; then
  echo "Recorded commit ${LAST_COMMIT} is not in this repo; doing a full upload."
  FULL_DEPLOY=1
fi

if [ "$FULL_DEPLOY" -eq 0 ] && ! git merge-base --is-ancestor "$LAST_COMMIT" HEAD; then
  echo "Recorded commit ${LAST_COMMIT} is not an ancestor of HEAD; doing a full upload."
  FULL_DEPLOY=1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Warning: working tree has uncommitted changes; deploy uses HEAD (${HEAD_SHORT})."
fi

files=()
deleted_files=()

if [ "$FULL_DEPLOY" -eq 1 ]; then
  MODE="full"
  while IFS= read -r -d '' file; do
    rel="${file#./}"
    if should_skip "$rel"; then
      continue
    fi
    files+=("$rel")
  done < <(list_all_deployable_files)
  echo "Full deploy of ${#files[@]} file(s) at ${HEAD_SHORT} (${HEAD_TITLE})"
else
  MODE="incremental"
  if [ "$LAST_COMMIT" = "$HEAD_COMMIT" ]; then
    echo "Server already at ${HEAD_SHORT}; nothing to upload."
    exit 0
  fi

  COMMITS_SINCE="$(git rev-list --count "${LAST_COMMIT}..HEAD")"
  echo "Incremental deploy: $(git rev-parse --short "$LAST_COMMIT") → ${HEAD_SHORT} (${COMMITS_SINCE} commit(s))"
  git log --oneline "${LAST_COMMIT}..HEAD" | sed 's/^/  /'

  while IFS= read -r -d '' status; do
    [ -n "$status" ] || continue
    letter="${status:0:1}"
    case "$letter" in
      R | C)
        IFS= read -r -d '' old_path
        IFS= read -r -d '' new_path
        if ! should_skip "$old_path"; then
          deleted_files+=("$old_path")
        fi
        if ! should_skip "$new_path"; then
          files+=("$new_path")
        fi
        ;;
      D)
        IFS= read -r -d '' path
        if ! should_skip "$path"; then
          deleted_files+=("$path")
        fi
        ;;
      *)
        IFS= read -r -d '' path
        if ! should_skip "$path"; then
          files+=("$path")
        fi
        ;;
    esac
  done < <(git diff -z --name-status "$LAST_COMMIT" HEAD)

  echo "Changed files to upload: ${#files[@]}"
  echo "Remote files to delete: ${#deleted_files[@]}"
fi

if [ "${#files[@]}" -gt 0 ]; then
  for rel in "${files[@]}"; do
    upload_rel "$rel"
  done
fi

if [ "${#deleted_files[@]}" -gt 0 ]; then
  for rel in "${deleted_files[@]}"; do
    ftp_delete "$rel"
  done
fi

apply_publish_maps

DEPLOY_INFO_OUT="$INFO_LOCAL" \
DEPLOY_COMMIT="$HEAD_COMMIT" \
DEPLOY_SHORT_COMMIT="$HEAD_SHORT" \
DEPLOY_TITLE="$HEAD_TITLE" \
DEPLOY_DESCRIPTION="$HEAD_DESCRIPTION" \
DEPLOY_AUTHOR="$HEAD_AUTHOR" \
DEPLOY_EMAIL="$HEAD_EMAIL" \
DEPLOY_BRANCH="$HEAD_BRANCH" \
DEPLOY_MODE="$MODE" \
DEPLOY_FILES_COUNT="$count" \
DEPLOY_DELETED_COUNT="$deleted_count" \
DEPLOY_COMMITS_SINCE="$COMMITS_SINCE" \
DEPLOY_PREVIOUS_COMMIT="$PREVIOUS_COMMIT" \
DEPLOY_DATE="$(date +%Y-%m-%d)" \
DEPLOY_TIME="$(date +%H:%M:%S)" \
DEPLOY_TZ="$(date +%z)" \
DEPLOY_DEPLOYED_AT="$(date --iso-8601=seconds)" \
python3 - <<'PY'
import json, os
from pathlib import Path

info = {
    "commit": os.environ["DEPLOY_COMMIT"],
    "id": os.environ["DEPLOY_COMMIT"],
    "short_commit": os.environ["DEPLOY_SHORT_COMMIT"],
    "title": os.environ["DEPLOY_TITLE"],
    "description": os.environ.get("DEPLOY_DESCRIPTION", "").rstrip("\n"),
    "author": os.environ["DEPLOY_AUTHOR"],
    "author_email": os.environ["DEPLOY_EMAIL"],
    "branch": os.environ["DEPLOY_BRANCH"],
    "mode": os.environ["DEPLOY_MODE"],
    "files_count": int(os.environ["DEPLOY_FILES_COUNT"]),
    "deleted_count": int(os.environ["DEPLOY_DELETED_COUNT"]),
    "commits_since": int(os.environ["DEPLOY_COMMITS_SINCE"]),
    "previous_commit": os.environ.get("DEPLOY_PREVIOUS_COMMIT") or None,
    "date": os.environ["DEPLOY_DATE"],
    "time": os.environ["DEPLOY_TIME"],
    "timezone": os.environ["DEPLOY_TZ"],
    "deployed_at": os.environ["DEPLOY_DEPLOYED_AT"],
}
Path(os.environ["DEPLOY_INFO_OUT"]).write_text(
    json.dumps(info, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY

echo "  upload ${DEPLOY_INFO_NAME}"
ftp_put "$INFO_LOCAL" "$INFO_REMOTE"

echo "FTP upload done (${MODE}: ${count} files, ${deleted_count} deleted) → ${FTP_HOST}:${REMOTE_ROOT}"
echo "Recorded ${HEAD_SHORT} in ${DEPLOY_INFO_NAME}."
