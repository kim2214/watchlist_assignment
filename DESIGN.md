# 구현 기록 #01 — 목록 화면 실시간 갱신 최적화 (baseline → after → 측정 → 검증)

> 실시간 관심종목 과제의 첫 개선 단계 전체 여정 기록.
> "tick 시 UI 갱신 최소화 + 보이는 만큼만 갱신" 아이디어에서 출발해,
> 구조 설계 → 개선 구현 → 실기기 프레임 측정 → 꼬리 최적화 시도(실패) → 5회 중앙값 검증
> 까지의 과정과 **판단의 근거**를 남긴다.
> 상태: `flutter analyze` 클린 / `flutter test` 3개 통과 / PERF.md 완성.

---

## 0. 여정 한눈에 보기

1. **baseline 구현** — 일부러 순진하게 짜서 jank를 눈/DevTools로 확인 (before 기준선)
2. **개선 구조 설계** — coalescing + 종목별 신호 + 증분 집계 + Top-20 라이브 랭킹
3. **개선본 구현** — 정합성(역순/정지/에러)까지 포함
4. **PERF 측정** — `pump()` 기반 결정론 벤치를 실기기 profile에서 실행
5. **꼬리 최적화 시도** — 가설을 세우고 적용했으나 **효과 없음 → 정직하게 기각**
6. **5회 중앙값 검증** — 노이즈를 제거하고 최종 결론

---

## 1. 설계 아이디어 → 구현 방식

원래 생각:
1. tick(pump) 이벤트를 받았을 때 UI 갱신을 최소화한다.
2. 보이는 정도(20 row 정도)만 갱신한다.

검토 후 결론:
- **①은 정확하다.** 단, "최소화"를 **시간축(coalescing)** 과 **공간축(rebuild 범위)** 둘로 분리해 다뤘다.
- **②는 직관은 맞지만 방식이 위험하다.** 20개를 직접 세서 고르면 뷰포트가 크거나 스크롤 중일 때
  일부 보이는 행이 갱신 안 되는 버그 + 신선도(200ms) 위반이 난다.
  → `ListView.builder`(보이는 것만 생성) + **종목별 신호**(바뀐 것만 알림)로 두면
  결과적으로 **(보이는 ∩ 바뀐)** 행만 rebuild되어 같은 목표를 견고하게 달성한다.

---

## 2. 파일 구성

| 파일 | 역할 |
|---|---|
| `lib/domain/symbol_view.dart` | UI가 보는 **불변** 뷰 모델 (`SymbolView`, `MarketSummary`, `TopMover`). raw `QuoteTick`은 여기까지 안 내려옴 |
| `lib/state/market_store.dart` | **핵심.** feed↔UI 경계. 정합성·coalescing·집계·랭킹 전부 여기 |
| `lib/ui/watchlist_screen.dart` | 개선본(after) 화면. 행별/요약별 독립 구독 |
| `lib/main.dart` | 개선본 엔트리 |
| `lib/baseline/naive_watchlist_screen.dart` + `lib/main_baseline.dart` | baseline(before) 보존. before/after 비교용 |
| `test/widget_test.dart` | 역순 tick·정지·에러복구 회귀 테스트 3종 |
| `integration_test/perf_test.dart` + `test_driver/integration_test.dart` | `pump()` 기반 프레임 타임 벤치마크 |
| `PERF.md` | 병목 분석 + before/after 중앙값 수치 |
| `perf/runs/run_1..5.json` 등 | 측정 원본 데이터 보존 |

실행:
- 개선본: `flutter run --profile -d [device]`
- baseline: `flutter run --profile -t lib/main_baseline.dart -d [device]`

---

## 3. ① UI 갱신 최소화 — 두 축

### 시간축 (Coalescing) — `MarketStore`
- tick 배치가 오면(`_onBatch`) 즉시 UI 반영하지 않고 **상태 맵만 갱신 + 바뀐 코드를 `_dirty`에 담음**.
- `_scheduleFlush()`가 `addPostFrameCallback` + `scheduleFrame`으로 **프레임당 1회** `_flush()` 예약(중복 예약 무시).
- 초당 60배치가 와도 UI 반영은 프레임당 1회. 같은 종목이 한 프레임에 여러 번 바뀌어도 마지막 값만.
  신선도 200ms(≈12프레임) 안이라 여유.

### 공간축 (rebuild 범위 축소) — 종목별 신호
- 종목마다 rebuild 신호 하나씩(`_RowSignal`).
- `_flush()`는 `_dirty`에 든 종목 중 **화면에 보이는 것만** 신호 → **그 행만** rebuild. 나머지는 손도 안 댐.

---

## 4. ② "보이는 만큼만" — 수동이 아니라 구조로

**중요 설계 전환:** notifier가 *데이터*를 나르지 않고 *"다시 그려라" 신호*(int 카운터)만 나른다.
데이터는 행이 그릴 때 `viewOf()`로 **라이브 상태에서 직접 읽는다.**

```dart
// watchlist_screen.dart
ListView.builder(                       // (a) 보이는 행만 생성 (프레임워크가 공짜로)
  itemExtent: 60,
  itemBuilder: (context, index) => RepaintBoundary(   // (c) 행 단위 래스터 격리
    child: ValueListenableBuilder<int>(               // (b) 자기 종목 "신호"만 구독
      valueListenable: store.notifierFor(code),
      builder: (_, _, _) => _WatchRow(view: store.viewOf(code), ...), // 그릴 때 라이브 읽기
    ),
  ),
)
```
- (a) 보이는 행만 위젯이 존재. 안 보이는 행은 위젯 자체가 없음.
- (b) 각 행은 자기 종목 신호만 구독 → 그 종목이 안 바뀌면 rebuild 안 함.
- (c) `RepaintBoundary`로 행별 래스터 격리.
- **왜 신호+`viewOf` 구조인가:** 스크롤로 새로 보이게 된 행도 그리는 순간 라이브 상태를 읽으므로
  **항상 최신값**(신선도 보장). 안 보이는 행에는 뷰 객체조차 안 만든다.
- 요약·Top-20·에러배너는 **각각 별도 notifier** 구독 → 행 rebuild와 완전 격리.

---

## 5. 정합성 (엣지 3종) — `_onBatch`

- **역순 tick**: 종목별 `_lastTs`(마지막 반영 `timestampMs`) 보관. `t.timestampMs > lastTs`일 때만
  가격·상태 갱신 → **가격이 과거로 되돌아가지 않음.**
- **거래정지(halt)**: `status == halted` → `_halted[c]=true`(가격은 feed가 고정값 제공),
  이후 `active` tick으로 해제. 행에 "정지" 배지 + 회색.
- **스트림 에러**: `listen(onError:..., cancelOnError:false)`로 구독 유지. 에러 시 배너,
  다음 성공 배치에서 자동 해제.
- **dayVolume**: 누적값이라 `timestampMs`와 별개로 **max**로만 증가시켜 역순에도 감소 방지.

판단 (DESIGN.md에 명시 예정): 정지 종목도 시총·순위에 **마지막 값으로 포함**.

---

## 6. 증분 집계 & Top-20 — 전체 순회/재정렬 없음

- **시총 합계**: `_totalMarketCap += (newPrice - old) * shares`. 배치 크기만큼만 연산.
  (baseline은 매 build 2,000 순회)
- **Top-20 라이브**: `SplayTreeSet<String>`을 등락률 내림차순 유지. `_flush()`에서 **pct가 바뀐
  종목만** remove→값 갱신→add (O(log n)). 트리 정렬 기준값은 `_treePct`에 따로 보관해 트리
  불변식 유지. Top-20 = `take(20)`.

---

## 7. 성능 측정 여정 (PERF.md)

### 7-1. 측정 방법
- **결정론 벤치**: 벽시계가 아니라 `feed.pump(600)`(60Hz×10초) + 30배치마다 스크롤. seed 고정이라
  baseline/after가 **바이트 단위로 같은 tick 수열**을 받음 → 공정 비교.
- **실기기 profile**: EF550R (Android 11, Impeller/Vulkan). `watchPerformance` → `TimelineSummary`.
- **삽질 기록**: `flutter drive`에 **`--no-dds`** 를 안 붙이면 `watchPerformance`가 VM Service
  타임라인에 못 붙어 `SocketException: Connection refused`로 실패. (첫 시도 때 겪음)

### 7-2. baseline 관찰
- 앱 구동 로그부터 `I/Choreographer: Skipped 77 frames!` — 눈에 보이는 jank.
- 병목은 **UI(빌드) 스레드**. 래스터는 예산(16.67ms) 초과 0, 빌드만 초과.
- 원인: ① 배치마다 setState 전체 rebuild ② 매 build 2,000 순회 집계 ③ RepaintBoundary 부재.

### 7-3. 최종 결과 — 5회 중앙값 (단일 측정은 노이즈라 신뢰 안 함)

| 지표 | Before | After | 변화 |
|---|---|---|---|
| 평균 프레임 빌드 | 10.74 ms | **8.87 ms** | **−17.4%** ✅ |
| 90th %ile 빌드 | 15.44 ms | **13.80 ms** | **−10.7%** ✅ |
| **예산 초과 프레임 수** | **52** | **29** | **−44.2%** ✅ |
| young-gen GC | 164 | **122** | **−25.6%** ✅ |
| 99th %ile 빌드 | 22.89 ms | 28.91 ms | +26.3% ❌ |
| 최악 빌드 | 26.55 ms | 34.23 ms | +28.9% ❌ |
| 평균 래스터 | 4.68 ms | 5.54 ms | +18.4% ❌ |
| old-gen GC | 14 | 24 | +71% ❌ |

**회차별 분포(노이즈 확인)** — after는 값도 낮지만 **편차가 거의 없다**:
- 예산 초과: baseline `52,45,57,44,52` vs after `29,29,29,29,30`

### 7-4. 정직한 해석
- **after가 이긴 곳**: 평균·90th·**끊김 총량(−44%)**·young-GC. 게다가 baseline엔 없던 기능
  (Top-20·정합성·정지표시·에러UI)을 **더 넣고도** 얻음.
- **after가 진 곳**: 극단 꼬리(99th/worst)와 래스터.
    - 래스터↑ = Top-20 스트립·배지·배너를 더 그리는 **기능 비용**(단 예산 초과 0, 병목 아님).
    - 꼬리↑ = **coalescing 버스트**. 큰 배치(최대 250건) 프레임에서 SplayTree 갱신 + Top-20
      재계산이 몰림. baseline은 매 프레임 "2,000 순회"로 일정해 꼬리가 오히려 평탄.
- **트레이드오프 판단**: baseline = 상시 저강도 버벅임(초과 52), after = 대체로 매끄럽고 가끔 큰
  히치(초과 29). 60fps 체감에선 **끊김 총량이 절반인 after**가 유리 → "평균·끊김횟수·신선도"를
  취하고 "극단 꼬리 소폭 악화"를 감수.

---

## 8. 검증했지만 효과 없던 시도 (정직한 기록)

- **가설**: 꼬리(worst/99th)의 주범은 "안 보이는 행까지 매 flush `SymbolView` 할당".
- **적용**: flush에서 보이는(리스너 있는) 행만 신호하도록 변경 + notifier를 신호로 전환
  (`hasListeners`는 protected라 `_RowSignal extends ValueNotifier<int>`로 `isWatched` 노출).
- **결과**: 꼬리는 **거의 안 움직임**(worst 33→32ms, 노이즈 수준). **가설 기각.**
    - 이유: 작은 객체 240개 할당은 Dart young-gen에서 저렴. 진짜 꼬리 비용은 **뷰 할당이 아니라
      랭킹 버스트**(SplayTree 갱신 + Top-20 재계산, 보이든 안 보이든 실행)였다.
- **그럼에도 유지하는 이유**: 성능이 아니라 **구조(신호/데이터 분리) + 신선도 보장** 이점.
- **다음에 꼬리를 줄이려면**: Top-20 재계산·트리 갱신을 매 flush가 아니라 N프레임마다 스로틀,
  또는 상위 경계 근처 변동만 부분 반영. (측정으로 검증 필요)

> 이 "가설 → 측정 → 기각 → 재분석"이 이번 단계에서 가장 값진 기록. 과제가 보려는
> "판단의 근거"에 정확히 부합한다.

---

## 9. 테스트 (`test/widget_test.dart`)

`MarketStore.attachForBenchmark()` + `feed.pump()` + `debugFlush()`(테스트 훅)로 결정론 검증:
1. 스냅샷으로 스토어 초기화 (2,000종목, 시총>0)
2. 역순 tick이 와도 가격 0 이하로 안 되고 등락률이 일일 제한(±30%) 안 —
   `transientErrorProbability:0.1`로 에러 복구도 함께 검증
3. `haltProbability` 올려 정지 종목이 정지 상태로 표시되는지

결과: 3개 모두 통과.

---

## 10. 배운 것 / 남은 것

**배운 것**
- 성능 개선은 "축(시간/공간)"으로 나눠 생각하면 설계가 명확해진다.
- 평균만 보면 안 된다 — **꼬리(99th/worst)와 끊김 횟수**가 체감을 좌우한다.
- **단일 측정은 못 믿는다** — 실기기는 편차가 커서 중앙값(다회)이 필요.
- 가설은 반드시 **측정으로 검증**. 틀린 가설을 정직하게 기록하는 게 오히려 강점.

**아직 안 한 것 / 다음 결정 필요**
- **초성 검색** (필수) — 미구현
- **상세 화면 + 스파크라인** — 미구현
- 남은 판단: 정지 종목 집계 포함 여부 확정, 상세 진입 시 목록 flush pause 여부,
  필터 시 시총·Top-20 기준(필터집합 vs 전체)
- (선택) 꼬리 최적화 재도전: 랭킹 버스트 스로틀 + 다회 측정 검증

---

_기록 시점: 목록 최적화 + PERF 측정/검증 완료. 다음 단계는 초성 검색._



# 구현 기록 #02 — 초성 검색 (초성 / 완성형 / 종목코드)

> 관심종목 목록의 검색 기능. 한글 **초성 검색**을 필수로, 완성형 부분일치·종목코드
> 부분일치까지 한 입력창에서 지원한다. 라이브러리 없이 `codeUnitAt` 기반으로 직접 구현.
> 상태: 실기기 동작 확인 완료 / `flutter analyze` 클린 / `flutter test` 12개 통과.

---

## 0. 설계 판단 요약 (DESIGN.md에 반영 예정)

| 항목 | 판단 | 이유 |
|---|---|---|
| 초성 매칭 | **앞일치(startsWith)** | 과제 예시가 전부 앞에서부터(ㄱㅇ→가온), 주식 검색 UX와 일치 |
| 이름 매칭 | **부분일치(contains)** | "전자"→"가온전자" 같은 중간 일치 요구 |
| 코드 매칭 | **부분일치(contains)** | "000590" 부분 입력 허용 |
| 시총·Top-20 기준 | **필터 걸리면 필터 집합 기준** | 사용자가 보는 집합과 일치 |
| 표시 종목 수 | **필터 통과 수** | 정의상 화면에 보이는 수 |
| 필터 아웃 종목 | 렌더 안 함(신호 스킵) + 상태 맵은 계속 갱신 | 필터 해제 시 정합성 유지, rebuild 비용 0 |
| 라이브러리 | **미사용(직접 구현)** | 로직 단순, 의존성 최소 |

---

## 1. 핵심 원리 — 완성형 한글의 규칙적 배열

완성형 한글은 유니코드 `가(0xAC00)` ~ `힣(0xD7A3)`에 규칙적으로 배열된다:

```
코드 = 0xAC00 + (초성×588) + (중성×28) + 종성
```

따라서 초성 인덱스는 나눗셈 하나로 얻는다:

```dart
final c = ch.codeUnitAt(0);
if (c >= 0xAC00 && c <= 0xD7A3) {
  final chosungIndex = (c - 0xAC00) ~/ 588;  // 0~18
}
```

검증: `전(0xC804)` → `(0xC804-0xAC00)~/588 = 12` → 12번 초성 `ㅈ`.
`가온전자` → `ㄱㅇㅈㅈ` (과제 예시와 일치).

---

## 2. ⚠️ 핵심 함정 — "초성 인덱스"와 "키보드로 친 ㄱ"은 다른 문자

가장 실수하기 쉬운 지점. 두 종류의 자모가 있다:

- 사용자가 키보드로 치는 `ㄱ` = **호환 자모(Compatibility Jamo)**, `U+3131`
- 완성형을 분해해 얻는 초성 `ㄱ` = **한글 자모(Hangul Jamo)**, `U+1100`

→ **코드포인트가 다르다.** 초성 인덱스를 U+1100 계열로 만들면 사용자 입력(U+3131)과
절대 안 맞는다. 그래서 **인덱스를 호환 자모로 매핑하는 테이블**이 필수다:

```dart
// 초성 인덱스 0~18 → 키보드 입력과 같은 호환 자모 (쌍자음 포함 19개)
const _chosung = [
  'ㄱ','ㄲ','ㄴ','ㄷ','ㄸ','ㄹ','ㅁ','ㅂ','ㅃ','ㅅ',
  'ㅆ','ㅇ','ㅈ','ㅉ','ㅊ','ㅋ','ㅌ','ㅍ','ㅎ',
];

String chosungOf(String s) {
  final sb = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 0xAC00 && c <= 0xD7A3) {
      sb.write(_chosung[(c - 0xAC00) ~/ 588]);
    } else {
      sb.writeCharCode(c); // 공백·영문·기호는 원문 유지
    }
  }
  return sb.toString();
}
```

> seed의 `_nameFor()` 종목명은 전부 완성형 음절 + BMP 범위라 `codeUnitAt(i)`가 안전
> (서로게이트 페어 없음). 이모지 등이 섞이면 `runes`가 필요하지만 이 과제엔 불필요.

---

## 3. 파일 구성

| 파일 | 역할 |
|---|---|
| `lib/search/chosung.dart` | `chosungOf` / `isChosungQuery` / `hasDigit` — 초성 추출·쿼리 분류 |
| `lib/state/market_store.dart` | 초성 인덱스 캐시 + `setQuery` + 필터 반영 집계 |
| `lib/ui/watchlist_screen.dart` | 검색창(debounce) + 필터 반영 목록 |
| `test/search_test.dart` | 초성/완성형/코드 매칭 회귀 테스트 9종 |

---

## 4. 매칭 로직 — 3-모드 분기 (`setQuery`)

```dart
final digit   = hasDigit(q);                 // 숫자 있으면 코드 검색 의도
final chosung = !digit && isChosungQuery(q);  // 전부 호환 자모면 초성 검색
for (final s in symbols) {
  final bool hit;
  if (digit)        hit = s.code.contains(q);                 // 종목코드 부분일치
  else if (chosung) hit = _chosungByCode[s.code]!.startsWith(q); // 초성 앞일치
  else              hit = s.name.contains(q);                 // 완성형 이름 부분일치
  if (hit) result.add(s.code);
}
```

- `isChosungQuery`: 쿼리가 전부 호환 자모 자음(`U+3131~U+314E`)이면 초성 검색으로 간주.
- 결과는 `_filtered` (코드 리스트)로 materialize. 빈 쿼리면 `_filtered = null`(전체, 빠른 경로).

---

## 5. 성능 설계 — "매 tick·keystroke 전체 재계산 금지" 충족

1. **초성 인덱스 1회 구축** — 이름은 불변이므로 `_chosungByCode`를 초기화 때만 계산.
   tick이 아무리 흘러도 초성은 재계산하지 않는다.
2. **debounce 200ms** — keystroke마다 필터를 돌리지 않고, 입력이 멎으면 1회만 `setQuery`.
3. **필터 스캔은 쿼리 변경 시 1회** — O(2,000) 스캔은 debounce된 쿼리 변경 때만. tick과 무관.
4. **행 갱신 경로는 그대로** — 목록은 `filterVersion`이 바뀔 때만 "구조"를 재빌드하고,
   각 행은 여전히 종목별 신호를 구독한다. tick coalescing/rebuild 격리는 검색 중에도 유지.
5. **필터 아웃 종목** — 렌더되지 않아 신호가 스킵(rebuild 0). 단 상태 맵은 계속 갱신되어
   필터를 풀면 즉시 최신값으로 보인다(정합성 유지).

---

## 6. 필터 반영 집계 (`_recomputeAggregates`)

```
필터 없음(_filtered == null):
  - 시총 = 전체 증분값(_totalMarketCap)   ← 빠른 경로 (전체 순회 없음)
  - Top-20 = SplayTreeSet 앞 20 (pct 변동 시에만)

필터 있음(_filtered != null):
  - 시총 = 통과 집합만 순회해 합산       ← 크기에 비례(bounded)
  - Top-20 = 통과 집합을 pct 내림차순 정렬해 상위 20
```

필터 시 통과 집합만 순회하므로, 검색으로 좁혀진 집합(대개 수십~수백)에 비례하는 비용만 든다.
집계는 flush(프레임당 1회)와 `setQuery`(틱 없이 즉시 반영) 양쪽에서 호출된다.

---

## 7. UI — 검색창 + debounce

```dart
void _onQueryChanged(String q) {
  _debounce?.cancel();
  _debounce = Timer(const Duration(milliseconds: 200), () => _store.setQuery(q));
}
```
- 힌트: `초성(ㄱㅇ) · 이름(전자) · 코드(000590)`
- 목록은 `ValueListenableBuilder<int>(filterVersion)`로 감싸 구조 변경 시에만 재빌드.
- 결과 0건이면 "검색 결과가 없습니다".

---

## 8. 테스트 (`test/search_test.dart`)

- `chosungOf('가온전자')=='ㄱㅇㅈㅈ'`, `chosungOf('나래화학')=='ㄴㄹㅎㅎ'`
- 쿼리 분류(`isChosungQuery`, `hasDigit`)
- `ㄱㅇ` → 결과 전부 초성이 ㄱㅇ로 시작
- `ㄴㄹㅎㅎ` → 나래화학 포함
- `전자` → 이름에 "전자" 포함 / `000001` → 코드 부분일치
- 필터 시 요약 종목 수 = 표시 수

**테스트가 오판을 잡은 사례:** `ㄴㄹㅎㅎ`는 나래화학뿐 아니라 **누리화학**("누리"도 초성 ㄴㄹ)도
매칭된다. 처음엔 "나래화학만"이라 단정했는데 테스트가 실패 → 코드가 맞고 기대가 틀렸음을 확인.
→ 검증의 가치. (역순/정지 등 기존 3종 포함 총 12개 통과)

---

## 9. 남은 것

- **상세 화면 + 스파크라인** (다음 단계)
- 구독 수명 관리(상세 진입 시 목록 flush pause 여부)
- DESIGN.md / PERF.md에 이 판단들 반영

---

_기록 시점: 초성 검색(초성/완성형/코드) 구현·검증 완료. 다음은 종목 상세 화면._
