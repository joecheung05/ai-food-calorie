import 'package:hive/hive.dart';

part 'food_record.g.dart';

@HiveType(typeId: 0)
class FoodRecord extends HiveObject {
  @HiveField(0)
  String dishName;

  @HiveField(1)
  double totalCal;

  @HiveField(2)
  DateTime dateTime;

  @HiveField(3)
  Map<String, dynamic> rawJson;

  // ⭐ 新增以下欄位
  @HiveField(4)
  double protein;

  @HiveField(5)
  double fat;

  @HiveField(6)
  double carbs; // 建議連碳水也一起加上，營養紀錄才完整

  @HiveField(7)
  String? imageUrl; // 儲存 Firebase Storage 的圖片網址

  @HiveField(8)
  double quantity;

  FoodRecord({
    required this.dishName,
    required this.totalCal,
    required this.dateTime,
    required this.rawJson,
    this.protein = 0.0, // 給予預設值
    this.fat = 0.0,
    this.carbs = 0.0,
    this.imageUrl,
    this.quantity = 1.0,
  });
}