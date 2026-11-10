import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const FazlakaApp());

const petrol = Color(0xFF0A3D3E);
const bgColor = Color(0xFFDFF5F2);

// ===== MikroTik API =====
class MikroTikApi {
  Socket? sock;
  List<int> buf = [];
  Future<void> connect(String host, String user, String pass) async {
    sock = await Socket.connect(host, 8728,
      timeout: const Duration(seconds: 5));
    sock!.listen((d) { buf.addAll(d); });
    final chal = await loginStep(user);
    final chalBytes = hexToBytes(chal);
    final h = md5.convert([0, ...utf8.encode(pass), ...chalBytes]);
    final resp = await send(['/login', '=name=$user', '=response=00$h']);
    if (resp.any((m) => m['__type__'] == '!trap')) {
      throw Exception('بيانات الدخول غير صحيحة');
    }
  }
  List<int> hexToBytes(String hex) {
    final out = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }
  Future<String> loginStep(String user) async {
    final r = await send(['/login', '=name=$user']);
    if (r.isEmpty) return '';
    return r.first['ret'] ?? '';
  }
  Future<List<Map<String, String>>> command(String cmd,
      [List<String> args = const []]) async {
    return send([cmd, ...args]);
  }
  Future<List<Map<String, String>>> send(List<String> words) async {
    buf.clear();
    for (final w in words) { writeWord(w); }
    writeWord('');
    await sock!.flush();
    await Future.delayed(const Duration(milliseconds: 900));
    for (int i = 0; i < 12; i++) {
      if (buf.isNotEmpty) break;
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return parse(buf);
  }
  void writeWord(String w) {
    final b = utf8.encode(w);
    final len = b.length;
    if (len < 0x80) {
      sock!.add([len]);
    } else if (len < 0x4000) {
      sock!.add([0x80 | (len >> 8), len & 0xFF]);
    } else {
      sock!.add([0xC0 | (len >> 16), (len >> 8) & 0xFF, len & 0xFF]);
    }
    sock!.add(b);
  }
  List<Map<String, String>> parse(List<int> data) {
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
        }
      }
      if (len == 0) {
        if (cur.isNotEmpty) { out.add(cur); cur = <String, String>{}; }
        continue;
      }
      if (i + len > data.length) break;
      final word = utf8.decode(data.sublist(i, i + len),
        allowMalformed: true);
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
  void close() { try { sock?.destroy(); } catch (_) {} }
  Future<List<Map<String, String>>> run(String host, String user,
      String pass, String cmd, [List<String> args = const []]) async {
    await connect(host, user, pass);
    try { return await command(cmd, args); } finally { close(); }
  }
}

// ===== App =====
class FazlakaApp extends StatefulWidget {
  const FazlakaApp({super.key});
  @override
  State<FazlakaApp> createState() => _FazlakaAppState();
}
class _FazlakaAppState extends State<FazlakaApp> {
  bool ar = true;
  @override
  void initState() { super.initState(); loadLang(); }
  Future<void> loadLang() async {
    final p = await SharedPreferences.getInstance();
    setState(() => ar = p.getString('lang') != 'en');
  }
  Future<void> toggleLang() async {
    final p = await SharedPreferences.getInstance();
    setState(() => ar = !ar);
    await p.setString('lang', ar ? 'ar' : 'en');
  }
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(scaffoldBackgroundColor: bgColor),
      home: LoginScreen(ar: ar, onToggleLang: toggleLang),
    );
  }
}

// ===== Login + تذكرني =====
class LoginScreen extends StatefulWidget {
  final bool ar;
  final VoidCallback onToggleLang;
  const LoginScreen({super.key, required this.ar, required this.onToggleLang});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}
class _LoginScreenState extends State<LoginScreen> {
  final hostC = TextEditingController(text: '10.10.10.1');
  final userC = TextEditingController();
  final passC = TextEditingController();
  bool loading = false;
  String err = '';
  bool remember = false;
  @override
  void initState() { super.initState(); loadSaved(); }
  Future<void> loadSaved() async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool('remember') ?? false) {
      setState(() {
        remember = true;
        hostC.text = p.getString('saved_host') ?? '10.10.10.1';
        userC.text = p.getString('saved_user') ?? '';
        passC.text = p.getString('saved_pass') ?? '';
      });
    }
  }
  Future<void> login() async {
    setState(() { loading = true; err = ''; });
    try {
      final api = MikroTikApi();
      await api.connect(hostC.text.trim(), userC.text.trim(), passC.text.trim());
      api.close();
      final p = await SharedPreferences.getInstance();
      if (remember) {
        await p.setBool('remember', true);
        await p.setString('saved_host', hostC.text.trim());
        await p.setString('saved_user', userC.text.trim());
        await p.setString('saved_pass', passC.text.trim());
      } else {
        await p.setBool('remember', false);
        await p.remove('saved_host');
        await p.remove('saved_user');
        await p.remove('saved_pass');
      }
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(
        builder: (_) => MainTabs(
          host: hostC.text.trim(),
          user: userC.text.trim(),
          pass: passC.text.trim(),
          ar: widget.ar,
          onToggleLang: widget.onToggleLang,
        ),
      ));
    } catch (e) {
      setState(() => err = 'تعذر الاتصال بالراوتر');
    }
    setState(() => loading = false);
  }
  InputDecoration dec(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14)),
    );
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            Align(
              alignment: Alignment.topLeft,
              child: ElevatedButton(
                onPressed: widget.onToggleLang,
                child: Text(widget.ar ? 'EN' : 'عربي'),
              ),
            ),
            const SizedBox(height: 30),
            const CircleAvatar(
              radius: 45,
              backgroundColor: petrol,
              child: Icon(Icons.wifi, color: Colors.white, size: 45),
            ),
            const SizedBox(height: 16),
            const Text('FAZLAKA', style: TextStyle(
              fontSize: 36, fontWeight: FontWeight.bold,
              color: petrol, letterSpacing: 4)),
            Text(widget.ar ? 'مدير الهوت سبوت' : 'Hotspot Manager'),
            const SizedBox(height: 30),
            TextField(controller: hostC,
              decoration: dec(widget.ar ? 'عنوان السيرفر' : 'Server IP')),
            const SizedBox(height: 12),
            TextField(controller: userC,
              decoration: dec(widget.ar ? 'اسم المستخدم' : 'Username')),
            const SizedBox(height: 12),
            TextField(controller: passC, obscureText: true,
              decoration: dec(widget.ar ? 'كلمة السر' : 'Password')),
            const SizedBox(height: 8),
            Row(children: [
              Checkbox(value: remember, activeColor: petrol,
                onChanged: (v) => setState(() => remember = v ?? false)),
              Text(widget.ar ? 'تذكرني' : 'Remember Me'),
            ]),
            if (err.isNotEmpty)
              Text(err, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity, height: 56,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: petrol,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28))),
                onPressed: loading ? null : login,
                child: loading
                  ? const CircularProgressIndicator(color: Colors.white)
                  : Text(widget.ar ? 'دخول' : 'CONNECT',
                    style: const TextStyle(fontSize: 20)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ===== Tabs =====
class MainTabs extends StatefulWidget {
  final String host, user, pass;
  final bool ar;
  final VoidCallback onToggleLang;
  const MainTabs({super.key, required this.host, required this.user,
    required this.pass, required this.ar, required this.onToggleLang});
  @override
  State<MainTabs> createState() => _MainTabsState();
}
class _MainTabsState extends State<MainTabs> {
  int idx = 0;
  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeTab(host: widget.host, user: widget.user,
        pass: widget.pass, ar: widget.ar),
      CardsTab(host: widget.host, user: widget.user,
        pass: widget.pass, ar: widget.ar),
      SalesTab(ar: widget.ar),
      const AccountTab(),
    ];
    return Scaffold(
      appBar: AppBar(
        backgroundColor: petrol,
        title: const Text('FAZLAKA',
          style: TextStyle(color: Colors.white, letterSpacing: 4)),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: widget.onToggleLang,
            icon: Text(widget.ar ? 'EN' : 'عربي',
              style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: pages[idx],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: idx,
        onTap: (i) => setState(() => idx = i),
        selectedItemColor: petrol,
        items: [
          BottomNavigationBarItem(icon: const Icon(Icons.home),
            label: widget.ar ? 'الرئيسية' : 'Home'),
          BottomNavigationBarItem(icon: const Icon(Icons.credit_card),
            label: widget.ar ? 'الكروت' : 'Cards'),
          BottomNavigationBarItem(icon: const Icon(Icons.bar_chart),
            label: widget.ar ? 'المبيعات' : 'Sales'),
          BottomNavigationBarItem(icon: const Icon(Icons.person),
            label: widget.ar ? 'الحساب' : 'Account'),
        ],
      ),
    );
  }
}

// ===== Home =====
class HomeTab extends StatefulWidget {
  final String host, user, pass;
  final bool ar;
  const HomeTab({super.key, required this.host, required this.user,
    required this.pass, required this.ar});
  @override
  State<HomeTab> createState() => _HomeTabState();
}
class _HomeTabState extends State<HomeTab> {
  String profile = '20';
  int count = 1;
  List<String> created = [];
  String printer = 'غير متصلة';
  String msg = '';
  bool busy = false;

  Future<void> pickPrinter() async {
    final s1 = await Permission.bluetoothConnect.request();
    await Permission.bluetoothScan.request();
    await Permission.location.request();
    if (!s1.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('يرجى السماح بإذن البلوتوث')));
      }
      return;
    }
    try {
      try { await PrintBluetoothThermal.disconnect(); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
      final paired = await PrintBluetoothThermal.pairedBluetooths;
      if (!mounted) return;
      if (paired.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا توجد طابعة مقترنة')));
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
              final ok = await PrintBluetoothThermal.connect(
                macPrinterAddress: p.macAdress);
              setState(() => printer = ok ? p.name : 'غير متصلة');
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(ok
                    ? 'تم الاتصال بالطابعة'
                    : 'تعذر الاتصال بالطابعة')));
              }
            },
          )).toList(),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر الاتصال بالطابعة')));
      }
    }
  }

  String quota(String p) => p == '20' ? '2' : p == '50' ? '8' : '20';
  String days(String p) => p == '20' ? '3d' : p == '50' ? '7d' : '30d';
  String bytes(String p) =>
    p == '20' ? '2147483648' : p == '50' ? '8589934592' : '21474836480';

  Future<void> create() async {
    setState(() { busy = true; msg = ''; created = []; });
    try {
      final rnd = Random();
      final names = <String>[];
      for (int i = 0; i < count; i++) {
        names.add('${1000000 + rnd.nextInt(9000000)}');
      }
      for (final name in names) {
        final res = await MikroTikApi().run(
          widget.host, widget.user, widget.pass,
          '/ip/hotspot/user/add',
          ['=name=$name', '=password=$name',
            '=profile=$profile', '=server=all']);
        if (res.any((m) => m['__type__'] == '!trap')) {
          throw Exception('تعذر إنشاء الكارت');
        }
        final check = await MikroTikApi().run(
          widget.host, widget.user, widget.pass,
          '/ip/hotspot/user/print');
        final found = check.where((m) => m['name'] == name).toList();
        if (found.isEmpty) throw Exception('تعذر إنشاء الكارت');
        final id = found.first['.id'] ?? '';
        if (id.isNotEmpty) {
          await MikroTikApi().run(
            widget.host, widget.user, widget.pass,
            '/ip/hotspot/user/set',
            ['=numbers=$id', '=limit-uptime=${days(profile)}',
              '=limit-bytes-total=${bytes(profile)}']);
        }
      }
      final p = await SharedPreferences.getInstance();
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final oc = p.getInt('sales_${today}_count') ?? 0;
      final os = p.getInt('sales_${today}_sum') ?? 0;
      await p.setInt('sales_${today}_count', oc + names.length);
      final pr = int.parse(profile) * names.length;
      await p.setInt('sales_${today}_sum', os + pr);
      setState(() {
        created = names;
        msg = widget.ar ? 'تم إنشاء $count كارت بنجاح' : 'Created';
      });
    } catch (e) {
      setState(() => msg = 'تعذر إنشاء الكارت');
    }
    setState(() => busy = false);
  }

  Future<void> printCards() async {
    if (created.isEmpty) {
      setState(() => msg = 'أنشئ كارت أولاً');
      return;
    }
    if (printer == 'غير متصلة') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('اختر الطابعة أولاً')));
      }
      return;
    }
    try {
      for (final name in created) {
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
        bytes.addAll(utf8.encode('Price: $profile | Quota: ${quota(profile)}GB\n\n\n'));
        bytes.addAll([0x1D, 0x56, 0x00]);
        await PrintBluetoothThermal.writeBytes(bytes);
        await Future.delayed(const Duration(milliseconds: 500));
      }
      setState(() => msg = 'تمت الطباعة');
    } catch (e) {
      setState(() => msg = 'تعذر الطباعة');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20)),
          child: Column(children: [
            Text(widget.ar ? 'إنشاء كروت' : 'Create Cards',
              style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Row(children: ['20', '50', '100'].map((p) => Expanded(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: GestureDetector(
                  onTap: () => setState(() => profile = p),
                  child: Container(
                    height: 60,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: profile == p ? petrol : Colors.grey[200],
                      borderRadius: BorderRadius.circular(14)),
                    child: Text(p, style: const TextStyle(fontSize: 24)),
                  ),
                ),
              ),
            )).toList()),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(widget.ar ? 'عدد الكروت' : 'Count'),
                Row(children: [
                  IconButton(
                    onPressed: () {
                      setState(() { if (count < 100) count++; });
                    },
                    icon: const Icon(Icons.add),
                  ),
                  Text('$count',
                    style: const TextStyle(fontSize: 22)),
                  IconButton(
                    onPressed: () {
                      setState(() { if (count > 1) count--; });
                    },
                    icon: const Icon(Icons.remove),
                  ),
                ]),
              ],
            ),
          ]),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity, height: 56,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: petrol),
            onPressed: busy ? null : create,
            child: Text(widget.ar ? 'إنشاء' : 'Create'),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity, height: 56,
          child: OutlinedButton(
            onPressed: printCards,
            child: Text(widget.ar ? 'طباعة' : 'Print'),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity, height: 56,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white),
            onPressed: pickPrinter,
            icon: const Icon(Icons.bluetooth, color: petrol),
            label: Text(printer == 'غير متصلة'
              ? (widget.ar ? 'توصيل الطابعة' : 'Connect Printer')
              : '${widget.ar ? 'الطابعة' : 'Printer'}: $printer'),
          ),
        ),
        const SizedBox(height: 12),
        if (msg.isNotEmpty) Text(msg),
        if (created.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16)),
            child: Column(children: [
              Text(widget.ar ? 'الكروت الجاهزة' : 'Ready Cards'),
              ...created.map((c) => Padding(
                padding: const EdgeInsets.all(6),
                child: Text(c,
                  style: const TextStyle(fontSize: 22)),
              )),
            ]),
          ),
        ],
      ]),
    );
  }
}

// ===== Cards =====
class CardsTab extends StatefulWidget {
  final String host, user, pass;
  final bool ar;
  const CardsTab({super.key, required this.host, required this.user,
    required this.pass, required this.ar});
  @override
  State<CardsTab> createState() => _CardsTabState();
}
class _CardsTabState extends State<CardsTab> {
  List<Map<String, String>> users = [];
  List<Map<String, String>> active = [];
  bool showActive = true;
  bool loading = false;
  String err = '';
  @override
  void initState() { super.initState(); refresh(); }
  Future<void> refresh() async {
    setState(() { loading = true; err = ''; });
    try {
      final api = MikroTikApi();
      await api.connect(widget.host, widget.user, widget.pass);
      users = await api.command('/ip/hotspot/user/print');
      active = await api.command('/ip/hotspot/active/print');
      api.close();
    } catch (e) {
      setState(() => err = 'تعذر الاتصال بالراوتر');
    }
    setState(() => loading = false);
  }
  @override
  Widget build(BuildContext context) {
    final list = showActive ? active : users;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Text(widget.ar ? 'الكروت' : 'Cards'),
        Text('${users.length}'),
        Text(widget.ar ? 'النشط' : 'Active'),
        Text('${active.length}'),
        Row(children: [
          Expanded(child: ElevatedButton(
            onPressed: () => setState(() => showActive = true),
            child: Text(widget.ar ? 'المتصلين الآن' : 'Online'))),
          const SizedBox(width: 8),
          Expanded(child: ElevatedButton(
            onPressed: () => setState(() => showActive = false),
            child: Text(widget.ar ? 'كل الكروت' : 'All Cards'))),
        ]),
        if (loading) const CircularProgressIndicator(),
        if (err.isNotEmpty) Text(err),
        ...list.map((u) => Card(
          child: ListTile(
            title: Text(u['user'] ?? u['name'] ?? ''),
            subtitle: Text(u['profile'] ?? ''),
          ),
        )),
        TextButton.icon(
          onPressed: refresh,
          icon: const Icon(Icons.refresh),
          label: Text(widget.ar ? 'تحديث' : 'Refresh'),
        ),
      ]),
    );
  }
}

// ===== Sales =====
class SalesTab extends StatefulWidget {
  final bool ar;
  const SalesTab({super.key, required this.ar});
  @override
  State<SalesTab> createState() => _SalesTabState();
}
class _SalesTabState extends State<SalesTab> {
  int count = 0;
  int sum = 0;
  @override
  void initState() { super.initState(); load(); }
  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    setState(() {
      count = p.getInt('sales_${today}_count') ?? 0;
      sum = p.getInt('sales_${today}_sum') ?? 0;
    });
  }
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.ar ? 'مبيعات اليوم' : 'Today Sales'),
            Text('$sum ${widget.ar ? 'ج.م' : 'EGP'}'),
            Text('$count ${widget.ar ? 'كارت' : 'cards'}'),
            TextButton(
              onPressed: load,
              child: Text(widget.ar ? 'تحديث' : 'Refresh'),
            ),
          ],
        ),
      ),
    );
  }
}

// ===== Account =====
class AccountTab extends StatefulWidget {
  const AccountTab({super.key});
  @override
  State<AccountTab> createState() => _AccountTabState();
}
class _AccountTabState extends State<AccountTab> {
  int exp = 0;
  @override
  void initState() { super.initState(); load(); }
  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    setState(() => exp = p.getInt('exp_today') ?? 0);
  }
  Future<void> addExp() async {
    final c = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('إضافة مصروف'),
        content: TextField(
          controller: c,
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, c.text),
            child: const Text('إضافة'),
          ),
        ],
      ),
    );
    if (v != null && v.isNotEmpty) {
      final p = await SharedPreferences.getInstance();
      await p.setInt('exp_today', exp + (int.tryParse(v) ?? 0));
      load();
    }
  }
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Text('المصاريف: $exp'),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity, height: 52,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: petrol),
            onPressed: addExp,
            child: const Text('إضافة مصروف'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity, height: 52,
          child: OutlinedButton(
            onPressed: () async {
              final p = await SharedPreferences.getInstance();
              await p.setInt('exp_today', 0);
              load();
            },
            child: const Text('تصفير'),
          ),
        ),
      ]),
    );
  }
}
