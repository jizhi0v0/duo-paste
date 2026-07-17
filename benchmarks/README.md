# Large-library benchmarks

R4.1 is an explicit release-only manual/nightly benchmark. It never uses the production
`~/Library/Application Support/duo-paste` tree and is not invoked by ordinary `swift test`.

```sh
swift run -c release duo-pasted benchmark-library \
  --workspace .benchmark/r4-1 \
  --rows 1000000 --blob-gib 8 --samples 20 --rebuild
```

Use `--reuse` for later runs against an exact matching manifest. Destructive `--rebuild` is only
accepted when the directory contains the benchmark marker. Blob files are sparse placeholders by
default: the report records both their logical and allocated size, and search never reads them.
Pass `--materialize-blobs` only when physical blob allocation itself is under test.

`cold_fts` means a new production `Database`/SQLite connection per sample. macOS page cache is not
purged, so the report labels this `connection_cold_os_cache_uncontrolled`. `first_screen_render`
includes the exact production input debounce, the four-query data path, and layout of the real
`AppState` + `SearchView` in an `NSHostingView`; it is not a synthetic card proxy. Use
`--reuse --render-only` to rerun that focused metric after macOS UI/input changes.

Initial gates on Apple Silicon release builds:

- `warm_fts.p95 < 100ms`
- `first_screen_render.p95 < 150ms`

Committed reports live in [`results/`](results/). Workspaces are ignored by Git.
