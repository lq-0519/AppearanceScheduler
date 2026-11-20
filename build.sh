#!/bin/bash

set -euo pipefail

# 通过脚本位置找到源码和签名配置，允许从任意目录执行构建。
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_name="AppearanceScheduler.app"
output_app="${1:-}"

if [[ $# -ne 1 || "$output_app" != /* || "$(basename "$output_app")" != "$app_name" || "$output_app" == */ ]]; then
  printf '用法：%s /绝对路径/%s\n' "$0" "$app_name" >&2
  exit 2
fi

# 使用同一签名证书重装时可保持应用身份；临时签名便于在其他 Mac 上本地构建。
signing_identity="${SIGNING_IDENTITY:--}"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$project_dir/Info.plist")"
output_dir="$(dirname "$output_app")"
mkdir -p "$output_dir"

# 只替换使用相同 Bundle ID 的应用，避免覆盖路径上已有的其他文件。
if [[ -e "$output_app" || -L "$output_app" ]]; then
  if [[ -L "$output_app" || ! -d "$output_app" ]] || \
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$output_app/Contents/Info.plist" 2>/dev/null)" != "$bundle_id" ]]; then
    printf '无法替换此输出路径：%s\n' "$output_app" >&2
    exit 1
  fi
fi

# 在输出目录内组装并验证应用，之后再用同卷移动替换旧包。
build_dir="$(mktemp -d "$output_dir/.AppearanceScheduler-build.XXXXXXXX")"
previous_app="$build_dir/previous.app"
bundle="$build_dir/$app_name"

# 如果替换过程中失败，恢复旧包并清理本次构建目录。
cleanup() {
  if [[ -e "$previous_app" && ! -e "$output_app" ]]; then
    if ! mv "$previous_app" "$output_app"; then
      printf '旧应用保留在：%s\n' "$previous_app" >&2
      return 1
    fi
  fi
  rm -rf "$build_dir"
}
trap cleanup EXIT

mkdir -p "$bundle/Contents/MacOS"
/usr/bin/plutil -lint "$project_dir/Info.plist" "$project_dir/AppearanceScheduler.entitlements"
cp "$project_dir/Info.plist" "$bundle/Contents/Info.plist"

# 为当前处理器编译经优化的原生应用，最低系统版本与 Info.plist 保持一致。
/usr/bin/xcrun swiftc \
  -parse-as-library \
  -swift-version 5 \
  -O -whole-module-optimization \
  -target "$(uname -m)-apple-macosx13.0" \
  -sdk "$(/usr/bin/xcrun --sdk macosx --show-sdk-path)" \
  -framework AppKit -framework ServiceManagement \
  -o "$bundle/Contents/MacOS/AppearanceScheduler" \
  "$project_dir"/Sources/*.swift

/usr/bin/codesign --force --options runtime --timestamp=none \
  --entitlements "$project_dir/AppearanceScheduler.entitlements" \
  --sign "$signing_identity" "$bundle"
/usr/bin/codesign --verify --strict "$bundle"

if [[ -e "$output_app" ]]; then
  mv "$output_app" "$previous_app"
fi
mv "$bundle" "$output_app"
printf '已构建并签名：%s\n' "$output_app"
