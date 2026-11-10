import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

const Color kPetrol = Color(0xFF0A3D3E);
const Color kLightTurq = Color(0xFFDFF5F2);

void main() { runApp(const FazlakaApp()); }

class Package {
  final String profile; final int price; final int quotaGB; final int days;
  const Package({required this.profile, required this.price, required this.quotaGB, required this.days});
}
const List<Package> packages = [
  Package(profile: '20', price: 20, quotaGB: 2, days: 3),
  Package(profile: '50', price: 50, quotaGB: 8, days: 7),
  Package(profile: '100', price: 100, quotaGB: 20, days: 30),
];

class FazlakaApp extends StatelessWidget {
  const FazlakaApp({super.key});
  @override Widget build(BuildContext context) {
    return MaterialApp(debugShowCheckedModeBanner: false, title: 'Fazlaka',
      theme: ThemeData(useMaterial3: true, scaffoldBackgroundColor: kLightTurq),
      home: const LoginScreen());
  }
}

class MikrotikApi {
  Socket? _s; Stream<List<int>>? _broad;
  Future<void> connect(String h, int p) async {
    final sock = await Socket.connect(h, p, timeout: const Duration(seconds: 5));
    _s = sock; _broad = sock.asBroadcastStream();
  }
  void _wWord(String w) {
    final b = utf8.encode(w); final l = b.length;
    if (l < 0x80) { _s!.add([l]); }
    else if (l < 0x4000) { _s!.add([(l >> 8) | 0x80, l & 0xFF]); }
    else { _s!.add([(l >> 16) | 0xC0, (l >> 8) & 0xFF, l & 0xFF]); }
    _s!.add(b);
  }
  void _wSen(List<String> ws) { for (final w in ws) _wWord(w); _s!.add([0]); }
  Future<List<Map<String,String>>> _read() async {
    final c = Completer<List<Map<String,String>>>();
    final out = <Map<String,String>>[]; var cur = <String,String>{}; var buf = <int>[];
    StreamSubscription? sub;
    sub = _broad!.listen((d) {
      buf.addAll(d); int i = 0;
      while (i < buf.length) {
        int len = buf[i]; i++;
        if (len == 0) { if (cur.isNotEmpty) { out.add(Map.from(cur)); cur = {}; } continue; }
        if (len & 0x80 != 0) { if (i >= buf.length) break; len = ((len & 0x7F) << 8) | buf[i]; i++; }
        if (i + len > buf.length) break;
        final word = utf8.decode(buf.sublist(i, i+len), allowMalformed: true); i += len;
        if (word == '!done' || word == '!re' || word == '!trap' || word == '!fatal') {
          if (word != '!re') { if (cur.isNotEmpty) { out.add(Map.from(cur)); cur = {}; } }
          if (word == '!done') { if (!c.isCompleted) { c.complete(out); sub?.cancel(); } }
        } else if (word.startsWith('=')) {
          final eq = word.indexOf('=', 1); if (eq > 0) cur[word.substring(1, eq)] = word.substring(eq+1);
        }
      }
      buf = buf.sublist(i);
    }, onError: (e){ if(!c.isCompleted) c.completeError(e); }, onDone: (){ if(!c.isCompleted) c.complete(out); });
    return c.future.timeout(const Duration(seconds: 8), onTimeout: ()=>out);
  }
  Future<void> login(String u, String p) async {
    _wSen(['/login', '=name=$u', '=password=$p']);
    var r = await _read(); String? ret;
    for (var m in r) { if (m.containsKey('ret')) ret = m['ret']; if (m.containsKey('message')) throw m['message']!; }
    if (ret != null) {
      final chal = <int>[]; for (int i=0;i<ret.length;i+=2) chal.add(int.parse(ret.substring(i,i+2), radix:16));
      final pass = md5.convert(utf8.encode(p)).bytes;
      final data = <int>[0]..addAll(chal)..addAll(pass);
      final h = '00' + md5.convert(data).toString();
      _wSen(['/login', '=name=$u', '=response=$h']);
      var r2 = await _read(); for (var m in r2) { if (m.containsKey('message')) throw m['message']!; }
    }
  }
  Future<List<Map<String,String>>> cmd(List<String> ws) async { _wSen(ws); return _read(); }
  void close(){ try{_s?.destroy();}catch(_){} _s=null; _broad=null; }
}

class LoginScreen extends StatefulWidget { const LoginScreen({super.key}); @override State<LoginScreen> createState()=>_LoginState(); }
class _LoginState extends State<LoginScreen> {
  final _ip = TextEditingController(text: '10.10.10.1');
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _show=false,_rem=true,_auto=false,_loading=false; bool isArabic=true;
  @override void initState(){ super.initState(); _load(); }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState((){ _ip.text = p.getString('ip') ?? '10.10.10.1'; _user.text = p.getString('user') ?? ''; _pass.text = p.getString('pass') ?? ''; _rem = p.getBool('remember') ?? true; _auto = p.getBool('auto') ?? false; isArabic = p.getBool('isArabic') ?? true; });
    if (_auto && _user.text.isNotEmpty) _doLogin();
  }
  String t(String ar,String en)=> isArabic?ar:en;
  Future<void> _doLogin() async {
    setState(()=>_loading=true);
    try {
      final api = MikrotikApi(); await api.connect(_ip.text.trim(), 8728); await api.login(_user.text.trim(), _pass.text.trim());
      final p = await SharedPreferences.getInstance();
      if (_rem) { await p.setString('ip', _ip.text.trim()); await p.setString('user', _user.text.trim()); await p.setString('pass', _pass.text.trim()); }
      await p.setBool('remember', _rem); await p.setBool('auto', _auto); await p.setBool('isArabic', isArabic);
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_)=>MainTabs(api: api, isArabic: isArabic)));
    } catch(e){ if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${t('فشل الدخول: ', 'Login failed: ')}$e'))); }
    if(mounted) setState(()=>_loading=false);
  }
  @override Widget build(BuildContext context) {
    return Scaffold(backgroundColor: kLightTurq, body: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: kPetrol)), child: TextButton(onPressed: ()=>setState(()=>isArabic=!isArabic), child: Text(isArabic?'EN':'عربي', style: const TextStyle(color: kPetrol, fontWeight: FontWeight.bold)))),
        const Icon(Icons.notifications_none, color: kPetrol),
      ]),
      const SizedBox(height: 20),
      Container(padding: const EdgeInsets.all(18), decoration: const BoxDecoration(color: kPetrol, shape: BoxShape.circle), child: const Icon(Icons.wifi, size: 44, color: Colors.white)),
      const SizedBox(height: 14),
      const Text('FAZLAKA', textAlign: TextAlign.center, style: TextStyle(fontSize: 36, fontWeight: FontWeight.w900, color: kPetrol, letterSpacing: 4)),
      Text(t('مدير الهوت سبوت','Hotspot Manager'), style: const TextStyle(color: Colors.grey)),
      const SizedBox(height: 20),
      Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t('عنوان السيرفر','SERVER ADDRESS'), style: const TextStyle(fontSize: 12, color: Colors.grey)),
        TextField(controller: _ip, decoration: InputDecoration(prefixIcon: const Icon(Icons.dns, color: kPetrol), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)))),
        const SizedBox(height: 12),
        Text(t('اسم المستخدم','USERNAME'), style: const TextStyle(fontSize: 12, color: Colors.grey)),
        TextField(controller: _user, decoration: InputDecoration(prefixIcon: const Icon(Icons.person, color: kPetrol), hintText: t('اكتب اليوزر','Enter username'), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)))),
        const SizedBox(height: 12),
        Text(t('كلمة السر','PASSWORD'), style: const TextStyle(fontSize: 12, color: Colors.grey)),
        TextField(controller: _pass, obscureText: !_show, decoration: InputDecoration(prefixIcon: const Icon(Icons.lock, color: kPetrol), hintText: t('اكتب الباسورد','Enter password'), suffixIcon: IconButton(icon: Icon(_show?Icons.visibility_off:Icons.visibility), onPressed: ()=>setState(()=>_show=!_show)), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)))),
      ])),
      CheckboxListTile(value: _rem, onChanged: (v)=>setState(()=>_rem=v??true), title: Text(t('تذكرني','Remember Me')), activeColor: kPetrol),
      CheckboxListTile(value: _auto, onChanged: (v)=>setState(()=>_auto=v??false), title: Text(t('دخول تلقائي','Auto Login')), activeColor: kPetrol),
      Text(t('● غير متصل','● Not Connected'), style: const TextStyle(color: Colors.red)),
      const SizedBox(height: 10),
      SizedBox(width: double.infinity, child: ElevatedButton(onPressed: _loading?null:_doLogin, style: ElevatedButton.styleFrom(backgroundColor: kPetrol, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30))), child: _loading ? const CircularProgressIndicator(color: Colors.white) : Text(t('دخول','CONNECT'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)))),
      const SizedBox(height: 8), const Text('RazyTech - 5890IV', style: TextStyle(color: Colors.grey, fontSize: 12)),
    ]))));
  }
}

class MainTabs extends StatefulWidget {
  final MikrotikApi api; final bool isArabic;
  const MainTabs({super.key, required this.api, required this.isArabic});
  @override State<MainTabs> createState()=>_MainTabsState();
}
class _MainTabsState extends State<MainTabs> {
  int idx=0; late bool isArabic;
  @override void initState(){ super.initState(); isArabic=widget.isArabic; }
  String t(String ar,String en)=> isArabic?ar:en;
  @override Widget build(BuildContext context) {
    return Scaffold(body: IndexedStack(index: idx, children: [HomeTab(api: widget.api, isArabic: isArabic), CardsTab(api: widget.api, isArabic: isArabic), SalesTab(isArabic: isArabic), AccountTab(isArabic: isArabic)]),
      bottomNavigationBar: BottomNavigationBar(currentIndex: idx, onTap: (i)=>setState(()=>idx=i), selectedItemColor: kPetrol, unselectedItemColor: Colors.grey, type: BottomNavigationBarType.fixed, backgroundColor: Colors.white, items: [
        BottomNavigationBarItem(icon: const Icon(Icons.home), label: t('الرئيسية','Home')),
        BottomNavigationBarItem(icon: const Icon(Icons.credit_card), label: t('الكروت','Cards')),
        BottomNavigationBarItem(icon: const Icon(Icons.bar_chart), label: t('المبيعات','Sales')),
        BottomNavigationBarItem(icon: const Icon(Icons.person), label: t('الحساب','Account')),
      ]));
  }
}

class HomeTab extends StatefulWidget { final MikrotikApi api; final bool isArabic; const HomeTab({super.key, required this.api, required this.isArabic}); @override State<HomeTab> createState()=>_HomeState(); }
class _HomeState extends State<HomeTab> {
  int sel=1, count=1; List<String> generated=[]; bool busy=false; String status=''; String printerName='No Printer';
  String t(String ar,String en)=> widget.isArabic?ar:en;
  Package get pkg => packages[sel];
  String _rand(){ final r=Random(); String s=''; while(s.length<7) s+=r.nextInt(10).toString(); return s=='0000000'?_rand():s; }
  Future<void> _gen() async {
    setState(()=>busy=true);
    try {
      List<String> news=[];
      for(int i=0;i<count;i++){ String n=_rand(); var r=await widget.api.cmd(['/ip/hotspot/user/add','=name=$n','=password=','=profile=${pkg.profile}','=limit-uptime=${pkg.days}d','=limit-bytes-total=${pkg.quotaGB*1024*1024*1024}']); if(r.any((m)=>m.containsKey('message'))) throw 'Router: ${r.first['message']}'; news.add(n); }
      generated=news;
      final p=await SharedPreferences.getInstance(); final today=DateTime.now().toIso8601String().substring(0,10);
      if(p.getString('stats_date')!=today){ await p.setString('stats_date', today); await p.setInt('today_cards',0); await p.setInt('today_sales',0); }
      await p.setInt('today_cards', (p.getInt('today_cards')??0)+news.length); await p.setInt('today_sales', (p.getInt('today_sales')??0)+news.length*pkg.price);
      setState(()=>status=t('تم انشاء ${news.length} كارت','Created ${news.length} cards'));
    } catch(e){ setState(()=>status='$e'); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); }
    setState(()=>busy=false);
  }
  Future<List<int>> _cardBytes(String num, Package p) async {
    const int w=576, h=720; final rec=ui.PictureRecorder(); final cv=Canvas(rec, Rect.fromLTWH(0,0,w.toDouble(),h.toDouble()));
    cv.drawRect(Rect.fromLTWH(0,0,w.toDouble(),h.toDouble()), Paint()..color=Colors.white);
    void txt(String s,double size,double y,FontWeight fw){ final tp=TextPainter(text: TextSpan(text: s, style: TextStyle(fontSize: size, fontWeight: fw, color: Colors.black)), textDirection: TextDirection.ltr, textAlign: TextAlign.center)..layout(maxWidth: w.toDouble()); tp.paint(cv, Offset((w-tp.width)/2, y)); }
    txt('FAZLAKA',64,80,FontWeight.w900); txt('01016620065 - 01141418040',28,180,FontWeight.bold);
    cv.drawLine(const Offset(40,250), const Offset(w-40,250), Paint()..color=Colors.black..strokeWidth=2);
    txt(num,110,400,FontWeight.w900); txt('Price: ${p.price}  |  Quota: ${p.quotaGB}GB',32,592,FontWeight.bold);
    final pic=rec.endRecording(); final img=await pic.toImage(w,h); final bd=await img.toByteData(format: ui.ImageByteFormat.rawRgba); final rgba=bd!.buffer.asUint8List();
    List<int> out=[]; out.addAll([0x1B,0x40]); out.addAll([0x1B,0x61,0x01]); int bpr=(w+7)~/8; out.addAll([0x1D,0x76,0x30,0x00, bpr&0xFF, (bpr>>8)&0xFF, h&0xFF, (h>>8)&0xFF]);
    for(int y=0;y<h;y++) for(int bx=0;bx<bpr;bx++){ int b=0; for(int bit=0;bit<8;bit++){ int x=bx*8+bit; if(x>=w) continue; int idx=(y*w+x)*4; int gray=(rgba[idx]+rgba[idx+1]+rgba[idx+2])~/3; if(gray<150) b|=(0x80>>bit); } out.add(b); }
    out.addAll(utf8.encode('\n\n\n\n\n\n')); out.addAll([0x1B,0x64,0x05]); out.addAll([0x1D,0x56,0x01]); return out;
  }
  Future<void> _pick() async {
    try {
      final devs=await PrintBluetoothThermal.pairedBluetooths; if(devs.isEmpty) throw t('مفيش طابعة - اعمل Pair الاول','No printer - Pair first');
      if(!mounted) return;
      showDialog(context: context, builder: (_)=>AlertDialog(title: Text(t('اختر الطابعة','Select Printer')), content: SizedBox(width: double.maxFinite, height: 300, child: ListView(children: devs.map((d)=>ListTile(title: Text(d.name), subtitle: Text(d.macAdress), onTap: () async { Navigator.pop(context); final ok=await PrintBluetoothThermal.connect(macPrinterAddress: d.macAdress); setState(()=>printerName=ok?d.name:'Failed'); })).toList())), actions: [TextButton(onPressed: ()=>Navigator.pop(context), child: Text(t('اغلاق','Close')))]));
    } catch(e){ ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); }
  }
  Future<void> _print() async {
    if(generated.isEmpty){ ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('انشئ كروت الأول','Create cards first')))); return; }
    setState(()=>busy=true);
    try { bool con=await PrintBluetoothThermal.connectionStatus; if(!con){ await _pick(); con=await PrintBluetoothThermal.connectionStatus; if(!con) throw t('اختر الطابعة الاول','Select printer first'); } for(final c in generated){ await PrintBluetoothThermal.writeBytes(await _cardBytes(c, pkg)); } setState(()=>status=t('تمت الطباعة','Printed')); } catch(e){ if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); }
    setState(()=>busy=false);
  }
  @override Widget build(BuildContext context) {
    return Scaffold(backgroundColor: kLightTurq, appBar: AppBar(backgroundColor: kPetrol, foregroundColor: Colors.white, centerTitle: true, title: const Text('FAZLAKA', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 4))),
      body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t('انشاء كروت','Create Cards'), textAlign: TextAlign.right, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: kPetrol)),
          const SizedBox(height: 12),
          Row(children: List.generate(packages.length, (i){ final p=packages[i]; final s=i==sel; return Expanded(child: GestureDetector(onTap: ()=>setState(()=>sel=i), child: Container(margin: const EdgeInsets.symmetric(horizontal: 4), padding: const EdgeInsets.symmetric(vertical: 16), decoration: BoxDecoration(color: s?kPetrol:const Color(0xFFF0F0F0), borderRadius: BorderRadius.circular(14)), child: Center(child: Text('${p.price}', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: s?Colors.white:Colors.black)))))); })),
          const SizedBox(height: 14),
          Row(children: [Text(t('عدد الكروت','Number of Cards'), style: const TextStyle(fontWeight: FontWeight.bold)), const Spacer(), IconButton(onPressed: ()=>setState(()=>count=(count-1).clamp(1,100)), icon: const Icon(Icons.remove), style: IconButton.styleFrom(backgroundColor: Colors.white, side: const BorderSide(color: kPetrol))), Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text('$count', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold))), IconButton(onPressed: ()=>setState(()=>count=(count+1).clamp(1,100)), icon: const Icon(Icons.add), style: IconButton.styleFrom(backgroundColor: kPetrol, foregroundColor: Colors.white))]),
        ])),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, child: ElevatedButton(onPressed: busy?null:_gen, style: ElevatedButton.styleFrom(backgroundColor: kPetrol, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))), child: Text(t('انشاء','Create'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)))),
        const SizedBox(height: 10),
        SizedBox(width: double.infinity, child: OutlinedButton(onPressed: busy?null:_print, style: OutlinedButton.styleFrom(side: const BorderSide(color: kPetrol, width: 2), foregroundColor: kPetrol, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))), child: Text(t('طباعة','Print'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)))),
        const SizedBox(height: 10),
        OutlinedButton.icon(onPressed: _pick, icon: const Icon(Icons.bluetooth, color: kPetrol), label: Text('${t('طابعة:','Printer:')} $printerName')),
        if(status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(status, textAlign: TextAlign.center)),
        if(generated.isNotEmpty) Container(margin: const EdgeInsets.only(top: 12), padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Text(t('الكروت المنشأة - راجع قبل الطباعة','Created Cards - Review before printing'), style: const TextStyle(fontWeight: FontWeight.bold)), const SizedBox(height: 10), ...generated.map((c)=>Container(margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(12), decoration: BoxDecoration(border: Border.all(color: kPetrol), borderRadius: BorderRadius.circular(12)), child: Row(children: [const Icon(Icons.credit_card, color: kPetrol), const SizedBox(width: 8), Text(c, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 2))])))])),
      ])));
  }
}

class CardsTab extends StatefulWidget { final MikrotikApi api; final bool isArabic; const CardsTab({super.key, required this.api, required this.isArabic}); @override State<CardsTab> createState()=>_CardsState(); }
class _CardsState extends State<CardsTab> {
  int activeCount=0, usersCount=0; List<Map<String,String>> list=[]; bool showAll=false;
  String t(String ar,String en)=> widget.isArabic?ar:en;
  @override void initState(){ super.initState(); _refresh(); }
  Future<void> _refresh() async { try{ var a=await widget.api.cmd(['/ip/hotspot/active/print']); var u=await widget.api.cmd(['/ip/hotspot/user/print']); setState((){ activeCount=a.length; usersCount=u.length; list=a; showAll=false; }); }catch(_){} }
  @override Widget build(BuildContext context) {
    return Scaffold(backgroundColor: kLightTurq, appBar: AppBar(backgroundColor: kPetrol, foregroundColor: Colors.white, centerTitle: true, title: Text(t('الكروت','Cards')), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh)]),
      body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)), child: Column(children: [
          Row(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(20)), child: Text(t('● متصل','● Online'), style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold))), const Spacer(), Text(t('حالة الراوتر','Router Status'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: kPetrol))]),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [Column(children: [Text(t('النشط','Active'), style: const TextStyle(color: Colors.grey)), Text('$activeCount', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: kPetrol))]), Column(children: [Text(t('الكروت','Cards'), style: const TextStyle(color: Colors.grey)), Text('$usersCount', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: kPetrol))])]),
          const SizedBox(height: 12),
          Row(children: [Expanded(child: ElevatedButton(onPressed: _refresh, style: ElevatedButton.styleFrom(backgroundColor: !showAll?kPetrol:Colors.white, foregroundColor: !showAll?Colors.white:kPetrol, side: const BorderSide(color: kPetrol)), child: Text(t('المتصلين الآن','Active Now')))), const SizedBox(width: 10), Expanded(child: ElevatedButton(onPressed: () async { var u=await widget.api.cmd(['/ip/hotspot/user/print']); setState((){ list=u; showAll=true; }); }, style: ElevatedButton.styleFrom(backgroundColor: showAll?kPetrol:Colors.white, foregroundColor: showAll?Colors.white:kPetrol, side: const BorderSide(color: kPetrol)), child: Text(t('كل الكروت','All Cards'))))]),
        ])),
        const SizedBox(height: 12),
        Text(showAll ? t('كل الكروت','All Cards') : t('المتصلين الآن - النشطين بس','Active Now - Active Only'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        ...list.map((m){ final name=m['user'] ?? m['name'] ?? ''; if(!showAll){ return Container(margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)), child: Row(children: [Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), const Spacer(), Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(20)), child: Text(t('نشط','Active'), style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)))])); } return Container(margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)), child: Row(children: [Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))])); }),
      ])));
  }
}

class SalesTab extends StatefulWidget { final bool isArabic; const SalesTab({super.key, required this.isArabic}); @override State<SalesTab> createState()=>_SalesState(); }
class _SalesState extends State<SalesTab> {
  int cards=0, sales=0; @override void initState(){ super.initState(); _load(); }
  Future<void> _load() async { final p=await SharedPreferences.getInstance(); setState((){ cards=p.getInt('today_cards')??0; sales=p.getInt('today_sales')??0; }); }
  String t(String ar,String en)=> widget.isArabic?ar:en;
  @override Widget build(BuildContext context){ return Scaffold(backgroundColor: kLightTurq, appBar: AppBar(backgroundColor: kPetrol, foregroundColor: Colors.white, centerTitle: true, title: Text(t('المبيعات','Sales'))), body: Padding(padding: const EdgeInsets.all(16), child: Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)), child: Column(children: [Text(t('مبيعات النهاردة',"Today's Sales"), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: kPetrol)), const SizedBox(height: 12), Text('$sales ${t('ج.م','EGP')}', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: kPetrol)), Text('$cards ${t('كارت','cards')}', style: const TextStyle(color: Colors.grey))])))); }
}

class AccountTab extends StatefulWidget { final bool isArabic; const AccountTab({super.key, required this.isArabic}); @override State<AccountTab> createState()=>_AccState(); }
class _AccState extends State<AccountTab> {
  int sales=0, exp=0; @override void initState(){ super.initState(); _load(); }
  Future<void> _load() async { final p=await SharedPreferences.getInstance(); setState((){ sales=p.getInt('today_sales')??0; exp=p.getInt('expenses')??0; }); }
  Future<void> _save() async { final p=await SharedPreferences.getInstance(); await p.setInt('expenses', exp); }
  String t(String ar,String en)=> widget.isArabic?ar:en;
  @override Widget build(BuildContext context){ return Scaffold(backgroundColor: kLightTurq, appBar: AppBar(backgroundColor: kPetrol, foregroundColor: Colors.white, centerTitle: true, title: Text(t('الحساب','Account'))), body: Padding(padding: const EdgeInsets.all(16), child: Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)), child: Column(children: [Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(t('الصافي','Net')), Text('${sales-exp} ${t('ج.م','EGP')}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: kPetrol))]), const Divider(), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(t('المصاريف','Expenses')), Text('$exp ${t('ج.م','EGP')}', style: const TextStyle(fontWeight: FontWeight.bold))]), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(t('المبيعات','Sales')), Text('$sales ${t('ج.م','EGP')}', style: const TextStyle(fontWeight: FontWeight.bold))]), const SizedBox(height: 12), Row(children: [Expanded(child: OutlinedButton(onPressed: () async { final c=TextEditingController(); final v=await showDialog<String>(context: context, builder: (_)=>AlertDialog(title: Text(t('اضافة مصروف','Add Expense')), content: TextField(controller: c, keyboardType: TextInputType.number, decoration: InputDecoration(hintText: t('المبلغ','Amount'))), actions: [TextButton(onPressed: ()=>Navigator.pop(context, c.text), child: Text(t('حفظ','Save')))])); if(v!=null&&v.isNotEmpty){ setState(()=>exp+=int.tryParse(v)??0); _save(); } }, style: OutlinedButton.styleFrom(side: const BorderSide(color: kPetrol)), child: Text(t('اضافة مصروف','Add Expense'), style: const TextStyle(color: kPetrol)))), const SizedBox(width: 10), Expanded(child: ElevatedButton(onPressed: () async { final p=await SharedPreferences.getInstance(); await p.setInt('today_cards',0); await p.setInt('today_sales',0); await p.setInt('expenses',0); _load(); }, style: ElevatedButton.styleFrom(backgroundColor: kPetrol), child: Text(t('تصفير','Reset'), style: const TextStyle(color: Colors.white))))])])))); }
}
