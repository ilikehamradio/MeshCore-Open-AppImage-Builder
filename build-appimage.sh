#!/usr/bin/env bash

set -euo pipefail

# Usage:
#   ./build-appimage.sh [app_name] [executable]
# Example:
#   ./build-appimage.sh MeshcoreOpen meshcore_open
#
# Optional env overrides:
#   VERSION=1.0.0
#   ARCH=x86_64
#   GITHUB_REPO=zjs81/meshcore-open
#   GITHUB_ASSET_PATTERN='linux.*\.(zip|tar\.gz|tgz)$'
#   PUBLISH_OWNER=ilikehamradio
#   PUBLISH_REPO=MeshCore-Open-AppImage-Builder
#   ONNXRUNTIME_VERSION=1.28.3   # auto-detected from plugin when possible
#   SKIP_DEP_VERIFY=1            # skip post-bundle ldd gate
#
# Audit of ~/AppImages/meshcoreopen.appimage (2026-10-28):
#   Hard startup miss: libonnxruntime.so.1 (flutter_onnxruntime → 1.28.3)
#   Soft/lazy miss:    libjvm.so (libdartjni.so; NOT in binary DT_NEEDED)
#   Everything else (GTK/Vulkan/ggml/llama/LiteRt/dawn) resolves from
#   the bundle + normal host libs.

APP_NAME="${1:-MeshcoreOpen}"
EXECUTABLE="${2:-meshcore_open}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${VERSION:-1.0.0}"
ARCH="${ARCH:-x86_64}"
GITHUB_REPO="${GITHUB_REPO:-zjs81/meshcore-open}"
GITHUB_ASSET_PATTERN="${GITHUB_ASSET_PATTERN:-linux.*\.(zip|tar\.gz|tgz)$}"
# Where YOUR AppImages are published (for Gear Lever auto-updates)
PUBLISH_OWNER="${PUBLISH_OWNER:-ilikehamradio}"
PUBLISH_REPO="${PUBLISH_REPO:-MeshCore-Open-AppImage-Builder}"
# flutter_onnxruntime currently vendors 1.28.3; override if upstream bumps it.
ONNXRUNTIME_VERSION="${ONNXRUNTIME_VERSION:-}"
SKIP_DEP_VERIFY="${SKIP_DEP_VERIFY:-0}"

APPDIR="${SCRIPT_DIR}/${APP_NAME}.AppDir"
APPIMAGE_TOOL="${SCRIPT_DIR}/appimagetool-${ARCH}.AppImage"
OUTPUT_NAME="${APP_NAME}-${ARCH}.AppImage"
ZSYNC_NAME="${OUTPUT_NAME}.zsync"
UPDATE_INFO="gh-releases-zsync|${PUBLISH_OWNER}|${PUBLISH_REPO}|latest|${APP_NAME}-*${ARCH}.AppImage.zsync"
ICON_FILE=""

# System libs we expect from the host (do NOT fail the build if ldd finds these).
# Everything else that remains "not found" after bundling is a packaging bug.
HOST_OK_LIBS_REGEX='^(ld-linux-x86-64\.so\.2|libc\.so\.6|libm\.so\.6|libdl\.so\.2|libpthread\.so\.0|librt\.so\.1|libgcc_s\.so\.1|libstdc\+\+\.so\.6|libz\.so\.1|libgtk-3\.so\.0|libgdk-3\.so\.0|libgdk_pixbuf-2\.0\.so\.0|libglib-2\.0\.so\.0|libgobject-2\.0\.so\.0|libgio-2\.0\.so\.0|libpango-1\.0\.so\.0|libpangocairo-1\.0\.so\.0|libcairo\.so\.2|libcairo-gobject\.so\.2|libatk-1\.0\.so\.0|libharfbuzz\.so\.0|libfontconfig\.so\.1|libepoxy\.so\.0|libvulkan\.so\.1|libX11\.so\.6|libXext\.so\.6|libXi\.so\.6|libXcursor\.so\.1|libXdamage\.so\.1|libXfixes\.so\.3|libXrandr\.so\.2|libXinerama\.so\.1|libXcomposite\.so\.1|libxkbcommon\.so\.0|libwayland-client\.so\.0|libwayland-cursor\.so\.0|libwayland-egl\.so\.1|libdbus-1\.so\.3|libpcre2?-8\.so\.0|libffi\.so\.8|libselinux\.so\.1|libmount\.so\.1|libblkid\.so\.1|libuuid\.so\.1|libpng16\.so\.16|libjpeg\.so\.8|libfreetype\.so\.6|libfribidi\.so\.0|libthai\.so\.0|libdatrie\.so\.1|libgraphite2\.so\.3|libpixman-1\.so\.0|libxcb.*|libjvm\.so)$'

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
  local path

  script_name="$(basename "${BASH_SOURCE[0]}")"

  shopt -s dotglob nullglob
  for path in "${SCRIPT_DIR}"/*; do
    case "$(basename "${path}")" in
      "${script_name}"|"${OUTPUT_NAME}"|"${ZSYNC_NAME}")
        continue
        ;;
    esac
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
  local curl_auth=()

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  echo "Fetching recent release metadata from: ${api_url}"
  release_json="$(curl -fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: appimage-builder" "${curl_auth[@]}" "${api_url}")"

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

detect_onnxruntime_version() {
  local plugin="${SCRIPT_DIR}/lib/libflutter_onnxruntime_plugin.so"
  local detected=""

  if [[ -n "${ONNXRUNTIME_VERSION}" ]]; then
    echo "${ONNXRUNTIME_VERSION}"
    return
  fi

  if [[ -f "${plugin}" ]] && command -v strings >/dev/null 2>&1; then
    detected="$(
      strings "${plugin}" \
        | sed -n 's/.*onnxruntime-linux-[^/]*-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' \
        | head -n1
    )"
    if [[ -z "${detected}" ]]; then
      # OrtGetApiBase@VERS_1.28.3 style
      detected="$(
        strings "${plugin}" \
          | sed -n 's/.*VERS_\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' \
          | head -n1
      )"
    fi
  fi

  if [[ -z "${detected}" ]]; then
    detected="1.28.3"
    echo "Could not detect ONNX Runtime version from plugin; defaulting to ${detected}" >&2
  else
    echo "Detected ONNX Runtime version ${detected} from flutter_onnxruntime plugin" >&2
  fi

  echo "${detected}"
}

# Upstream linux zip ships libflutter_onnxruntime_plugin.so but omits
# libonnxruntime.so.1. Bundle the matching Microsoft release into lib/.
ensure_onnxruntime_libs() {
  local lib_dir="${1:-${SCRIPT_DIR}/lib}"
  local version
  local arch_tag
  local tarball_name
  local url
  local download_path
  local extract_dir
  local src_lib

  if [[ -e "${lib_dir}/libonnxruntime.so.1" || -e "${lib_dir}/libonnxruntime.so" ]]; then
    echo "ONNX Runtime already present in ${lib_dir}; leaving as-is"
    return
  fi

  if [[ ! -f "${lib_dir}/libflutter_onnxruntime_plugin.so" ]]; then
    echo "No flutter_onnxruntime plugin found; skipping ONNX Runtime bundle"
    return
  fi

  version="$(detect_onnxruntime_version)"
  case "${ARCH}" in
    x86_64|amd64) arch_tag="x64" ;;
    aarch64|arm64) arch_tag="aarch64" ;;
    *)
      echo "Unsupported ARCH=${ARCH} for ONNX Runtime download" >&2
      exit 1
      ;;
  esac

  tarball_name="onnxruntime-linux-${arch_tag}-${version}.tgz"
  url="https://github.com/microsoft/onnxruntime/releases/download/v${version}/${tarball_name}"
  download_path="${SCRIPT_DIR}/.${tarball_name}"
  extract_dir="${SCRIPT_DIR}/.onnxruntime-extract"

  echo "Bundling missing ONNX Runtime ${version} from: ${url}"
  rm -rf "${extract_dir}" "${download_path}"
  mkdir -p "${extract_dir}"
  curl -fL "${url}" -o "${download_path}"
  tar -xzf "${download_path}" -C "${extract_dir}"

  src_lib="$(find "${extract_dir}" -type d -path "*/lib" | head -n1)"
  if [[ -z "${src_lib}" ]]; then
    echo "ONNX Runtime tarball did not contain a lib/ directory" >&2
    exit 1
  fi

  # Real .so plus soname/symlink aliases the dynamic linker expects.
  cp -a "${src_lib}"/libonnxruntime.so* "${lib_dir}/"
  if [[ -f "${src_lib}/libonnxruntime_providers_shared.so" ]]; then
    cp -a "${src_lib}/libonnxruntime_providers_shared.so" "${lib_dir}/"
  fi

  require_file "${lib_dir}/libonnxruntime.so.1"
  echo "Installed ONNX Runtime into ${lib_dir}:"
  ls -l "${lib_dir}"/libonnxruntime.so* "${lib_dir}"/libonnxruntime_providers_shared.so 2>/dev/null || true
}

# Fail the build if the AppDir still has non-host missing libs on the
# hard startup chain (binary + its DT_NEEDED plugins). libjvm is excluded
# because dartjni is not linked into the binary; AppRun probes a host JDK.
verify_appdir_deps() {
  local appdir="$1"
  local lib_dir="${appdir}/lib"
  local binary="${appdir}/${EXECUTABLE}"
  local missing

  if [[ "${SKIP_DEP_VERIFY}" == "1" ]]; then
    echo "SKIP_DEP_VERIFY=1; skipping dependency verification"
    return
  fi

  require_file "${binary}"
  require_file "${lib_dir}"

  echo "Verifying shared-library closure for ${binary} ..."
  missing="$(
    LD_LIBRARY_PATH="${lib_dir}" ldd "${binary}" 2>/dev/null \
      | awk '/not found/ {print $1}' \
      | sort -u \
      | while IFS= read -r lib; do
          [[ -z "${lib}" ]] && continue
          if [[ "${lib}" =~ ${HOST_OK_LIBS_REGEX} ]]; then
            continue
          fi
          printf '%s\n' "${lib}"
        done
  )"

  if [[ -n "${missing}" ]]; then
    echo "AppDir still missing libraries required at startup:" >&2
    printf '  %s\n' ${missing} >&2
    echo "Bundle them in ensure_* helpers before packaging." >&2
    exit 1
  fi

  if [[ -f "${lib_dir}/libflutter_onnxruntime_plugin.so" ]]; then
    require_file "${lib_dir}/libonnxruntime.so.1"
  fi

  echo "Dependency verification passed (startup chain)."
  if [[ -f "${lib_dir}/libdartjni.so" ]]; then
    echo "Note: libdartjni.so needs libjvm.so at runtime for JNI features;"
    echo "      AppRun will probe JAVA_HOME / /usr/lib/jvm/*/lib/server (not bundled)."
  fi
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
  if [[ -f "${SCRIPT_DIR}/data/flutter_assets/assets/images/mesh-icon.png" ]]; then
    ICON_FILE="${SCRIPT_DIR}/data/flutter_assets/assets/images/mesh-icon.png"
    echo "Using local bundle icon: ${ICON_FILE}"
    return
  fi

  if [[ -f "${SCRIPT_DIR}/data/flutter_assets/assets/icons/done_all.svg" ]]; then
    ICON_FILE="${SCRIPT_DIR}/data/flutter_assets/assets/icons/done_all.svg"
    echo "Using local bundle icon: ${ICON_FILE}"
    return
  fi

  echo "No icon found on GitHub or locally; continuing without icon."
}

write_apprun() {
  # LD_LIBRARY_PATH covers bundled libs (incl. onnxruntime).
  # JVM probe is for optional dartjni features — we do not ship a JRE.
  cat > "${APPDIR}/AppRun" <<EOF
#!/usr/bin/env bash
HERE="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="\$HERE/lib:\${LD_LIBRARY_PATH:-}"

# Optional JNI (libdartjni.so → libjvm.so). Prefer an existing host JDK.
_jvm_candidates=()
if [[ -n "\${JAVA_HOME:-}" ]]; then
  _jvm_candidates+=("\${JAVA_HOME}/lib/server" "\${JAVA_HOME}/lib/amd64/server")
fi
_jvm_candidates+=(
  /usr/lib/jvm/default-java/lib/server
  /usr/lib/jvm/default/lib/server
)
# shellcheck disable=SC2044
for _d in \$(ls -d /usr/lib/jvm/*/lib/server 2>/dev/null || true); do
  _jvm_candidates+=("\${_d}")
done
for _jvm_dir in "\${_jvm_candidates[@]}"; do
  if [[ -e "\${_jvm_dir}/libjvm.so" ]]; then
    export LD_LIBRARY_PATH="\${_jvm_dir}:\${LD_LIBRARY_PATH}"
    break
  fi
done
unset _jvm_candidates _jvm_dir _d

exec "\$HERE/${EXECUTABLE}" "\$@"
EOF
  chmod +x "${APPDIR}/AppRun"
}

main() {
  rm -rf "${SCRIPT_DIR}/data" "${SCRIPT_DIR}/lib" "${SCRIPT_DIR}/${EXECUTABLE}"
  download_latest_linux_bundle

  require_file "${SCRIPT_DIR}/${EXECUTABLE}"
  require_file "${SCRIPT_DIR}/data"
  require_file "${SCRIPT_DIR}/lib"

  # Fix packaging gaps before assembling AppDir.
  ensure_onnxruntime_libs "${SCRIPT_DIR}/lib"

  rm -rf "${APPDIR}"
  mkdir -p "${APPDIR}"

  # Keep the same layout as your existing Linux bundle to avoid
  # runtime path issues (binary expects sibling data/ and lib/).
  cp -a "${SCRIPT_DIR}/${EXECUTABLE}" "${APPDIR}/"
  cp -a "${SCRIPT_DIR}/data" "${APPDIR}/"
  cp -a "${SCRIPT_DIR}/lib" "${APPDIR}/"

  write_apprun

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

  verify_appdir_deps "${APPDIR}"

  download_appimagetool

  echo "Building AppImage with update info: ${UPDATE_INFO}"
  # Use extract-and-run so appimagetool works on systems without FUSE.
  # -u embeds .upd_info so Gear Lever can auto-detect updates.
  ARCH="${ARCH}" APPIMAGE_EXTRACT_AND_RUN=1 "${APPIMAGE_TOOL}" \
    -u "${UPDATE_INFO}" \
    "${APPDIR}"

  require_file "${SCRIPT_DIR}/${OUTPUT_NAME}"
  require_file "${SCRIPT_DIR}/${ZSYNC_NAME}"

  cleanup_workspace
  echo "Done. Created:"
  echo "  ${SCRIPT_DIR}/${OUTPUT_NAME}"
  echo "  ${SCRIPT_DIR}/${ZSYNC_NAME}"
}

main "$@"
