import 'package:hive/hive.dart';

part 'food_record.g.dart'; // This will be generated

@HiveType(typeId: 0)
class FoodRecord extends HiveObject {
  @HiveField(0)
  final String dishName;

  @HiveField(1)
  final double totalCal;

  @HiveField(2)
  final DateTime dateTime;

  @HiveField(3)
  final Map<String, dynamic> rawJson; // Store the full response

  FoodRecord({
    required this.dishName,
    required this.totalCal,
    required this.dateTime,
    required this.rawJson,
  });
}