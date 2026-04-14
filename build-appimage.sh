#!/usr/bin/env bash

set -euo pipefail

# Usage:
#   ./build-appimage.sh [app_name] [executable]
# Example:
#   ./build-appimage.sh MeshcoreOpen meshcore_open

APP_NAME="${1:-MeshcoreOpen}"
EXECUTABLE="${2:-meshcore_open}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${VERSION:-1.0.0}"
ARCH="${ARCH:-x86_64}"
GITHUB_REPO="${GITHUB_REPO:-zjs81/meshcore-open}"
GITHUB_ASSET_PATTERN="${GITHUB_ASSET_PATTERN:-linux.*\.(zip|tar\.gz|tgz)$}"

APPDIR="${SCRIPT_DIR}/${APP_NAME}.AppDir"
APPIMAGE_TOOL="${SCRIPT_DIR}/appimagetool-${ARCH}.AppImage"
ICON_FILE=""

require_file() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "Missing required file or directory: $path" >&2
    exit 1
  fi
}

download_appimagetool() {
  if [[ -x "${APPIMAGE_TOOL}" ]]; then
    return
  fi

  local url="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${ARCH}.AppImage"
  echo "Downloading appimagetool from: ${url}"
  curl -fL "$url" -o "${APPIMAGE_TOOL}"
  chmod +x "${APPIMAGE_TOOL}"
}

cleanup_workspace() {
  local script_name
  local output_name
  local path

  script_name="$(basename "${BASH_SOURCE[0]}")"
  output_name="${APP_NAME}-${ARCH}.AppImage"

  shopt -s dotglob nullglob
  for path in "${SCRIPT_DIR}"/*; do
    if [[ "$(basename "${path}")" == "${script_name}" ]]; then
      continue
    fi
    if [[ "$(basename "${path}")" == "${output_name}" ]]; then
      continue
    fi
    rm -rf "${path}"
  done
  shopt -u dotglob nullglob
}

download_latest_linux_bundle() {
  local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=10"
  local release_json
  local asset_info
  local asset_name
  local asset_url
  local download_path
  local extract_dir
  local bundle_root

  echo "Fetching recent release metadata from: ${api_url}"
  release_json="$(curl -fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: appimage-builder" "${api_url}")"

  asset_info="$(
    python3 -c '
import json
import re
import sys

data = json.load(sys.stdin)
if isinstance(data, dict) and data.get("message"):
    msg = data.get("message", "GitHub API error")
    print(f"ERROR::{msg}")
    raise SystemExit(0)

if isinstance(data, dict):
    releases = [data]
else:
    releases = data

patterns = [
    r"linux.*(x86_64|amd64).*\.(zip|tar\.gz|tgz)$",
    r"(x86_64|amd64).*linux.*\.(zip|tar\.gz|tgz)$",
    r"linux-release\.(zip|tar\.gz|tgz)$",
    sys.argv[1],
    r"linux.*\.(zip|tar\.gz|tgz)$",
]

for pattern in patterns:
    regex = re.compile(pattern, re.IGNORECASE)
    for release in releases:
        for asset in release.get("assets", []):
            name = asset.get("name", "")
            if regex.search(name):
                print(name)
                print(asset.get("browser_download_url", ""))
                raise SystemExit(0)
' "${GITHUB_ASSET_PATTERN}" <<< "${release_json}"
  )"

  if [[ "${asset_info}" == ERROR::* ]]; then
    echo "GitHub API returned an error for ${GITHUB_REPO}: ${asset_info#ERROR::}" >&2
    echo "If you hit API limits, try again later or set GITHUB_TOKEN for authenticated requests." >&2
    exit 1
  fi

  if [[ -z "${asset_info}" ]]; then
    echo "No Linux build asset found across recent releases for ${GITHUB_REPO}." >&2
    echo "Current pattern: ${GITHUB_ASSET_PATTERN}" >&2
    echo "You can override it with GITHUB_ASSET_PATTERN='<regex>'." >&2
    exit 1
  fi

  mapfile -t _asset_lines <<< "${asset_info}"
  asset_name="${_asset_lines[0]}"
  asset_url="${_asset_lines[1]}"

  if [[ -z "${asset_url}" ]]; then
    echo "Latest release asset URL is empty for ${GITHUB_REPO}." >&2
    exit 1
  fi

  download_path="${SCRIPT_DIR}/.latest-linux-build-${asset_name}"
  extract_dir="${SCRIPT_DIR}/.latest-linux-build"
  rm -rf "${extract_dir}" "${download_path}"
  mkdir -p "${extract_dir}"

  echo "Downloading latest Linux bundle: ${asset_name}"
  curl -fL "${asset_url}" -o "${download_path}"

  case "${asset_name}" in
    *.zip)
      unzip -q "${download_path}" -d "${extract_dir}"
      ;;
    *.tar.gz|*.tgz)
      tar -xzf "${download_path}" -C "${extract_dir}"
      ;;
    *)
      echo "Unsupported asset format for ${asset_name}; expected .zip or .tar.gz/.tgz" >&2
      exit 1
      ;;
  esac

  bundle_root="$(
    find "${extract_dir}" -type f -name "${EXECUTABLE}" -printf '%h\n' \
      | while IFS= read -r path; do
          if [[ -d "${path}/data" && -d "${path}/lib" ]]; then
            printf '%s\n' "${path}"
            break
          fi
        done
  )"

  if [[ -z "${bundle_root}" ]]; then
    echo "Could not locate ${EXECUTABLE} with sibling data/ and lib/ in ${asset_name}" >&2
    exit 1
  fi

  cp -a "${bundle_root}/${EXECUTABLE}" "${SCRIPT_DIR}/${EXECUTABLE}"
  cp -a "${bundle_root}/data" "${SCRIPT_DIR}/data"
  cp -a "${bundle_root}/lib" "${SCRIPT_DIR}/lib"
}

resolve_icon() {
  # Prefer the exact project icon from GitHub.
  local candidates=(
    "https://raw.githubusercontent.com/zjs81/meshcore-open/dev/assets/images/mesh-icon.png"
  )

  for url in "${candidates[@]}"; do
    local ext="${url##*.}"
    local out="${SCRIPT_DIR}/appicon.${ext}"
    if curl -fsSL "$url" -o "$out"; then
      ICON_FILE="$out"
      echo "Using icon from GitHub: $url"
      return
    fi
  done

  # Fallback: local icon from the extracted Linux bundle.
  if [[ -f "${SCRIPT_DIR}/data/flutter_assets/assets/icons/done_all.svg" ]]; then
    ICON_FILE="${SCRIPT_DIR}/data/flutter_assets/assets/icons/done_all.svg"
    echo "Using local bundle icon: ${ICON_FILE}"
    return
  fi

  echo "No icon found on GitHub or locally; continuing without icon."
}

main() {
  rm -rf "${SCRIPT_DIR}/data" "${SCRIPT_DIR}/lib" "${SCRIPT_DIR}/${EXECUTABLE}"
  download_latest_linux_bundle

  require_file "${SCRIPT_DIR}/${EXECUTABLE}"
  require_file "${SCRIPT_DIR}/data"
  require_file "${SCRIPT_DIR}/lib"

  rm -rf "${APPDIR}"
  mkdir -p "${APPDIR}"

  # Keep the same layout as your existing Linux bundle to avoid
  # runtime path issues (binary expects sibling data/ and lib/).
  cp -a "${SCRIPT_DIR}/${EXECUTABLE}" "${APPDIR}/"
  cp -a "${SCRIPT_DIR}/data" "${APPDIR}/"
  cp -a "${SCRIPT_DIR}/lib" "${APPDIR}/"

  cat > "${APPDIR}/AppRun" <<EOF
#!/usr/bin/env bash
HERE="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="\$HERE/lib:\${LD_LIBRARY_PATH:-}"
exec "\$HERE/${EXECUTABLE}" "\$@"
EOF
  chmod +x "${APPDIR}/AppRun"

  cat > "${APPDIR}/${APP_NAME}.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=${APP_NAME}
Exec=${EXECUTABLE}
Terminal=false
Categories=Utility;
Icon=${APP_NAME}
EOF

  resolve_icon
  if [[ -n "${ICON_FILE}" ]]; then
    local icon_ext="${ICON_FILE##*.}"
    cp "${ICON_FILE}" "${APPDIR}/${APP_NAME}.${icon_ext}"
    ln -sf "${APP_NAME}.${icon_ext}" "${APPDIR}/.DirIcon"
    mkdir -p "${APPDIR}/usr/share/icons/hicolor/256x256/apps"
    cp "${ICON_FILE}" "${APPDIR}/usr/share/icons/hicolor/256x256/apps/${APP_NAME}.${icon_ext}"
  fi

  download_appimagetool

  echo "Building AppImage..."
  # Use extract-and-run so appimagetool works on systems without FUSE.
  ARCH="${ARCH}" APPIMAGE_EXTRACT_AND_RUN=1 "${APPIMAGE_TOOL}" "${APPDIR}"
  cleanup_workspace
  echo "Done. AppImage created in: ${SCRIPT_DIR}"
}

main "$@"
