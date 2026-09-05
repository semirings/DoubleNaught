import 'dart:convert';

import 'package:http/http.dart' as http;
import '../backend_config.dart';

class ModelBuilderApi {
  final String baseUrl;

  const ModelBuilderApi({this.baseUrl = BackendConfig.baseUrl});

  static const _jsonHeaders = {'Content-Type': 'application/json'};
  static const _timeout = Duration(minutes: 2);

  Future<ModelBuildResult> build(ModelBuildConfig cfg) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/model/build'),
          headers: _jsonHeaders,
          body: jsonEncode(cfg.toJson()),
        )
        .timeout(_timeout,
            onTimeout: () => throw ModelBuilderApiException(
                '/model/build', 408, 'Request timed out'));
    if (response.statusCode == 200) {
      return ModelBuildResult.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw ModelBuilderApiException(
        '/model/build', response.statusCode, response.body);
  }
}

class ModelBuildConfig {
  final int vocabSize;
  final int nLayers;
  final int dModel;
  final int nHeads;
  final int dFf;
  final double dropout;
  final int maxSeqLen;
  final bool useGradientCheckpointing;

  const ModelBuildConfig({
    this.vocabSize = 50257,
    this.nLayers = 12,
    this.dModel = 768,
    this.nHeads = 12,
    this.dFf = 3072,
    this.dropout = 0.1,
    this.maxSeqLen = 1024,
    this.useGradientCheckpointing = false,
  });

  ModelBuildConfig copyWith({
    int? vocabSize,
    int? nLayers,
    int? dModel,
    int? nHeads,
    int? dFf,
    double? dropout,
    int? maxSeqLen,
    bool? useGradientCheckpointing,
  }) =>
      ModelBuildConfig(
        vocabSize: vocabSize ?? this.vocabSize,
        nLayers: nLayers ?? this.nLayers,
        dModel: dModel ?? this.dModel,
        nHeads: nHeads ?? this.nHeads,
        dFf: dFf ?? this.dFf,
        dropout: dropout ?? this.dropout,
        maxSeqLen: maxSeqLen ?? this.maxSeqLen,
        useGradientCheckpointing:
            useGradientCheckpointing ?? this.useGradientCheckpointing,
      );

  Map<String, dynamic> toJson() => {
        'vocabSize': vocabSize,
        'nLayers': nLayers,
        'dModel': dModel,
        'nHeads': nHeads,
        'dFf': dFf,
        'dropout': dropout,
        'maxSeqLen': maxSeqLen,
        'useGradientCheckpointing': useGradientCheckpointing,
      };

  factory ModelBuildConfig.fromParams(Map<String, String> p) =>
      ModelBuildConfig(
        vocabSize: int.tryParse(p['vocabSize'] ?? '') ?? 50257,
        nLayers: int.tryParse(p['nLayers'] ?? '') ?? 12,
        dModel: int.tryParse(p['dModel'] ?? '') ?? 768,
        nHeads: int.tryParse(p['nHeads'] ?? '') ?? 12,
        dFf: int.tryParse(p['dFf'] ?? '') ?? 3072,
        dropout: double.tryParse(p['dropout'] ?? '') ?? 0.1,
        maxSeqLen: int.tryParse(p['maxSeqLen'] ?? '') ?? 1024,
        useGradientCheckpointing: p['useGradientCheckpointing'] == 'true',
      );

  Map<String, String> toParams() => {
        'vocabSize': '$vocabSize',
        'nLayers': '$nLayers',
        'dModel': '$dModel',
        'nHeads': '$nHeads',
        'dFf': '$dFf',
        'dropout': '$dropout',
        'maxSeqLen': '$maxSeqLen',
        'useGradientCheckpointing': '$useGradientCheckpointing',
      };
}

class ModelBuildResult {
  final String handleId;
  final int paramCount;
  final double paramCountM;
  final double estimatedVramFp16Mb;
  final double estimatedVramFp32Mb;
  final Map<String, dynamic> architecture;

  const ModelBuildResult({
    required this.handleId,
    required this.paramCount,
    required this.paramCountM,
    required this.estimatedVramFp16Mb,
    required this.estimatedVramFp32Mb,
    required this.architecture,
  });

  factory ModelBuildResult.fromJson(Map<String, dynamic> j) => ModelBuildResult(
        handleId: j['handleId'] as String,
        paramCount: (j['paramCount'] as num).toInt(),
        paramCountM: (j['paramCountM'] as num).toDouble(),
        estimatedVramFp16Mb: (j['estimatedVramFp16Mb'] as num).toDouble(),
        estimatedVramFp32Mb: (j['estimatedVramFp32Mb'] as num).toDouble(),
        architecture: j['architecture'] as Map<String, dynamic>,
      );
}

class ModelBuilderApiException implements Exception {
  final String path;
  final int statusCode;
  final String body;

  ModelBuilderApiException(this.path, this.statusCode, this.body);

  @override
  String toString() => 'ModelBuilderApiException($path → $statusCode): $body';
}
