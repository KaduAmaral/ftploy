#!/usr/bin/env bash
# Install the ftploy command for the current user.
#
#   curl -fsSL https://raw.githubusercontent.com/KaduAmaral/ftploy/main/install.sh | bash
#   wget -qO- https://raw.githubusercontent.com/KaduAmaral/ftploy/main/install.sh | bash
#
# Pin a tag (the ref must match the URL you downloaded):
#
#   curl -fsSL https://raw.githubusercontent.com/KaduAmaral/ftploy/v0.1.0/install.sh | bash -s -- --ref v0.1.0
#
# Local try-out, without GitHub:
#
#   bash install.sh --from-file ./deploy.sh --no-modify-path --dir /tmp/bin

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Este instalador precisa do bash: curl -fsSL <url>/install.sh | bash" >&2
  exit 1
fi

set -euo pipefail

DEFAULT_REPO="KaduAmaral/ftploy"
DEFAULT_REF="main"
DEFAULT_NAME="ftploy"
MARKER_BEGIN="# >>> ftploy >>>"
MARKER_END="# <<< ftploy <<<"

REPO="${DEPLOY_REPO:-$DEFAULT_REPO}"
REF="${DEPLOY_REF:-$DEFAULT_REF}"
CMD_NAME="${DEPLOY_CMD:-$DEFAULT_NAME}"
INSTALL_DIR="${DEPLOY_INSTALL_DIR:-${HOME}/.local/bin}"
FROM_FILE=""
DO_UNINSTALL=0
NO_MODIFY_PATH=0
DIR_SET=0

usage() {
  cat <<EOF
Usage: install.sh [options]

  Instala o comando ${CMD_NAME} em ${INSTALL_DIR}.
  Se esse diretório não estiver no PATH, acrescenta um bloco no arquivo
  de configuração do shell atual.

Options:
  --repo OWNER/NAME   Repositório GitHub (default: ${DEFAULT_REPO})
  --ref REF           Branch, tag ou commit (default: ${DEFAULT_REF})
  --name CMD          Nome do comando (default: ${DEFAULT_NAME})
  --dir DIR           Diretório de instalação (default: ~/.local/bin)
  --from-file PATH    Instala esta cópia local em vez de baixar
  --no-modify-path    Não altera .bashrc / .zshrc / config.fish
  --uninstall         Remove o comando e o bloco de PATH
  -h, --help          Mostra esta ajuda

Variáveis equivalentes: DEPLOY_REPO, DEPLOY_REF, DEPLOY_CMD, DEPLOY_INSTALL_DIR.
PROFILE=/dev/null pula a alteração do PATH.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      REPO="${2:?--repo exige OWNER/NAME}"
      shift 2
      ;;
    --repo=*)
      REPO="${1#--repo=}"
      shift
      ;;
    --ref | --branch | --tag)
      REF="${2:?--ref exige um branch, tag ou commit}"
      shift 2
      ;;
    --ref=* | --branch=* | --tag=*)
      REF="${1#*=}"
      shift
      ;;
    --name)
      CMD_NAME="${2:?--name exige o nome do comando}"
      shift 2
      ;;
    --name=*)
      CMD_NAME="${1#--name=}"
      shift
      ;;
    --dir)
      INSTALL_DIR="${2:?--dir exige um diretório}"
      DIR_SET=1
      shift 2
      ;;
    --dir=*)
      INSTALL_DIR="${1#--dir=}"
      DIR_SET=1
      shift
      ;;
    --from-file)
      FROM_FILE="${2:?--from-file exige um caminho}"
      shift 2
      ;;
    --from-file=*)
      FROM_FILE="${1#--from-file=}"
      shift
      ;;
    --no-modify-path)
      NO_MODIFY_PATH=1
      shift
      ;;
    --uninstall)
      DO_UNINSTALL=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Opção desconhecida: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "${PROFILE:-}" = "/dev/null" ]; then
  NO_MODIFY_PATH=1
fi

display_path() {
  case "$1" in
    "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

fetch_to() {
  local url="$1"
  local dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
  else
    echo "curl ou wget é necessário para baixar o script." >&2
    exit 1
  fi
}

assert_deploy_script() {
  local file="$1"
  if [ ! -s "$file" ]; then
    echo "Arquivo vazio: $file" >&2
    exit 1
  fi
  if ! head -n 1 "$file" | grep -q 'bash'; then
    echo "O arquivo baixado não é o script de deploy." >&2
    exit 1
  fi
}

detect_profile() {
  if [ -n "${PROFILE:-}" ]; then
    printf '%s\n' "$PROFILE"
    return 0
  fi
  local name="${SHELL:-}"
  name="${name##*/}"
  case "$name" in
    bash)
      if [ -f "$HOME/.bashrc" ]; then
        printf '%s\n' "$HOME/.bashrc"
      elif [ -f "$HOME/.bash_profile" ]; then
        printf '%s\n' "$HOME/.bash_profile"
      else
        printf '%s\n' "$HOME/.bashrc"
      fi
      ;;
    zsh)
      printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc"
      ;;
    fish)
      printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"
      ;;
    *)
      printf '%s\n' "$HOME/.profile"
      ;;
  esac
}

strip_block() {
  local file="$1"
  [ -f "$file" ] || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    skip { next }
    { print }
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

path_block() {
  local profile="$1"
  local dir_expr
  case "$INSTALL_DIR" in
    "$HOME"/*) dir_expr="\$HOME/${INSTALL_DIR#"$HOME"/}" ;;
    *) dir_expr="$INSTALL_DIR" ;;
  esac
  if [[ "$profile" == *.fish ]]; then
    cat <<EOF
$MARKER_BEGIN
fish_add_path ${dir_expr}
$MARKER_END
EOF
  else
    cat <<EOF
$MARKER_BEGIN
case ":\$PATH:" in
  *":${dir_expr}:"*) ;;
  *) export PATH="${dir_expr}:\$PATH" ;;
esac
$MARKER_END
EOF
  fi
}

ensure_blank_line() {
  local file="$1"
  [ -s "$file" ] || return 0
  # tail -c strips nothing when the file already ends in a newline, so the
  # command substitution is empty in that case.
  if [ -n "$(tail -c 1 "$file")" ]; then
    printf '\n\n' >>"$file"
  elif [ -n "$(tail -n 1 "$file")" ]; then
    printf '\n' >>"$file"
  fi
}

configure_path() {
  local profile
  profile="$(detect_profile)"
  mkdir -p "$(dirname "$profile")"
  strip_block "$profile"
  ensure_blank_line "$profile"
  path_block "$profile" >>"$profile"
  printf '%s\n' "$profile"
}

known_profiles() {
  printf '%s\n' \
    "$HOME/.bashrc" \
    "$HOME/.bash_profile" \
    "$HOME/.profile" \
    "$HOME/.zshrc" \
    "${ZDOTDIR:-$HOME}/.zshrc" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"
}

path_contains_dir() {
  case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) return 0 ;;
    *) return 1 ;;
  esac
}

install_command() {
  local dest="${INSTALL_DIR}/${CMD_NAME}"
  local tmp
  tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  if [ -n "$FROM_FILE" ]; then
    if [ ! -f "$FROM_FILE" ]; then
      echo "Arquivo não encontrado: $FROM_FILE" >&2
      exit 1
    fi
    cp "$FROM_FILE" "$tmp"
  else
    case "$REPO" in
      SEU_USUARIO/* | "" )
        echo "Defina o repositório antes de publicar." >&2
        echo "Edite DEFAULT_REPO em install.sh ou passe --repo owner/nome." >&2
        exit 1
        ;;
    esac
    local url="https://raw.githubusercontent.com/${REPO}/${REF}/deploy.sh"
    echo "Baixando ${url}" >&2
    fetch_to "$url" "$tmp"
  fi

  assert_deploy_script "$tmp"
  mkdir -p "$INSTALL_DIR"
  # Preserve the destination inode when the file already exists.
  cat "$tmp" >"$dest"
  chmod 755 "$dest"
  printf '%s\n' "$dest"
}

uninstall_command() {
  local dest="${INSTALL_DIR}/${CMD_NAME}"
  local profile
  local removed=0
  if [ -f "$dest" ]; then
    rm -f "$dest"
    echo "Removido $(display_path "$dest")"
    removed=1
  fi
  local seen=" "
  while IFS= read -r profile; do
    [ -n "$profile" ] || continue
    case "$seen" in
      *" $profile "*) continue ;;
    esac
    seen="${seen}${profile} "
    if [ -f "$profile" ] && grep -qF "$MARKER_BEGIN" "$profile"; then
      strip_block "$profile"
      echo "PATH removido de $(display_path "$profile")"
      removed=1
    fi
  done < <(known_profiles)
  if [ "$removed" -eq 0 ]; then
    echo "Nada para remover em $(display_path "$dest")"
  fi
}

if [ "$(id -u)" -eq 0 ] && [ "$DIR_SET" -eq 0 ] && [ -z "${DEPLOY_INSTALL_DIR:-}" ]; then
  echo "Como root, a instalação padrão iria para /root/.local/bin." >&2
  echo "Rode sem sudo para instalar no seu usuário, ou use --dir /usr/local/bin." >&2
  exit 1
fi

if [ "$DO_UNINSTALL" -eq 1 ]; then
  uninstall_command
  exit 0
fi

DEST="$(install_command)"
echo "Instalado em $(display_path "$DEST")"

if [ "$NO_MODIFY_PATH" -eq 0 ]; then
  case "$INSTALL_DIR" in
    /usr/local/bin | /usr/bin | /bin) ;;
    *)
      PROFILE_FILE="$(configure_path)"
      echo "PATH atualizado em $(display_path "$PROFILE_FILE")"
      ;;
  esac
fi

if path_contains_dir; then
  echo "Pronto. Rode: ${CMD_NAME} --help"
else
  echo "Abra um terminal novo, ou rode agora:"
  echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
  echo "Depois: ${CMD_NAME} --help"
fi
