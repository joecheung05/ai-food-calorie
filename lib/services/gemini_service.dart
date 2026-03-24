import 'dart:typed_data';
import 'dart:convert';
import 'package:firebase_ai/firebase_ai.dart';

class GeminiService {
  late GenerativeModel model;

  final List<String> modelChain = [
    'gemini-3.1-flash-lite-preview',   
    'gemini-2.5-flash-lite',         // 第一順位：最新、辨識最強, // 第二順位：快、配額通常獨立
    'gemini-2.5-flash',           // 第三順位：最穩定、保底用
  ];

  GeminiService() {
    // 建議使用 gemini-1.5-flash，這是目前最穩定、速度最快且免費額度較高的模型
    // final googleAI = FirebaseAI.googleAI(); 
    
    // model = googleAI.generativeModel(
    //   // 將這裡改為 1.5-flash，避免 3.1 版本的相容性問題
    //   model: 'gemini-3.1-flash-lite-preview', 
    //   // 如果你想嘗試 2.0 版本且 SDK 支援，也可以用 'gemini-2.0-flash-exp'
    // );
    _initModel(modelChain[0]);
  }

  void _initModel(String modelName) {
    final googleAI = FirebaseAI.googleAI();
    model = googleAI.generativeModel(model: modelName);
    print("DEBUG: [System] 初始化模型 -> $modelName");
  }

  // 文字重新分析功能 (取消註解並優化)
  Future<Map<String, dynamic>> reanalyzeFoodByText(String foodDescription) async {
    try {
      final prompt = """
      使用者修正了食材描述為：「$foodDescription」。
      請根據這個描述，重新估算營養成分。
      請嚴格回傳純 JSON 格式，不要包含任何 markdown 標籤或解釋文字。
      
      格式如下：
      {
        "dish_name": "食物名稱",
        "total_calories": 數字,
        "total_protein_g": 數字,
        "total_carbs_g": 數字,
        "total_fat_g": 數字,
        "foods": [{"name": "食材", "estimated_grams": 數字, "calories": 數字, "protein_g": 數字, "carbs_g": 數字, "fat_g": 數字}]
      }
      """;

      final response = await model.generateContent([Content.text(prompt)]);
      final text = response.text;
      if (text == null) throw Exception("AI 回傳內容為空");

      // 使用正則表達式更安全地清理 JSON
      final jsonString = text.replaceAll(RegExp(r'^```json\s*|\s*```$'), '').trim();
      return jsonDecode(jsonString);
    } catch (e) {
      throw Exception("文字分析失敗: $e");
    }
  }

  Future<Map<String, dynamic>> analyzeFoodImage(Uint8List imageBytes) async {
    String? lastError;

    for (String modelName in modelChain) {
      try {
        _initModel(modelName); // 切換模型
        
        print("DEBUG: [Step 1] 準備數據 - 使用模型: $modelName");
        final content = Content.multi([
          TextPart(_getPrompt()),
          InlineDataPart('image/jpeg', imageBytes),
        ]);

        print("DEBUG: [Step 2] 正在請求伺服器...");
        final response = await model.generateContent([content]);

        print("DEBUG: [Step 3] 伺服器成功回應");
        final text = response.text ?? '{}';
        
        print("DEBUG: [Step 4] 解析 JSON...");
        final jsonStr = text.replaceAll(RegExp(r'^```json\s*|\s*```$'), '').trim();
        return jsonDecode(jsonStr);

      } catch (e) {
        lastError = e.toString();
        print("DEBUG: [Warning] 模型 $modelName 失敗: $lastError");
        
        // 如果是 500 (載重) 或 429 (配額)，則繼續下一個模型
        if (lastError.contains("500") || lastError.contains("429") || lastError.contains("limit")) {
          print("DEBUG: [Action] 嘗試自動切換至下一個備援模型...");
          continue; 
        } else {
          // 其他類型錯誤 (如網路斷線) 直接報錯，不浪費配額
          throw Exception("辨識發生錯誤: $e");
        }
      }
    }
    throw Exception("所有 AI 模型目前皆無法回應 (最後錯誤: $lastError)。請稍後再試。");
  }

  String _getPrompt() {
    return '''
      這是一張餐點照片，使用常見營養資料庫標準（USDA 或 香港食物安全中心資料）。請盡可能精確辨識所有食物項目、估計每項的份量（克數或大約大小），然後計算總熱量、蛋白質、碳水化合物、脂肪。如果有港式/中式菜餚，請盡量使用亞洲食物資料庫的近似值。

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
            "estimated_grams": 200,
            "calories": 400,
            "protein_g": 20,
            "carbs_g": 40,
            "fat_g": 10
          }
        ],
        "dish_name" : "食物名稱",
        "total_calories": 400,
        "total_protein_g": 20,
        "total_carbs_g": 40,
        "total_fat_g": 10
      }
      '''; // 保持原有的 Prompt
  }
    
}