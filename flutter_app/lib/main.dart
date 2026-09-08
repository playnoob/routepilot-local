import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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
  Map<String, dynamic>? routeGeometry;
  double? routeDistanceMeters;
  double? routeDurationSeconds;
  LatLng? currentLocation;
  bool optimizing = false;
  List<dynamic> routeStops = [];

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

  String apiErrorMessage(http.Response response, String fallback) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic> && body['detail'] != null) {
        return body['detail'].toString();
      }
    } on FormatException {
      // The server may return a plain-text or proxy error page.
    }
    final text = response.body.trim();
    return text.isEmpty || text.length > 180 ? fallback : '$fallback: $text';
  }

  Future<void> addOrder() async {
    final customerController = TextEditingController();
    final addressController = TextEditingController();
    final value = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إضافة شحنة'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: customerController,
              decoration: const InputDecoration(labelText: 'اسم العميل'),
            ),
            TextField(
              controller: addressController,
              decoration: const InputDecoration(labelText: 'العنوان بالتفصيل'),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('إضافة')),
        ],
      ),
    );
    if (value != true) {
      customerController.dispose();
      addressController.dispose();
      return;
    }

    Future<void> scanShipment() async {
      final value = await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (_) => const BarcodeScannerPage()),
      );
      if (value == null || value.trim().isEmpty) return;
      try {
        final response = await http.post(
          Uri.parse('$apiBase/api/orders/from-barcode'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'value': value.trim()}),
        );
        if (response.statusCode >= 400) {
          throw Exception(apiErrorMessage(response, 'لم يحتوي الباركود على عنوان صالح'));
        }
        await load();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تمت قراءة الشحنة وإضافتها للخريطة')),
          );
        }
      } catch (exception) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$exception')));
        }
      }
    }
    final customerName = customerController.text.trim();
    final address = addressController.text.trim();
    customerController.dispose();
    addressController.dispose();
    if (customerName.isEmpty || address.length < 3) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('اكتب اسم العميل والعنوان بالتفصيل')),
        );
      }
      return;
    }
    try {
      final response = await http.post(
        Uri.parse('$apiBase/api/orders'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'customer_name': customerName, 'address': address}),
      );
      if (response.statusCode >= 400) {
        throw Exception(apiErrorMessage(response, 'تعذر إضافة الشحنة'));
      }

      await load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تمت إضافة الشحنة وتحديد موقعها')),
        );
      }
    } catch (exception) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$exception')));
      }
    }
  }
  Future<void> optimize() async {
    if (orders.isEmpty) return;
    try {
      setState(() => optimizing = true);
      final permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        throw Exception('يرجى السماح للتطبيق بالوصول إلى الموقع');
      }
      final position = await Geolocator.getCurrentPosition();
      final start = LatLng(position.latitude, position.longitude);
      final response = await http.post(Uri.parse('$apiBase/api/routes/optimize'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({
        'start': {'latitude': position.latitude, 'longitude': position.longitude},
        'order_ids': orders.map((order) => order['id']).toList(),
      }));
      if (response.statusCode >= 400) throw Exception('تعذر حساب المسار');
      final result = jsonDecode(response.body) as Map<String, dynamic>;
      setState(() {
        orders = result['orders'] as List<dynamic>;
        routeStops = result['stops'] as List<dynamic>? ?? [];
        routeGeometry = result['geometry'] as Map<String, dynamic>?;
        routeDistanceMeters = (result['distance_meters'] as num?)?.toDouble();
        routeDurationSeconds = (result['duration_seconds'] as num?)?.toDouble();
        currentLocation = start;
        optimizing = false;
      });
    } catch (exception) {
      setState(() => optimizing = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(exception.toString())));
    }
  }

  List<LatLng> get routePoints {
      final coordinates = routeGeometry?['coordinates'] as List<dynamic>? ?? [];
      return coordinates
          .whereType<List<dynamic>>()
          .where((point) => point.length >= 2)
          .map((point) => LatLng((point[1] as num).toDouble(), (point[0] as num).toDouble()))
          .toList();
    }

  Future<void> openNavigation(Map<String, dynamic> order, {required bool osmand}) async {
      final latitude = order['latitude'];
      final longitude = order['longitude'];
      if (latitude is! num || longitude is! num) return;
      final label = Uri.encodeComponent(order['customer_name'] as String? ?? 'Delivery');
      final url = osmand
          ? Uri.parse('osmand.navigation:q=$latitude,$longitude&title=$label')
          : Uri.parse('om://map?v=1&ll=$latitude,$longitude&n=$label');
      if (!await launchUrl(url, mode: LaunchMode.externalApplication) && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('التطبيق الملاحي غير مثبت')));
      }
    }

  Widget buildMap() {
      final markers = <Marker>[
        if (currentLocation != null)
          Marker(
            point: currentLocation!,
            width: 44,
            height: 44,
            child: const Icon(Icons.my_location, color: Colors.blue, size: 30),
          ),
        ...(routeStops.isNotEmpty ? routeStops : orders).asMap().entries.where((entry) {
          final order = entry.value as Map<String, dynamic>;
          return order['latitude'] is num && order['longitude'] is num;
        }).map((entry) {
          final stop = entry.value as Map<String, dynamic>;
          final stopOrders = stop['orders'] as List<dynamic>? ?? [];
          return Marker(
            point: LatLng((stop['latitude'] as num).toDouble(), (stop['longitude'] as num).toDouble()),
            width: 44,
            height: 44,
            child: GestureDetector(
              onTap: () => stopOrders.isNotEmpty
                  ? showOrderActions(stopOrders.first as Map<String, dynamic>, entry.key + 1)
                  : showOrderActions(stop, entry.key + 1),
              child: CircleAvatar(
                backgroundColor: const Color(0xffc8f169),
                child: Text('${stop['sequence'] ?? entry.key + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          );
        }),
      ];
      final center = currentLocation ??
          (markers.isNotEmpty ? markers.first.point : const LatLng(30.0444, 31.2357));
      return SizedBox(
        height: 330,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: FlutterMap(
            options: MapOptions(initialCenter: center, initialZoom: 12),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.routepilot.routepilot_mobile',
              ),
              if (routePoints.length > 1)
                PolylineLayer(
                  polylines: [Polyline(points: routePoints, strokeWidth: 5, color: const Color(0xffff7048))],
                ),
              MarkerLayer(markers: markers),
              RichAttributionWidget(
                attributions: [TextSourceAttribution('OpenStreetMap contributors')],
              ),
            ],
          ),
        ),
      );
  }

    Future<void> showOrderActions(Map<String, dynamic> order, int sequence) async {
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('الشحنة رقم $sequence', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                Text(order['customer_name'] as String? ?? ''),
                Text(order['address'] as String? ?? ''),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: () { Navigator.pop(context); openNavigation(order, osmand: true); },
                  icon: const Icon(Icons.navigation),
                  label: const Text('فتح في OsmAnd'),
                ),
                OutlinedButton.icon(
                  onPressed: () { Navigator.pop(context); openNavigation(order, osmand: false); },
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('فتح في Organic Maps'),
                ),
              ],
            ),
          ),
        ),
      );
    }
  @override
  void initState() { super.initState(); loadSettings(); }
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('RoutePilot'), actions: [
          IconButton(onPressed: editServerUrl, tooltip: 'إعداد الخادم', icon: const Icon(Icons.settings_outlined)),
          IconButton(onPressed: scanShipment, tooltip: 'مسح باركود', icon: const Icon(Icons.qr_code_scanner)),
          IconButton(onPressed: load, icon: const Icon(Icons.refresh)),
        ]),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.cloud_off, size: 48),
                          const SizedBox(height: 12),
                          const Text('تعذر الاتصال بالخادم'),
                          const SizedBox(height: 8),
                          Text(error!, textAlign: TextAlign.center),
                          const SizedBox(height: 16),
                          OutlinedButton(onPressed: editServerUrl, child: const Text('تغيير عنوان الخادم')),
                        ],
                      ),
                    ),
                  )
                : orders.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.inventory_2_outlined, size: 64),
                              const SizedBox(height: 16),
                              const Text('لا توجد شحنات حتى الآن', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 8),
                              const Text('أضف أول شحنة من الهاتف أو من لوحة الإدارة.', textAlign: TextAlign.center),
                              const SizedBox(height: 20),
                              FilledButton.icon(onPressed: scanShipment, icon: const Icon(Icons.qr_code_scanner), label: const Text('مسح باركود الشحنة')),
                              const SizedBox(height: 10),
                              OutlinedButton.icon(onPressed: addOrder, icon: const Icon(Icons.edit_location_alt), label: const Text('إضافة يدوية بديلة')),
                            ],
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: load,
                        child: ListView(
                          padding: const EdgeInsets.all(14),
                          children: [
                            buildMap(),
                            const SizedBox(height: 14),
                            if (routeGeometry != null)
                              Card(
                                child: ListTile(
                                  leading: const Icon(Icons.route),
                                  title: const Text('المسار جاهز'),
                                  subtitle: Text(
                                    '${routeDistanceMeters?.round() ?? 0} متر • '
                                    '${((routeDurationSeconds ?? 0) / 60).round()} دقيقة تقريباً',
                                  ),
                                ),
                              ),
                            ...orders.asMap().entries.map((entry) {
                              final order = entry.value as Map<String, dynamic>;
                              return Card(
                                child: ListTile(
                                  leading: CircleAvatar(child: Text('${entry.key + 1}')),
                                  title: Text(order['customer_name'] as String),
                                  subtitle: Text(order['address'] as String),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.navigation_outlined),
                                    onPressed: () => showOrderActions(order, entry.key + 1),
                                  ),
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
        floatingActionButton: orders.isEmpty
            ? null
            : FloatingActionButton.extended(
                onPressed: optimizing ? null : optimize,
                label: const Text('رتّب المسار'),
                icon: const Icon(Icons.route),
              ),
      );
}

class BarcodeScannerPage extends StatefulWidget {
  const BarcodeScannerPage({super.key});

  @override
  State<BarcodeScannerPage> createState() => _BarcodeScannerPageState();
}

class _BarcodeScannerPageState extends State<BarcodeScannerPage> {
  bool handled = false;

  void onDetect(BarcodeCapture capture) {
    if (handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.trim().isNotEmpty) {
        handled = true;
        Navigator.pop(context, value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('مسح باركود الشحنة'),
          actions: [
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
              tooltip: 'إلغاء',
            ),
          ],
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(onDetect: onDetect),
            Center(
              child: Container(
                width: 280,
                height: 150,
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xffc8f169), width: 3),
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
            ),
            const Positioned(
              left: 24,
              right: 24,
              bottom: 36,
              child: Text(
                'وجّه الكاميرا إلى الباركود الموجود على الشحنة',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      );
