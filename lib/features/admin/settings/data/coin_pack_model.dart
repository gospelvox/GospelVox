// Coin pack data model

class CoinPackModel {
  final String id;
  final int coins;
  final int price;
  final String label;
  final int order;
  final bool isPopular;
  final bool isActive;

  const CoinPackModel({
    required this.id,
    required this.coins,
    required this.price,
    required this.label,
    required this.order,
    required this.isPopular,
    required this.isActive,
  });

  double get pricePerCoin => coins > 0 ? price / coins : 0;
  int get oldPrice => ((coins * 1.5) / 100).ceil() * 100;
  int get discountPercent =>
      oldPrice > 0 ? (((oldPrice - price) / oldPrice) * 100).round() : 0;

  factory CoinPackModel.fromFirestore(
      String docId, Map<String, dynamic> data) {
    return CoinPackModel(
      id: docId,
      coins: (data['coins'] as num?)?.toInt() ?? 0,
      price: (data['price'] as num?)?.toInt() ?? 0,
      label: data['label'] as String? ?? '',
      order: (data['order'] as num?)?.toInt() ?? 0,
      isPopular: data['isPopular'] as bool? ?? false,
      isActive: data['isActive'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toFirestore() => {
        'coins': coins,
        'price': price,
        'label': label,
        'order': order,
        'isPopular': isPopular,
        'isActive': isActive,
      };

  CoinPackModel copyWith({
    String? id,
    int? coins,
    int? price,
    String? label,
    int? order,
    bool? isPopular,
    bool? isActive,
  }) =>
      CoinPackModel(
        id: id ?? this.id,
        coins: coins ?? this.coins,
        price: price ?? this.price,
        label: label ?? this.label,
        order: order ?? this.order,
        isPopular: isPopular ?? this.isPopular,
        isActive: isActive ?? this.isActive,
      );
}
