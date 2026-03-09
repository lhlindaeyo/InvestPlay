import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

// ─────────────────────────────────────────────────────────
// Firebase Functions URL (2세대 - 함수마다 개별 URL)
// ─────────────────────────────────────────────────────────
const _urlGetStockPrice =
    'https://getstockprice-ihgnnp5a5q-du.a.run.app';
const _urlGetStockChart =
    'https://getstockchart-ihgnnp5a5q-du.a.run.app';
const _urlSearchStock =
    'https://searchstock-ihgnnp5a5q-du.a.run.app';
const _urlRefreshKisToken =
    'https://refreshkistoken-ihgnnp5a5q-du.a.run.app';

// ─────────────────────────────────────────────────────────
// 모델
// ─────────────────────────────────────────────────────────

/// 주식 현재가
class StockPrice {
  final String code;
  final String name;
  final int currentPrice;
  final int priceChange;
  final double changeRate;
  final bool isUp;

  const StockPrice({
    required this.code,
    required this.name,
    required this.currentPrice,
    required this.priceChange,
    required this.changeRate,
    required this.isUp,
  });

  factory StockPrice.fromKis(String code, Map<String, dynamic> json) {
    final output = json['output'] as Map<String, dynamic>? ?? {};
    final price = int.tryParse(output['stck_prpr'] ?? '0') ?? 0;
    final change = int.tryParse(output['prdy_vrss'] ?? '0') ?? 0;
    final rate = double.tryParse(output['prdy_ctrt'] ?? '0') ?? 0.0;
    final sign = output['prdy_vrss_sign'] ?? '3'; // 1:상한 2:상승 3:보합 4:하락 5:하한

    return StockPrice(
      code: code,
      name: output['hts_kor_isnm'] ?? '',
      currentPrice: price,
      priceChange: change,
      changeRate: rate,
      isUp: sign == '1' || sign == '2',
    );
  }
}

/// 차트 캔들 데이터
class CandleData {
  final DateTime date;
  final int open;
  final int high;
  final int low;
  final int close;
  final int volume;

  const CandleData({
    required this.date,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  factory CandleData.fromKis(Map<String, dynamic> json) {
    final dateStr = json['stck_bsop_date'] ?? '20000101';
    final date = DateTime(
      int.parse(dateStr.substring(0, 4)),
      int.parse(dateStr.substring(4, 6)),
      int.parse(dateStr.substring(6, 8)),
    );

    return CandleData(
      date: date,
      open: int.tryParse(json['stck_oprc'] ?? '0') ?? 0,
      high: int.tryParse(json['stck_hgpr'] ?? '0') ?? 0,
      low: int.tryParse(json['stck_lwpr'] ?? '0') ?? 0,
      close: int.tryParse(json['stck_clpr'] ?? '0') ?? 0,
      volume: int.tryParse(json['acml_vol'] ?? '0') ?? 0,
    );
  }
}

/// 종목 검색 결과
class StockSearchResult {
  final String code;
  final String name;
  final String market;

  const StockSearchResult({
    required this.code,
    required this.name,
    required this.market,
  });

  factory StockSearchResult.fromKis(Map<String, dynamic> json) {
    return StockSearchResult(
      code: json['pdno'] ?? '',
      name: json['prdt_abrv_name'] ?? '',
      market: json['mket_id_cd'] ?? '',
    );
  }
}

/// KIS API 전용 예외
class KisApiException implements Exception {
  final String message;
  const KisApiException(this.message);

  @override
  String toString() => 'KisApiException: $message';
}

// ─────────────────────────────────────────────────────────
// KIS API Service
// ─────────────────────────────────────────────────────────
class KisApiService {
  final http.Client _client;

  KisApiService({http.Client? client}) : _client = client ?? http.Client();

  // ── 주식 현재가 조회 ──────────────────────────────────
  Future<StockPrice> getStockPrice(String code) async {
    final uri = Uri.parse('$_urlGetStockPrice?code=$code');

    try {
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw KisApiException('현재가 조회 실패: ${response.statusCode}');
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return StockPrice.fromKis(code, json);
    } catch (e) {
      if (e is KisApiException) rethrow;
      throw KisApiException('네트워크 오류: $e');
    }
  }

  // ── 일봉/주봉/월봉 차트 조회 ──────────────────────────
  Future<List<CandleData>> getStockChart(
    String code, {
    ChartPeriod period = ChartPeriod.day,
  }) async {
    final uri = Uri.parse(
      '$_urlGetStockChart?code=$code&period=${period.value}',
    );

    try {
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw KisApiException('차트 조회 실패: ${response.statusCode}');
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final output2 = json['output2'] as List<dynamic>? ?? [];

      return output2
          .map((e) => CandleData.fromKis(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.date.compareTo(b.date));
    } catch (e) {
      if (e is KisApiException) rethrow;
      throw KisApiException('네트워크 오류: $e');
    }
  }

  // ── 종목 검색 ─────────────────────────────────────────
  Future<List<StockSearchResult>> searchStock(String query) async {
    final encoded = Uri.encodeComponent(query);
    final uri = Uri.parse('$_urlSearchStock?query=$encoded');

    try {
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw KisApiException('종목 검색 실패: ${response.statusCode}');
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final output = json['output'] as List<dynamic>? ?? [];

      return output
          .map((e) => StockSearchResult.fromKis(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      if (e is KisApiException) rethrow;
      throw KisApiException('네트워크 오류: $e');
    }
  }

  void dispose() => _client.close();
}

/// 차트 기간 enum
enum ChartPeriod {
  day('D'),
  week('W'),
  month('M');

  final String value;
  const ChartPeriod(this.value);
}

// ─────────────────────────────────────────────────────────
// Riverpod Providers
// ─────────────────────────────────────────────────────────
final kisApiServiceProvider = Provider<KisApiService>((ref) {
  final service = KisApiService();
  ref.onDispose(service.dispose);
  return service;
});

/// 주식 현재가 Provider
final stockPriceProvider =
    FutureProvider.family<StockPrice, String>((ref, code) async {
  final service = ref.watch(kisApiServiceProvider);
  return service.getStockPrice(code);
});

/// 차트 데이터 Provider
final stockChartProvider =
    FutureProvider.family<List<CandleData>, StockChartParams>((ref, params) async {
  final service = ref.watch(kisApiServiceProvider);
  return service.getStockChart(params.code, period: params.period);
});

/// 차트 조회 파라미터
class StockChartParams {
  final String code;
  final ChartPeriod period;

  const StockChartParams({required this.code, required this.period});

  @override
  bool operator ==(Object other) =>
      other is StockChartParams && code == other.code && period == other.period;

  @override
  int get hashCode => Object.hash(code, period);
}