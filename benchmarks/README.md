# Photo Viewer performance microbenchmark

This isolated, optimized Swift harness creates only synthetic fixtures in a newly
created empty temporary directory. It does not read or modify personal photos.
It retains a snapshot of the earlier folder enumeration / symlink-index behavior
and compares that work with an in-memory filename index. It also compares full
48-megapixel ImageIO decode with a 2560-pixel maximum decode using the same options.

Run from the repository root:

```sh
task_benchmark_root=$(mktemp -d /private/tmp/photo-viewer-benchmark.XXXXXX)
mkdir "$task_benchmark_root/cache" "$task_benchmark_root/fixtures"
xcrun swiftc -O -parse-as-library -module-cache-path "$task_benchmark_root/cache" benchmarks/Benchmark.swift -o "$task_benchmark_root/PhotoViewerBenchmark"
"$task_benchmark_root/PhotoViewerBenchmark" "$task_benchmark_root/fixtures"
```

Results are warm-cache microbenchmarks, not end-to-end application latency. The
catalog baseline includes natural sorting, per-file metadata checks, and finding
the final image through repeated symlink resolution. Cached lookup excludes the
one-time initial folder scan/index construction, which is still required.
Image measurements use a deterministic generated JPEG, not a representative
photo corpus. Pixel-buffer byte counts are actual `bytesPerRow * height`, not
peak application memory. Returned checksums prevent the compiler eliminating the
in-memory lookup loop. The fixture's content hash, name, size, creation date, and
modification date, and extended attributes are checked before and after decode.
The synthetic JPEG is assigned a custom extended attribute during fixture setup
to ensure this check covers a nonempty metadata value.

The temporary directory is intentionally left intact for inspection. It may be
removed after reviewing its contents; do not point this harness at a personal
photo directory.

## Recorded run, 11 October 2026

Raw measurements are in `results-2026-10-11.json`. On this Mac, the old folder scan
plus final-image canonical lookup took about 20 ms for 100 images, 206 ms for 1,000,
and 1,014 ms for 5,000. In-memory lookup was below 0.001 ms per operation, excluding
initial/background catalog construction. These figures isolate navigation's
bookkeeping, not image loading or drawing.

For the generated 8,000 × 6,000 JPEG, the median full decode was 385 ms versus
273 ms at 2,560 × 1,920, approximately 29% less decode time in this run. The
decoded pixel buffer was 192 MB versus 19.7 MB, approximately 90% smaller. A
previous run showed 368 ms versus 280 ms, illustrating normal timing variation.
Do not present this as a guaranteed percentage improvement for all real images.

The JPEG's SHA-256, filename, size, creation/modification dates, and both extended
attributes (`com.apple.provenance` plus the explicit benchmark marker) matched
before and after decoding.

## Historical baseline

This harness preserves the pre-hardening algorithm comparison. It is not a benchmark of the current sandboxed, input-limited application. The recorded result file has fixture paths replaced with relative synthetic names for publication; timings and measured values are unchanged.
