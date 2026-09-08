import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const compiledApiBase = String.fromEnvironment('API_BASE', defaultValue: 'http://10.0.2.2:8000');

void main() => runApp(const RoutePilotApp());

class RoutePilotApp extends StatelessWidget {
  const RoutePilotApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'RoutePilot',
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffc8f169)), useMaterial3: true),
        home: const OrdersPage(),
      );
}

class OrdersPage extends StatefulWidget {
  const OrdersPage({super.key});
  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  List<dynamic> orders = [];
  bool loading = true;
  String? error;
  String apiBase = compiledApiBase;

  Future<void> loadSettings() async {
    final preferences = await SharedPreferences.getInstance();
    setState(() => apiBase = preferences.getString('api_base') ?? compiledApiBase);
    await load();
  }

  Future<void> editServerUrl() async {
    final controller = TextEditingController(text: apiBase);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('عنوان الخادم'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'http://192.168.1.20:8000',
            labelText: 'رابط FastAPI',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('حفظ')),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.trim().isEmpty) return;
    final normalized = value.trim().replaceFirst(RegExp(r'/$'), '');
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('api_base', normalized);
    setState(() => apiBase = normalized);
    await load();
  }

  Future<void> load() async {
    try {
      final response = await http.get(Uri.parse('$apiBase/api/orders'));
      if (response.statusCode >= 400) throw Exception('تعذر الاتصال بالخادم المحلي');
      setState(() { orders = jsonDecode(response.body) as List<dynamic>; loading = false; error = null; });
    } catch (exception) {
      setState(() { loading = false; error = exception.toString(); });
    }
  }
  Future<void> optimize() async {
    if (orders.isEmpty) return;
    try {
      final permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        throw Exception('يرجى السماح للتطبيق بالوصول إلى الموقع');
      }
      final position = await Geolocator.getCurrentPosition();
      final response = await http.post(Uri.parse('$apiBase/api/routes/optimize'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({
        'start': {'latitude': position.latitude, 'longitude': position.longitude},
        'order_ids': orders.map((order) => order['id']).toList(),
      }));
      if (response.statusCode >= 400) throw Exception('تعذر حساب المسار');
      final result = jsonDecode(response.body) as Map<String, dynamic>;
      setState(() => orders = result['orders'] as List<dynamic>);
    } catch (exception) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(exception.toString())));
    }
  }
  @override
  void initState() { super.initState(); loadSettings(); }
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('RoutePilot'), actions: [
          IconButton(onPressed: editServerUrl, tooltip: 'إعداد الخادم', icon: const Icon(Icons.settings_outlined)),
          IconButton(onPressed: load, icon: const Icon(Icons.refresh)),
        ]),
        body: loading ? const Center(child: CircularProgressIndicator()) : error != null ? Center(child: Text(error!)) : RefreshIndicator(
          onRefresh: load,
          child: ListView.builder(itemCount: orders.length, itemBuilder: (_, index) {
            final order = orders[index] as Map<String, dynamic>;
            return ListTile(leading: CircleAvatar(child: Text('${index + 1}')), title: Text(order['customer_name'] as String), subtitle: Text(order['address'] as String), trailing: Text(order['driver_name'] as String? ?? 'غير معيّنة'));
          }),
        ),
        floatingActionButton: FloatingActionButton.extended(onPressed: optimize, label: const Text('رتّب المسار'), icon: const Icon(Icons.route)),
      );
}
