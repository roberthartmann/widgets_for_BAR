#!/usr/bin/env bash
# Erzeugt zwei gleich behandelte Mess-Varianten (beide laufen als User-Widget):
#   bench/variants/gui_top_bar_BENCH_official.lua  -> "Top Bar BENCH official"
#   bench/variants/gui_top_bar_BENCH_perf.lua      -> "Top Bar BENCH perf"
# Basis "official" ist der unveraenderte Baseline-Commit, "perf" der aktuelle Stand.
set -euo pipefail
cd "$(dirname "$0")/.."
BASELINE_COMMIT=57f4203
mkdir -p bench/variants
make_variant() { # <src> <dst> <name>
	sed -e "0,/name = \"Top Bar\",/s//name = \"$3\",/" \
	    -e "0,/enabled = true,/s//enabled = false,/" "$1" > "$2"
	cat bench/selfbench_block.lua >> "$2"
	grep -q "name = \"$3\"" "$2" || { echo "rename failed for $2" >&2; exit 1; }
}
git show "$BASELINE_COMMIT:topbar_performance/gui_top_bar.lua" > bench/variants/.official_src.lua
make_variant bench/variants/.official_src.lua bench/variants/gui_top_bar_BENCH_official.lua "Top Bar BENCH official"
make_variant gui_top_bar.lua bench/variants/gui_top_bar_BENCH_perf.lua "Top Bar BENCH perf"
rm bench/variants/.official_src.lua
echo "ok: bench/variants/"
