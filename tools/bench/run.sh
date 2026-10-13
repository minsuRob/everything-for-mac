#!/bin/zsh
# Runs the same queries through Cardinal's search engine (search-cache crate, pinned commit)
# and through EFM, on the same folder. Usage: tools/bench/run.sh [ROOT]   (default: $HOME)
set -euo pipefail
cd "${0:a:h}/../.."
ROOT=${1:-$HOME}
CARDINAL_COMMIT=4c50734f9a09d88110f96652b43634b412f79449
QUERIES=("report" "readme" "index.js" "*.pdf" "ext:swift" "보고서" "node_modules" "report draft"
         "test !spec" "src/**/main" 'regex:^READ.*\.md$' "size:>100mb" "dm:today" "a" "")

if [[ ! -d build/cardinal ]]; then
  git clone -q https://github.com/cardisoft/cardinal.git build/cardinal
  git -C build/cardinal checkout -q $CARDINAL_COMMIT
fi
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
(cd tools/bench/cardbench && cargo build -q --release)
swift build -c release --product efm >/dev/null

echo "== Cardinal (search-cache @ ${CARDINAL_COMMIT:0:7})"
/usr/bin/time -l tools/bench/cardbench/target/release/cardbench "$ROOT" --repeat 5 "${QUERIES[@]}" 2> build/cardinal.time
grep -E "maximum resident" build/cardinal.time

echo "== EFM"
rm -f build/efm-bench.idx
/usr/bin/time -l .build/release/efm bench --root "$ROOT" --cache build/efm-bench.idx --repeat 5 "${QUERIES[@]}" 2> build/efm.time
grep -E "maximum resident" build/efm.time
