import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:image_picker/image_picker.dart';

import 'services/gemini_service.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
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
  final GeminiService _gemini = GeminiService();
  final ImagePicker _picker = ImagePicker();
  Map<String, dynamic>? _result;
  bool _loading = false;
  File? _image;
  Uint8List? _imageData;

  Future<void> _analyzeImageFromBytes(Uint8List bytes) async {
    setState(() => _loading = true);

    try {
      final data = await _gemini.analyzeFoodImage(bytes);
      setState(() => _result = data);
    } catch (e) {
      final errorMsg = e.toString();
      debugPrint('錯誤: $errorMsg');
      final displayMsg = errorMsg.contains('已達免費額度')
          ? '已達免費額度，請稍後重試或升級配額。'
          : '分析圖片時發生錯誤';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(displayMsg)),
      );
    } finally {
      setState(() => _loading = false);
    }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 食物營養分析'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_imageData != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.memory(_imageData!, height: 260, fit: BoxFit.cover),
                ),
                const SizedBox(height: 20),
              ] else if (_image != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.file(_image!, height: 260, fit: BoxFit.cover),
                ),
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
        ),
      ),
    );
  }
}
