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
      bottomNavigationBar: BottomNavigationBar(currentIndex: _tab, selectedItemColor: petrol, onTap: (i) => setState(() => _tab = i), items: [
        BottomNavigationBarItem(icon: const Icon(Icons.home), label: widget.ar ? 'الرئيسية' : 'Home'),
        BottomNavigationBarItem(icon: const Icon(Icons.card_membership), label: widget.ar ? 'الكروت' : 'Cards'),
        BottomNavigationBarItem(icon: const Icon(Icons.bar_chart), label: widget.ar ? 'المبيعات' : 'Sales'),
        BottomNavigationBarItem(icon: const Icon(Icons.person), label: widget.ar ? 'الحساب' : 'Account'),
      ]),
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
  String _quota(String p) => p == '20' ? '2' : p == '50' ? '8' : '20';
  String _days(String p) => p == '20' ? '3d' : p == '50' ? '7d' : '30d';
  String _bytes(String p) => p == '20' ? '2147483648' : p == '50' ? '8589934592' : '21474836480';
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
      for (final name in names) {
        final res = await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/user/add', ['=name=$name', '=password=', '=profile=$_profile', '=server=all']);
        if (res.any((m) => m['__type__'] == '!trap')) throw Exception('create failed');
        final check = await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/user/print');
        final found = check.where((m) => m['name'] == name).toList();
        if (found.isEmpty) throw Exception('not found');
        final id = found.first['.id'] ?? '';
        if (id.isNotEmpty) { await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/user/set', ['=numbers=$id', '=limit-uptime=${_days(_profile)}', '=limit-bytes-total=${_bytes(_profile)}']); }
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
          final builder = ui.ParagraphBuilder(ui.ParagraphStyle(textAlign: ui.TextAlign.center, fontSize: size, fontWeight: bold ? ui.FontWeight.bold : ui.FontWeight.normal));
          builder.addText(text);
          final p = builder.build()..layout(ui.ParagraphConstraints(width: 384));
          canvas.drawParagraph(p, ui.Offset(0, y));
        }
        drawText('FAZLAKA', 10, 42, true);
        drawText('01016620065 - 01141418040', 70, 22, false);
        drawText('------------------------------', 105, 22, false);
        drawText(num, 130, 58, true);
        drawText('Price: $_profile | Quota: ${_quota(_profile)}GB', 195, 22, false);
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
              if (r < 128) b |= (0x80 >> bit);
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
        Row(children: ['20','50','100'].map((p) => Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: GestureDetector(onTap: () => setState(() => _profile = p), child: Container(height: 58, decoration: BoxDecoration(color: _profile == p ? petrol : const Color(0xFFEDEDED), borderRadius: BorderRadius.circular(14)), alignment: Alignment.center, child: Text(p, style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: _profile == p ? Colors.white : Colors.black))))))).toList()),
        const SizedBox(height: 16),
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
            Text('Price: $_profile | Quota: ${_quota(_profile)}GB'),
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
  Future<void> _load() async {
    setState(() { _loading = true; });
    try {
      final a = await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/active/print');
      final u = await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/user/print');
      setState(() { _active = a; _all = u; _status = widget.ar ? 'متصل' : 'Connected'; });
    } catch (_) { setState(() => _status = widget.ar ? 'غير متصل' : 'Disconnected'); }
    setState(() => _loading = false);
  }
  @override void initState() { super.initState(); _load(); }
  @override Widget build(BuildContext context) {
    return SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(children: [
      Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(widget.ar ? 'حالة الراوتر' : 'Router', style: const TextStyle(fontWeight: FontWeight.bold)),
        Text('${widget.ar ? 'حالة الراوتر -' : 'Router -'} $_status'),
      ])),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: _showActive ? petrol : Colors.white), onPressed: () => setState(() => _showActive = true), child: Text(widget.ar ? 'المتصلين الآن' : 'Online', style: TextStyle(color: _showActive ? Colors.white : petrol)))),
        const SizedBox(width: 8),
        Expanded(child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: !_showActive ? petrol : Colors.white), onPressed: () => setState(() => _showActive = false), child: Text(widget.ar ? 'كل الكروت' : 'All Cards', style: TextStyle(color: !_showActive ? Colors.white : petrol)))),
      ]),
      const SizedBox(height: 8),
      Text(widget.ar ? 'النشط: ${_active.length} | الكروت: ${_all.length}' : 'Active: ${_active.length} | Cards: ${_all.length}'),
      const SizedBox(height: 12),
      if (_loading) const CircularProgressIndicator(),
      if (!_loading && _showActive) ..._active.map((m) => Card(child: ListTile(title: Text('${m['user'] ?? ''} - ${widget.ar ? 'نشط' : 'Active'}')))),
      if (!_loading && !_showActive) ..._all.map((m) => Card(child: ListTile(title: Text(m['name'] ?? ''), subtitle: Text('${m['profile'] ?? ''}')))),
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
