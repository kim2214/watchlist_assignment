/// 한글 초성 추출·매칭 유틸 (라이브러리 없이 codeUnitAt 기반).
///
/// 완성형 한글은 유니코드에 규칙적으로 배열된다:
///   코드 = 0xAC00 + (초성×588) + (중성×28) + 종성
/// 따라서 초성 인덱스는 `(code - 0xAC00) ~/ 588` 로 얻는다.
///
/// 주의(핵심 함정): 사용자가 키보드로 치는 'ㄱ','ㅇ' 은 **호환 자모**
/// (Compatibility Jamo, ㄱ=U+3131...)이고, 완성형을 분해해 얻는 초성은 **한글 자모**
/// (Hangul Jamo, ㄱ=U+1100...)로 코드포인트가 다르다. 그래서 초성 인덱스를 아래
/// [_chosung] (호환 자모) 로 매핑해야 사용자 입력과 매칭된다.
library;

/// 초성 인덱스(0~18) → 키보드 입력과 같은 호환 자모 문자. (쌍자음 포함 19개)
const List<String> _chosung = [
  'ㄱ', 'ㄲ', 'ㄴ', 'ㄷ', 'ㄸ', 'ㄹ', 'ㅁ', 'ㅂ', 'ㅃ', 'ㅅ',
  'ㅆ', 'ㅇ', 'ㅈ', 'ㅉ', 'ㅊ', 'ㅋ', 'ㅌ', 'ㅍ', 'ㅎ',
];

const int _hangulBase = 0xAC00; // '가'
const int _hangulLast = 0xD7A3; // '힣'
const int _jamoPerChosung = 588; // 중성21 × 종성28

/// 문자열의 초성열을 뽑는다. 완성형이 아닌 문자는 그대로 통과시킨다.
/// 예: "가온전자" → "ㄱㅇㅈㅈ"
String chosungOf(String s) {
  final sb = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= _hangulBase && c <= _hangulLast) {
      sb.write(_chosung[(c - _hangulBase) ~/ _jamoPerChosung]);
    } else {
      sb.writeCharCode(c); // 공백·영문·기호 등은 원문 유지
    }
  }
  return sb.toString();
}

/// 호환 자모 자음 영역(ㄱ~ㅎ, 쌍자음·겹자음 포함).
/// 이 범위 문자로만 이뤄진 쿼리는 "초성 검색"으로 간주한다.
bool _isCompatConsonant(int c) => c >= 0x3131 && c <= 0x314E;

/// 쿼리가 전부 초성(호환 자모 자음)인가.
bool isChosungQuery(String q) {
  if (q.isEmpty) return false;
  for (var i = 0; i < q.length; i++) {
    if (!_isCompatConsonant(q.codeUnitAt(i))) return false;
  }
  return true;
}

/// 쿼리에 숫자가 하나라도 있는가(=종목코드 검색 의도).
bool hasDigit(String q) {
  for (var i = 0; i < q.length; i++) {
    final c = q.codeUnitAt(i);
    if (c >= 0x30 && c <= 0x39) return true;
  }
  return false;
}
