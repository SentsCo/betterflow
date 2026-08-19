#!/bin/zsh
set -euo pipefail

configuration="${1:-debug}"
case "$configuration" in
  debug | release) ;;
  *)
    print -u2 "usage: $0 [debug|release]"
    exit 2
    ;;
esac

project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"

swift package resolve

mlx_project="$project_dir/.build/checkouts/mlx-swift/xcode/MLX.xcodeproj"
mlx_derived_data="$project_dir/.build/mlx-xcode"
xcode_configuration="${(C)configuration}"

if ! xcrun metal --version >/dev/null 2>&1; then
  print -u2 "error: Apple's Metal Toolchain is required for Qwen cleanup."
  print -u2 "install it with: xcodebuild -downloadComponent MetalToolchain"
  exit 1
fi

xcodebuild \
  -quiet \
  -project "$mlx_project" \
  -scheme Cmlx \
  -configuration "$xcode_configuration" \
  -derivedDataPath "$mlx_derived_data" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build

metallib="$mlx_derived_data/Build/Products/$xcode_configuration/Cmlx.framework/Versions/A/Resources/default.metallib"
if [[ ! -f "$metallib" ]]; then
  print -u2 "error: MLX did not produce default.metallib"
  exit 1
fi

bin_dir=$(swift build -c "$configuration" --show-bin-path)
mkdir -p "$bin_dir/Resources" "$bin_dir/mlx-swift_Cmlx.bundle"
install -m 644 "$metallib" "$bin_dir/Resources/default.metallib"
install -m 644 "$metallib" "$bin_dir/mlx-swift_Cmlx.bundle/default.metallib"

for test_bundle in "$bin_dir"/*.xctest(N); do
  test_resources="$test_bundle/Contents/MacOS/Resources"
  mkdir -p "$test_resources"
  install -m 644 "$metallib" "$test_resources/default.metallib"
done
