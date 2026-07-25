# PERF.md — 성능 병목 분석과 before/after 수치

> 측정은 벽시계가 아니라 `MarketFeed.pump()` 로 **결정론적**으로 배치를 밀어넣는
> `integration_test` 시나리오로 수행한다. 기본 seed(20260703)이므로 tick 수열이
> 항상 동일 → 후보(baseline/after) 간 공정 비교가 가능하다.
>
> **단일 측정은 신뢰하지 않는다.** 아래 수치는 **동일 조건 5회 반복의 중앙값(median)**
> 이다. 실기기는 발열·백그라운드로 run-to-run 편차가 커서(예: baseline 예산 초과
> 프레임이 44~57 사이로 출렁) 단일 run의 ±1~2 차이는 노이즈다.

## 측정 환경

- 기기: **EF550R (Android 11, arm64)** — 실기기, **profile 모드**
- 렌더러: Impeller (Vulkan) / 프레임 예산: **16.67ms (60fps)**
- 도구: `IntegrationTestWidgetsFlutterBinding.watchPerformance` → `TimelineSummary`
- 원본 데이터: `perf/runs/run_1..5.json` (5회), `perf/paired_result.json`, `perf/baseline_result.json`

## 재현 방법

```bash
# 1회
flutter drive --no-dds \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/perf_test.dart \
  --profile -d <device>

# 5회 반복(중앙값용)은 위 명령을 반복하며 build/integration_response_data.json 을
# perf/runs/run_N.json 으로 각각 복사해 모은다.
```

> `--no-dds` 필수: 없으면 `watchPerformance`가 VM Service 타임라인에 붙지 못하고
> `SocketException: Connection refused` 로 실패한다.

- 시나리오(`integration_test/perf_test.dart`): 600배치 pump(60Hz×10초) + 30배치마다
  1회 스크롤 + 각 배치 후 한 프레임 렌더. baseline=`NaiveWatchlistScreen`,
  after=`WatchlistScreen`, 둘 다 feed 주입 + `autoStart:false`로 pump 구동.

---

## 대상

**Before (baseline)** — `lib/baseline/naive_watchlist_screen.dart`
- tick 배치마다 `setState()` 로 화면 전체 rebuild
- 요약(시총)을 매 build마다 전체 2,000 순회 재계산
- `RepaintBoundary` 없음 / 정합성 처리 없음
- 기능 없음: Top-20·검색·에러 UI·정지 표시 전부 미구현

**After (개선본)** — `lib/state/market_store.dart` + `lib/ui/watchlist_screen.dart`
- 프레임당 1회 coalescing flush + 종목별 rebuild 신호 + `RepaintBoundary`
- 증분 시총 집계, SplayTreeSet 기반 Top-20 라이브 랭킹
- 정합성(역순 tick 가드)·거래정지 표시·스트림 에러 배너 **추가 구현**
- 꼬리 최적화: notifier는 "다시 그려라" 신호만 나르고, 데이터는 행이 그릴 때
  `viewOf()`로 라이브 상태에서 읽음 → 보이는 행만 뷰 객체 생성(신선도 유지)

---

## 결과 (5회 중앙값)

| 지표 | Before | After | 변화 |
|---|---|---|---|
| 총 프레임 수 | ~635 | ~637 | — |
| **평균 프레임 빌드 시간** | 10.74 ms | **8.87 ms** | **−17.4%** ✅ |
| 90th %ile 빌드 시간 | 15.44 ms | **13.80 ms** | **−10.7%** ✅ |
| **예산 초과 프레임 수** | **52** | **29** | **−44.2%** ✅ |
| young-gen GC | 164 | **122** | **−25.6%** ✅ |
| 99th %ile 빌드 시간 | 22.89 ms | 28.91 ms | +26.3% ❌ |
| 최악 프레임 빌드 시간 | 26.55 ms | 34.23 ms | +28.9% ❌ |
| 평균 래스터 시간 | 4.68 ms | 5.54 ms | +18.4% ❌ |
| 최악 래스터 시간 | 9.93 ms | 12.31 ms | +24.0% ❌ |
| old-gen GC | 14 | 24 | +71% ❌ |

### 회차별 분포 (노이즈 확인)

| 지표 | Before 5회 | After 5회 |
|---|---|---|
| 예산 초과 프레임 | 52, 45, 57, 44, 52 | **29, 29, 29, 29, 30** |
| 평균 빌드(ms) | 10.9, 10.5, 10.8, 10.7, 10.7 | 8.3, 8.9, 8.9, 8.9, 8.4 |
| 최악 빌드(ms) | 35.1, 28.7, 26.0, 24.8, 26.6 | 31.6, 35.6, 34.2, 34.1, 35.7 |

→ **after는 값 자체도 낮지만 편차가 거의 없다**(예산 초과 29±0.5 vs baseline 50±6).
꼬리(worst ~34ms)도 5회 내내 안정적으로 높으므로 **노이즈가 아니라 실재하는 특성**이다.

---

## 해석

### 1) after가 이긴 곳 — 평균·중앙값·끊김 총량·할당
평균 빌드 −17%, 90th −11%, **예산 초과 프레임 −44%**, young-GC −26%.
게다가 baseline엔 없던 기능(Top-20·정합성·정지 표시·에러 UI)을 **추가하고도** 얻은 결과다.
원인:
- **coalescing** — 초당 60배치를 프레임당 1회 flush로 병합해 rebuild 횟수를 줄임.
- **rebuild 범위 축소** — 종목별 신호 + `RepaintBoundary`로 (보이는 ∩ 바뀐) 행만 갱신.
- **증분 집계** — 매 build 2,000 순회 제거(baseline 빌드 시간을 상수로 끌어올리던 주범).

### 2) after가 진 곳 — 극단 꼬리(99th/worst)와 래스터
- **래스터 +18~24%**: Top-20 스트립·정지 배지·에러 배너를 더 그리는 **기능 비용**.
  (단 래스터는 예산 16.67ms를 한 번도 안 넘음 → 병목 아님)
- **99th/worst 빌드 +26~29%**: **coalescing 버스트**. 큰 배치(최대 250건)가 온 프레임에서
  `_flush()`가 pct 바뀐 종목마다 SplayTree `remove`+`add`(최대 250회) + `_computeTop20()`
  + Top-20 카드 rebuild를 몰아서 처리 → 그 소수 프레임만 ~34ms로 튄다.
  baseline은 매 프레임 "2,000 순회"라는 일정한 무게라 꼬리가 오히려 평탄하다.

### 3) 트레이드오프를 어디에 그었나
- baseline: 예산 초과 52프레임이 17~27ms에 퍼짐 → **상시 저강도 버벅임**.
- after: 예산 초과 29프레임, 대신 소수가 ~34ms로 튐 → **대체로 매끄럽고 가끔 큰 히치**.
- 60fps 체감에선 **끊김 프레임 총량이 절반**인 after가 유리하다고 판단해, "평균·끊김 횟수·
  신선도"를 취하고 "극단 꼬리 소폭 악화"를 감수했다. 신선도 200ms 제약도 프레임당 flush
  (≈12프레임 예산 내 1회)로 지켜진다.

---

## 검증했지만 효과 없던 시도 (정직한 기록)

**가설:** 꼬리(worst/99th)의 주범은 "안 보이는 행까지 `SymbolView`를 매 flush 할당"하는 것.
→ **flush에서 보이는(리스너 있는) 행만 뷰를 만들도록 변경.**

**결과:** 꼬리는 **거의 움직이지 않았다**(worst 33→32ms, 노이즈 수준). 가설 기각.
작은 객체 240개 할당은 Dart young-gen에서 저렴했고, 진짜 꼬리 비용은 **뷰 할당이 아니라
랭킹 버스트**(SplayTree 갱신 + Top-20 재계산, 보이든 안 보이든 실행)에 있었다.
→ 이 변경은 성능이 아니라 **구조(신호/데이터 분리)와 신선도 보장** 이점으로 유지한다.

**다음에 꼬리를 더 줄이려면:** Top-20 재계산·트리 갱신을 매 flush가 아니라 N프레임마다로
스로틀하거나, 상위 경계 근처 변동만 부분 반영. (측정으로 검증 필요)
