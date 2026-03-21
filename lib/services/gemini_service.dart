import 'dart:typed_data';
import 'dart:convert';
import 'package:firebase_ai/firebase_ai.dart';

class GeminiService {
  late final GenerativeModel model;

  GeminiService() {
    // 使用 Google AI 後端（免費 Gemini 模型）
    final googleAI = FirebaseAI.googleAI();  // 或 FirebaseAI.vertexAI() 如果你用 Vertex
    model = googleAI.generativeModel(
      model: 'gemini-3.1-flash-lite-preview',  // 或 'gemini-3.1-flash' 如果可用 
      // 可加 safetySettings 等
    );
  }

  Future<Map<String, dynamic>> reanalyzeFoodByText(String foodDescription) async {
  try {
    // 這裡使用與圖片分析相同的 prompt 結構，但改為純文字輸入
    final prompt = """
    使用者修正了食材描述為：「$foodDescription」。
    請根據這個描述，重新估算營養成分。
    請嚴格回傳 JSON 格式，包含：
    {
      "dish_name": "食物名稱",
      "total_calories": 數字,
      "total_protein_g": 數字,
      "total_carbs_g": 數字,
      "total_fat_g": 數字,
      "foods": [{"name": "食材", "estimated_grams": 數字, "calories": 數字, "protein_g": 數字, "carbs_g": 數字, "fat_g": 數字}]
    }
    """;

    // 呼叫你的 GoogleGenerativeAI model (假設你已經在 service 初始化了 model)
    final content = [Content.text(prompt)];
    final response = await model.generateContent(content);
    
    final text = response.text;
    if (text == null) throw Exception("AI 回傳內容為空");

    // 移除 markdown 標籤並解析 JSON
    final jsonString = text.replaceAll('```json', '').replaceAll('```', '').trim();
    return jsonDecode(jsonString);
  } catch (e) {
    throw Exception("文字分析失敗: $e");
  }
}

  Future<Map<String, dynamic>> analyzeFoodImage(Uint8List imageBytes) async {
    String promptText = '''
      這是一張餐點照片，使用常見營養資料庫標準（USDA 或 香港食物安全中心資料）。請盡可能精確辨識所有食物項目、估計每項的份量（克數或大約大小），然後計算總熱量、蛋白質、碳水化合物、脂肪。  如果有港式/中式菜餚，請盡量使用亞洲食物資料庫的近似值。

      步驟：
      1. 辨識所有可見食物（主菜、配菜、湯、醬汁）。
      2. 估計實際重量（克數），參考常見餐盤大小。
      3. 列出菜式名稱並計算熱量、蛋白質、碳水、脂肪。
      4. 回覆必須是純 JSON，不要任何額外文字、解釋或 markdown。

      輸出格式（嚴格遵守）：
      {
        "foods": [
          {
            "name": "食物名稱",
            "estimated_grams": 280,
            "calories": 680,
            "protein_g": 38,
            "carbs_g": 85,
            "fat_g": 22
          }
        ],
        "dish_name" : "食物名稱",
        "total_calories": 725,
        "total_protein_g": 41,
        "total_carbs_g": 93,
        "total_fat_g": 23
      }
      ''';

    // 新版多模態內容建構（用 Content.multi + TextPart + InlineDataPart）
    final content = Content.multi([
      TextPart(promptText),
      InlineDataPart('image/jpeg', imageBytes),  // MIME type 根據圖片格式（jpeg/png）
    ]);

    late final String text;

    try {
      final response = await model.generateContent([content]);  // 傳 List<Content>
      text = response.text ?? '{}';
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('resource_exhausted') || msg.contains('quota') || msg.contains('429')) {
        throw Exception('已達免費額度，請稍後重試或升級配額。');
      }
      rethrow;
    }

    // 清理可能的 ```json 包圍
    final jsonStr = text.replaceAll(RegExp(r'^```json\s*|\s*```$'), '').trim();

    try {
      return jsonDecode(jsonStr);
    } catch (e) {
      throw Exception('JSON 解析失敗: $e\n原始回應: $text');
    }
  }
}