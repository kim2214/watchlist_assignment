import 'package:integration_test/integration_test_driver.dart';

/// integration_test의 reportData(성능 요약)를
/// build/integration_response_data.json 으로 저장하는 드라이버.
///
/// 실행:
///   flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/perf_test.dart \
///     --profile -d [device]
Future<void> main() => integrationDriver();
