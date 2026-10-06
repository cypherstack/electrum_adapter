/// notice that get_transaction.dart is tightly coupled to the datastructure of
/// of the electrum server. this has pros and cons, but currently we would only
/// use it to get the memo from a transaction, thus, I added this code to
/// accomplish only that.

import 'package:electrum_adapter/electrum_adapter.dart';

/// https://github.com/moontreeapp/moontree/issues/5
/// we assume one transaction can only have one OP_RETURN
@Deprecated('Use memoFromScript: asm shows a push of four bytes or fewer as '
    'a decimal number, and a bare OP_RETURN throws a RangeError here.')
String parseAsmForMemo(String asm) {
  var x = asm.split(' ');
  var i = 0;
  for (var item in x) {
    if (item == 'OP_RETURN') return x[i + 1];
    i = i + 1;
  }
  return '';
}

/// Returns the data pushed after OP_RETURN in the script [hex], as hex: ''
/// for a bare OP_RETURN, and the byte pushed by OP_1NEGATE or OP_1 to OP_16,
/// such as '0a' for OP_10. Returns null when [hex] is not hex, the script is
/// not an OP_RETURN script, what follows is not a push, or the push is cut
/// short.
///
/// Reads the hex rather than the script's asm, which shows a push of four
/// bytes or fewer as a decimal number.
String? memoFromScript(String hex) {
  if (!RegExp(r'^(?:[0-9a-fA-F]{2})*$').hasMatch(hex)) return null;
  final bytes = [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16)
  ];
  const opReturn = 0x6a;
  if (bytes.isEmpty || bytes[0] != opReturn) return null;
  if (bytes.length == 1) return '';
  final int start;
  final int length;
  switch (bytes[1]) {
    case final op when op <= 0x4b: // push of op bytes
      start = 2;
      length = op;
    case 0x4c when bytes.length >= 3: // OP_PUSHDATA1
      start = 3;
      length = bytes[2];
    case 0x4d when bytes.length >= 4: // OP_PUSHDATA2
      start = 4;
      length = bytes[2] | bytes[3] << 8;
    case 0x4e when bytes.length >= 6: // OP_PUSHDATA4
      start = 6;
      length = bytes[2] | bytes[3] << 8 | bytes[4] << 16 | bytes[5] << 24;
    case 0x4f: // OP_1NEGATE pushes -1, the byte 0x81
      return '81';
    case final op when op >= 0x51 && op <= 0x60: // OP_1 to OP_16
      return (op - 0x50).toRadixString(16).padLeft(2, '0');
    default:
      return null;
  }
  if (start + length > bytes.length) return null;
  return hex.substring(start * 2, (start + length) * 2);
}

extension GetMemoMethod on RavenElectrumClient {
  Future<String> getMemo(String txHash) async {
    var response = Map<String, dynamic>.from((await request(
      'blockchain.transaction.get',
      [txHash, true],
    )) as Map);
    if (response.keys.contains('vout')) {
      for (var vout in response['vout'] as List) {
        var memo = memoFromScript(vout['scriptPubKey']['hex'] as String);
        if (memo != null && memo.isNotEmpty) {
          return memo;
        }
      }
    }
    return '';
  }

  /// returns memos in the same order as txHashes passed in
  Future<List<String>> getMemos(List<String> txids) async {
    var futures = <Future<String>>[];
    if (txids.isNotEmpty) {
      peer.withBatch(() {
        for (var txid in txids) {
          futures.add(getMemo(txid));
        }
      });
    }
    List<String> results = await Future.wait<String>(futures);
    return results;
  }
}
