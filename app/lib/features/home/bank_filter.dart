import '../../data/database.dart';

/// One choice of the bank filter on the wrong-book and favourites lists.
class BankOption {
  const BankOption({required this.id, required this.name, required this.count});

  final String id;
  final String name;
  final int count;

  @override
  bool operator ==(Object other) => other is BankOption && other.id == id && other.name == name && other.count == count;

  @override
  int get hashCode => Object.hash(id, name, count);

  @override
  String toString() => 'BankOption($id, $name, $count)';
}

/// Shown for questions whose bank this device no longer knows (deleted on the server).
const unknownBank = '已删除的题库';

/// The banks that have questions among [items], with how many, in the order of [banks] (banks the device
/// no longer lists come last, under a stand-in name; their questions stay reachable).
List<BankOption> bankOptions(List<Question> items, List<Bank> banks) {
  final count = <String, int>{};
  for (final q in items) {
    count[q.bankId] = (count[q.bankId] ?? 0) + 1;
  }
  final out = <BankOption>[];
  for (final b in banks) {
    final n = count.remove(b.id);
    if (n != null) out.add(BankOption(id: b.id, name: b.title, count: n));
  }
  final rest = count.keys.toList()..sort();
  for (final id in rest) {
    out.add(BankOption(id: id, name: unknownBank, count: count[id]!));
  }
  return out;
}

/// [items] of one bank, or all of them when [bankId] is empty.
List<Question> inBank(List<Question> items, String bankId) =>
    bankId.isEmpty ? items : [for (final q in items) if (q.bankId == bankId) q];
