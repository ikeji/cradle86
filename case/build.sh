#!/bin/sh
# case.js から各パーツおよびマルチボディ STEP ファイルを書き出す。
set -e
cd "$(dirname "$0")"
CLI=${REPLICAD_CLI:-$HOME/work/desktop/replicad/packages/replicad-cli/bin/replicad-cli.js}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

build_target() {
  target="$1"
  fmt="$2"
  sed "s/^const DEFAULT = true/const DEFAULT = false/; s/name: \"$target\",/name: \"$target\", output: true,/" case.js > "$TMP/$target.js"
  node "$CLI" -f "$fmt" "$TMP/$target.js" "$TMP/$target"
  cp "$TMP/$target.step" "$target.step"
  echo "OK: $target.step ($fmt)"
}

build_target case step
build_target lid step
build_target all step-assembly
build_target print_set step-assembly

echo "--- PRODUCT count check ---"
echo "all.step:       $(grep -c 'PRODUCT(' all.step) products"
echo "print_set.step: $(grep -c 'PRODUCT(' print_set.step) products"
