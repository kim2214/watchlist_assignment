# 실시간 관심종목 (Flutter)

2,000개 종목의 고빈도 시세 스트림을 60fps로 렌더링하는 관심종목 화면.
초당 최대 15,000건(평균 약 7,530건)이 밀려오는 `MarketFeed`를 **`MarketStore` 하나의 경계**로
받아, **시간축(프레임당 1회 coalescing)** 과 **공간축(종목별 신호 + 보이는 행만 rebuild)** 으로
UI 갱신을 줄였다. 개선 효과는 실기기 profile 모드에서 **결정론적 벤치마크 5회 중앙값**으로 측정했다.

- `flutter analyze` 클린 / `flutter test` **19개 통과**
- 외부 의존성 **0개** (flutter SDK + `cupertino_icons`만)
- Flutter 3.44.8 / Dart SDK `^3.12.2`
- `lib/seed/` (수정 금지 영역)는 **원본 그대로** 유지

---

## 실행

```bash
flutter pub get

# 개선본 (권장: profile 모드)
flutter run --profile -d <device>

# baseline — 개선 전 비교용 화면
flutter run --profile -t lib/main_baseline.dart -d <device>
```

> **profile 모드로 볼 것.** debug는 JIT + assert 때문에 빌드 시간이 실제의 몇 배로 나와
> 성능 판단에 쓸 수 없다.

---

## 구현한 것

| 요구 | 구현 | 위치 |
|---|---|---|
| 2,000종목 실시간 목록 | `ListView.builder` + 종목별 rebuild 신호 | `ui/watchlist_screen.dart` |
| 갱신 신선도 200ms 이내 | 프레임당 1회 flush (16.67ms) → **약 12배 여유** | `state/market_store.dart` |
| 역순(지연) tick 정합성 | `timestampMs` 가드로 과거 tick 폐기, 거래량은 `max`로 단조 증가 | `_onBatch` |
| 거래정지 표시 | `status` 추적 + 행 "정지" 배지·회색 처리 | `_halted` |
| 스트림 에러 생존 | `cancelOnError: false` + 배너, 다음 성공 배치에 자동 복구 | `_onError` |
| 요약(종목 수·시총) | 증분 집계 — 전체 순회 없이 델타만 반영 | `_totalMarketCap` |
| 등락률 Top-20 라이브 | `Float64List`에 등락률 O(1) 갱신 + 상위 20을 선형 스캔으로 선택 | `_topK` |
| 초성 검색 | `가온전자 → ㄱㅇㅈㅈ`. 초성/완성형/종목코드 3-모드 + debounce 200ms | `search/chosung.dart` |
| 종목 상세 + 스파크라인 | 시·고·저 누적, 최근 60틱 링버퍼 | `ui/detail_screen.dart` |
| 구독 수명 관리 | 상세 진입 시 목록 갱신 pause, 복귀 시 강제 동기화 | `openDetail`/`closeDetail` |
| before/after 성능 근거 | `pump()` 기반 결정론 벤치 + 실기기 5회 | `integration_test/`, `PERF.md` |

---

## 구조

```
lib/
├─ seed/                        수정 금지 영역 (원본 유지)
│  ├─ market_feed.dart          시세 소스: 60Hz 배치, 역순 tick, 거래정지, 일시 에러
│  └─ market_models.dart        raw 타입 (QuoteTick 등)
├─ state/
│  └─ market_store.dart         ★ feed↔UI 유일한 경계
│                               정합성 · coalescing · 증분 집계 · 랭킹 · 검색 · 수명 관리
├─ domain/
│  └─ symbol_view.dart          UI가 보는 불변 뷰 모델 (raw 타입은 여기서 끝난다)
├─ search/
│  └─ chosung.dart              초성 추출 · 쿼리 분류 (라이브러리 없이 직접 구현)
├─ ui/
│  ├─ watchlist_screen.dart     목록 + 요약 + Top-20 + 검색 + 에러 배너
│  └─ detail_screen.dart        종목 상세 + 스파크라인
├─ baseline/
│  └─ naive_watchlist_screen.dart   before 기준선 (배치마다 setState 전체 rebuild)
├─ main.dart                    개선본 엔트리
└─ main_baseline.dart           baseline 엔트리
```

핵심 흐름 — **notifier는 데이터가 아니라 "다시 그려라" 신호만 나른다.**
데이터는 각 행이 그리는 순간 `store.viewOf(code)`로 라이브 상태에서 직접 읽는다.
덕분에 스크롤로 새로 보이게 된 행도 항상 최신값이고, 보이지 않는 행에는 뷰 객체조차 만들지 않는다.

---

## 성능

`MarketFeed.pump()`로 배치를 결정론적으로 밀어넣어(같은 seed → 바이트 단위로 같은 tick 수열)
baseline과 개선본에 **동일한 입력**을 준 뒤, 실기기 profile 모드에서 프레임 타임을 측정했다.
5회 반복 중앙값 — 실기기는 run-to-run 편차가 커서 단일 측정은 신뢰하지 않는다.

| 지표 | Before | After | 변화 |
|---|---|---|---|
| **예산 초과 프레임 수** | **60** | **31** | **−48.3%** ✅ |
| 평균 프레임 빌드 시간 | 11.41 ms | **8.42 ms** | **−26.2%** ✅ |
| 90th %ile 빌드 시간 | 15.85 ms | **13.46 ms** | **−15.1%** ✅ |
| young-gen GC | 156 | **72** | **−53.8%** ✅ |
| old-gen GC | 14 | **14** | **±0%** = |
| 99th %ile 빌드 시간 | 24.09 ms | 29.39 ms | +22.0% ❌ |
| 최악 프레임 빌드 시간 | 30.26 ms | 35.43 ms | +17.1% ❌ |

개선본은 baseline에 **없던 기능**(Top-20·정합성·정지 표시·에러 UI)을 더 얹고도 위 결과를 얻었다.
다만 **극단 꼬리(99th/worst)는 나빠졌다.** coalescing이 작업을 제거하는 게 아니라 합치는
장치이기 때문에 총량은 줄고 분산은 커지는, 구조적인 트레이드오프다. "끊김 프레임 총량 절반"을
취하고 "소수 프레임의 큰 히치"를 감수한 판단의 근거는 `PERF.md`에 있다.

> **측정 회차가 둘이다.** 위 표는 2차(2026-08-06, Top-20 랭킹을 선형 선택으로 교체한 뒤)다.
> 실기기는 날마다 상태가 달라 **baseline조차 10.74 → 11.41ms로 6% 느려졌으므로 회차끼리 직접
> 비교하면 안 된다** — 각 회차는 같은 세션 안의 baseline↔after 비교로 읽는다. 1차 수치와
> 교체 전후 해석은 `PERF.md §결과`·`§5`에 있다.

재현:

```bash
flutter drive --no-dds \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/perf_test.dart \
  --profile -d <device>
```

> `--no-dds` 없으면 `watchPerformance`가 VM Service 타임라인에 붙지 못해 실패한다.

측정 원본은 `perf/runs/`에 보존했다 — `run_1..5.json`(1차), `topk_run_1..5.json`(2차).
5회 중앙값 표는 손으로 계산하지 않고 스크립트로 만든다.

```bash
python3 perf/summarize.py                    # 회차 간 비교
python3 perf/summarize.py --within topk_run_ # 회차 내 baseline↔after (권장)
dart run perf/top20_bench.dart               # 랭킹 자료구조 단독 A/B
```

---

## 테스트

```bash
flutter test        # 19개
```

| 파일 | 개수 | 검증 |
|---|---|---|
| `test/widget_test.dart` | 3 | 스냅샷 초기화 / 역순 tick + 에러 복구 / 거래정지 |
| `test/search_test.dart` | 9 | 초성 추출 · 쿼리 분류 · 초성/이름/코드 매칭 · 필터 집계 일치 |
| `test/top_movers_test.dart` | 5 | Top-20을 **무차별 전체 정렬과 대조** — 초기·tick 5라운드·행 값 일치·필터 경로·20개 미만 경계 |
| `test/detail_test.dart` | 2 | 시·고·저 불변식 / 스파크라인 링버퍼 상한 / 재진입 초기화 |

위젯을 띄우지 않고 store를 직접 검증하는 방식이 대부분이다 — 경계를 하나로 그었기 때문에 가능하다.
`feed.pump(n)` + `debugFlush()`로 프레임을 기다리지 않고 결정론적으로 확인한다.
단언은 값 비교보다 **불변식**으로 썼다: `가격 > 0`, `등락률 ∈ [-31, 31]`, `high ≥ price ≥ low`,
`spark.length ≤ 60`.

---

## 문서

| 문서 | 내용 |
|---|---|
| **[DESIGN.md](DESIGN.md)** | 설계 판단과 그 근거. 시간순 구현 기록 — #01 목록 최적화 · #02 초성 검색 · **#03 랭킹 자료구조 교체** |
| **[PERF.md](PERF.md)** | 측정 방법론(왜 `pump()`인가), 5회 중앙값 수치, 해석, **효과 없어 기각한 가설 2건** |
| `perf/top20_bench.dart` | 랭킹 자료구조 A/B 벤치 — 실제 피드 tick으로 등가성까지 대조 |
| `perf/summarize.py` | 5회 중앙값 집계(`--within`으로 회차 내 비교) |

---

## 알려진 한계

지적당하기 전에 먼저 적는다. 꼬리 관련 개선 방향은 `PERF.md` 마지막 절에 정리했다.

- **99th/worst 꼬리 +17~22%** — 원인을 **두 번 틀렸다.** ① "안 보이는 행의 뷰 객체 할당" →
  적용해보니 효과 없어 기각. ② "랭킹 버스트(트리 갱신 + Top-20 재계산)" → 랭킹 계산을 36배
  줄였는데도(175us → 4.8us) 꼬리가 안 움직여 기각. 남은 1순위 가설은 **Top-20 카드 diff**
  (바뀐 카드만 교체)이며 아직 **측정으로 검증하지 않았다.** 전말은 `PERF.md §5`.
- **스파크라인이 도착 순서로 쌓인다** — 목록·상세 본문은 `timestampMs`로 가드하지만
  스파크라인 링버퍼는 예외라 역순 tick이 시계열을 흐트릴 수 있다.
- **`open`은 진짜 시가가 아니라 "구독 시점가"** — feed가 시가를 주지 않아 대체한 값이다.
- **rebuild 횟수를 세는 테스트가 없다** — "flush 1회에 보이는 행만 rebuild된다"는 성질을
  프레임 타임으로 간접 검증만 했다.
- **관심종목 CRUD·영속화 없음** — 현재는 전체 2,000종목을 표시한다.
- ~~old-gen GC +71%의 원인 미분리~~ → **해소.** 랭킹 자료구조의 할당(`Map<String,double>`의
  박싱 double + `SplayTreeSet` 노드, 프레임당 약 12만 객체)이 원인이었고, `Float64List`로
  바꿔 할당을 없애자 **±0%로 복귀**했다(`PERF.md §5.5`).
