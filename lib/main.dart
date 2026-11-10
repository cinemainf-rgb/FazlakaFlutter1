import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const FazlakaApp());

const petrol = Color(0xFF0A3D3E);
const bgColor = Color(0xFFDFF5F2);

class MikroTikApi {
  Socket? _socket;
  List<int> _buf = [];
  Future<void> connect(String host, String user, String pass) async {
    _socket = await Socket.connect(host, 8728, timeout: const Duration(seconds: 5));
    _socket!.listen((d) { _buf.addAll(d); });
    final chalHex = await _loginStep(user);
    List<int> hexToBytes(String hex) {
      final out = <int>[];
      for (int i = 0; i < hex.length; i += 2) {
        out.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
      return out;
    }
    final chalBytes = hexToBytes(chalHex);
    final respHash = md5.convert([0, ...utf8.encode(pass), ...chalBytes]).toString();
    final resp = await _send(['/login', '=name=$user', '=response=00$respHash']);
    if (resp.any((m) => m['__type__'] == '!trap')) {
      throw Exception('اسم المستخدم أو كلمة السر غير صحيحة');
    }
  }
  Future<String> _loginStep(String user) async {
    final r = await _send(['/login', '=name=$user']);
    if (r.isEmpty) return '';
    return r.first['ret'] ?? '';
  }
  Future<List<Map<String, String>>> command(String cmd, [List<String> args = const []]) async {
    return _send([cmd, ...args]);
  }
  Future<List<Map<String, String>>> _send(List<String> words) async {
    _buf.clear();
    for (var w in words) { _writeWord(w); }
    _writeWord('');
    await _socket!.flush();
    await Future.delayed(const Duration(milliseconds: 900));
    for (int i = 0; i < 12; i++) {
      if (_buf.isNotEmpty) break;
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return _parse(_buf);
  }
  void _writeWord(String w) {
    final b = utf8.encode(w);
    final len = b.length;
    if (len < 0x80) {
      _socket!.add([len]);
    } else if (len < 0x4000) {
      _socket!.add([0x80 | (len >> 8), len & 0xFF]);
    } else {
      _socket!.add([0xC0 | (len >> 16), (len >> 8) & 0xFF, len & 0xFF]);
    }
    _socket!.add(b);
  }
  List<Map<String, String>> _parse(List<int> data) {
    final out = <Map<String, String>>[];
    var cur = <String, String>{};
    int i = 0;
    while (i < data.length) {
      int len = data[i++];
      if ((len & 0x80) != 0) {
        if ((len & 0xC0) == 0x80) {
          len = ((len & 0x3F) << 8) | data[i++];
        } else if ((len & 0xE0) == 0xC0) {
          len = ((len & 0x1F) << 16) | (data[i++] << 8) | data[i++];
        } else if ((len & 0xF0) == 0xE0) {
          len = ((len & 0x0F) << 24) | (data[i++] << 16) | (data[i++] << 8) | data[i++];
        }
      }
      if (len == 0) {
        if (cur.isNotEmpty) { out.add(cur); cur = <String, String>{}; }
        continue;
      }
      if (i + len > data.length) break;
      final word = utf8.decode(data.sublist(i, i + len), allowMalformed: true);
      i += len;
      if (word.startsWith('!')) {
        if (cur.isNotEmpty) { out.add(cur); cur = <String, String>{}; }
        cur['__type__'] = word;
      } else if (word.startsWith('=')) {
        final eq = word.indexOf('=', 1);
        if (eq > 0) cur[word.substring(1, eq)] = word.substring(eq + 1);
      }
    }
    if (cur.isNotEmpty) out.add(cur);
    return out;
  }
  void close() { try { _socket?.destroy(); } catch (_) {} }
  Future<List<Map<String, String>>> run(String host, String user, String pass, String cmd, [List<String> args = const []]) async {
    await connect(host, user, pass);
    try { return await command(cmd, args); } finally { close(); }
  }
}

class FazlakaApp extends StatefulWidget {
  const FazlakaApp({super.key});
  @override
  State<FazlakaApp> createState() => _FazlakaAppState();
}
class _FazlakaAppState extends State<FazlakaApp> {
  bool ar = true;
  @override
  void initState() { super.initState(); _loadLang(); }
  Future<void> _loadLang() async {
    final p = await SharedPreferences.getInstance();
    setState(() => ar = p.getString('lang') != 'en');
  }
  Future<void> _toggleLang() async {
    final p = await SharedPreferences.getInstance();
    setState(() => ar = !ar);
    await p.setString('lang', ar ? 'ar' : 'en');
  }
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(scaffoldBackgroundColor: bgColor, primaryColor: petrol),
      home: LoginScreen(ar: ar, onToggleLang: _toggleLang),
    );
  }
}

class LoginScreen extends StatefulWidget {
  final bool ar;
  final VoidCallback onToggleLang;
  const LoginScreen({super.key, required this.ar, required this.onToggleLang});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}
class _LoginScreenState extends State<LoginScreen> {
  final _host = TextEditingController(text: '10.10.10.1');
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _loading = false;
  String _err = '';
  bool _remember = false;
  @override
  void initState() { super.initState(); _loadSaved(); }
  Future<void> _loadSaved() async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool('remember') ?? false) {
      setState(() {
        _remember = true;
        _host.text = p.getString('saved_host') ?? '10.10.10.1';
        _user.text = p.getString('saved_user') ?? '';
        _pass.text = p.getString('saved_pass') ?? '';
      });
    }
  }
  Future<void> _login() async {
    setState(() { _loading = true; _err = ''; });
    try {
      final api = MikroTikApi();
      await api.connect(_host.text.trim(), _user.text.trim(), _pass.text.trim());
      api.close();
      final p = await SharedPreferences.getInstance();
      if (_remember) {
        await p.setBool('remember', true);
        await p.setString('saved_host', _host.text.trim());
        await p.setString('saved_user', _user.text.trim());
        await p.setString('saved_pass', _pass.text.trim());
      } else {
        await p.setBool('remember', false);
        await p.remove('saved_host');
        await p.remove('saved_user');
        await p.remove('saved_pass');
      }
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => MainTabs(host: _host.text.trim(), user: _user.text.trim(), pass: _pass.text.trim(), ar: widget.ar, onToggleLang: widget.onToggleLang)),
      );
    } catch (e) {
      setState(() => _err = 'تعذر الاتصال بالراوتر');
    }
    setState(() => _loading = false);
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Align(alignment: Alignment.topLeft, child: ElevatedButton(onPressed: widget.onToggleLang, child: Text(widget.ar ? 'EN' : 'عربي'))),
              const SizedBox(height: 30),
              const CircleAvatar(radius: 45, backgroundColor: petrol, child: Icon(Icons.wifi, color: Colors.white, size: 45)),
              const SizedBox(height: 16),
              const Text('FAZLAKA', style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: petrol, letterSpacing: 4)),
              Text(widget.ar ? 'مدير الهوت سبوت' : 'Hotspot Manager', style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 30),
              TextField(controller: _host, decoration: InputDecoration(labelText: widget.ar ? 'عنوان السيرفر' : 'Server IP', filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)))),
              const SizedBox(height: 12),
              TextField(controller: _user, decoration: InputDecoration(labelText: widget.ar ? 'اسم المستخدم' : 'Username', filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)))),
              const SizedBox(height: 12),
              TextField(controller: _pass, obscureText: true, decoration: InputDecoration(labelText: widget.ar ? 'كلمة السر' : 'Password', filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)))),
              const SizedBox(height: 8),
              Row(children: [Checkbox(value: _remember, activeColor: petrol, onChanged: (v) => setState(() => _remember = v ?? false)), Text(widget.ar ? 'تذكرني' : 'Remember Me', style: const TextStyle(fontSize: 16))]),
              const SizedBox(height: 8),
              if (_err.isNotEmpty) Text(_err, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: petrol, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28))),
                  onPressed: _loading ? null : _login,
                  child: _loading ? const CircularProgressIndicator(color: Colors.white) : Text(widget.ar ? 'دخول' : 'CONNECT', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MainTabs extends StatefulWidget {
  final String host, user, pass;
  final bool ar;
  final VoidCallback onToggleLang;
  const MainTabs({super.key, required this.host, required this.user, required this.pass, required this.ar, required this.onToggleLang});
  @override
  State<MainTabs> createState() => _MainTabsState();
}
class _MainTabsState extends State<MainTabs> {
  int _idx = 0;
  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeTab(host: widget.host, user: widget.user, pass: widget.pass, ar: widget.ar),
      CardsTab(host: widget.host, user: widget.user, pass: widget.pass, ar: widget.ar),
      SalesTab(ar: widget.ar),
      const AccountTab(),
    ];
    return Scaffold(
      appBar: AppBar(backgroundColor: petrol, title: const Text('FAZLAKA', style: TextStyle(color: Colors.white, letterSpacing: 4)), centerTitle: true, actions: [IconButton(onPressed: widget.onToggleLang, icon: Text(widget.ar ? 'EN' : 'عربي', style: const TextStyle(color: Colors.white)))]),
      body: pages[_idx],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _idx,
        onTap: (i) => setState(() => _idx = i),
        selectedItemColor: petrol,
        unselectedItemColor: Colors.grey,
        items: [
          BottomNavigationBarItem(icon: const Icon(Icons.home), label: widget.ar ? 'الرئيسية' : 'Home'),
          BottomNavigationBarItem(icon: const Icon(Icons.credit_card), label: widget.ar ? 'الكروت' : 'Cards'),
          BottomNavigationBarItem(icon: const Icon(Icons.bar_chart), label: widget.ar ? 'المبيعات' : 'Sales'),
          BottomNavigationBarItem(icon: const Icon(Icons.person), label: widget.ar ? 'الحساب' : 'Account'),
        ],
      ),
    );
  }
}

class HomeTab extends StatefulWidget {
  final String host, user, pass;
  final bool ar;
  const HomeTab({super.key, required this.host, required this.user, required this.pass, required this.ar});
  @override
  State<HomeTab> createState() => _HomeTabState();
}
class _HomeTabState extends State<HomeTab> {
  String _profile = '20';
  int _count = 1;
  List<String> _created = [];
  String _printer = 'غير متصلة';
  String _msg = '';
  bool _busy = false;

  Future<void> _pickPrinter() async {
    final s1 = await Permission.bluetoothConnect.request();
    await Permission.bluetoothScan.request();
    await Permission.location.request();
    if (!s1.isGranted) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يرجى السماح بإذن البلوتوث')));
      return;
    }
    try {
      try { await PrintBluetoothThermal.disconnect(); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
      final paired = await PrintBluetoothThermal.pairedBluetooths;
      if (!mounted) return;
      if (paired.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('لا توجد طابعة مقترنة')));
        return;
      }
      showModalBottomSheet(
        context: context,
        builder: (_) => ListView(
          children: paired.map((p) => ListTile(
            title: Text(p.name),
            subtitle: Text(p.macAdress),
            onTap: () async {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('جارٍ الاتصال بـ ${p.name}...')));
              final ok = await PrintBluetoothThermal.connect(macPrinterAddress: p.macAdress);
              setState(() => _printer = ok ? p.name : 'غير متصلة');
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'تم الاتصال بالطابعة' : 'تعذر الاتصال بالطابعة')));
            },
          )).toList(),
        ),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر الاتصال بالطابعة')));
    }
  }

  String _quota(String p) => p == '20' ? '2' : p == '50' ? '8' : '20';
  String _days(String p) => p == '20' ? '3d' : p == '50' ? '7d' : '30d';
  String _bytes(String p) => p == '20' ? '2147483648' : p == '50' ? '8589934592' : '21474836480';

  Future<void> _create() async {
    setState(() { _busy = true; _msg = ''; _created = []; });
    try {
      final rnd = Random();
      final names = <String>[];
      for (int i = 0; i < _count; i++) { names.add('${1000000 + rnd.nextInt(9000000)}'); }
      for (final name in names) {
        final res = await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/user/add', ['=name=$name', '=password=$name', '=profile=$_profile', '=server=all']);
        if (res.any((m) => m['__type__'] == '!trap')) { throw Exception('تعذر إنشاء الكارت'); }
        final check = await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/user/print');
        final found = check.where((m) => m['name'] == name).toList();
        if (found.isEmpty) { throw Exception('تعذر إنشاء الكارت'); }
        final id = found.first['.id'] ?? '';
        if (id.isNotEmpty) {
          await MikroTikApi().run(widget.host, widget.user, widget.pass, '/ip/hotspot/user/set', ['=numbers=$id', '=limit-uptime=${_days(_profile)}', '=limit-bytes-total=${_bytes(_profile)}']);
        }
      }
      final p = await SharedPreferences.getInstance();
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final oldCount = p.getInt('sales_${today}_count') ?? 0;
      final oldSum = p.getInt('sales_${today}_sum') ?? 0;
      await p.setInt('sales_${today}_count', oldCount + names.length);
      await p.setInt('sales_${today}_sum', oldSum + (int.parse(_profile) * names.length));
      setState(() { _created = names; _msg = widget.ar ? 'تم إنشاء $_count كارت بنجاح' : 'Created $_count cards successfully'; });
    } catch (e) {
      setState(() => _msg = 'تعذر إنشاء الكارت');
    }
    setState(() => _busy = false);
  }

  Future<void> _print() async {
    if (_created.isEmpty) { setState(() => _msg = 'أنشئ كارت أولاً'); return; }
    try {
      if (_printer == 'غير متصلة') {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('اختر الطابعة أولاً')));
        return;
      }
      for (final name in _created) {
        final bytes = <int>[];
        bytes.addAll([0x1B, 0x40]);
        bytes.addAll([0x1B, 0x61, 0x01]);
        bytes.addAll([0x1D, 0x21, 0x11]);
        bytes.addAll(utf8.encode('FAZLAKA\n'));
        bytes.addAll([0x1D, 0x21, 0x00]);
        bytes.addAll(utf8.encode('01016620065 - 01141418040\n'));
        bytes.addAll(utf8.encode('----------------\n'));
        bytes.addAll([0x1D, 0x21, 0x22]);
        bytes.addAll(utf8.encode('$name\n'));
        bytes.addAll([0x1D, 0x21, 0x00]);
        bytes.addAll(utf8.encode('Price: $_profile | Quota: ${_quota(_profile)}GB\n\n\n'));
        bytes.addAll([0x1D, 0x56, 0x00]);
        await PrintBluetoothThermal.writeBytes(bytes);
        await Future.delayed(const Duration(milliseconds: 500));
      }
      setState(() => _msg = 'تمت الطباعة');
    } catch (e) {
      setState(() => _msg = 'تعذر الطباعة');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
            child: Column(
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(widget.ar ? 'إنشاء كروت' : 'Create Cards', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: petrol))]),
                const SizedBox(height: 12),
                Row(
                  children: ['20', '50', '100'].map((p) => Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: GestureDetector(
                        onTap: () => setState(() => _profile = p),
                        child: Container(height: 60, alignment: Alignment.center, decoration: BoxDecoration(color: _profile == p ? petrol : Colors.grey[200], borderRadius: BorderRadius.circular(14)), child: Text(p, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _profile == p ? Colors.white : Colors.black))),
                      ),
                    ),
                  )).toList(),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(widget.ar ? 'عدد الكروت' : 'Count'),
                    Row(children: [
                      IconButton(onPressed: () { setState(() { if (_count < 100) _count++; }); }, icon: const Icon(Icons.add)),
                      Text('$_count', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                      IconButton(onPressed: () { setState(() { if (_count > 1) _count--; }); }, icon: const Icon(Icons.remove)),
                    ]),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(width: double.infinity, height: 56, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: petrol, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), onPressed: _busy ? null : _create, child: Text(widget.ar ? 'إنشاء' : 'Create', style: const TextStyle(fontSize: 20)))),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, height: 56, child: OutlinedButton(style: OutlinedButton.styleFrom(side: const BorderSide(color: petrol, width: 2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), onPressed: _print, child: Text(widget.ar ? 'طباعة' : 'Print', style: const TextStyle(fontSize: 20, color: petrol)))),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: petrol, side: const BorderSide(color: petrol, width: 2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
              onPressed: _pickPrinter,
              icon: const Icon(Icons.bluetooth, color: petrol),
              label: Text(_printer == 'غير متصلة' ? (widget.ar ? 'توصيل الطابعة' : 'Connect Printer') : '${widget.ar ? 'الطابعة' : 'Printer'}: $_printer', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 12),
          if (_msg.isNotEmpty) Text(_msg, style: const TextStyle(fontWeight: FontWeight.bold)),
          if (_created.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
              child: Column(children: [Text(widget.ar ? 'الكروت الجاهزة' : 'Ready Cards'), ..._created.map((c) => Padding(padding: const EdgeInsets.all(6), child: Text(c, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 2))))]),
            ),
          ],
        ],
      ),
    );
  }
}

class CardsTab extends StatefulWidget {
  final String host, user, pass;
  final bool ar;
  const CardsTab({super.key, required this.host, required this.user, required this.pass, required this.ar});
  @override
  State<CardsTab> createState() => _CardsTabState();
}
class _CardsTabState extends State<CardsTab> {
  List<Map<String, String>> _users = [];
  List<Map<String, String>> _active = [];
  bool _showActive = true;
  bool _loading = false;
  String _err = '';
  @override
  void initState() { super.initState(); _refresh(); }
  Future<void> _refresh() async {
    setState(() { _loading = true; _err = ''; });
    try {
      final api = MikroTikApi();
      await api.connect(widget.host, widget.user, widget.pass);
      final users = await api.command('/ip/hotspot/user/print');
      final active = await api.command('/ip/hotspot/active/print');
      api.close();
      setState(() { _users = users; _active = active; });
    } catch (e) {
      setState(() => _err = 'تعذر الاتصال بالراوتر');
    }
    setState(() => _loading = false);
  }
  @override
  Widget build(BuildContext context) {
    final list = _showActive ? _active : _users;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
            child: Column(
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(widget.ar ? 'حالة الراوتر' : 'Router Status', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)), Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: Colors.green[50], borderRadius: BorderRadius.circular(20)), child: const Text('● متصل', style: TextStyle(color: Colors.green)))]),
                const SizedBox(height: 16),
                Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [Column(children: [Text(widget.ar ? 'الكروت' : 'Cards', style: const TextStyle(color: Colors.grey)), Text('${_users.length}', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: petrol))]), Column(children: [Text(widget.ar ? 'النشط' : 'Active', style: const TextStyle(color: Colors.grey)), Text('${_active.length}', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: petrol))])]),
                const SizedBox(height: 16),
                Row(children: [Expanded(child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: _showActive ? petrol : Colors.white, foregroundColor: _showActive ? Colors.white : petrol), onPressed: () => setState(() => _showActive = true), child: Text(widget.ar ? 'المتصلين الآن' : 'Online Now'))), const SizedBox(width: 8), Expanded(child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: !_showActive ? petrol : Colors.white, foregroundColor: !_showActive ? Colors.white : petrol), onPressed: () => setState(() => _showActive = false), child: Text(widget.ar ? 'كل الكروت' : 'All Cards')))]),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_loading) const CircularProgressIndicator(color: petrol),
          if (_err.isNotEmpty) Text(_err, style: const TextStyle(color: Colors.red)),
          Text(widget.ar ? (_showActive ? 'المتصلين الآن' : 'كل الكروت') : (_showActive ? 'Online Only' : 'All Cards'), style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...list.map((u) => Card(child: ListTile(title: Text(u['user'] ?? u['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)), subtitle: Text(_showActive ? (widget.ar ? 'نشط' : 'Active') : (u['profile'] ?? '')), trailing: _showActive ? const Icon(Icons.circle, color: Colors.green, size: 12) : null))),
          TextButton.icon(onPressed: _refresh, icon: const Icon(Icons.refresh), label: Text(widget.ar ? 'تحديث' : 'Refresh')),
        ],
      ),
    );
  }
}

class SalesTab extends StatefulWidget {
  final bool ar;
  const SalesTab({super.key, required this.ar});
  @override
  State<SalesTab> createState() => _SalesTabState();
}
class _SalesTabState extends State<SalesTab> {
  int _count = 0;
  int _sum = 0;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    setState(() { _count = p.getInt('sales_${today}_count') ?? 0; _sum = p.getInt('sales_${today}_sum') ?? 0; });
  }
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(width: double.infinity, padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [Text(widget.ar ? 'مبيعات اليوم' : "Today's Sales", style: const TextStyle(fontSize: 18)), const SizedBox(height: 16), Text('$_sum ${widget.ar ? 'ج.م' : 'EGP'}', style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: petrol)), Text('$_count ${widget.ar ? 'كارت' : 'cards'}'), TextButton(onPressed: _load, child: Text(widget.ar ? 'تحديث' : 'Refresh'))]))),
    );
  }
}

class AccountTab extends StatefulWidget {
  const AccountTab({super.key});
  @override
  State<AccountTab> createState() => _AccountTabState();
}
class _AccountTabState extends State<AccountTab> {
  int _exp = 0;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() => _exp = p.getInt('exp_today') ?? 0);
  }
  Future<void> _addExp() async {
    final c = TextEditingController();
    final v = await showDialog<String>(context: context, builder: (_) => AlertDialog(title: const Text('إضافة مصروف'), content: TextField(controller: c, keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: 'المبلغ')), actions: [TextButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('إضافة'))]));
    if (v != null && v.isNotEmpty) {
      final p = await SharedPreferences.getInstance();
      await p.setInt('exp_today', _exp + (int.tryParse(v) ?? 0));
      _load();
    }
  }
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)), child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [Column(children: [const Text('الصافي'), Text('$_exp', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: petrol))]), Column(children: [const Text('المصاريف'), Text('$_exp', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold))])])),
        const SizedBox(height: 16),
        SizedBox(width: double.infinity, height: 52, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: petrol), onPressed: _addExp, child: const Text('إضافة مصروف'))),
        const SizedBox(height: 8),
        SizedBox(width: double.infinity, height: 52, child: OutlinedButton(onPressed: () async { final p = await SharedPreferences.getInstance(); await p.setInt('exp_today', 0); _load(); }, child: const Text('تصفير'))),
      ]),
    );
  }
}
