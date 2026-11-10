import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial_plus/flutter_bluetooth_serial_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const FazlakaApp());

const petrol = Color(0xFF0A3D3E);
const bgColor = Color(0xFFDFF5F2);

int daysForProfile(String p) {
  if (p == '20') return 3;
  if (p == '50') return 15;
  if (p == '100') return 30;
  if (p == '200') return 30;
  return 30;
}
String quotaFor(String p) => p == '20' ? '2' : p == '50' ? '8' : p == '100' ? '20' : p == '200' ? '45' : '2';
String bytesFor(String p) => p == '20' ? '2147483648' : p == '50' ? '8589934592' : p == '100' ? '21474836480' : p == '200' ? '48318382080' : '2147483648';

int parseTime(String s) {
  if (s.isEmpty) return 0;
  if (s.contains(':')) {
    int days = 0;
    String rest = s;
    if (s.contains('d')) {
      final parts = s.split('d');
      days = int.tryParse(parts[0]) ?? 0;
      rest = parts.length > 1 ? parts[1] : '0:0:0';
    }
    final p = rest.split(':');
    int h = 0, m = 0, sec = 0;
    if (p.length == 3) { h = int.tryParse(p[0]) ?? 0; m = int.tryParse(p[1]) ?? 0; sec = int.tryParse(p[2]) ?? 0; }
    else if (p.length == 2) { m = int.tryParse(p[0]) ?? 0; sec = int.tryParse(p[1]) ?? 0; }
    return days * 86400 + h * 3600 + m * 60 + sec;
  }
  int total = 0;
  final reg = RegExp(r'(\d+)([dhms])');
  for (final m in reg.allMatches(s)) {
    final v = int.tryParse(m.group(1) ?? '0') ?? 0;
    final u = m.group(2);
    if (u == 'd') total += v * 86400;
    if (u == 'h') total += v * 3600;
    if (u == 'm') total += v * 60;
    if (u == 's') total += v;
  }
  if (total == 0) total = int.tryParse(s) ?? 0;
  return total;
}

class MikroTikApi {
  Socket? _socket;
  List<int> _buf = [];
  Future<List<Map<String,String>>> run(String host, String user, String pass, String cmd, [List<String> args = const []]) async {
    _socket = await Socket.connect(host, 8728, timeout: const Duration(seconds: 5));
    _socket!.listen((d) { _buf.addAll(d); });
    final chalHex = await _loginStep(user);
    List<int> hexToBytes(String hex) {
      final out = <int>[];
      for (int i = 0; i < hex.length; i += 2) out.add(int.parse(hex.substring(i, i + 2), radix: 16));
      return out;
    }
    final respHash = md5.convert([0, ...utf8.encode(pass), ...hexToBytes(chalHex)]).toString();
    await _send(['/login', '=name=$user', '=response=00$respHash']);
    final loginRes = await _readSentence();
    if (loginRes.any((m) => m['__type__'] == '!trap')) throw Exception('login failed');
    await _send([cmd, ...args]);
    return _readAll();
  }
  Future<String> _loginStep(String user) async {
    await _send(['/login', '=name=$user']);
    final res = await _readSentence();
    for (final m in res) { if (m.containsKey('ret')) return m['ret']!; }
    throw Exception('no challenge');
  }
  Future<void> _send(List<String> words) async {
    final out = <int>[];
    for (final w in words) {
      final b = utf8.encode(w);
      if (b.length < 0x80) { out.add(b.length); }
      else if (b.length < 0x4000) { out.add(0x80 | (b.length >> 8)); out.add(b.length & 0xFF); }
      else { out.add(0xC0 | (b.length >> 16)); out.add((b.length >> 8) & 0xFF); out.add(b.length & 0xFF); }
      out.addAll(b);
    }
    out.add(0);
    _socket!.add(out);
    await _socket!.flush();
  }
  Future<List<Map<String,String>>> _readSentence() async {
    while (true) {
      final parsed = _tryParse();
      if (parsed != null) return parsed;
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }
  Future<List<Map<String,String>>> _readAll() async {
    final all = <Map<String,String>>[];
    while (true) {
      final s = await _readSentence();
      all.addAll(s);
      if (s.any((m) => m['__type__'] == '!done')) break;
    }
    return all;
  }
  List<Map<String,String>>? _tryParse() {
    int pos = 0;
    final result = <Map<String,String>>[];
    var cur = <String,String>{};
    while (pos < _buf.length) {
      int len = _buf[pos]; pos++;
      if (len == 0) {
        if (cur.isNotEmpty) { result.add(cur); cur = <String,String>{}; }
        _buf = _buf.sublist(pos);
        return result;
      }
      if ((len & 0x80) != 0) {
        if ((len & 0xC0) == 0x80) { if (pos >= _buf.length) return null; len = ((len & 0x3F) << 8) | _buf[pos]; pos++; }
        else if ((len & 0xE0) == 0xC0) { if (pos + 1 >= _buf.length) return null; len = ((len & 0x1F) << 16) | (_buf[pos] << 8) | _buf[pos+1]; pos += 2; }
        else return null;
      }
      if (pos + len > _buf.length) return null;
      final word = utf8.decode(_buf.sublist(pos, pos + len), allowMalformed: true);
      pos += len;
      if (word.startsWith('!')) { if (cur.isNotEmpty) { result.add(cur); cur = <String,String>{}; } cur['__type__'] = word; }
      else if (word.startsWith('=')) {
        final eq = word.indexOf('=', 1);
        if (eq > 0) cur[word.substring(1, eq)] = word.substring(eq + 1);
      } else if (word.startsWith('.')) {
        final eq = word.indexOf('=');
        if (eq > 0) cur[word.substring(0, eq)] = word.substring(eq + 1);
      }
    }
    return null;
  }
}

bool isExpiredReal(Map<String,String> u) {
  final profile = u['profile'] ?? '';
  final days = daysForProfile(profile);
  final comment = u['comment'] ?? '';
  if (comment.contains('created:')) {
    try {
      final dateStr = comment.split('created:')[1].split(' ')[0].split('|')[0].trim();
      final created = DateTime.parse(dateStr);
      final now = DateTime.now();
      final diffDays = now.difference(created).inDays;
      if (diffDays >= days) return true;
      return false;
    } catch (_) {}
  }
  final limitTime = u['limit-uptime'] ?? '';
  final up = u['uptime'] ?? '';
  if (limitTime.isNotEmpty) {
    final limitSec = parseTime(limitTime);
    final upSec = parseTime(up);
    if (limitSec > 0 && upSec >= limitSec) return true;
  }
  final limitBytesStr = u['limit-bytes-total'] ?? '';
  if (limitBytesStr.isNotEmpty) {
    final limitBytes = int.tryParse(limitBytesStr) ?? 0;
    final inBytes = int.tryParse(u['bytes-in'] ?? '0') ?? 0;
    final outBytes = int.tryParse(u['bytes-out'] ?? '0') ?? 0;
    if (limitBytes > 0 && (inBytes + outBytes) >= limitBytes) return true;
  }
  return false;
}

int remainingDays(Map<String,String> u) {
  final profile = u['profile'] ?? '';
  final days = daysForProfile(profile);
  final comment = u['comment'] ?? '';
  if (comment.contains('created:')) {
    try {
      final dateStr = comment.split('created:')[1].split(' ')[0].split('|')[0].trim();
      final created = DateTime.parse(dateStr);
      final diff = DateTime.now().difference(created).inDays;
      final left = days - diff;
      return left < 0 ? 0 : left;
    } catch (_) { return days; }
  }
  return days;
}

Future<int> disableExpiredUsers(String host, String user, String pass) async {
  int disabled = 0;
  try {
    final users = await MikroTikApi().run(host, user, pass, '/ip/hotspot/user/print');
    for (final u in users) {
      if (!isExpiredReal(u)) continue;
      if ((u['disabled'] ?? 'false') == 'true') continue;
      final id = u['.id'] ?? '';
      if (id.isNotEmpty) {
        await MikroTikApi().run(host, user, pass, '/ip/hotspot/user/set', ['=numbers=$id', '=disabled=yes']);
        disabled++;
      }
    }
  } catch (_) {}
  return disabled;
}

Future<int> deleteDisabledUsers(String host, String user, String pass) async {
  int deleted = 0;
  try {
    final users = await MikroTikApi().run(host, user, pass, '/ip/hotspot/user/print');
    for (final u in users) {
      final isDis = (u['disabled'] ?? 'false') == 'true';
      if (!isDis) continue;
      final id = u['.id'] ?? '';
      if (id.isNotEmpty) {
        await MikroTikApi().run(host, user, pass, '/ip/hotspot/user/remove', ['=numbers=$id']);
        deleted++;
      }
    }
  } catch (_) {}
  return deleted;
}

class FazlakaApp extends StatefulWidget { const FazlakaApp({super.key}); @override State<FazlakaApp> createState() => _FazlakaAppState(); }
class _FazlakaAppState extends State<FazlakaApp> {
  bool ar = true;
  bool logged = false;
  String host = '10.10.10.1', user = '', pass = '';
  @override Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: !logged
        ? LoginScreen(ar: ar, onLang: () => setState(() => ar = !ar), onLogin: (h,u,p) { setState(() { host=h; user=u; pass=p; logged=true; }); })
        : HomeScreen(ar: ar, host: host, user: user, pass: pass, onLang: () => setState(() => ar = !ar), onLogout: () => setState(() => logged=false)),
    );
  }
}

class LoginScreen extends StatefulWidget {
  final bool ar; final VoidCallback onLang; final void Function(String,String,String) onLogin;
  const LoginScreen({super.key, required this.ar, required this.onLang, required this.onLogin});
  @override State<LoginScreen> createState() => _LoginScreenState();
}
class _LoginScreenState extends State<LoginScreen> {
  final _host = TextEditingController(text: '10.10.10.1');
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _remember = true, _busy = false;
  String _msg = '';
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    _user.text = sp.getString('router_user') ?? '';
    _pass.text = sp.getString('router_pass') ?? '';
    _host.text = sp.getString('router_host') ?? '10.10.10.1';
    setState(() {});
  }
  Future<void> _doLogin() async {
    setState(() { _busy = true; _msg = ''; });
    try {
      await MikroTikApi().run(_host.text.trim(), _user.text.trim(), _pass.text, '/ip/hotspot/user/print');
      final sp = await SharedPreferences.getInstance();
      if (_remember) { await sp.setString('router_user', _user.text.trim()); await sp.setString('router_pass', _pass.text); await sp.setString('router_host', _host.text.trim()); }
      else { await sp.remove('router_user'); await sp.remove('router_pass'); }
      widget.onLogin(_host.text.trim(), _user.text.trim(), _pass.text);
    } catch (_) { setState(() => _msg = widget.ar ? 'يوزر أو باسورد غلط' : 'Wrong user or password'); }
    setState(() => _busy = false);
  }
  @override Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(backgroundColor: petrol, title: const Text('FAZLAKA', style: TextStyle(color: Colors.white, letterSpacing: 4)), centerTitle: true, actions: [TextButton(onPressed: widget.onLang, child: Text(widget.ar ? 'EN' : 'عربي', style: const TextStyle(color: Colors.white)))]),
      body: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(children: [
        const SizedBox(height: 20),
        const Text('FAZLAKA', style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: petrol, letterSpacing: 4)),
        const SizedBox(height: 24),
        TextField(controller: _host, decoration: InputDecoration(labelText: 'Server IP', filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)))),
        const SizedBox(height: 12),
        TextField(controller: _user, decoration: InputDecoration(labelText: widget.ar ? 'اسم المستخدم' : 'Username', filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)))),
        const SizedBox(height: 12),
        TextField(controller: _pass, obscureText: true, decoration: InputDecoration(labelText: widget.ar ? 'كلمة السر' : 'Password', filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)))),
        const SizedBox(height: 8),
        Row(children: [Checkbox(value: _remember, activeColor: petrol, onChanged: (v) => setState(() => _remember = v ?? false)), Text(widget.ar ? 'تذكرني' : 'Remember Me')]),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, height: 52, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: petrol, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), onPressed: _busy ? null : _doLogin, child: Text(_busy ? '...' : (widget.ar ? 'دخول / CONNECT' : 'Login / CONNECT'), style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)))),
        if (_msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_msg, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
      ])),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final bool ar; final String host, user, pass; final VoidCallback onLang, onLogout;
  const HomeScreen({super.key, required this.ar, required this.host, required this.user, required this.pass, required this.onLang, required this.onLogout});
  @override State<HomeScreen> createState() => _HomeScreenState();
}
class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  @override Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(backgroundColor: petrol, title: const Text('FAZLAKA', style: TextStyle(color: Colors.white, letterSpacing: 4)), centerTitle: true, actions: [TextButton(onPressed: widget.onLang, child: Text(widget.ar ? 'EN' : 'عربي', style: const TextStyle(color: Colors.white))), IconButton(onPressed: widget.onLogout, icon: const Icon(Icons.logout, color: Colors.white))]),
      body: _tab == 0 ? HomeTab(ar: widget.ar, host: widget.host, user: widget.user, pass: widget.pass)
        : _tab == 1 ? CardsTab(ar: widget.ar, host: widget.host, user: widget.user, pass: widget.pass)
        : _tab == 2 ? SalesTab(ar: widget.ar)
        : AccountTab(ar: widget.ar),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tab,
        backgroundColor: petrol,
        selectedItemColor: Colors.white,
        unselectedItemColor: Colors.white70,
        type: BottomNavigationBarType.fixed,
        onTap: (i) => setState(() => _tab = i),
        items: [
          BottomNavigationBarItem(icon: const Icon(Icons.home), label: widget.ar ? 'الرئيسية' : 'Home'),
          BottomNavigationBarItem(icon: const Icon(Icons.card_membership), label: widget.ar ? 'الكروت' : 'Cards'),
          BottomNavigationBarItem(icon: const Icon(Icons.bar_chart), label: widget.ar ? 'المبيعات' : 'Sales'),
          BottomNavigationBarItem(icon: const Icon(Icons.person), label: widget.ar ? 'الحساب' : 'Account'),
        ],
      ),
    );
  }
}

class HomeTab extends StatefulWidget {
  final bool ar; final String host, user, pass;
  const HomeTab({super.key, required this.ar, required this.host, required this.user, required this.pass});
  @override State<HomeTab> createState() => _HomeTabState();
}
class _HomeTabState extends State<HomeTab> {
  String _profile = '20';
  int _count = 1;
  List<String> _created = [];
  String _printer = 'غير متصلة';
  BluetoothConnection? _bt;
  String _msg = '';
  bool _busy = false;
  Future<void> _pickPrinter() async {
    await Permission.bluetoothConnect.request();
    await Permission.bluetoothScan.request();
    await Permission.locationWhenInUse.request();
    await Permission.bluetoothAdvertise.request();
    try {
      final enabled = await FlutterBluetoothSerial.instance.isEnabled ?? false;
      if (!enabled) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.ar ? 'شغل البلوتوث الأول' : 'Turn Bluetooth on'))); return; }
      final bonded = await FlutterBluetoothSerial.instance.getBondedDevices();
      if (!mounted) return;
      if (bonded.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.ar ? 'لا توجد طابعة مقترنة - اقترن من إعدادات الموبايل الأول' : 'No paired printer'))); return; }
      showModalBottomSheet(context: context, builder: (_) => ListView(children: bonded.map((d) => ListTile(
        title: Text(d.name ?? 'Printer'),
        subtitle: Text(d.address),
        onTap: () async {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${widget.ar ? 'جارٍ الاتصال بـ' : 'Connecting to'} ${d.name}...')));
          bool ok = false;
          for (int i = 0; i < 2 && !ok; i++) {
            try { try { _bt?.close(); } catch (_) {} _bt = await BluetoothConnection.toAddress(d.address); ok = _bt?.isConnected ?? false; } catch (_) { ok = false; await Future.delayed(const Duration(milliseconds: 1000)); }
          }
          if (ok) { final sp = await SharedPreferences.getInstance(); await sp.setString('saved_printer_mac', d.address); await sp.setString('saved_printer_name', d.name ?? 'Printer'); }
          if (!mounted) return;
          setState(() => _printer = ok ? (d.name ?? 'Printer') : 'غير متصلة');
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? (widget.ar ? 'تم الاتصال بالطابعة' : 'Printer connected') : (widget.ar ? 'تعذر الاتصال بالطابعة' : 'Cannot connect'))));
        },
      )).toList()));
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${widget.ar ? 'خطأ الطابعة' : 'Printer error'}: $e'))); }
  }
  Future<void> _create() async {
    setState(() { _busy = true; _msg = ''; _created = []; });
    try {
      final rnd = Random();
      final names = <String>[];
      for (int i = 0; i < _count; i++) { names.add('${1000000 + rnd.nextInt(9000000)}'); }
      final todayStr = DateTime.now().toIso8601String().substring(0, 10);
      for (final name in names) {
        final res = await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/user/add', ['=name=$name', '=password=', '=profile=$_profile', '=server=all', '=comment=created:$todayStr']);
        if (res.any((m) => m['__type__'] == '!trap')) throw Exception('create failed');
        final check = await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/user/print');
        final found = check.where((m) => m['name'] == name).toList();
        if (found.isEmpty) throw Exception('not found');
        final id = found.first['.id'] ?? '';
        if (id.isNotEmpty) { await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/user/set', ['=numbers=$id', '=limit-uptime=${daysForProfile(_profile)}d', '=limit-bytes-total=${bytesFor(_profile)}']); }
      }
      final sp = await SharedPreferences.getInstance();
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final oldCount = sp.getInt('sales_${today}_count') ?? 0;
      final oldSum = sp.getInt('sales_${today}_sum') ?? 0;
      await sp.setInt('sales_${today}_count', oldCount + names.length);
      await sp.setInt('sales_${today}_sum', oldSum + (int.parse(_profile) * names.length));
      setState(() { _created = names; _msg = widget.ar ? 'تم إنشاء $_count كارت بنجاح' : 'Created $_count cards successfully'; });
    } catch (_) { setState(() => _msg = widget.ar ? 'تعذر إنشاء الكارت' : 'Cannot create card'); }
    setState(() => _busy = false);
  }
  Future<void> _print() async {
    if (_created.isEmpty) { setState(() => _msg = widget.ar ? 'أنشئ كارت أولاً' : 'Create a card first'); return; }
    if (_bt == null || !(_bt?.isConnected ?? false)) { setState(() => _msg = widget.ar ? 'اختر الطابعة أولاً' : 'Choose printer first'); return; }
    try {
      for (final num in _created) {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, 384, 220));
        canvas.drawRect(ui.Rect.fromLTWH(0, 0, 384, 220), ui.Paint()..color = const Color(0xFFFFFFFF));
        void drawText(String text, double y, double size, bool bold) {
          final builder = ui.ParagraphBuilder(ui.ParagraphStyle(textAlign: ui.TextAlign.center, fontSize: size, fontWeight: bold ? ui.FontWeight.bold : ui.FontWeight.normal, textDirection: ui.TextDirection.ltr));
          builder.pushStyle(ui.TextStyle(color: const Color(0xFF000000), fontSize: size, fontWeight: bold ? ui.FontWeight.bold : ui.FontWeight.normal));
          builder.addText(text);
          builder.pop();
          final p = builder.build()..layout(ui.ParagraphConstraints(width: 384));
          canvas.drawParagraph(p, ui.Offset(0, y));
        }
        drawText('FAZLAKA', 10, 42, true);
        drawText('01016620065 - 01141418040', 70, 22, false);
        drawText('------------------------------', 105, 22, false);
        drawText(num, 130, 58, true);
        drawText('Price: $_profile | Quota: ${quotaFor(_profile)}GB', 195, 22, false);
        final pic = recorder.endRecording();
        final img = await pic.toImage(384, 220);
        final byteData = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        final rgba = byteData!.buffer.asUint8List();
        final mono = <int>[];
        for (int y = 0; y < 220; y++) {
          for (int x = 0; x < 384; x += 8) {
            int b = 0;
            for (int bit = 0; bit < 8; bit++) {
              final idx = (y * 384 + x + bit) * 4;
              final r = rgba[idx];
              final g = rgba[idx + 1];
              final bl = rgba[idx + 2];
              final gray = (r + g + bl) ~/ 3;
              if (gray < 150) b |= (0x80 >> bit);
            }
            mono.add(b);
          }
        }
        final bytes = <int>[];
        bytes.addAll([0x1B, 0x40]);
        bytes.addAll([0x1B, 0x61, 0x01]);
        bytes.addAll([0x1D, 0x76, 0x30, 0x00, 48, 0, 220, 0]);
        bytes.addAll(mono);
        bytes.addAll([0x0A, 0x0A, 0x0A]);
        bytes.addAll([0x1D, 0x56, 0x00]);
        _bt!.output.add(Uint8List.fromList(bytes));
        await _bt!.output.allSent;
        await Future.delayed(const Duration(milliseconds: 800));
      }
      setState(() => _msg = widget.ar ? 'تمت الطباعة' : 'Printed');
    } catch (_) { setState(() => _msg = widget.ar ? 'تعذر الطباعة' : 'Cannot print'); }
  }
  @override void dispose() { try { _bt?.close(); } catch (_) {} super.dispose(); }
  @override Widget build(BuildContext context) {
    return SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(children: [
      Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)), child: Column(children: [
        Align(alignment: Alignment.centerRight, child: Text(widget.ar ? 'انشاء كروت' : 'Create Cards', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: petrol))),
        const SizedBox(height: 16),
        Row(children: ['20','50'].map((p) => Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: GestureDetector(onTap: () => setState(() => _profile = p), child: Container(height: 58, decoration: BoxDecoration(color: _profile == p ? petrol : const Color(0xFFEDEDED), borderRadius: BorderRadius.circular(14)), alignment: Alignment.center, child: Text(p, style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: _profile == p ? Colors.white : Colors.black))))))).toList()),
        const SizedBox(height: 8),
        Row(children: ['100','200'].map((p) => Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: GestureDetector(onTap: () => setState(() => _profile = p), child: Container(height: 58, decoration: BoxDecoration(color: _profile == p ? petrol : const Color(0xFFEDEDED), borderRadius: BorderRadius.circular(14)), alignment: Alignment.center, child: Text(p, style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: _profile == p ? Colors.white : Colors.black))))))).toList()),
        const SizedBox(height: 8),
        Text(widget.ar ? '${quotaFor(_profile)} جيجا - ${daysForProfile(_profile)} يوم' : '${quotaFor(_profile)}GB - ${daysForProfile(_profile)} days', style: const TextStyle(fontWeight: FontWeight.bold, color: petrol)),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(widget.ar ? 'عدد الكروت' : 'Count', style: const TextStyle(fontSize: 16)),
          Row(children: [
            IconButton(onPressed: () => setState(() => _count++), icon: const Icon(Icons.add)),
            Text('$_count', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            IconButton(onPressed: () { if (_count > 1) setState(() => _count--); }, icon: const Icon(Icons.remove)),
          ]),
        ]),
      ])),
      const SizedBox(height: 16),
      SizedBox(width: double.infinity, height: 52, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: petrol, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), onPressed: _busy ? null : _create, child: Text(widget.ar ? 'انشاء' : 'Create', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)))),
      const SizedBox(height: 12),
      SizedBox(width: double.infinity, height: 52, child: OutlinedButton(style: OutlinedButton.styleFrom(side: const BorderSide(color: petrol), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), onPressed: _print, child: Text(widget.ar ? 'طباعة' : 'Print', style: const TextStyle(color: petrol, fontSize: 18, fontWeight: FontWeight.bold)))),
      const SizedBox(height: 12),
      SizedBox(width: double.infinity, height: 52, child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: petrol))), onPressed: _pickPrinter, icon: const Icon(Icons.bluetooth, color: petrol), label: Text(_printer == 'غير متصلة' ? (widget.ar ? 'توصيل الطابعة' : 'Connect Printer') : '${widget.ar ? 'الطابعة' : 'Printer'}: $_printer', style: const TextStyle(color: petrol, fontSize: 16, fontWeight: FontWeight.bold)))),
      const SizedBox(height: 12),
      if (_msg.isNotEmpty) Text(_msg, style: const TextStyle(fontWeight: FontWeight.bold)),
      if (_created.isNotEmpty) ...[
        const SizedBox(height: 12),
        Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)), child: Column(children: [
          Align(alignment: Alignment.centerRight, child: Text(widget.ar ? 'الكروت الجاهزة' : 'Ready Cards', style: const TextStyle(fontWeight: FontWeight.bold))),
          const SizedBox(height: 8),
          ..._created.map((c) => Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Column(children: [
            const Text('FAZLAKA', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 3)),
            const Text('01016620065 - 01141418040'),
            const Text('------------------------------'),
            Text(c, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            Text('Price: $_profile | Quota: ${quotaFor(_profile)}GB'),
          ]))),
        ])),
      ],
    ]));
  }
}

class CardsTab extends StatefulWidget {
  final bool ar; final String host, user, pass;
  const CardsTab({super.key, required this.ar, required this.host, required this.user, required this.pass});
  @override State<CardsTab> createState() => _CardsTabState();
}
class _CardsTabState extends State<CardsTab> {
  bool _showActive = true;
  List<Map<String,String>> _active = [], _all = [];
  bool _loading = false;
  String _status = '';
  String _delMsg = '';
  String _search = '';
  final _searchCtrl = TextEditingController();
  Future<void> _load() async {
    setState(() { _loading = true; });
    try {
      final disabled = await disableExpiredUsers(widget.host, widget.user, widget.pass);
      if (disabled > 0) setState(() => _delMsg = widget.ar ? 'تم تعطيل $disabled يوزر منتهي أوتوماتيك' : 'Disabled $disabled expired users');
      final a = await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/active/print');
      final u = await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/user/print');
      setState(() { _active = a; _all = u; _status = widget.ar ? 'متصل' : 'Connected'; });
    } catch (_) { setState(() => _status = widget.ar ? 'غير متصل' : 'Disconnected'); }
    setState(() => _loading = false);
  }
  List<Map<String,String>> get _filteredActive {
    if (_search.trim().isEmpty) return _active;
    final q = _search.trim().toLowerCase();
    return _active.where((m) => (m['user'] ?? '').toLowerCase().contains(q) || (m['address'] ?? '').toLowerCase().contains(q) || (m['mac-address'] ?? '').toLowerCase().contains(q)).toList();
  }
  List<Map<String,String>> get _filteredAll {
    if (_search.trim().isEmpty) return _all;
    final q = _search.trim().toLowerCase();
    return _all.where((m) => (m['name'] ?? '').toLowerCase().contains(q) || (m['profile'] ?? '').toLowerCase().contains(q) || (m['comment'] ?? '').toLowerCase().contains(q)).toList();
  }
  Future<void> _kickActive(String id, String name) async {
    final confirm = await showDialog<String>(context: context, builder: (_) => AlertDialog(
      title: Text(widget.ar ? 'اخراج $name ؟' : 'Kick $name ?'),
      content: Text(widget.ar ? 'تختار ايه؟' : 'Choose:'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, 'cancel'), child: Text(widget.ar ? 'الغاء' : 'Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, 'kick'), child: Text(widget.ar ? 'اخراج بس' : 'Kick only', style: const TextStyle(color: Colors.orange))),
        TextButton(onPressed: () => Navigator.pop(context, 'kick_disable'), child: Text(widget.ar ? 'اخراج + تعطيل' : 'Kick + Disable', style: const TextStyle(color: Colors.red))),
      ],
    ));
    if (confirm == null || confirm == 'cancel') return;
    try {
      await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/active/remove', ['=numbers=$id']);
      if (confirm == 'kick_disable') {
        final users = await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/user/print');
        final found = users.where((m) => m['name'] == name).toList();
        if (found.isNotEmpty) {
          final uid = found.first['.id'] ?? '';
          if (uid.isNotEmpty) await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/user/set', ['=numbers=$uid', '=disabled=yes']);
        }
      }
      setState(() => _delMsg = widget.ar ? 'تم اخراج $name' : 'Kicked $name');
      _load();
    } catch (_) { setState(() => _delMsg = widget.ar ? 'تعذر الاخراج' : 'Cannot kick'); }
  }
  Future<void> _kickAll() async {
    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(title: Text(widget.ar ? 'اخراج الكل؟' : 'Kick all?'), content: Text(widget.ar ? 'هتخرج كل المتصلين دلوقتي، متأكد؟' : 'Kick all active users?'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(widget.ar ? 'لا' : 'No')), TextButton(onPressed: () => Navigator.pop(context, true), child: Text(widget.ar ? 'نعم اخرج الكل' : 'Yes kick all'))]));
    if (confirm != true) return;
    for (final m in _active) {
      final id = m['.id'] ?? '';
      if (id.isNotEmpty) { try { await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/active/remove', ['=numbers=$id']); } catch (_) {} }
    }
    setState(() => _delMsg = widget.ar ? 'تم اخراج الكل' : 'Kicked all');
    _load();
  }
  Future<void> _manualDelete() async {
    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(title: Text(widget.ar ? 'حذف المنتهية؟' : 'Delete expired?'), content: Text(widget.ar ? 'هيمسح كل اليوزرات المعطلة، متأكد؟' : 'Delete all disabled users?'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(widget.ar ? 'لا' : 'No')), TextButton(onPressed: () => Navigator.pop(context, true), child: Text(widget.ar ? 'نعم احذف' : 'Yes delete'))]));
    if (confirm != true) return;
    setState(() => _delMsg = widget.ar ? 'جارٍ الحذف...' : 'Deleting...');
    final d = await deleteDisabledUsers(widget.host, widget.user, widget.pass);
    setState(() => _delMsg = widget.ar ? 'تم حذف $d يوزر' : 'Deleted $d users');
    _load();
  }
  Future<void> _enableUser(String id, String name) async {
    try {
      await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/user/set', ['=numbers=$id', '=disabled=no']);
      setState(() => _delMsg = widget.ar ? 'تم تفعيل $name' : 'Enabled $name');
      _load();
    } catch (_) {}
  }
  @override void initState() { super.initState(); _load(); }
  @override void dispose() { _searchCtrl.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) {
    return SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(children: [
      Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(widget.ar ? 'حالة الراوتر' : 'Router', style: const TextStyle(fontWeight: FontWeight.bold)),
        Text('${widget.ar ? 'حالة الراوتر -' : 'Router -'} $_status'),
      ])),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: SizedBox(height: 48, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))), onPressed: _kickAll, child: Text(widget.ar ? 'اخراج الكل' : 'Kick All', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))))),
        const SizedBox(width: 8),
        Expanded(child: SizedBox(height: 48, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))), onPressed: _manualDelete, child: Text(widget.ar ? 'حذف المنتهية' : 'Delete Expired', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))))),
      ]),
      if (_delMsg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_delMsg, style: const TextStyle(fontWeight: FontWeight.bold, color: petrol))),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: _showActive ? petrol : Colors.white), onPressed: () { setState(() { _showActive = true; _search = ''; _searchCtrl.clear(); }); }, child: Text(widget.ar ? 'المتصلين الآن' : 'Online', style: TextStyle(color: _showActive ? Colors.white : petrol)))),
        const SizedBox(width: 8),
        Expanded(child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: !_showActive ? petrol : Colors.white), onPressed: () { setState(() { _showActive = false; _search = ''; _searchCtrl.clear(); }); }, child: Text(widget.ar ? 'كل الكروت' : 'All Cards', style: TextStyle(color: !_showActive ? Colors.white : petrol)))),
      ]),
      const SizedBox(height: 12),
      TextField(
        controller: _searchCtrl,
        onChanged: (v) => setState(() => _search = v),
        decoration: InputDecoration(
          hintText: _showActive ? (widget.ar ? 'بحث في المتصلين - رقم أو IP' : 'Search active - number or IP') : (widget.ar ? 'بحث في الكروت - رقم أو بروفايل' : 'Search cards - number or profile'),
          prefixIcon: const Icon(Icons.search, color: petrol),
          suffixIcon: _search.isNotEmpty ? IconButton(icon: const Icon(Icons.clear), onPressed: () { setState(() { _search = ''; _searchCtrl.clear(); }); }) : null,
          filled: true, fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        ),
      ),
      const SizedBox(height: 8),
      Text(widget.ar ? 'النشط: ${_active.length} | الكروت: ${_all.length} | النتيجة: ${_showActive ? _filteredActive.length : _filteredAll.length}' : 'Active: ${_active.length} | Cards: ${_all.length} | Found: ${_showActive ? _filteredActive.length : _filteredAll.length}'),
      const SizedBox(height: 12),
      if (_loading) const CircularProgressIndicator(),
      if (!_loading && _showActive) ..._filteredActive.map((m) {
        final name = m['user'] ?? '';
        final id = m['.id'] ?? '';
        return Card(child: ListTile(
          title: Text('$name - ${widget.ar ? 'نشط' : 'Active'}'),
          subtitle: Text('${m['address'] ?? ''} - ${m['uptime'] ?? ''}'),
          trailing: IconButton(icon: const Icon(Icons.logout, color: Colors.red), tooltip: widget.ar ? 'اخراج' : 'Kick', onPressed: () => _kickActive(id, name)),
        ));
      }),
      if (!_loading && !_showActive) ..._filteredAll.map((m) {
        final isDis = (m['disabled'] ?? 'false') == 'true';
        final left = remainingDays(m);
        return Card(child: ListTile(
          title: Text(m['name'] ?? ''),
          subtitle: Text('${m['profile'] ?? ''} - ${isDis ? (widget.ar ? 'معطل' : 'Disabled') : (widget.ar ? 'شغال - باقي $left يوم' : 'Active - $left days left')}'),
          trailing: isDis ? IconButton(icon: const Icon(Icons.check_circle, color: Colors.green), tooltip: widget.ar ? 'تفعيل' : 'Enable', onPressed: () => _enableUser(m['.id'] ?? '', m['name'] ?? '')) : null,
        ));
      }),
      if (!_loading && _showActive && _filteredActive.isEmpty) Padding(padding: const EdgeInsets.only(top: 20), child: Text(widget.ar ? 'مفيش نتيجة' : 'No results')),
      if (!_loading && !_showActive && _filteredAll.isEmpty) Padding(padding: const EdgeInsets.only(top: 20), child: Text(widget.ar ? 'مفيش نتيجة' : 'No results')),
    ]));
  }
}

class SalesTab extends StatefulWidget { final bool ar; const SalesTab({super.key, required this.ar}); @override State<SalesTab> createState() => _SalesTabState(); }
class _SalesTabState extends State<SalesTab> {
  int _count = 0, _sum = 0;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    setState(() { _count = sp.getInt('sales_${today}_count') ?? 0; _sum = sp.getInt('sales_${today}_sum') ?? 0; });
  }
  @override Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.all(16), child: Column(children: [
      Container(width: double.infinity, padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)), child: Column(children: [
        Text(widget.ar ? 'مبيعات اليوم' : 'Today Sales', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Text('$_count ${widget.ar ? 'كارت' : 'cards'}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        Text('$_sum ${widget.ar ? 'جنيه' : 'EGP'}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: petrol)),
      ])),
    ]));
  }
}

class AccountTab extends StatefulWidget { final bool ar; const AccountTab({super.key, required this.ar}); @override State<AccountTab> createState() => _AccountTabState(); }
class _AccountTabState extends State<AccountTab> {
  int _sales = 0, _expenses = 0;
  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    setState(() { _sales = sp.getInt('sales_${today}_sum') ?? 0; _expenses = sp.getInt('expenses_${today}') ?? 0; });
  }
  @override void initState() { super.initState(); _load(); }
  Future<void> _addExpense() async {
    final c = TextEditingController();
    final v = await showDialog<String>(context: context, builder: (_) => AlertDialog(title: Text(widget.ar ? 'اضافة مصروف' : 'Add Expense'), content: TextField(controller: c, keyboardType: TextInputType.number), actions: [TextButton(onPressed: () => Navigator.pop(context, c.text), child: Text(widget.ar ? 'حفظ' : 'Save'))]));
    if (v != null && v.isNotEmpty) {
      final sp = await SharedPreferences.getInstance();
      final today = DateTime.now().toIso8601String().substring(0, 10);
      await sp.setInt('expenses_${today}', _expenses + (int.tryParse(v) ?? 0));
      _load();
    }
  }
  Future<void> _reset() async {
    final sp = await SharedPreferences.getInstance();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    await sp.setInt('expenses_${today}', 0);
    await sp.setInt('sales_${today}_count', 0);
    await sp.setInt('sales_${today}_sum', 0);
    _load();
  }
  @override Widget build(BuildContext context) {
    final net = _sales - _expenses;
    return Padding(padding: const EdgeInsets.all(16), child: Column(children: [
      Container(width: double.infinity, padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)), child: Column(children: [
        Text('${widget.ar ? 'الصافي' : 'Net'}: $net', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: petrol)),
        const SizedBox(height: 8),
        Text('${widget.ar ? 'المصاريف' : 'Expenses'}: $_expenses'),
        Text('${widget.ar ? 'المبيعات' : 'Sales'}: $_sales'),
      ])),
      const SizedBox(height: 12),
      SizedBox(width: double.infinity, height: 48, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: petrol), onPressed: _addExpense, child: Text(widget.ar ? 'اضافة مصروف' : 'Add Expense', style: const TextStyle(color: Colors.white)))),
      const SizedBox(height: 8),
      SizedBox(width: double.infinity, height: 48, child: OutlinedButton(onPressed: _reset, child: Text(widget.ar ? 'تصفير' : 'Reset'))),
    ]));
  }
}
