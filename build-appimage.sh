#!/usr/bin/env bash

set -euo pipefail

# Usage:
#   ./build-appimage.sh [app_name] [executable]
# Example:
#   ./build-appimage.sh MeshcoreOpen meshcore_open
#
# Builds from upstream MeshCore Open source (not a prebuilt zip):
#   1. Clone GITHUB_REPO @ UPSTREAM_TAG (or latest release tag)
#   2. strip_nags.py patch-sources (shop banner + map contribute prompt)
#   3. flutter build linux --release
#   4. Bundle onnxruntime if missing, package AppImage
#
# Requires: flutter on PATH (or FLUTTER_ROOT), git, python3, AppImage deps.
#
# Optional env overrides:
#   VERSION=1.0.0
#   ARCH=x86_64
#   GITHUB_REPO=zjs81/meshcore-open
#   PUBLISH_OWNER=ilikehamradio
#   PUBLISH_REPO=MeshCore-Open-AppImage-Builder
#   ONNXRUNTIME_VERSION=1.28.3   # auto-detected from plugin when possible
#   SKIP_DEP_VERIFY=1            # skip post-bundle ldd gate
#   UPSTREAM_TAG=BETA-99.0.0     # pin upstream git tag/release
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
# Where YOUR AppImages are published (for Gear Lever auto-updates)
PUBLISH_OWNER="${PUBLISH_OWNER:-ilikehamradio}"
PUBLISH_REPO="${PUBLISH_REPO:-MeshCore-Open-AppImage-Builder}"
# flutter_onnxruntime currently vendors 1.28.3; override if upstream bumps it.
ONNXRUNTIME_VERSION="${ONNXRUNTIME_VERSION:-}"
SKIP_DEP_VERIFY="${SKIP_DEP_VERIFY:-0}"
UPSTREAM_TAG="${UPSTREAM_TAG:-}"
STRIP_NAGS_PY="${SCRIPT_DIR}/strip_nags.py"

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
      "${script_name}"|"${OUTPUT_NAME}"|"${ZSYNC_NAME}"|strip_nags.py|test_strip_nags.py|test-impact-map.json|LICENSE|.git|.github)
        continue
        ;;
    esac
    rm -rf "${path}"
  done
  shopt -u dotglob nullglob
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

  if [[ -e "${lib_dir}/libonnxruntime.so" && ! -e "${lib_dir}/libonnxruntime.so.1" ]]; then
    # Plugin bundles the lib as libonnxruntime.so; its soname is .so.1.
    ln -s libonnxruntime.so "${lib_dir}/libonnxruntime.so.1"
    echo "Linked libonnxruntime.so.1 -> libonnxruntime.so in ${lib_dir}"
  fi
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

resolve_upstream_tag() {
  local curl_auth=()
  local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
  local tag

  if [[ -n "${UPSTREAM_TAG}" ]]; then
    echo "${UPSTREAM_TAG}"
    return
  fi

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  tag="$(
    curl -fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: appimage-builder" \
      "${curl_auth[@]}" "${api_url}" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])'
  )"
  if [[ -z "${tag}" ]]; then
    echo "Could not resolve latest upstream tag for ${GITHUB_REPO}" >&2
    exit 1
  fi
  echo "${tag}"
}

# flutter_onnxruntime's CMake downloads onnxruntime-linux-<arch>-<ver>.tgz from
# github.com/microsoft/onnxruntime and fails if that download is unavailable
# (it does not check the HTTP status). When GitHub cannot serve it, pre-seed the
# extraction directory from Microsoft's NuGet package (Microsoft.ML.OnnxRuntime)
# so CMake finds headers + lib and skips its own download. NuGet does not carry
# every GitHub patch release, so fall back to the newest NuGet build with the
# same major.minor (same C API level) when the exact version is missing.
seed_onnxruntime_for_plugin() {
  local src_dir="$1"
  local plugin_root plugin_cmake want arch_tag nuget_rid build_arch
  local gh_url nuget_ver dest work nupkg

  plugin_root="$(python3 - "${src_dir}/.dart_tool/package_config.json" <<'PY' || true
import json, sys
from urllib.parse import urlparse, unquote
cfg = json.load(open(sys.argv[1]))
for pkg in cfg.get("packages", []):
    if pkg.get("name") == "flutter_onnxruntime":
        uri = pkg["rootUri"]
        print(unquote(urlparse(uri).path) if uri.startswith("file:") else uri)
PY
)"
  if [[ -z "${plugin_root}" ]]; then
    echo "flutter_onnxruntime not in dependencies; no ONNX Runtime seeding needed"
    return
  fi
  plugin_cmake="${plugin_root}/linux/CMakeLists.txt"
  if [[ ! -f "${plugin_cmake}" ]]; then
    echo "flutter_onnxruntime has no linux/CMakeLists.txt; skipping ONNX Runtime seeding"
    return
  fi

  want="${ONNXRUNTIME_VERSION:-$(sed -n 's/.*set(ONNXRUNTIME_VERSION "\([0-9.]*\)").*/\1/p' "${plugin_cmake}" | head -n1)}"
  if [[ -z "${want}" ]]; then
    echo "Could not determine flutter_onnxruntime's ONNX Runtime version; leaving CMake to download" >&2
    return
  fi

  case "${ARCH}" in
    x86_64|amd64) arch_tag="x64"; nuget_rid="linux-x64"; build_arch="x64" ;;
    aarch64|arm64) arch_tag="aarch64"; nuget_rid="linux-arm64"; build_arch="arm64" ;;
    *) echo "Unsupported ARCH=${ARCH} for ONNX Runtime" >&2; exit 1 ;;
  esac

  gh_url="https://github.com/microsoft/onnxruntime/releases/download/v${want}/onnxruntime-linux-${arch_tag}-${want}.tgz"
  if curl -fsIL -o /dev/null "${gh_url}"; then
    echo "ONNX Runtime ${want} available from GitHub; plugin will download it itself"
    return
  fi
  echo "ONNX Runtime ${want} not downloadable from GitHub (${gh_url}); seeding from NuGet"

  nuget_ver="$(curl -fsSL https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/index.json \
    | python3 -c '
import json, sys
want = sys.argv[1]
wmaj, wmin, wpat = (int(x) for x in want.split("."))
best = None
for v in json.load(sys.stdin)["versions"]:
    parts = v.split(".")
    if len(parts) != 3 or not all(p.isdigit() for p in parts):
        continue  # skip pre-releases
    maj, mn, pat = map(int, parts)
    if (maj, mn) == (wmaj, wmin) and pat <= wpat and (best is None or pat > best[2]):
        best = (maj, mn, pat)
print(".".join(map(str, best)) if best else "")
' "${want}")"
  if [[ -z "${nuget_ver}" ]]; then
    echo "No NuGet Microsoft.ML.OnnxRuntime release compatible with ${want}" >&2
    exit 1
  fi
  if [[ "${nuget_ver}" != "${want}" ]]; then
    echo "Using NuGet ONNX Runtime ${nuget_ver} (same API level as ${want})"
  fi

  # Directory name must match what the plugin's CMake computes from ${want}.
  dest="${src_dir}/build/linux/${build_arch}/release/plugins/flutter_onnxruntime/onnxruntime/onnxruntime-linux-${arch_tag}-${want}"
  work="${SCRIPT_DIR}/.onnxruntime-nuget"
  nupkg="${work}/ort.nupkg"
  rm -rf "${work}" "${dest}"
  mkdir -p "${work}" "${dest}/include" "${dest}/lib"
  curl -fL -o "${nupkg}" \
    "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/${nuget_ver}/microsoft.ml.onnxruntime.${nuget_ver}.nupkg"
  unzip -q "${nupkg}" 'build/native/include/*' "runtimes/${nuget_rid}/native/*" -d "${work}"

  cp -a "${work}/build/native/include/." "${dest}/include/"
  cp -a "${work}/runtimes/${nuget_rid}/native/." "${dest}/lib/"
  require_file "${dest}/include/onnxruntime_cxx_api.h"
  require_file "${dest}/lib/libonnxruntime.so"
  ln -sf libonnxruntime.so "${dest}/lib/libonnxruntime.so.1"
  rm -rf "${work}"
  echo "Seeded ONNX Runtime into ${dest}"
}

build_from_patched_source() {
  local tag="$1"
  local src_dir="${SCRIPT_DIR}/.upstream-src"
  local bundle_dir
  local flutter_bin="${FLUTTER_ROOT:+${FLUTTER_ROOT}/bin/flutter}"

  if [[ -z "${flutter_bin}" ]]; then
    flutter_bin="$(command -v flutter || true)"
  fi
  if [[ -z "${flutter_bin}" ]]; then
    echo "flutter is required on PATH (or set FLUTTER_ROOT)" >&2
    exit 1
  fi

  require_file "${STRIP_NAGS_PY}"

  rm -rf "${src_dir}"
  echo "Cloning ${GITHUB_REPO}@${tag} ..."
  git clone --depth 1 --branch "${tag}" "https://github.com/${GITHUB_REPO}.git" "${src_dir}"

  echo "Stripping shop banner + map contribute prompt from sources..."
  python3 "${STRIP_NAGS_PY}" patch-sources "${src_dir}"

  (
    cd "${src_dir}"
    "${flutter_bin}" pub get
  )
  seed_onnxruntime_for_plugin "${src_dir}"
  (
    cd "${src_dir}"
    # Upstream now packages its own AppImage during the Release install step
    # (and, on hosts with a newer glibc than its baseline, rebuilds the whole
    # app inside a Podman/Docker Ubuntu container). We package ourselves, so
    # skip that and just produce the plain Flutter bundle.
    MESHCORE_BUILD_APPIMAGE=0 "${flutter_bin}" build linux --release --no-pub
  )

  bundle_dir="${src_dir}/build/linux/x64/release/bundle"
  if [[ ! -d "${bundle_dir}" ]]; then
    bundle_dir="$(find "${src_dir}/build/linux" -type d -path '*/release/bundle' | head -n1 || true)"
  fi
  if [[ -z "${bundle_dir}" || ! -d "${bundle_dir}" ]]; then
    echo "flutter build linux did not produce a release bundle" >&2
    exit 1
  fi

  rm -rf "${SCRIPT_DIR}/data" "${SCRIPT_DIR}/lib" "${SCRIPT_DIR}/${EXECUTABLE}"
  cp -a "${bundle_dir}/${EXECUTABLE}" "${SCRIPT_DIR}/${EXECUTABLE}"
  cp -a "${bundle_dir}/data" "${SCRIPT_DIR}/data"
  cp -a "${bundle_dir}/lib" "${SCRIPT_DIR}/lib"
}

write_apprun() {
  # LD_LIBRARY_PATH covers bundled libs (incl. onnxruntime).
  # JVM probe is for optional dartjni features — we do not ship a JRE.
  # Before launch, force network-map upload off and mark the opt-in prompt shown.
  cat > "${APPDIR}/AppRun" <<EOF
#!/usr/bin/env bash
HERE="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="\$HERE/lib:\${LD_LIBRARY_PATH:-}"

# Never contribute to the public network map; never re-prompt.
if [[ -f "\$HERE/strip_nags.py" ]]; then
  python3 "\$HERE/strip_nags.py" force-map-prefs >/dev/null 2>&1 || true
fi

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
  build_from_patched_source "$(resolve_upstream_tag)"

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
  cp -a "${STRIP_NAGS_PY}" "${APPDIR}/strip_nags.py"

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
