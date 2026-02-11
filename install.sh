#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install.sh install [--install-dir DIR] [--build]
  install.sh build [--target TARGET]
  install.sh upload [--target TARGET]
  install.sh clear [--install-dir DIR]
  install.sh uninstall [--install-dir DIR]
  install.sh --help

Commands:
  install            Install a built codex binary and update the codex symlink
  build              Build codex and write target/release/.version
  upload             Upload a built codex binary to king.promakh.com
  clear              Remove unused version directories from <install_dir>/codex.d
  uninstall          Remove only <install_dir>/codex symlink (keep versioned binaries)

Options:
  --install-dir DIR  Install base directory (default: $HOME/.local/bin)
  --build            Build codex binary before installing (install command only)
  -t, --target       Target for build/upload commands: linux (default) or windows
  --help             Show this help message
USAGE
}

build_codex() {
  local target="$1"
  local cargo_args=(build --release -p codex-cli)
  if [[ "$target" == "windows" ]]; then
    cargo_args+=(--target x86_64-pc-windows-gnu)
  fi

  (cd codex-rs && cargo "${cargo_args[@]}")
  version="$(awk -F'"' '/^version = / {print $2; exit}' codex-rs/Cargo.toml)"
  if [[ -z "$version" ]]; then
    echo "error: could not determine version from codex-rs/Cargo.toml" >&2
    exit 1
  fi
  short_sha="$(git rev-parse --short HEAD 2>/dev/null || true)"
  if [[ -z "$short_sha" ]]; then
    echo "error: could not determine git commit SHA" >&2
    exit 1
  fi
  printf '%s-%s\n' "$version" "$short_sha" > codex-rs/target/release/.version
  echo "Built codex $version-$short_sha"
}

install_codex() {
  local install_dir="$1"
  local binary_src="codex-rs/target/release/codex"
  local version_file="codex-rs/target/release/.version"

  if [[ ! -x "$binary_src" ]]; then
    echo "error: binary not found or not executable: $binary_src" >&2
    echo "hint: run './install.sh build' or './install.sh install --build'" >&2
    exit 1
  fi
  if [[ ! -f "$version_file" ]]; then
    echo "error: version file not found: $version_file" >&2
    echo "hint: run './install.sh build' or './install.sh install --build'" >&2
    exit 1
  fi

  local version_sha
  version_sha="$(tr -d '[:space:]' < "$version_file")"
  if [[ -z "$version_sha" ]]; then
    echo "error: version file is empty: $version_file" >&2
    echo "hint: run './install.sh build' or './install.sh install --build'" >&2
    exit 1
  fi

  local codex_d="$install_dir/codex.d"
  local install_path="$codex_d/$version_sha/codex"

  mkdir -p "$codex_d/$version_sha"
  cp -f "$binary_src" "$install_path"
  chmod +x "$install_path"

  ln -sfn "$install_path" "$install_dir/codex"
  echo "Installed codex $version_sha to $install_path"
}

clear_unused_versions() {
  local install_dir="$1"
  local codex_d="$install_dir/codex.d"
  local current_link="$install_dir/codex"
  local keep_dir=""

  if [[ -L "$current_link" ]]; then
    local link_target
    link_target="$(readlink -f "$current_link" || true)"
    if [[ -n "$link_target" ]]; then
      keep_dir="$(dirname "$link_target")"
    fi
  fi

  if [[ ! -d "$codex_d" ]]; then
    echo "Nothing to clear: $codex_d does not exist"
    return 0
  fi

  for dir in "$codex_d"/*; do
    if [[ -d "$dir" && "$dir" != "$keep_dir" ]]; then
      rm -rf "$dir"
    fi
  done

  echo "Cleared unused versions from $codex_d"
}

uninstall_link() {
  local install_dir="$1"
  local current_link="$install_dir/codex"

  if [[ ! -e "$current_link" ]]; then
    echo "No codex link to remove at $current_link"
    return 0
  fi
  if [[ ! -L "$current_link" ]]; then
    echo "error: $current_link exists but is not a symlink; refusing to remove it" >&2
    exit 1
  fi

  rm -f "$current_link"
  echo "Removed codex symlink at $current_link"
}

validate_target() {
  local target="$1"

  case "$target" in
    linux|windows)
      ;;
    *)
      echo "error: --target must be 'linux' or 'windows'" >&2
      usage >&2
      exit 1
      ;;
  esac
}

upload_codex() {
  local target="$1"
  local binary_src

  case "$target" in
    linux)
      binary_src="codex-rs/target/release/codex"
      ;;
    windows)
      binary_src="codex-rs/target/x86_64-pc-windows-gnu/release/codex.exe"
      ;;
    *)
      echo "error: unsupported target for upload: $target" >&2
      exit 1
      ;;
  esac

  if [[ ! -f "$binary_src" ]]; then
    echo "error: binary not found for target '$target': $binary_src" >&2
    echo "hint: run './install.sh build --target $target' first" >&2
    exit 1
  fi

  scp "$binary_src" "king.promakh.com:~/docker/nginx-ui/www/"
  echo "Uploaded $binary_src to king.promakh.com:~/docker/nginx-ui/www/"
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 1
fi

command="$1"
shift

install_dir="${HOME}/.local/bin"
run_build=false
build_target="linux"

case "$command" in
  --help|-h|help)
    usage
    exit 0
    ;;
  install)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --install-dir)
          if [[ $# -lt 2 ]]; then
            echo "error: --install-dir requires a value" >&2
            exit 1
          fi
          install_dir="$2"
          shift 2
          ;;
        --install-dir=*)
          install_dir="${1#*=}"
          shift
          ;;
        --build)
          run_build=true
          shift
          ;;
        --help|-h)
          usage
          exit 0
          ;;
        *)
          echo "error: unknown option for install: $1" >&2
          usage >&2
          exit 1
          ;;
      esac
    done
    mkdir -p "$install_dir"
    if [[ "$run_build" == "true" ]]; then
      build_codex "linux"
    fi
    install_codex "$install_dir"
    ;;
  build)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t|--target)
          if [[ $# -lt 2 ]]; then
            echo "error: $1 requires a value" >&2
            exit 1
          fi
          build_target="$2"
          shift 2
          ;;
        --target=*)
          build_target="${1#*=}"
          shift
          ;;
        --help|-h)
          usage
          exit 0
          ;;
        *)
          echo "error: unknown option for build: $1" >&2
          usage >&2
          exit 1
          ;;
      esac
    done

    validate_target "$build_target"
    build_codex "$build_target"
    ;;
  upload)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t|--target)
          if [[ $# -lt 2 ]]; then
            echo "error: $1 requires a value" >&2
            exit 1
          fi
          build_target="$2"
          shift 2
          ;;
        --target=*)
          build_target="${1#*=}"
          shift
          ;;
        --help|-h)
          usage
          exit 0
          ;;
        *)
          echo "error: unknown option for upload: $1" >&2
          usage >&2
          exit 1
          ;;
      esac
    done

    validate_target "$build_target"
    upload_codex "$build_target"
    ;;
  clear)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --install-dir)
          if [[ $# -lt 2 ]]; then
            echo "error: --install-dir requires a value" >&2
            exit 1
          fi
          install_dir="$2"
          shift 2
          ;;
        --install-dir=*)
          install_dir="${1#*=}"
          shift
          ;;
        --help|-h)
          usage
          exit 0
          ;;
        *)
          echo "error: unknown option for clear: $1" >&2
          usage >&2
          exit 1
          ;;
      esac
    done
    clear_unused_versions "$install_dir"
    ;;
  uninstall)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --install-dir)
          if [[ $# -lt 2 ]]; then
            echo "error: --install-dir requires a value" >&2
            exit 1
          fi
          install_dir="$2"
          shift 2
          ;;
        --install-dir=*)
          install_dir="${1#*=}"
          shift
          ;;
        --help|-h)
          usage
          exit 0
          ;;
        *)
          echo "error: unknown option for uninstall: $1" >&2
          usage >&2
          exit 1
          ;;
      esac
    done
    uninstall_link "$install_dir"
    ;;
  *)
    echo "error: unknown command: $command" >&2
    usage >&2
    exit 1
    ;;
esac
