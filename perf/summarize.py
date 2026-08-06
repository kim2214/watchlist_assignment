#!/usr/bin/env python3
"""perf/runs/*.json 을 모아 지표별 중앙값 비교표를 만든다.

PERF.md 는 "단일 측정은 신뢰하지 않는다 → 5회 중앙값"을 원칙으로 삼는다.
그 계산을 손으로 하지 않기 위한 스크립트다.

사용:
  python3 perf/summarize.py                      # 기본: run_* vs topk_run_*
  python3 perf/summarize.py <이전prefix> <이후prefix>
  python3 perf/summarize.py --within <prefix>    # 한 측정 회차 안에서 baseline vs after

`--within` 이 중요한 이유: 실기기는 날에 따라 발열·백그라운드 상태가 달라 **측정
회차끼리 직접 비교하면 기기 드리프트가 섞인다.** 같은 회차 안에서 baseline과 after를
비교하면 그 드리프트가 두 시나리오에 공통으로 걸리므로 상당 부분 상쇄된다.

각 run json 은 {"baseline": {...}, "after": {...}} 형태이고, 여기서 비교하는 것은
두 run 집합의 **"after"(개선본)** 끼리다 — 즉 랭킹 자료구조 교체 전/후.
"baseline"(naive 구현)은 두 집합에서 같아야 하므로 대조군 검증용으로 함께 찍는다.
"""
import glob
import json
import statistics
import sys

METRICS = [
    ("average_frame_build_time_millis", "평균 빌드(ms)", "lower"),
    ("90th_percentile_frame_build_time_millis", "90th 빌드(ms)", "lower"),
    ("99th_percentile_frame_build_time_millis", "99th 빌드(ms)", "lower"),
    ("worst_frame_build_time_millis", "최악 빌드(ms)", "lower"),
    ("missed_frame_build_budget_count", "예산 초과 프레임", "lower"),
    ("average_frame_rasterizer_time_millis", "평균 래스터(ms)", "lower"),
    ("worst_frame_rasterizer_time_millis", "최악 래스터(ms)", "lower"),
    ("new_gen_gc_count", "young-gen GC", "lower"),
    ("old_gen_gc_count", "old-gen GC", "lower"),
    ("frame_count", "총 프레임 수", "info"),
]


def load(prefix):
    runs = []
    for path in sorted(glob.glob(f"perf/runs/{prefix}*.json")):
        with open(path) as fh:
            runs.append((path, json.load(fh)))
    return runs


def median_of(runs, scenario, key):
    vals = [d[scenario][key] for _, d in runs if key in d.get(scenario, {})]
    return statistics.median(vals) if vals else None


def delta(before, after, direction):
    if direction == "info" or before == 0:
        return "—"
    pct = (after - before) / before * 100
    mark = " ✅" if pct < -1 else (" ❌" if pct > 1 else " =")
    return f"{pct:+.1f}%{mark}"


def within(prefix):
    """한 측정 회차 안에서 baseline(naive) vs after(개선본)."""
    runs = load(prefix)
    if not runs:
        sys.exit(f"run 파일이 없다: {prefix}*")
    print(f"## {prefix}* {len(runs)}회 중앙값 — baseline(naive) vs after(개선본)")
    print()
    print("| 지표 | Before | After | 변화 |")
    print("|---|---|---|---|")
    for key, label, direction in METRICS:
        b, a = median_of(runs, "baseline", key), median_of(runs, "after", key)
        if b is None or a is None:
            continue
        print(f"| {label} | {b:g} | {a:g} | {delta(b, a, direction)} |")


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--within":
        within(sys.argv[2])
        return

    before_p = sys.argv[1] if len(sys.argv) > 2 else "run_"
    after_p = sys.argv[2] if len(sys.argv) > 2 else "topk_run_"

    before, after = load(before_p), load(after_p)
    if not before or not after:
        sys.exit(f"run 파일이 없다: {before_p}* = {len(before)}개, {after_p}* = {len(after)}개")

    print(f"before: {before_p}* {len(before)}회  |  after: {after_p}* {len(after)}회")
    print()
    print("## after(개선본) 끼리 비교 — 랭킹 자료구조 교체 전/후")
    print()
    print("| 지표 | 교체 전 | 교체 후 | 변화 |")
    print("|---|---|---|---|")
    for key, label, direction in METRICS:
        b, a = median_of(before, "after", key), median_of(after, "after", key)
        if b is None or a is None:
            continue
        print(f"| {label} | {b:g} | {a:g} | {delta(b, a, direction)} |")

    print()
    print("## baseline(naive) 대조군 — 두 집합에서 비슷해야 측정이 신뢰된다")
    print()
    print("| 지표 | 이전 측정 | 이번 측정 |")
    print("|---|---|---|")
    for key, label, _ in METRICS:
        b, a = median_of(before, "baseline", key), median_of(after, "baseline", key)
        if b is None or a is None:
            continue
        print(f"| {label} | {b:g} | {a:g} |")

    print()
    print("## 회차별 분포 (노이즈 확인, after 시나리오)")
    print()
    for key, label, _ in METRICS[:5]:
        row = lambda runs: ", ".join(f"{d['after'][key]:g}" for _, d in runs)
        print(f"- {label}")
        print(f"    교체 전: {row(before)}")
        print(f"    교체 후: {row(after)}")


if __name__ == "__main__":
    main()
