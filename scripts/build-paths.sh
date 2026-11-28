# Sourced from the repository root by both entry points.
run_id="${NEARPANE_RUN_ID:-}"
case "$run_id" in *[!A-Za-z0-9_-]*) echo "Invalid isolated run ID" >&2; exit 2;; esac
if [ "${#run_id}" -gt 64 ]; then echo "Isolated run ID too long" >&2; exit 2; fi
build_root=.build
product_root=build
if [ -n "$run_id" ]; then
  build_root="build/standalone.$run_id/cache"
  product_root="build/standalone.$run_id/products"
fi
export NEARPANE_TEST_DIRECTORY="$build_root/test-data"
