// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'food_record.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class FoodRecordAdapter extends TypeAdapter<FoodRecord> {
  @override
  final int typeId = 0;

  @override
  FoodRecord read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return FoodRecord(
      dishName: fields[0] as String,
      totalCal: fields[1] as double,
      dateTime: fields[2] as DateTime,
      rawJson: (fields[3] as Map).cast<String, dynamic>(),
    );
  }

  @override
  void write(BinaryWriter writer, FoodRecord obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.dishName)
      ..writeByte(1)
      ..write(obj.totalCal)
      ..writeByte(2)
      ..write(obj.dateTime)
      ..writeByte(3)
      ..write(obj.rawJson);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FoodRecordAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
