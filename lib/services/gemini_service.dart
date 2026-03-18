import 'dart:typed_data';
import 'dart:convert';
import 'package:firebase_ai/firebase_ai.dart';

class GeminiService {
  late final GenerativeModel model;

  GeminiService() {
    // 使用 Google AI 後端（免費 Gemini 模型）
    final googleAI = FirebaseAI.googleAI();  // 或 FirebaseAI.vertexAI() 如果你用 Vertex
    model = googleAI.generativeModel(
      model: 'gemini-2.5-flash',  // 或 'gemini-3.1-flash' 如果可用
      // 可加 safetySettings 等
    );
  }

  Future<Map<String, dynamic>> analyzeFoodImage(Uint8List imageBytes) async {
    const promptText = '''
這是一張餐點照片。
請盡可能精確辨識所有食物項目、估計每項的份量（克數或大約大小），然後計算總熱量、蛋白質、碳水化合物、脂肪。
用以下JSON格式回覆（不要多餘文字）：
{
  "foods": [
    {"name": "食物名稱", "grams": 150, "cal": 450, "protein": 35, "carbs": 40, "fat": 15}
  ],
  "total_cal": 1200,
  "total_protein": 68,
  "total_carbs": 150,
  "total_fat": 45
}
使用常見營養資料庫標準（USDA或香港食物資料）。如果有港式菜請盡量準確。
''';

    // 新版多模態內容建構（用 Content.multi + TextPart + InlineDataPart）
    final content = Content.multi([
      TextPart(promptText),
      InlineDataPart('image/jpeg', imageBytes),  // MIME type 根據圖片格式（jpeg/png）
    ]);

    final response = await model.generateContent([content]);  // 傳 List<Content>

    final text = response.text ?? '{}';

    // 清理可能的 ```json 包圍
    final jsonStr = text.replaceAll(RegExp(r'^```json\s*|\s*```$'), '').trim();
    
    try {
      return jsonDecode(jsonStr);
    } catch (e) {
      throw Exception('JSON 解析失敗: $e\n原始回應: $text');
    }
  }
}