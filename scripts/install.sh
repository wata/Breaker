#!/usr/bin/env bash

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

usage() {
    cat <<EOF
Usage: ./scripts/install.sh [OPTIONS]

Release ビルドを作り、/Applications/Breaker.app を置き換えて起動する

OPTIONS:
  --no-launch  インストール後に起動しない
  -h, --help   このヘルプを表示
EOF
}

LAUNCH=true

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --no-launch)
            LAUNCH=false
            shift
            ;;
        *)
            echo -e "${RED}不明なオプション: $1${NC}" >&2
            usage >&2
            exit 1
            ;;
    esac
done

DERIVED_DATA="build/release"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/Breaker.app"
INSTALLED_APP="/Applications/Breaker.app"
# Xcode から起動した Debug ビルドも同じ bundle ID なので、終了させるのはインストール先から起動したものに限る
INSTALLED_BINARY="$INSTALLED_APP/Contents/MacOS/Breaker"

step() {
    echo -e "${BLUE}==> $1${NC}"
}

step "Release ビルド"
xcodebuild build \
    -project Breaker.xcodeproj \
    -scheme Breaker \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet

if pgrep -xf "$INSTALLED_BINARY" >/dev/null; then
    step "起動中の Breaker を終了"
    # bundle ID で指すと同じ ID の Debug ビルドが先に選ばれて終了しないことがあるため、パスで指す
    osascript -e "tell application \"$INSTALLED_APP\" to quit"
    for _ in {1..20}; do
        pgrep -xf "$INSTALLED_BINARY" >/dev/null || break
        sleep 0.5
    done
    if pgrep -xf "$INSTALLED_BINARY" >/dev/null; then
        echo -e "${RED}Breaker が 10 秒以内に終了しませんでした${NC}" >&2
        exit 1
    fi
fi

step "$INSTALLED_APP を置き換え"
rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"

if [[ "$LAUNCH" == true ]]; then
    step "起動"
    open "$INSTALLED_APP"
fi

echo -e "${GREEN}インストール完了: $INSTALLED_APP${NC}"
