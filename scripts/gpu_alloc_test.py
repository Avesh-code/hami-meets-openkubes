"""
GPU memory allocation probe for HAMi enforcement tests (Case 5 and Case 6).

MODE=probe   Allocate memory in chunks up to ALLOC_TARGET_MIB, then report the result.
             EXPECT=oom      -> PASS if allocation fails before the target (cap enforced)
             EXPECT=success  -> PASS if the full target is allocated (control run)
             START_DELAY_SECONDS lets a neighbour start first (Case 6).

MODE=steady  "Good neighbour" workload: hold HOLD_MIB of memory and run a matmul
             loop forever, printing a heartbeat every HEARTBEAT_SECONDS. Used to show
             that a co-located pod hitting its OOM does not disturb this pod.

Every line is prefixed with a tag ([info] [alloc] [result] [verdict] [heartbeat])
so evidence can be grepped from `kubectl logs`.
"""
import os
import sys
import time

import torch

MiB = 2 ** 20


def env_int(name, default):
    return int(os.environ.get(name, default))


def info():
    free, total = torch.cuda.mem_get_info()
    print(
        f"[info] device={torch.cuda.get_device_name(0)} "
        f"visible_total_mib={total // MiB} free_mib={free // MiB} "
        f"torch={torch.__version__} cuda={torch.version.cuda}",
        flush=True,
    )


def probe():
    target = env_int("ALLOC_TARGET_MIB", 8192)
    chunk = env_int("CHUNK_MIB", 256)
    expect = os.environ.get("EXPECT", "oom").lower()

    blocks, allocated, outcome = [], 0, None
    try:
        while allocated + chunk <= target:
            blocks.append(torch.empty(chunk * MiB, dtype=torch.uint8, device="cuda"))
            allocated += chunk
            print(f"[alloc] total_allocated_mib={allocated}", flush=True)
        outcome = "success"
        print(f"[result] SUCCESS allocated_mib={allocated} target_mib={target}", flush=True)
    except RuntimeError as e:  # torch.cuda.OutOfMemoryError is a RuntimeError subclass
        outcome = "oom"
        first_line = str(e).strip().splitlines()[0] if str(e).strip() else repr(e)
        print(
            f"[result] OOM allocated_mib={allocated} target_mib={target} error={first_line}",
            flush=True,
        )

    passed = outcome == expect
    print(f"[verdict] {'PASS' if passed else 'FAIL'} expected={expect} observed={outcome}", flush=True)

    hold = env_int("HOLD_SECONDS", 0)
    if hold > 0:
        print(f"[info] holding allocation for {hold}s", flush=True)
        time.sleep(hold)
    return 0 if passed else 1


def steady():
    hold_mib = env_int("HOLD_MIB", 4096)
    beat = env_int("HEARTBEAT_SECONDS", 5)
    reserve = torch.empty(hold_mib * MiB, dtype=torch.uint8, device="cuda")  # noqa: F841
    x = torch.randn(2048, 2048, device="cuda")
    print(f"[info] steady workload holding {hold_mib} MiB", flush=True)
    n = 0
    while True:
        t0 = time.time()
        for _ in range(50):
            y = x @ x
        torch.cuda.synchronize()
        n += 1
        print(
            f"[heartbeat] n={n} ts={time.strftime('%H:%M:%S')} "
            f"matmul_ms={(time.time() - t0) * 1000:.1f} "
            f"allocated_mib={torch.cuda.memory_allocated() // MiB} "
            f"checksum={float(y[0, 0]):.3f}",
            flush=True,
        )
        time.sleep(beat)


if __name__ == "__main__":
    if not torch.cuda.is_available():
        print("[result] ERROR cuda_not_available", flush=True)
        sys.exit(2)
    info()
    delay = env_int("START_DELAY_SECONDS", 0)
    if delay > 0:
        print(f"[info] waiting {delay}s before starting", flush=True)
        time.sleep(delay)
    mode = os.environ.get("MODE", "probe").lower()
    sys.exit(steady() if mode == "steady" else probe())
