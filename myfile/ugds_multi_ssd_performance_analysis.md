# uGDS Multi-SSD Performance Benchmark Data and Analysis

## Purpose and Scope

`test/perf/bench_multi_ssd.cu` measures whether two independently registered
uGDS handles can issue direct GPU-to-SSD reads concurrently. It reports three
phases in one invocation:

1. SSD 0 by itself.
2. SSD 1 by itself.
3. SSD 0 and SSD 1 concurrently, with the configured worker count and an
   independent GPU buffer slice per worker on each device.

The benchmark exercises storage membership and independent per-handle queue
contexts. It does not implement or measure I/O striping, RAID, redundancy,
filesystem I/O, placement policy, or automatic load balancing. Every I/O is
explicitly directed to the handle belonging to the selected SSD.

## Running the Benchmark

Build the benchmark from an existing configured build directory:

```bash
cmake --build build --target bench_multi_ssd -j8
```

Use two distinct uGDS device nodes and a GPU visible to both devices:

```bash
./build/bench_multi_ssd \
  -f /dev/ugds_drv0 \
  -F /dev/ugds_drv1 \
  -d 0 \
  -t 8 \
  -n 1024 \
  -s 4K
```

Add `-j` when collecting data for a script or a results table:

```bash
./build/bench_multi_ssd \
  -f /dev/ugds_drv0 \
  -F /dev/ugds_drv1 \
  -d 0 \
  -t 8 \
  -n 1024 \
  -s 4K \
  -j
```

`-t` is the worker count per SSD and defaults to `8`; the concurrent phase
therefore uses `2 * -t` threads. `-n` is the number of operations per worker
per phase, and `-s` accepts bytes or a `K`, `M`, or `G` suffix. Its default is
`4K` and the value must be a non-zero multiple of 4 KiB. The benchmark rejects
identical values for `-f` and `-F`.

## Workload and Metrics

The I/O type is synchronous read and the access pattern is sequential. Every
worker reads `-n` adjacent `-s`-sized blocks from its own contiguous range on
the selected SSD. Worker ranges do not overlap, and each worker owns a GPU
buffer slice. The three phases use the same per-device ranges so their
bandwidth comparison has the same requested I/O volume.

The benchmark measures elapsed monotonic-clock time around the complete worker
set for bandwidth and IOPS. It also sums worker elapsed time for average
per-I/O latency.

| Metric | Definition |
| --- | --- |
| `ops` | Successfully completed reads. |
| `bytes` | `ops * io_size_bytes`. |
| `iops` | `ops * 1e9 / phase_wall_ns`. |
| `bandwidth_mib_s` | `bytes * 1e9 / phase_wall_ns / (1024 * 1024)`. |
| `avg_us` | Sum of worker elapsed time divided by `ops`, in microseconds. |
| `concurrent_wall_ms` | Wall time from before all concurrent thread creations to after all joins. |
| Concurrent aggregate IOPS and MiB/s | The sum of both workers' completed operations, divided by `concurrent_wall_ms`. |
| `theoretical_total_bandwidth_mib_s` | Sum of the two isolated SSD bandwidth measurements. |
| `concurrent_vs_theoretical_percent` | Concurrent aggregate bandwidth divided by theoretical total bandwidth, times 100. |
| `concurrent_vs_best_single_x` | Concurrent aggregate bandwidth divided by the faster isolated SSD bandwidth. |
| `concurrent_vs_best_single_percent` | `concurrent_vs_best_single_x - 1`, expressed as a percentage. |

For the concurrent per-device bandwidth fields, the denominator is the same
concurrent wall time. Their sum therefore equals the aggregate metric. The
multi-threaded benchmark reports only aggregate concurrent IOPS and average
latency; its purpose is bandwidth scaling rather than per-thread latency
distribution analysis.

## Text and JSON Data

Without `-j`, the output includes a storage header, one `single` row per
device, one `concurrent` row per device, and a final concurrent aggregate row.
The storage header records the number of registered devices and their summed
namespace capacity in bytes.

With `-j`, the result is one JSON object with these fields:

| Fields | Meaning |
| --- | --- |
| `io_type`, `access_pattern` | Always `synchronous read` and `sequential`. |
| `io_size_bytes`, `iterations_per_worker`, `threads_per_device`, `concurrent_total_threads` | Workload shape. |
| `storage_device_count`, `aggregate_capacity_bytes` | Storage-layer metadata observed by the benchmark. |
| `single_device[01]_bandwidth_mib_s`, `_iops`, `_avg_latency_us` | Isolated result for the named SSD. |
| `concurrent_wall_ms` | Common wall-time denominator for the concurrent phase. |
| `concurrent_device[01]_bandwidth_mib_s` | Each device's contribution during the common concurrent interval. |
| `concurrent_aggregate_bandwidth_mib_s`, `concurrent_aggregate_iops` | Combined throughput for both SSDs. |
| `theoretical_total_bandwidth_mib_s`, `concurrent_vs_theoretical_percent` | Concurrent throughput relative to summed isolated throughput. |
| `concurrent_vs_best_single_x`, `concurrent_vs_best_single_percent` | Concurrent throughput and percentage gain relative to the faster single SSD. |

## Interpreting Results

`concurrent_vs_theoretical_percent` near `100%` means the simultaneous
workload reaches roughly the sum of the two isolated runs. A result below
`100%` can indicate contention in
the PCIe topology or root complex, GPU DMA mapping, CPU scheduling, SSD
controllers, or thermal/power limits. It does not by itself indicate a
storage-layer routing fault because the benchmark uses explicit independent
handles.

`concurrent_vs_theoretical_percent` above `100%` should be treated cautiously.
Short-run variation,
device caching, frequency changes, and background activity can all make a
concurrent run look better than the two isolated reference runs; it is not
evidence of guaranteed superlinear scaling.

For review-quality data, run several trials with the same `-n` value, retain
all JSON records, and report a median plus range. Record the GPU model and
PCIe bus, SSD models and bus locations, driver/kernel version, uGDS build,
CPU load, and thermal state. A larger iteration count reduces timer and setup
noise. Larger `-s` values test bandwidth behavior, while `-s 4K` emphasizes
small-I/O IOPS and latency.

## Current Verification Status

The benchmark target compiles and links. Host 204 currently does not expose
two usable distinct `/dev/ugds_drv*` nodes, so no dual-SSD I/O result is
recorded here and no numeric performance result has been invented. Run the
commands above on a host with two physical uGDS devices to produce valid data.

This direct sequential-read benchmark remains a focused regression test for
concurrent, independent device paths; it is not a filesystem, RAID, or
automatic-placement benchmark.
