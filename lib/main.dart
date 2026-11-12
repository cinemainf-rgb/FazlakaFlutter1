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

// ---------- Monthly Sales Helpers - جديد: المبيعات بتتجمع طول الشهر ----------
String monthKeyOf(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';
String monthLabel(String k) {
  final p = k.split('-');
  const ms = ['', 'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];
  final mi = int.tryParse(p[1]) ?? 1;
  return '${ms[mi]} ${p[0]}';
}

Future<void> saveMonthlySale(String profile, int count) async {
  final sp = await SharedPreferences.getInstance();
  final month = monthKeyOf(DateTime.now());
  // sales_all: List of {m, p, price, date}
  List<Map<String, dynamic>> all = [];
  final raw = sp.getString('sales_all');
  if (raw != null && raw.isNotEmpty) {
    try { all = List<Map<String, dynamic>>.from(jsonDecode(raw)); } catch (_) {}
  }
  for (int i = 0; i < count; i++) {
    all.add({'m': month, 'p': profile, 'pr': int.tryParse(profile) ?? 0, 'd': DateTime.now().millisecondsSinceEpoch});
  }
  await sp.setString('sales_all', jsonEncode(all));
  // keep old today keys for backward compatibility
  final today = DateTime.now().toIso8601String().substring(0, 10);
  final oldCount = sp.getInt('sales_${today}_count') ?? 0;
  final oldSum = sp.getInt('sales_${today}_sum') ?? 0;
  await sp.setInt('sales_${today}_count', oldCount + count);
  await sp.setInt('sales_${today}_sum', oldSum + (int.parse(profile) * count));
}

Future<List<Map<String, dynamic>>> loadAllSales() async {
  final sp = await SharedPreferences.getInstance();
  final raw = sp.getString('sales_all');
  if (raw == null || raw.isEmpty) return [];
  try { return List<Map<String, dynamic>>.from(jsonDecode(raw)); } catch (_) { return []; }
}

Future<void> saveMonthlyExpense(int amount, String note) async {
  final sp = await SharedPreferences.getInstance();
  final month = monthKeyOf(DateTime.now());
  List<Map<String, dynamic>> all = [];
  final raw = sp.getString('expenses_all');
  if (raw != null && raw.isNotEmpty) {
    try { all = List<Map<String, dynamic>>.from(jsonDecode(raw)); } catch (_) {}
  }
  all.add({'m': month, 'a': amount, 'n': note, 'd': DateTime.now().millisecondsSinceEpoch});
  await sp.setString('expenses_all', jsonEncode(all));
  final today = DateTime.now().toIso8601String().substring(0, 10);
  final old = sp.getInt('expenses_${today}') ?? 0;
  await sp.setInt('expenses_${today}', old + amount);
}

Future<List<Map<String, dynamic>>> loadAllExpenses() async {
  final sp = await SharedPreferences.getInstance();
  final raw = sp.getString('expenses_all');
  if (raw == null || raw.isEmpty) return [];
  try { return List<Map<String, dynamic>>.from(jsonDecode(raw)); } catch (_) { return []; }
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
  bool _autoTried = false;

  @override void initState() {
    super.initState();
    // جديد: اتصال تلقائي بالطابعة أول ما تفتح التطبيق
    Future.delayed(const Duration(milliseconds: 500), _autoConnectPrinter);
  }

  // جديد: اتصال تلقائي - يدور على RazyTech-5890IV أو آخر طابعة محفوظة
  Future<void> _autoConnectPrinter() async {
    if (_autoTried) return;
    _autoTried = true;
    try {
      await Permission.bluetoothConnect.request();
      await Permission.bluetoothScan.request();
      await Permission.locationWhenInUse.request();
      final sp = await SharedPreferences.getInstance();
      final savedMac = sp.getString('saved_printer_mac') ?? '';
      final savedName = sp.getString('saved_printer_name') ?? '';
      final enabled = await FlutterBluetoothSerial.instance.isEnabled ?? false;
      if (!enabled) return;
      final bonded = await FlutterBluetoothSerial.instance.getBondedDevices();
      BluetoothDevice? target;
      for (final d in bonded) {
        final n = (d.name ?? '').toLowerCase();
        if (d.address == savedMac) { target = d; break; }
        if (n.contains('razytech') || n.contains('5890') || n == savedName.toLowerCase()) { target = d; break; }
      }
      if (target == null) {
        // لو مفيش RazyTech، خد أول طابعة مقترنة لو فيه واحدة بس محفوظة قبل كده
        if (savedMac.isNotEmpty && bonded.isNotEmpty) {
          for (final d in bonded) { if (d.address == savedMac) target = d; }
        }
        if (target == null) return;
      }
      if (_bt != null && (_bt!.isConnected)) return;
      for (int i = 0; i < 2; i++) {
        try {
          try { _bt?.close(); } catch (_) {}
          _bt = await BluetoothConnection.toAddress(target.address);
          if (_bt?.isConnected ?? false) break;
        } catch (_) { await Future.delayed(const Duration(milliseconds: 800)); }
      }
      if (_bt?.isConnected ?? false) {
        await sp.setString('saved_printer_mac', target.address);
        await sp.setString('saved_printer_name', target.name ?? 'Printer');
        if (!mounted) return;
        setState(() => _printer = 
