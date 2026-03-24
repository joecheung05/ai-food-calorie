import 'dart:io';
import 'dart:typed_data';
import 'dart:convert'; // 必須加入這一行才能使用 base64Encode

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/services.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'services/gemini_service.dart';
import 'firebase_options.dart';


import 'models/food_record.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Hive
  await Hive.initFlutter();
  Hive.registerAdapter(FoodRecordAdapter());
  await Hive.openBox<FoodRecord>('food_history'); // Open the box

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI 食物營養分析',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  DateTime _selectedDate = DateTime.now();
  DateTime _focusedWeekDate = DateTime.now();
  final GeminiService _gemini = GeminiService();
  final ImagePicker _picker = ImagePicker();
  Map<String, dynamic>? _result;
  bool _isSaving = false;
  bool _loading = false;
  File? _image;
  Uint8List? _imageData;
  Uint8List? manualImageData;
  double _tdee = 0;
  String _goal = 'maintain'; // 'lose', 'maintain', 'gain'
  double _targetProtein = 0;
  double _targetCarbs = 0;
  double _targetFat = 0;
  double _targetCalories = 0;
// 控制項
final TextEditingController _ageController = TextEditingController();
final TextEditingController _weightController = TextEditingController();
final TextEditingController _heightController = TextEditingController();
String _gender = 'male';
double _activityLevel = 1.2; // 預設久坐

String _formatDate(DateTime date) {
  return "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
}

void _calculateNutrientGoals() {
  _calculateTDEE(); // 先計算基礎 TDEE
  
  if (_tdee <= 0) return;

  setState(() {
    // 1. 根據目標調整總熱量目標
    if (_goal == 'lose') {
      _targetCalories = _tdee - 400; // 減脂：減少 400 kcal
    } else if (_goal == 'gain') {
      _targetCalories = _tdee + 400; // 增肌：增加 400 kcal
    } else {
      _targetCalories = _tdee;       // 維持
    }

    // 2. 根據目標分配營養素比例 (Protein/Carbs/Fat)
    if (_goal == 'lose') {
      // 減脂：35% P, 35% C, 30% F (高蛋白保肌)
      _targetProtein = (_targetCalories * 0.35) / 4;
      _targetCarbs = (_targetCalories * 0.35) / 4;
      _targetFat = (_targetCalories * 0.30) / 9;
    } else if (_goal == 'gain') {
      // 增肌：25% P, 50% C, 25% F (高碳水提供能量)
      _targetProtein = (_targetCalories * 0.25) / 4;
      _targetCarbs = (_targetCalories * 0.50) / 4;
      _targetFat = (_targetCalories * 0.25) / 9;
    } else {
      // 維持：25% P, 45% C, 30% F
      _targetProtein = (_targetCalories * 0.25) / 4;
      _targetCarbs = (_targetCalories * 0.45) / 4;
      _targetFat = (_targetCalories * 0.30) / 9;
    }
  });
}

@override
void initState() {
  super.initState();
  _loadProfile(); // 初始化時載入資料
}

// 載入個人資料並計算 TDEE
Future<void> _loadProfile() async {
  final prefs = await SharedPreferences.getInstance();
  setState(() {
    _ageController.text = prefs.getString('age') ?? '';
    _weightController.text = prefs.getString('weight') ?? '';
    _heightController.text = prefs.getString('height') ?? '';
    _gender = prefs.getString('gender') ?? 'male';
    _activityLevel = prefs.getDouble('activity') ?? 1.2;
    _goal = prefs.getString('goal') ?? 'maintain'; // 記得載入目標
    
    _calculateTDEE();
    _calculateNutrientGoals(); // 關鍵：初始化時也要計算目標比例
  });
}

void _calculateTDEE() {
  double weight = double.tryParse(_weightController.text) ?? 0;
  double height = double.tryParse(_heightController.text) ?? 0;
  int age = int.tryParse(_ageController.text) ?? 0;

  if (weight > 0 && height > 0 && age > 0) {
    double bmr;
    if (_gender == 'male') {
      bmr = 10 * weight + 6.25 * height - 5 * age + 5;
    } else {
      bmr = 10 * weight + 6.25 * height - 5 * age - 161;
    }
    setState(() {
      _tdee = bmr * _activityLevel;
    });
  }
}

Future<void> _saveProfile() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('age', _ageController.text);
  await prefs.setString('weight', _weightController.text);
  await prefs.setString('height', _heightController.text);
  await prefs.setString('gender', _gender);
  await prefs.setDouble('activity', _activityLevel);
  await prefs.setString('goal', _goal); // 儲存目標
  
  _calculateNutrientGoals();
  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('資料已儲存')));
}

  Future<void> _analyzeImageFromBytes(Uint8List bytes) async {
  setState(() => _loading = true);
  debugPrint("--- 開始 AI 辨識流程 ---");

  
  try {
    final data = await _gemini.analyzeFoodImage(bytes);
    String base64Image = uint8ListToBase64(bytes);

    // 2. 檢查長度 (1MB 限制大約是 1,300,000 個字元)
    if (base64Image.length > 1000000) {
       print("警告：圖片太大，可能會儲存失敗");
    }
    setState(() => _result = data);
    // 1. 開啟 Loading
    setState(() => _isSaving = true);

    // --- SAVE TO HIVE ---
    final box = Hive.box<FoodRecord>('food_history');
    final newRecord = FoodRecord(
      dishName: data['dish_name'] ?? '未知菜餚',
      totalCal: (data['total_cal'] ?? data['total_calories'] ?? 0).toDouble(),
      dateTime: DateTime.now(),
      rawJson: data,
      protein: (data['total_protein'] ?? data['total_protein_g'] ?? 0).toDouble(),
      fat: (data['total_fat'] ?? data['total_fat_g'] ?? 0).toDouble(),
      carbs: (data['total_carbs'] ?? data['total_carbs_g'] ?? 0).toDouble(),
      imageUrl: base64Image, // 使用 Base64 字串作為圖片 URL
    );
    await box.add(newRecord); 
    debugPrint("✅ 本地 Hive 儲存成功");

    await _uploadToPublicCloud(newRecord, base64Image).timeout(
      const Duration(seconds: 5),
      onTimeout: () => debugPrint("⚠️ 雲端同步超時，略過上傳以恢復 UI"),
    );
    debugPrint("✅ 雲端同步流程結束");

  } catch (e) {
    debugPrint("❌ 辨識或儲存發生錯誤: $e");
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('辨識失敗: $e')),
      );
    }
  } finally {
    if (mounted) {
      setState(() => _isSaving = false);
      setState(() => _loading = false);
      debugPrint("--- 流程結束，已解除 Loading ---");
    }
  }
}

Map<String, List<FoodRecord>> _groupRecordsByDate(List<FoodRecord> records) {
    Map<String, List<FoodRecord>> grouped = {};
    for (var record in records) {
      String dateStr = "${record.dateTime.year}-${record.dateTime.month.toString().padLeft(2, '0')}-${record.dateTime.day.toString().padLeft(2, '0')}";
      if (grouped[dateStr] == null) {
        grouped[dateStr] = [];
      }
      grouped[dateStr]!.add(record);
    }
    return grouped;
  }

  Future<void> _pickImageFromGallery() async {
    try {
      final XFile? photo = await _picker.pickImage(source: ImageSource.gallery);
      if (photo == null) return;

      final bytes = await photo.readAsBytes();
      setState(() {
        _imageData = bytes;
        _image = kIsWeb ? null : File(photo.path);
      });
      await _analyzeImageFromBytes(bytes);
    } catch (e) {
      debugPrint('Image picking error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('從相簿選擇圖片時發生錯誤')),
      );
    }
  }

  Widget _buildResultRow(String label, dynamic value) {
  // 如果傳進來的 value 是 'null kcal' 或 '0 kcal'，嘗試從 _result 抓取不同的 key
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey)),
        Text(value.toString(), style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    ),
  );
}

  Widget _buildIngredientSection() {
    final foods = (_result?['foods'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
    if (foods.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('食材明細', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        ...foods.map((food) {
          final name = food['name'] ?? '-';
          final grams = food['estimated_grams'] != null ? '${food['estimated_grams']} g' : '-';
          final cal = food['calories'] != null ? '${food['calories']} kcal' : '-';
          final protein = food['protein_g'] != null ? '${food['protein_g']} g' : '-';
          final carbs = food['carbs_g'] != null ? '${food['carbs_g']} g' : '-';
          final fat = food['fat_g'] != null ? '${food['fat_g']} g' : '-';

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildResultRow('• $name', grams),
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildResultRow('卡路里', cal),
                    _buildResultRow('蛋白質', protein),
                    _buildResultRow('碳水化合物', carbs),
                    _buildResultRow('脂肪', fat),
                  ],
                ),
              ),
              const Divider(height: 20, thickness: 0.5),
            ],
          );
        }).toList(),
      ],
    );
  }

  Widget _buildHistoryTab() {
  return ValueListenableBuilder(
    valueListenable: Hive.box<FoodRecord>('food_history').listenable(),
    builder: (context, Box<FoodRecord> box, _) {
      final selectedDateStr = _formatDate(_selectedDate);
      final allRecords = box.values.toList();
      
      // 根據選定日期篩選紀錄 [cite: 405, 406]
      final dayMeals = allRecords.where((r) => _formatDate(r.dateTime) == selectedDateStr).toList();

      // 計算選定日期的總量以更新進度條 [cite: 424]
      double dayCal = 0, dayP = 0, dayC = 0, dayF = 0;
      for (var r in dayMeals) {
        double qty = (r.quantity <= 0) ? 1.0 : r.quantity;
        dayCal += (r.totalCal * qty);
        dayP += (r.protein * qty);
        dayC += (r.carbs * qty);
        dayF += (r.fat * qty);
      }

      return Column(
        children: [
          _buildWeeklyHeader(), // 顯示週切換 UI
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 每日進度條：現在會隨 _selectedDate 變動 [cite: 427, 436]
                if (_tdee > 0)
                  _buildDailyProgress(
                    dayCal, _targetCalories, 
                    dayP, _targetProtein, 
                    dayC, _targetCarbs, 
                    dayF, _targetFat
                  ),
                const SizedBox(height: 20),
                
                // 顯示該日餐點清單 [cite: 432]
                if (dayMeals.isEmpty)
                  const Center(child: Padding(
                    padding: EdgeInsets.only(top: 40),
                    child: Text("此日期暫無紀錄", style: TextStyle(color: Colors.grey)),
                  ))
                else
                  ...dayMeals.asMap().entries.map((entry) {
                    return _buildMealCard(entry.value, entry.key);
                  }).toList(),
              ],
            ),
          ),
        ],
      );
    },
  );
}

double _parseNum(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString()) ?? 0;
}

Widget _buildDailyProgress(
  double consumedCal, double targetCal,
  double consumedP, double targetP,
  double consumedC, double targetC,
  double consumedF, double targetF
) {
  return Card(
    elevation: 4,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // 總熱量大進度條
          _buildNutrientProgress("今日熱量 (kcal)", consumedCal, targetCal, Colors.teal, true),
          const Divider(height: 32),
          // 三大營養素小進度條
          Row(
            children: [
              Expanded(child: _buildNutrientProgress("蛋白質", consumedP, targetP, Colors.blue, false)),
              const SizedBox(width: 10),
              Expanded(child: _buildNutrientProgress("碳水", consumedC, targetC, Colors.green, false)),
              const SizedBox(width: 10),
              Expanded(child: _buildNutrientProgress("脂肪", consumedF, targetF, Colors.orange, false)),
            ],
          ),
        ],
      ),
    ),
  );
}

Widget _buildNutrientProgress(String label, double current, double target, Color color, bool isLarge) {
  double percent = target > 0 ? (current / target) : 0;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: isLarge ? 16 : 12, fontWeight: FontWeight.bold)),
          Text("${current.toStringAsFixed(0)} / ${target.toStringAsFixed(0)}${isLarge ? '' : 'g'}", 
               style: TextStyle(fontSize: isLarge ? 14 : 10)),
        ],
      ),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: LinearProgressIndicator(
          value: percent > 1.0 ? 1.0 : percent,
          minHeight: isLarge ? 12 : 6,
          backgroundColor: color.withOpacity(0.1),
          color: percent > 1.0 ? Colors.redAccent : color,
        ),
      ),
    ],
  );
}

Widget _buildProfileTab() {
  return SingleChildScrollView(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text("個人生理數據", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 20),
        TextField(controller: _ageController, decoration: const InputDecoration(labelText: "年齡"), keyboardType: TextInputType.number),
        TextField(controller: _weightController, decoration: const InputDecoration(labelText: "體重 (kg)"), keyboardType: TextInputType.number),
        TextField(controller: _heightController, decoration: const InputDecoration(labelText: "身高 (cm)"), keyboardType: TextInputType.number),
        const SizedBox(height: 20),
        const Text("性別"),
        Row(
          children: [
            Radio(value: 'male', groupValue: _gender, onChanged: (v) => setState(() => _gender = v.toString())), const Text("男"),
            Radio(value: 'female', groupValue: _gender, onChanged: (v) => setState(() => _gender = v.toString())), const Text("女"),
          ],
        ),
        const SizedBox(height: 20),
        const Text("每週運動量"),
        DropdownButton<double>(
          value: _activityLevel,
          isExpanded: true,
          items: const [
            DropdownMenuItem(value: 1.2, child: Text("久坐 (幾乎不運動)")),
            DropdownMenuItem(value: 1.375, child: Text("輕度 (每週運動 1-3 天)")),
            DropdownMenuItem(value: 1.55, child: Text("中度 (每週運動 3-5 天)")),
            DropdownMenuItem(value: 1.725, child: Text("高度 (每週運動 6-7 天)")),
          ],
          onChanged: (v) => setState(() => _activityLevel = v!),
        ),
        const Text("健身目標"),
        DropdownButton<String>(
          value: _goal,
          isExpanded: true,
          items: const [
            DropdownMenuItem(value: 'lose', child: Text("減脂 (減少熱量攝取)")),
            DropdownMenuItem(value: 'maintain', child: Text("維持體重")),
            DropdownMenuItem(value: 'gain', child: Text("增肌 (增加熱量攝取)")),
          ],
          onChanged: (v) => setState(() {
            _goal = v!;
            _calculateNutrientGoals();
          }),
        ),
        const SizedBox(height: 30),
        ElevatedButton(
          onPressed: _saveProfile, 
          style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white),
          child: const Text("儲存並計算營養目標")
        ),
        if (_tdee > 0) ...[
          const SizedBox(height: 30),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.teal.shade50, 
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.teal.shade200)
            ),
            child: Column(
              children: [
                const Text("每日總熱量消耗 (TDEE)", style: TextStyle(color: Colors.teal, fontWeight: FontWeight.w500)),
                Text("${_tdee.toStringAsFixed(0)} kcal", style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8.0),
                  child: Divider(),
                ),
                
                // 根據目標顯示最終建議攝取量
                Text(
                  _goal == 'lose' ? "🔥 減脂目標攝取" : 
                  _goal == 'gain' ? "💪 增肌目標攝取" : "⚖️ 維持體重攝取",
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.deepOrange)
                ),
                Text(
                  "${_targetCalories.toStringAsFixed(0)} kcal", 
                  style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.deepOrange)
                ),
                
                const SizedBox(height: 12),
                // 顯示三大營養素建議量
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildSimpleNutrientTag("蛋白質", "${_targetProtein.toStringAsFixed(0)}g"),
                    _buildSimpleNutrientTag("碳水", "${_targetCarbs.toStringAsFixed(0)}g"),
                    _buildSimpleNutrientTag("脂肪", "${_targetFat.toStringAsFixed(0)}g"),
                  ],
                )
              ],
            ),
          ),
        ]
      ],
    ),
  );
}

// 輔助：獲取今天日期
String _getTodayDate() {
  final now = DateTime.now();
  return "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
}

// 輔助：單個餐點卡片 (移除了跳轉邏輯，保持在當前頁面查看)

Widget _buildMealCard(FoodRecord record, int index) {
  // 確保數量預設至少為 1 (避免舊資料沒有 quantity 欄位)
  double currentQty = record.quantity <= 0 ? 1 : record.quantity;

  return Dismissible(
    key: Key(record.key.toString()),
    direction: DismissDirection.endToStart,
    background: Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      color: Colors.redAccent,
      child: const Icon(Icons.delete_forever, color: Colors.white, size: 28),
    ),
    confirmDismiss: (direction) async {
      return await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("刪除紀錄"),
          content: Text("確定要刪除「${record.dishName}」嗎？"),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("取消")),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("刪除", style: TextStyle(color: Colors.red))),
          ],
        ),
      );
    },
    onDismissed: (direction) async {
      await record.delete();
      setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("${record.dishName} 已刪除"), behavior: SnackBarBehavior.floating),
        );
      }
    },
    child: Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        onTap: () => _showEditDialog(record, index),
        leading: Container(
          width: 55,
          height: 55,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: Colors.blueGrey[50],
          ),
          child: (record.imageUrl != null && record.imageUrl!.isNotEmpty)
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    record.imageUrl!,
                    fit: BoxFit.cover,
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                    },
                    errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, color: Colors.grey),
                  ),
                )
              : const Icon(Icons.restaurant, color: Colors.blueGrey, size: 30),
        ),
        title: Text(
          record.dishName,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              "🔥卡路里: ${(record.totalCal * currentQty).toStringAsFixed(1)} kcal\n"
              "🥩蛋白質: ${(record.protein * currentQty).toStringAsFixed(1)}g | 🍞碳水化合物: ${(record.carbs * currentQty).toStringAsFixed(1)}g | 🥑脂肪: ${(record.fat * currentQty).toStringAsFixed(1)}g",
              style: TextStyle(color: Colors.blueGrey[600], height: 1.4, fontSize: 12),
            ),
            // ⭐ 新增數量調整器
            Row(
              children: [
                IconButton(
                  constraints: const BoxConstraints(),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.remove_circle_outline, size: 22, color: Colors.teal),
                  onPressed: () async {
                    if (record.quantity > 1) {
                      record.quantity -= 1;
                      await record.save();
                      setState(() {});
                    }
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Text(
                    "${currentQty.toInt()}",
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                IconButton(
                  constraints: const BoxConstraints(),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.add_circle_outline, size: 22, color: Colors.teal),
                  onPressed: () async {
                    record.quantity += 1;
                    await record.save();
                    setState(() {});
                  },
                ),
              ],
            ),
          ],
        ),
        // ⭐ 保留你原本的 Button 與時間顯示
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.edit_note, color: Colors.blueAccent),
            const SizedBox(height: 4),
            Text(
              "${record.dateTime.hour}:${record.dateTime.minute.toString().padLeft(2, '0')}",
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
    ),
  );
}

void _showEditDialog(FoodRecord record, int index) {
  final nameController = TextEditingController(text: record.dishName);
  final calController = TextEditingController(text: record.totalCal.toString());
  final proteinController = TextEditingController(text: record.protein.toString());
  final carbsController = TextEditingController(text: record.carbs.toString());
  final fatController = TextEditingController(text: record.fat.toString());

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text("修改紀錄"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: "食物名稱")),
            TextField(controller: calController, decoration: const InputDecoration(labelText: "卡路里"), keyboardType: TextInputType.number),
            TextField(controller: proteinController, decoration: const InputDecoration(labelText: "蛋白質 (g)"), keyboardType: TextInputType.number),
            TextField(controller: carbsController, decoration: const InputDecoration(labelText: "碳水 (g)"), keyboardType: TextInputType.number),
            TextField(controller: fatController, decoration: const InputDecoration(labelText: "脂肪 (g)"), keyboardType: TextInputType.number),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("取消")),
        ElevatedButton(
          onPressed: () async {
            // 更新物件屬性
            record.dishName = nameController.text;
            record.totalCal = double.tryParse(calController.text) ?? 0.0;
            record.protein = double.tryParse(proteinController.text) ?? 0.0;
            record.carbs = double.tryParse(carbsController.text) ?? 0.0;
            record.fat = double.tryParse(fatController.text) ?? 0.0;
            
            await record.save(); // HiveObject 的 save() 方法會自動更新 Box
            setState(() {}); 
            Navigator.pop(context);
          },
          child: const Text("儲存修改"),
        ),
      ],
    ),
  );
}

Widget _buildNutrientInfo(String label, String value, String unit, Color color) {
  return Column(
    children: [
      Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      const SizedBox(height: 4),
      RichText(
        text: TextSpan(
          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
          children: [
            TextSpan(text: value, style: TextStyle(fontSize: 16, color: color)),
            TextSpan(text: ' $unit', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.normal)),
          ],
        ),
      ),
    ],
  );
}

Widget _buildScannerTab() {
  return SingleChildScrollView(
    physics: const BouncingScrollPhysics(),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. 圖片預覽區域
        if (_imageData != null || _image != null) ...[
          GestureDetector(
            onTap: () => _showFullImage(context),
            child: Container(
              height: 300,
              decoration: BoxDecoration(
                color: Colors.black12,
                borderRadius: BorderRadius.circular(16),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: kIsWeb
                    ? Image.memory(_imageData!, fit: BoxFit.contain)
                    : Image.file(_image!, fit: BoxFit.contain),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text('💡 點擊圖片可查看全圖',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 20),
        ],

        // 2. 功能按鈕組 (多管道輸入)
        const Text("新增飲食紀錄",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        
        // 第一列：相機與相簿
        Row(
          children: [
            Expanded(
              child: _buildActionButton(
                icon: Icons.photo_library_outlined,
                label: "相簿選擇",
                color: Colors.blue,
                onPressed: _loading ? null : _pickImageFromGallery,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        
        // 第二列：雲端與手動
        Row(
          children: [
            Expanded(
              child: _buildActionButton(
                icon: Icons.manage_search, // 修正圖示名稱
                label: "雲端紀錄庫", 
                color: Colors.orange,
                onPressed: _loading ? null : _showCloudFoodPicker,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildActionButton(
                icon: Icons.border_color_outlined, // 手寫感圖示
                label: "自行輸入", 
                color: Colors.purple,
                onPressed: _loading ? null : _showManualAddDialog,
              ),
            ),
          ],
        ),

        // 3. Loading 狀態
        if (_loading) ...[
          const SizedBox(height: 30),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 10),
          const Text("AI 正在分析中...", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
        ],

        // 4. AI 辨識結果卡片
        if (_result != null && !_loading) ...[
          const SizedBox(height: 24),
          Card(
            elevation: 3,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text('${_result!['dish_name'] ?? '-'}',
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                      ),
                      const Icon(Icons.check_circle, color: Colors.green, size: 20),
                    ],
                  ),
                  const Divider(height: 20, thickness: 1),
                  _buildIngredientSection(),
                  if ((_result!['foods'] as List<dynamic>?)?.isNotEmpty ?? false)
                    const Divider(height: 20, thickness: 1),
                  _buildResultRow('總卡路里', '${_result!['total_calories'] ?? _result!['total_cal'] ?? '-'} kcal'),
                  _buildResultRow('總蛋白質', '${_result!['total_protein_g'] ?? _result!['total_protein'] ?? '-'} g'),
                  _buildResultRow('總碳水化合物', '${_result!['total_carbs_g'] ?? _result!['total_carbs'] ?? '-'} g'),
                  _buildResultRow('總脂肪', '${_result!['total_fat_g'] ?? _result!['total_fat'] ?? '-'} g'),
                ],
              ),
            ),
          ),
        ],

        const SizedBox(height: 40),
        const Text(
          'Powered by Gemini AI\nBy Joe',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey, fontSize: 12, fontStyle: FontStyle.italic),
        ),
      ],
    ),
  );
}

// 輔助組件：抽取重複的按鈕樣式
Widget _buildActionButton({
  required IconData icon,
  required String label,
  required Color color,
  required VoidCallback? onPressed,
}) {
  return ElevatedButton(
    onPressed: onPressed,
    style: ElevatedButton.styleFrom(
      backgroundColor: Colors.white,
      foregroundColor: color,
      elevation: 2,
      padding: const EdgeInsets.symmetric(vertical: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withOpacity(0.5)),
      ),
    ),
    child: Column(
      children: [
        Icon(icon, size: 28),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      ],
    ),
  );
}

  void _showFullImage(BuildContext context) {
  showDialog(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: Stack(
        alignment: Alignment.topRight,
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: SizedBox(
              width: double.infinity,
              height: double.infinity,
              child: kIsWeb 
                ? Image.memory(_imageData!, fit: BoxFit.contain)
                : Image.file(_image!, fit: BoxFit.contain),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 30),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    ),
  );
}

// 修改參數：將 FoodRecord 設為可選 (nullable)，增加 isNew 標記
// 暫時無用，保留以備未來手動新增功能使用
// Future<void> _updateRecordWithAI(FoodRecord? record, String description, {bool isNew = false}) async {
//   setState(() => _loading = true);

//   try {
//     // 1. 呼叫 Gemini 文字重新分析 (不管是更新還是手動新增，都用這支 API)
//     final newData = await _gemini.reanalyzeFoodByText(description);

//     if (isNew) {
//       // --- 模式 A：手動新增 (isNew == true) ---
//       final newRecord = FoodRecord(
//         dishName: newData['dish_name'] ?? description,
//         totalCal: _parseNum(newData['total_cal'] ?? newData['total_calories']),
//         dateTime: DateTime.now(),
//         rawJson: newData,
//         protein: _parseNum(newData['total_protein'] ?? newData['total_protein_g'] ?? newData['protein'] ?? 0),
//         carbs: _parseNum(newData['total_carbs'] ?? newData['total_carbs_g'] ?? newData['carbs'] ?? 0),
//         fat: _parseNum(newData['total_fat'] ?? newData['total_fat_g'] ?? newData['fat'] ?? 0),
//         imageUrl: null,
//       );

//       // 儲存到 Hive
//       final box = Hive.box<FoodRecord>('food_history');
//       await box.add(newRecord);
      
//       // (選配) 同步到 Firebase Firestore
//       // await _syncToCloud(newRecord); 

//       setState(() {
//         _result = newData; // 在辨識頁面顯示結果
//       });
      
//     } else if (record != null) {
//       // --- 模式 B：修正舊紀錄 (原本的長按邏輯) ---
//       setState(() {
//         record.dishName = newData['dish_name'] ?? description;
//         record.totalCal = _parseNum(newData['total_cal'] ?? newData['total_calories']);
//         record.rawJson = newData;
//       });
//       await record.save(); // HiveObject 內建的儲存方法
//     }

//     ScaffoldMessenger.of(context).showSnackBar(
//       SnackBar(content: Text(isNew ? '✅ 已新增紀錄' : '✅ 營養成分已更新')),
//     );
//   } catch (e) {
//     debugPrint('AI Update error: $e');
//     ScaffoldMessenger.of(context).showSnackBar(
//       const SnackBar(content: Text('❌ AI 分析失敗，請檢查網路')),
//     );
//   } finally {
//     setState(() => _loading = false);
//   }
// }

Widget _buildSimpleNutrientTag(String label, String value) {
  return Column(
    children: [
      Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
    ],
  );
}

// Future<void> _syncToCloud(FoodRecord record) async {
//   try {
//     // 取得當前 Firebase 登入的使用者
//     final user = FirebaseAuth.instance.currentUser;
//     if (user == null) {
//       debugPrint("使用者未登入，跳過雲端同步");
//       return;
//     }

//     await FirebaseFirestore.instance
//         .collection('users')
//         .doc(user.uid)
//         .collection('food_history')
//         .add({
//           'dish_name': record.dishName,
//           'total_cal': record.totalCal,
//           'date_time': record.dateTime.toIso8601String(),
//           'raw_json': record.rawJson,
//         });
//     debugPrint("雲端同步成功");
//   } catch (e) {
//     debugPrint("Cloud Sync Error: $e");
//   }
// }

// void _showCloudGallery() {
//   showModalBottomSheet(
//     context: context,
//     builder: (context) => StreamBuilder<QuerySnapshot>(
//       stream: FirebaseFirestore.instance.collection('cloud_photos').snapshots(),
//       builder: (context, snapshot) {
//         if (!snapshot.hasData) return const CircularProgressIndicator();
//         return GridView.builder(
//           gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3),
//           itemCount: snapshot.data!.docs.length,
//           itemBuilder: (context, index) {
//             String imageUrl = snapshot.data!.docs[index]['url'];
//             return GestureDetector(
//               onTap: () {
//                 Navigator.pop(context);
//                 _analyzeImageFromUrl(imageUrl); // 透過 URL 辨識
//               },
//               child: Image.network(imageUrl, fit: BoxFit.cover),
//             );
//           },
//         );
//       },
//     ),
//   );
// }

Future<void> _analyzeImageFromUrl(String url) async {
  setState(() => _loading = true);
  try {
    // 1. 將網路圖片轉為 Bytes
    final response = await HttpClient().getUrl(Uri.parse(url));
    final HttpClientRequest request = await response;
    final HttpClientResponse responseData = await request.close();
    final bytes = await consolidateHttpClientResponseBytes(responseData);

    setState(() {
      _imageData = bytes;
      _image = null; // 雲端圖片不佔用本地 File
    });

    // 2. 呼叫你現有的分析方法
    await _analyzeImageFromBytes(bytes);
    
  } catch (e) {
    debugPrint('Cloud image analysis error: $e');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('分析雲端圖片失敗')),
    );
  } finally {
    setState(() => _loading = false);
  }
}

// 請確保在檔案最上方有：import 'dart:convert';

void _showManualAddDialog() {
  final nameController = TextEditingController();
  final calController = TextEditingController();
  final proteinController = TextEditingController();
  final carbsController = TextEditingController();
  final fatController = TextEditingController();

  manualImageData = null;

  showDialog(
    context: context,
    barrierDismissible: false, 
    builder: (dialogContext) => StatefulBuilder( // 改名為 dialogContext 以區分
      builder: (context, setDialogState) {
        double screenWidth = MediaQuery.of(context).size.width;

        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
          title: const Text("手動新增飲食紀錄", style: TextStyle(fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: screenWidth * 0.9,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // --- 照片預覽區 (修正：限制高度與縮放方式) ---
                  GestureDetector(
                    onTap: () async {
                      final XFile? pickedFile = await _picker.pickImage(
                        source: ImageSource.gallery,
                        imageQuality: 50, // 降低品質減少 Base64 長度，避免 Cloud DB 爆炸
                      );
                      
                      if (pickedFile != null) {
                        final Uint8List bytes = await pickedFile.readAsBytes();
                        setDialogState(() {
                          manualImageData = bytes; 
                        });
                      }
                    },
                    child: Container(
                      height: 300, // 固定的預覽高度
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(16),
                        // ⭐ 加大邊框：粗細為 4.0
                        border: Border.all(
                          color: Colors.teal.shade300, 
                          width: 4.0, // 邊框粗細
                        ),
                      ),
                      child: manualImageData != null 
                      
                      ? Padding(
                          padding: const EdgeInsets.all(4.0), // ⭐ 內縮數值必須與邊框粗細 (width) 一致
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16), // 內層圓角需稍小，看起來才自然
                            child: Image.memory(
                              manualImageData!, 
                              fit: BoxFit.contain, // ⭐ 使用 cover 讓圖片完美填滿內圈且不變形
                            ),
                          ),
                        ) 
                      : const Center(child: Text("點擊加入照片", style: TextStyle(color: Colors.grey))),
                    ),
                  ),
                  const SizedBox(height: 20),

                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: "食物名稱", border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: calController,
                    decoration: const InputDecoration(labelText: "總卡路里 (kcal)", border: OutlineInputBorder()),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 16),
                  
                  const Align(alignment: Alignment.centerLeft, child: Text("詳細營養素 (g)", style: TextStyle(color: Colors.blueGrey, fontWeight: FontWeight.bold))),
                  const Divider(),

                  Row(
                    children: [
                      Expanded(child: TextField(controller: proteinController, decoration: const InputDecoration(labelText: "蛋白質"), keyboardType: TextInputType.number)),
                      const SizedBox(width: 8),
                      Expanded(child: TextField(controller: carbsController, decoration: const InputDecoration(labelText: "碳水"), keyboardType: TextInputType.number)),
                      const SizedBox(width: 8),
                      Expanded(child: TextField(controller: fatController, decoration: const InputDecoration(labelText: "脂肪"), keyboardType: TextInputType.number)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext), // 關鍵：使用正確的 context 關閉
              child: const Text("取消"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white),
              onPressed: () async {
                if (nameController.text.isEmpty) return;
                final navigator = Navigator.of(context, rootNavigator: true);

                // 準備數據
                final String? base64Image = manualImageData != null 
                    ? 'data:image/jpeg;base64,${base64Encode(manualImageData!)}' 
                    : null;

                final Map<String, dynamic> manualData = {
                  'dish_name': nameController.text,
                  'total_calories': double.tryParse(calController.text) ?? 0.0,
                  'total_protein_g': double.tryParse(proteinController.text) ?? 0.0,
                  'total_carbs_g': double.tryParse(carbsController.text) ?? 0.0,
                  'total_fat_g': double.tryParse(fatController.text) ?? 0.0,
                  'source': 'manual_input',
                };

                final newRecord = FoodRecord(
                  dishName: nameController.text,
                  totalCal: (manualData['total_calories'] as num).toDouble(),
                  dateTime: DateTime.now(),
                  rawJson: manualData,
                  protein: _parseNum(manualData['total_protein_g'] ?? 0),
                  carbs: _parseNum(manualData['total_carbs_g'] ?? 0),
                  fat: _parseNum(manualData['total_fat_g'] ?? 0),
                  imageUrl: base64Image,
                );

                // 1. 開啟 Loading
                setState(() => _isSaving = true);

                try {
                  // 2. 儲存到 Hive
                  debugPrint("正在儲存到 Hive...");
                  await Hive.box<FoodRecord>('food_history').add(newRecord);
                  debugPrint("✅ Hive 儲存成功");

                  // 3. 儲存到雲端 (最容易卡住的地方)
                  debugPrint("正在儲存到雲端 (Firestore)...");
                  // 設定超時或 catch 錯誤，防止這裡卡死導致無法 pop
                  await _uploadToPublicCloud(newRecord, base64Image).timeout(
                    const Duration(seconds: 5), 
                    onTimeout: () => debugPrint("⚠️ 雲端儲存超時，繼續執行關閉動作"),
                  );
                  debugPrint("✅ 雲端同步完成");

                } catch (e) {
                  // 如果雲端報錯，會跳到這裡
                  debugPrint("❌ 儲存過程發生錯誤: $e");
                  // 你可以在這裡決定是否要讓使用者知道錯誤，或是照樣關閉視窗
                }

                // 4. 更新 UI 與關閉視窗
                if (!mounted) {
                  debugPrint("⚠️ 元件已銷毀 (Not Mounted)，無法執行 pop");
                  return;
              }
        
                 setState(() { 
                  _isSaving = false;
                  _result = manualData; 
                  debugPrint("UI 已更新 (_result)");
                });

                debugPrint("正在執行 navigator.pop()...");
                navigator.pop(); 
                debugPrint("🚀 彈窗應已關閉");
                              
              },
              child: const Text("儲存並關閉"),
            ),
          ],
        );
      },
    ),
  );
}

String _searchQuery = ""; // 定義在 _HomeScreenState 中

void _showCloudFoodPicker() {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (context) => StatefulBuilder( // 讓搜尋列可以即時更新
      builder: (context, setModalState) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            // --- 搜尋列 ---
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                decoration: InputDecoration(
                  hintText: "搜尋雲端食物紀錄...",
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(30)),
                  filled: true,
                  fillColor: Colors.grey[100],
                ),
                onChanged: (val) {
                  setModalState(() => _searchQuery = val.toLowerCase());
                },
              ),
            ),
            
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance.collection('public_foods').snapshots(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                  
                  // 在本地端做簡單過濾（Firestore 的複合查詢較複雜，初期建議先這樣做）
                  final docs = snapshot.data!.docs.where((doc) {
                    final name = (doc['dish_name'] as String).toLowerCase();
                    return name.contains(_searchQuery);
                  }).toList();

                  return ListView.builder(
                    controller: scrollController,
                    itemCount: docs.length,
                    itemBuilder: (context, index) {
                      final data = docs[index].data() as Map<String, dynamic>;
                      return ListTile(
                        leading: Container(
                          width: 50, height: 50,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),

                            color: Colors.grey[300],
                          ),
                          child: const Icon(Icons.fastfood, color: Colors.white),
                        ),
                        title: Text(data['dish_name']),
                        subtitle: Text("${data['total_cal']} kcal"),
                        onTap: () async{

                          setState(() => _isSaving = true);
                          try {

                            final Map<String, dynamic> processedData = Map.from(data).map((key, value) {
                              if (value is Timestamp) {
                                return MapEntry(key, value.toDate()); // 將 Timestamp 轉為 DateTime
                              }
                              return MapEntry(key, value);
                            });
                            // 2. 解析資料 (使用多重檢查確保抓得到營養素)
                            double p = _parseNum(processedData['total_protein'] ?? processedData['protein'] ?? 0);
                            double c = _parseNum(processedData['total_carbs'] ?? processedData['carbs'] ?? 0);
                            double f = _parseNum(processedData['total_fat'] ?? processedData['fat'] ?? 0);
                            double cal = _parseNum(processedData['total_cal'] ?? processedData['total_calories'] ?? 0);

                            // 3. 建立 FoodRecord
                            final newRecord = FoodRecord(
                              dishName: processedData['dish_name'] ?? '未命名食物',
                              totalCal: cal,
                              protein: p,
                              carbs: c,
                              fat: f,
                              dateTime: DateTime.now(), // 這是存入本地的時間
                              rawJson: processedData,    // 這裡使用的是處理過（無 Timestamp）的 Map
                              imageUrl: processedData['image_url'],
                            );

                            // 4. 儲存到本地 Hive
                            final box = Hive.box<FoodRecord>('food_history');
                            await box.add(newRecord);

                            // 5. 提示使用者成功
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text("已將「${newRecord.dishName}」加入歷史紀錄")),
                              );
                            }
                          } catch (e) {
                            debugPrint("從雲端加入失敗: $e");
                          } finally {
                            // 6. 結束 Loading 並關閉雲端清單視窗
                            if (mounted) {
                              setState(() => _isSaving = false);
                              Navigator.pop(context); // 關閉 Picker
                            }
                          }
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _uploadToPublicCloud(FoodRecord record, String? imageUrl) async {
  try {
    await FirebaseFirestore.instance.collection('public_foods').add({
      'dish_name': record.dishName,
      'total_cal': record.totalCal,
      // ⭐ 確保這裡使用的 Key 與你 FoodRecord 解析時一致
      'total_protein': record.protein, 
      'total_carbs': record.carbs,
      'total_fat': record.fat,
      'image_url': imageUrl, 
      'created_at': FieldValue.serverTimestamp(),
    });
  } catch (e) {
    debugPrint("上傳公有雲失敗: $e");
  }
}

Widget _buildWeeklyHeader() {
  // 根據 _focusedWeekDate 生成該週的 7 天 (例如從 _focusedWeekDate 往前推 6 天)
  List<DateTime> days = List.generate(7, (index) {
    return _focusedWeekDate.subtract(Duration(days: 6 - index));
  });

  // 判斷右箭頭是否禁用 (如果當前週的最後一天已經是今天或以後)
  bool canGoNextWeek = _focusedWeekDate.isBefore(
    DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day)
  );

  return Container(
    padding: const EdgeInsets.symmetric(vertical: 12),
    color: Colors.white,
    child: Column(
      children: [
        // 年份月份顯示 + 左右換週按鈕
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: () {
                setState(() {
                  _focusedWeekDate = _focusedWeekDate.subtract(const Duration(days: 7));
                  // 可選：切換週時，自動選中那一週的最後一天
                  _selectedDate = _focusedWeekDate; 
                });
              },
            ),
            Text(
              "${_focusedWeekDate.year}年 ${_focusedWeekDate.month}月",
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            IconButton(
              icon: Icon(
                Icons.chevron_right,
                color: canGoNextWeek ? Colors.black : Colors.grey.shade300,
              ),
              onPressed: () {
                if (!canGoNextWeek) return;
                setState(() {
                  DateTime nextWeek = _focusedWeekDate.add(const Duration(days: 7));
                  // 確保不會超過今天
                  if (nextWeek.isAfter(DateTime.now())) {
                    _focusedWeekDate = DateTime.now();
                  } else {
                    _focusedWeekDate = nextWeek;
                  }
                  _selectedDate = _focusedWeekDate;
                });
              },
            ),
          ],
        ),
        const SizedBox(height: 10),
        
        // 橫向週 UI
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: days.map((date) {
              bool isSelected = _formatDate(date) == _formatDate(_selectedDate);
              bool isToday = _formatDate(date) == _formatDate(DateTime.now());
              bool isFuture = date.isAfter(DateTime.now());

              return GestureDetector(
                onTap: () {
                  if (isFuture) return; // 依舊不能選未來
                  setState(() => _selectedDate = date);
                },
                child: Container(
                  width: 50,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: isSelected ? Colors.teal : Colors.transparent,
                    borderRadius: BorderRadius.circular(15),
                    border: isToday && !isSelected 
                        ? Border.all(color: Colors.teal, width: 1) 
                        : null,
                  ),
                  child: Column(
                    children: [
                      Text(
                        _getWeekdayName(date.weekday),
                        style: TextStyle(
                          color: isSelected ? Colors.white : (isFuture ? Colors.grey : Colors.black54),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        date.day.toString(),
                        style: TextStyle(
                          color: isSelected ? Colors.white : (isFuture ? Colors.grey : Colors.black),
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    ),
  );
}

// 輔助方法：獲取星期名稱
String _getWeekdayName(int weekday) {
  const names = {1: '一', 2: '二', 3: '三', 4: '四', 5: '五', 6: '六', 7: '日'};
  return names[weekday] ?? '';
}

Widget _buildLoadingOverlay() {
  if (!_isSaving) return const SizedBox.shrink();
  return Container(
    color: Colors.black54, // 半透明背景
    child: const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 16),
          Text("正在儲存紀錄並同步雲端...", 
               style: TextStyle(color: Colors.white, fontSize: 16)),
        ],
      ),
    ),
  );
}

String uint8ListToBase64(Uint8List bytes) {
  // 將二進位數據轉為 Base64 字串
  return base64Encode(bytes);
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentIndex == 0 ? 'AI 食物營養分析' : '歷史紀錄'),
        centerTitle: true,
      ),
      // Switch between the Scanner view and the History view
      body: Stack(
      children: [
        IndexedStack(
          index: _currentIndex,
          children: [
            _buildScannerTab(),
            _buildHistoryTab(),
            _buildProfileTab(),
          ],
        ),
        _buildLoadingOverlay(), // 放在後面，才會蓋在內容上
      ],
    ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.bakery_dining), label: '辨識'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: '紀錄'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: '個人'),
        ],
      ),
    );
  }
}