import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';

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

  final GeminiService _gemini = GeminiService();
  final ImagePicker _picker = ImagePicker();
  Map<String, dynamic>? _result;
  bool _loading = false;
  File? _image;
  Uint8List? _imageData;
  double _tdee = 0;
// 控制項
final TextEditingController _ageController = TextEditingController();
final TextEditingController _weightController = TextEditingController();
final TextEditingController _heightController = TextEditingController();
String _gender = 'male';
double _activityLevel = 1.2; // 預設久坐

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
    _calculateTDEE();
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
  _calculateTDEE();
  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('資料已儲存')));
}

  Future<void> _analyzeImageFromBytes(Uint8List bytes) async {
  setState(() => _loading = true);

  
  try {
    final data = await _gemini.analyzeFoodImage(bytes);
    setState(() => _result = data);

    // --- SAVE TO HIVE ---
    final box = Hive.box<FoodRecord>('food_history');
    final newRecord = FoodRecord(
      dishName: data['dish_name'] ?? '未知菜餚',
      totalCal: (data['total_cal'] ?? data['total_calories'] ?? 0).toDouble(),
      dateTime: DateTime.now(),
      rawJson: data,
    );
    await box.add(newRecord); 
    // --------------------

  } catch (e) {
    // ... existing error handling
  } finally {
    setState(() => _loading = false);
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

  Widget _buildResultRow(String title, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
          Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
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
      final allRecords = box.values.toList().reversed.toList();
      final groupedRecords = _groupRecordsByDate(allRecords);
      final dates = groupedRecords.keys.toList();

      if (allRecords.isEmpty) {
        return const Center(child: Text("暫無歷史紀錄", style: TextStyle(color: Colors.grey)));
      }


      double todayConsumed = 0;
      final todayStr = _getTodayDate();
      if (groupedRecords.containsKey(todayStr)) {
        for (var r in groupedRecords[todayStr]!) {
          // 這裡使用兼容性讀取 Key，防止顯示 0
          final json = r.rawJson;
          todayConsumed += (r.rawJson['total_cal'] ?? r.rawJson['total_calories'] ?? 0).toDouble();
        }
      }

      if (dates.isEmpty) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildDailyProgress(todayConsumed, _tdee),
            const SizedBox(height: 100),
            const Center(child: Text("目前沒有任何飲食紀錄", style: TextStyle(color: Colors.grey))),
          ],
        );
      }

      

      return ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: dates.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _buildDailyProgress(todayConsumed, _tdee);
          }

          final dateIndex = index - 1;
          if (dateIndex >= dates.length) return const SizedBox.shrink();

          String date = dates[dateIndex];
          List<FoodRecord> dayMeals = groupedRecords[date] ?? [];

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 日期標題
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Row(
                  children: [
                    Container(
                      width: 4,
                      height: 18,
                      decoration: BoxDecoration(
                        color: Colors.teal,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      date == _getTodayDate() ? "今天 ($date)" : date,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.teal),
                    ),
                  ],
                ),
              ),
              // 該日期的餐點清單
              ...dayMeals.map((record) => _buildMealCard(record)).toList(),
              const SizedBox(height: 16),
            ],
          );
        },
      );
    },
  );
}

Widget _buildDailyProgress(double consumed, double target) {
  double percent = target > 0 ? (consumed / target) : 0;
  Color progressColor = percent > 1.0 ? Colors.red : Colors.teal;

  return Card(
    color: Colors.white,
    margin: const EdgeInsets.only(bottom: 20),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("今日熱量進度", style: TextStyle(fontWeight: FontWeight.bold)),
              Text("${consumed.toStringAsFixed(0)} / ${target.toStringAsFixed(0)} kcal"),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: percent > 1.0 ? 1.0 : percent,
            backgroundColor: Colors.grey.shade200,
            color: progressColor,
            minHeight: 10,
          ),
          if (percent > 1.0) 
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text("⚠️ 已超過今日目標！", style: TextStyle(color: Colors.red, fontSize: 12)),
            )
        ],
      ),
    ),
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
        const SizedBox(height: 30),
        ElevatedButton(onPressed: _saveProfile, child: const Text("儲存並計算 TDEE")),
        if (_tdee > 0) ...[
          const SizedBox(height: 30),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: Colors.teal.shade50, borderRadius: BorderRadius.circular(12)),
            child: Column(
              children: [
                const Text("您的每日總熱量消耗 (TDEE)"),
                Text("${_tdee.toStringAsFixed(0)} kcal", style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.teal)),
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
Widget _buildMealCard(FoodRecord record) {
  final json = record.rawJson;
  final timeStr = "${record.dateTime.hour.toString().padLeft(2, '0')}:${record.dateTime.minute.toString().padLeft(2, '0')}";

  // 核心修正：加入多種可能的 Key 讀取邏輯
  // 優先讀取總計欄位，如果沒有則顯示 0
  final cal = json['total_cal'] ?? json['total_calories'] ?? 0;
  final protein = json['total_protein'] ?? json['total_protein_g'] ?? 0;
  final carbs = json['total_carbs'] ?? json['total_carbs_g'] ?? 0;
  final fat = json['total_fat'] ?? json['total_fat_g'] ?? 0;

  return Card(
    margin: const EdgeInsets.only(bottom: 10),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: ExpansionTile(
      leading: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(timeStr, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
      title: Text(record.dishName, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text("$cal kcal"), // 顯示總卡路里
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
        onPressed: () => record.delete(),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // 這裡會正確顯示數值了
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildNutrientInfo('蛋白質', '$protein', 'g', Colors.blue),
                  _buildNutrientInfo('碳水', '$carbs', 'g', Colors.green),
                  _buildNutrientInfo('脂肪', '$fat', 'g', Colors.orange),
                ],
              ),
              const Divider(height: 24),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text("食材組成：", style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: (json['foods'] as List? ?? []).map((f) => Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(f['name'] ?? '', style: const TextStyle(fontSize: 11)),
                  backgroundColor: Colors.teal.withOpacity(0.05),
                )).toList(),
              )
            ],
          ),
        )
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
              if (_imageData != null || _image != null) ...[
                GestureDetector(
                  onTap: () => _showFullImage(context), // 點擊放大
                  child: Container(
                    height: 350, // 增加高度
                    decoration: BoxDecoration(
                      color: Colors.black12,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      // 改用 contain 確保圖片不被裁切
                      child: kIsWeb 
                        ? Image.memory(_imageData!, fit: BoxFit.contain)
                        : Image.file(_image!, fit: BoxFit.contain),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text('💡 點擊圖片可查看全圖', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 20),
              ],

              ElevatedButton.icon(
                onPressed: _loading ? null : _pickImageFromGallery,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('從相簿選擇圖片'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),

              if (_loading) ...[
                const SizedBox(height: 20),
                const Center(child: CircularProgressIndicator()),
              ],

              if (_result != null) ...[
                const SizedBox(height: 24),
                Card(
                  elevation: 3,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${_result!['dish_name'] ?? '-'}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                        const Divider(height: 20, thickness: 1),
                        _buildIngredientSection(),
                        if ((_result!['foods'] as List<dynamic>?)?.isNotEmpty ?? false) const Divider(height: 20, thickness: 1),
                        _buildResultRow('總卡路里', '${_result!['total_calories'] ?? _result!['total_cal'] ?? '-'} kcal'),
                        _buildResultRow('總蛋白質', '${_result!['total_protein_g'] ?? _result!['total_protein'] ?? '-'} g'),
                        _buildResultRow('總碳水化合物', '${_result!['total_carbs_g'] ?? _result!['total_carbs'] ?? '-'} g'),
                        _buildResultRow('總脂肪', '${_result!['total_fat_g'] ?? _result!['total_fat'] ?? '-'} g'),
                      ],
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 20),
              const Text(
                'By Joe\n\n',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 14, fontStyle: FontStyle.italic),
              ),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentIndex == 0 ? 'AI 食物營養分析' : '歷史紀錄'),
        centerTitle: true,
      ),
      // Switch between the Scanner view and the History view
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _buildScannerTab(),
          _buildHistoryTab(),
          _buildProfileTab(),
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