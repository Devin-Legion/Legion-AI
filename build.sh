#!/usr/bin/env bash
# LEGION cross-platform release builder.
#
# The default mode builds one target and embeds the already-exported frontend.
# `./build.sh --release` builds and packages all supported desktop/server targets.
#
# Environment variables:
#   LEGION_TARGET_OS=linux             One target OS in single-target mode.
#   LEGION_TARGET_ARCH=amd64           One target arch in single-target mode.
#   LEGION_TARGETS=linux/amd64,...     Comma-separated targets for multi-target mode.
#   LEGION_BUILD_VERSION=v0.3.3        Version embedded in the binary and archive name.
#   LEGION_OUTPUT=/path/to/legion       Explicit binary path in single-target mode.
#   LEGION_OUTPUT_DIR=dist             Directory for default binary paths.
#   LEGION_PACKAGE=1                   Create a zip archive for each target.
#   LEGION_PACKAGE_DIR=dist            Directory for release archives.
#   LEGION_COMPRESS=off                UPX mode: off, auto, or required.
#   LEGION_UPX_ARGS="--best --lzma"    Arguments passed to UPX.
#   LEGION_SKIP_FRONTEND=1             Reuse server/webui/dist (for CI artifact builds).
#   LEGION_SKIP_NPM_CI=1               Skip npm ci while rebuilding the frontend.
#   LEGION_GOSUMDB=sum.golang.org      Go checksum database.
set -euo pipefail

cd "$(cd "$(dirname "$0")" && pwd)"

info() { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok() { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
사용법:
  ./build.sh                         현재 시스템·현재 아키텍처로 컴파일
  ./build.sh --target linux/amd64   지정한 대상 하나를 컴파일
  ./build.sh --release               지원하는 모든 대상을 컴파일하고 패키징

옵션:
  --release              Linux, macOS, Windows 의 amd64/arm64 대상을 빌드하고 zip 생성
  --target OS/ARCH       단일 대상을 지정합니다. 예: windows/amd64
  --upx                  UPX 로 바이너리를 강제 압축합니다(일부 Linux 환경에서 호환성에 영향을 줄 수 있습니다)
  --no-compress          UPX 를 쓰지 않고 Go linker 로만 축소한 뒤 zip 을 압축
  --help                 도움말 표시

여러 대상 목록은 LEGION_TARGETS 로 재정의할 수 있습니다. 예:
  LEGION_TARGETS=linux/amd64,windows/amd64 ./build.sh --release
EOF
}

RELEASE_TARGETS_DEFAULT="linux/amd64,linux/arm64,darwin/amd64,darwin/arm64,windows/amd64"
LEGION_RELEASE="${LEGION_RELEASE:-0}"
LEGION_COMPRESS="${LEGION_COMPRESS:-off}"
LEGION_PACKAGE="${LEGION_PACKAGE:-0}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release)
      LEGION_RELEASE=1
      LEGION_PACKAGE=1
      shift
      ;;
    --target)
      [ "$#" -ge 2 ] || die "--target 에는 OS/ARCH 인자가 필요합니다"
      target_arg="$2"
      case "$target_arg" in
        */*)
          LEGION_TARGET_OS="${target_arg%%/*}"
          LEGION_TARGET_ARCH="${target_arg##*/}"
          LEGION_TARGETS="$target_arg"
          ;;
        *) die "대상은 OS/ARCH 형식이어야 합니다. 예: linux/amd64" ;;
      esac
      shift 2
      ;;
    --no-compress)
      LEGION_COMPRESS=0
      shift
      ;;
    --upx)
      LEGION_COMPRESS=required
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) die "알 수 없는 인자입니다: $1(사용법은 --help 로 확인하세요)" ;;
  esac
done

command -v go >/dev/null 2>&1 || die "Go 를 찾을 수 없습니다(이 프로젝트는 Go 1.26 이상이 필요합니다)"

LEGION_GOSUMDB="${LEGION_GOSUMDB:-sum.golang.org}"
if [ -z "${LEGION_BUILD_VERSION:-}" ]; then
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    LEGION_BUILD_VERSION="$(git describe --tags --always --dirty)"
  else
    LEGION_BUILD_VERSION="dev"
  fi
fi
# Release tags are commonly passed as v0.3.3; keep the binary version consistent.
LEGION_BUILD_VERSION="${LEGION_BUILD_VERSION#v}"
LEGION_OUTPUT_DIR="${LEGION_OUTPUT_DIR:-dist}"
LEGION_PACKAGE_DIR="${LEGION_PACKAGE_DIR:-$LEGION_OUTPUT_DIR}"
LEGION_UPX_ARGS="${LEGION_UPX_ARGS:---best --lzma}"

if [ "${LEGION_RELEASE}" = "1" ]; then
  LEGION_TARGETS="${LEGION_TARGETS:-$RELEASE_TARGETS_DEFAULT}"
else
  LEGION_TARGET_OS="${LEGION_TARGET_OS:-$(GOSUMDB="$LEGION_GOSUMDB" go env GOOS)}"
  LEGION_TARGET_ARCH="${LEGION_TARGET_ARCH:-$(GOSUMDB="$LEGION_GOSUMDB" go env GOARCH)}"
  LEGION_TARGETS="${LEGION_TARGETS:-${LEGION_TARGET_OS}/${LEGION_TARGET_ARCH}}"
fi

if [ "${LEGION_SKIP_FRONTEND:-0}" = "1" ]; then
  [ -d server/webui/dist ] || die "LEGION_SKIP_FRONTEND=1 이지만 server/webui/dist 가 없습니다"
else
  command -v npm >/dev/null 2>&1 || die "npm 을 찾을 수 없습니다(프런트엔드 정적 빌드에는 Node.js/npm 이 필요합니다)"
  command -v rsync >/dev/null 2>&1 || die "rsync 를 찾을 수 없습니다"
  info "프런트엔드 정적 리소스를 빌드합니다"
  if [ "${LEGION_SKIP_NPM_CI:-0}" != "1" ]; then
    (cd web && npm ci)
  fi
  (cd web && npm run build:static)
  info "프런트엔드 리소스를 server/webui/dist 로 동기화합니다"
  mkdir -p server/webui/dist
  rsync -a --delete web/out/ server/webui/dist/
fi

compress_binary() {
  binary="$1"
  goos="$2"
  case "$LEGION_COMPRESS" in
    0|off|false|none)
      info "UPX 를 건너뜁니다: $binary"
      return 0
      ;;
    auto|required|true|1) ;;
    *) die "LEGION_COMPRESS 는 off, auto, required 중 하나여야 합니다" ;;
  esac

  if ! command -v upx >/dev/null 2>&1; then
    if [ "$LEGION_COMPRESS" = "required" ]; then
      die "LEGION_COMPRESS=required 이지만 upx 를 찾을 수 없습니다"
    fi
    warn "upx 를 찾을 수 없어 linker 압축 결과를 그대로 둡니다: $binary"
    return 0
  fi

  before=$(wc -c < "$binary" | tr -d ' ')
  upx_args="$LEGION_UPX_ARGS"
  [ "$goos" = "darwin" ] && upx_args="$upx_args --force-macos"
  # shellcheck disable=SC2086
  if ! upx $upx_args -- "$binary"; then
    if [ "$LEGION_COMPRESS" = "required" ]; then
      die "UPX 압축에 실패했습니다: $binary"
    fi
    warn "UPX 가 이 대상 형식을 지원하지 않아 압축하지 않은 바이너리를 그대로 둡니다: $binary"
    return 0
  fi
  after=$(wc -c < "$binary" | tr -d ' ')
  ok "UPX 압축 완료: $binary (${before} -> ${after} bytes)"
}

package_binary() {
  binary="$1"
  goos="$2"
  goarch="$3"
  package_name="legion-${LEGION_BUILD_VERSION}-${goos}-${goarch}"
  package_root="${LEGION_PACKAGE_DIR}/${package_name}"
  archive="${LEGION_PACKAGE_DIR}/${package_name}.zip"

  command -v zip >/dev/null 2>&1 || die "패키징에는 zip 이 필요합니다"
  rm -rf "$package_root" "$archive"
  mkdir -p "$package_root"
  cp "$binary" "$package_root/"
  # 데몬 시작 스크립트가 정식 진입점입니다. 화면의 원클릭 업데이트는 프로세스가 종료된 뒤 이 스크립트가 다시 띄워 줘야 동작하고,
  # legion 본체를 직접 실행하면 업데이트 후 다시 기동되지 않습니다. 대상 시스템에 맞는 한 벌만 포함합니다.
  if [ "$goos" = "windows" ]; then
    cp start.bat "$package_root/"
  else
    cp start.sh "$package_root/"
    chmod +x "$package_root/start.sh"
  fi
  cp -R skills "$package_root/"
  cp config.example.json "$package_root/"
  if [ -f README.md ]; then cp README.md "$package_root/"; fi
  (cd "$LEGION_PACKAGE_DIR" && zip -q -r -9 "$(basename "$archive")" "$(basename "$package_root")")
  rm -rf "$package_root"
  ok "릴리스 압축 파일: $archive"
}

build_target() {
  target="$1"
  case "$target" in
    */*) ;;
    *) die "잘못된 대상입니다: $target(OS/ARCH 형식이어야 합니다)" ;;
  esac
  goos="${target%%/*}"
  goarch="${target##*/}"
  case "$goos" in
    linux|darwin|windows) ;;
    *) die "지원하지 않는 시스템입니다: $goos(linux, darwin, windows 를 지원합니다)" ;;
  esac

  binary_name="legion"
  [ "$goos" = "windows" ] && binary_name="legion.exe"
  if [ -n "${LEGION_OUTPUT:-}" ] && [ "$LEGION_RELEASE" != "1" ]; then
    output="$LEGION_OUTPUT"
  else
    output="${LEGION_OUTPUT_DIR}/legion-${goos}-${goarch}/${binary_name}"
  fi
  mkdir -p "$(dirname "$output")"

  info "${goos}/${goarch} 컴파일, 버전 ${LEGION_BUILD_VERSION}"
  GOSUMDB="$LEGION_GOSUMDB" \
  CGO_ENABLED=0 \
  GOOS="$goos" \
  GOARCH="$goarch" \
  go build \
    -tags embedui \
    -trimpath \
    -ldflags "-s -w -buildid= -X main.version=${LEGION_BUILD_VERSION}" \
    -o "$output" \
    ./cmd/legion

  compress_binary "$output" "$goos"
  if command -v file >/dev/null 2>&1; then file "$output"; fi
  if [ "$LEGION_PACKAGE" = "1" ]; then package_binary "$output" "$goos" "$goarch"; fi
  ok "컴파일 완료: $output"
}

write_checksums() {
  [ "$LEGION_PACKAGE" = "1" ] || return 0
  checksum_file="$LEGION_PACKAGE_DIR/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$LEGION_PACKAGE_DIR" && for archive in *.zip; do sha256sum "$archive"; done > "$(basename "$checksum_file")")
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$LEGION_PACKAGE_DIR" && for archive in *.zip; do shasum -a 256 "$archive"; done > "$(basename "$checksum_file")")
  else
    warn "sha256sum 또는 shasum 을 찾을 수 없어 SHA256SUMS 를 건너뜁니다"
    return 0
  fi
  ok "체크섬 파일: $checksum_file"
}

mkdir -p "$LEGION_OUTPUT_DIR"
if [ "$LEGION_PACKAGE" = "1" ]; then mkdir -p "$LEGION_PACKAGE_DIR"; fi

old_ifs="$IFS"
IFS=','
read -r -a targets <<< "$LEGION_TARGETS"
IFS="$old_ifs"
[ "${#targets[@]}" -gt 0 ] || die "LEGION_TARGETS 는 비워 둘 수 없습니다"
for target in "${targets[@]}"; do
  target="${target//[[:space:]]/}"
  [ -n "$target" ] || continue
  build_target "$target"
done

if [ "$LEGION_PACKAGE" = "1" ]; then
  write_checksums
  info "릴리스 패키지를 생성했습니다: $LEGION_PACKAGE_DIR"
fi
