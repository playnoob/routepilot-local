# RoutePilot Local

نظام محلي لإدارة مندوبي التوصيل، استخراج عناوين الفواتير، ترتيب المسارات، وتصدير GPX.

## التشغيل

1. ثبّت Python 3.11+ وTesseract OCR (وأضف العربية إلى بيانات Tesseract).
2. شغّل Photon وOSRM محلياً، أو عدّل `PHOTON_URL` و`OSRM_URL` في `.env`.
3. نفّذ:

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

افتح `http://127.0.0.1:8000`. توثيق الـ API متاح في `/docs`.

## تجربة التطبيق من VS Code قبل بناء APK

لا تحتاج إلى Android Studio أو محاكي Android في مرحلة التجربة. ثبّت VS Code، إضافة Flutter، وFlutter SDK فقط، ثم نفّذ من طرفية VS Code:

```powershell
cd "C:\Users\Compu Academy\OneDrive\سطح المكتب\APP FOR MAPS"
.\.venv\Scripts\python.exe -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

وفي طرفية ثانية:

```powershell
cd "C:\Users\Compu Academy\OneDrive\سطح المكتب\APP FOR MAPS\flutter_app"
flutter pub get
flutter run -d chrome --dart-define=API_BASE=http://127.0.0.1:8000
```

أو استخدم المهام الجاهزة من `Terminal > Run Task`:

- `RoutePilot: Start API`
- `RoutePilot: Open Flutter Web`

هذه الطريقة تعرض نفس واجهة التطبيق وتسمح بتجربة إضافة الشحنات وترتيبها، بدون تنزيل APK في كل تعديل. لاختبار GPS الحقيقي نحتاج هاتفاً فعلياً أو محاكي Android لاحقاً.

ملاحظة: Flutter SDK نفسه أكبر من 250 ميجابايت عادةً؛ لا يمكن بناء تطبيق Android أصلي بالكامل ضمن هذا الحد. لكن لا تحتاج Android Studio، ويمكن تأجيل تنزيل أدوات Android وبناء APK إلى النهاية.

## المسارات المهمة

- `GET/POST /api/drivers`: إدارة المندوبين.
- `GET/POST /api/orders`: عرض وإضافة شحنة مع Photon.
- `POST /api/orders/from-image`: رفع صورة فاتورة عبر Tesseract ثم geocoding.
- `POST /api/orders/from-barcode`: استقبال قيمة الباركود وإضافة الشحنة تلقائياً.
- `POST /api/routes/optimize`: ترتيب الشحنات من موقع البداية.
- `POST /api/routes/gpx`: تنزيل ملف GPX لفتحه في OsmAnd أو Organic Maps.

الخوارزمية الحالية تستخدم nearest-neighbor لترتيب 50 نقطة بسرعة، ثم تتحقق من المسار النهائي عبر OSRM.

## خريطة تطبيق المندوب

تطبيق Flutter يعرض خريطة OpenStreetMap مجانية داخل التطبيق، مع:

- علامات مرقمة لكل شحنة.
- خط المسار الذي يعيده OSRM.
- موقع المندوب الحالي كنقطة زرقاء.
- المسافة والمدة التقريبية بعد ترتيب المسار.
- فتح نقطة الشحنة مباشرة في OsmAnd أو Organic Maps.
- تجميع الشحنات التي تشترك في الشارع ورقم العمارة كنقطة توقف واحدة.

Photon وOSRM يظلان محليين كما هو مطلوب. تحتاج طبقة الخريطة نفسها إلى اتصال إنترنت لتحميل مربعات OpenStreetMap؛ ويمكن لاحقاً ربطها بمخدم tiles محلي للـ offline الكامل.

### حالة الخرائط دون إنترنت

دعم `.mbtiles` غير مفعّل في هذه النسخة؛ لأن الملف يجب أن يكون لحافظة/مدينة محددة وحجمه كبير، كما أن طريقة تقديمه تختلف عن بلاطات OSM العادية. التطبيق حالياً يوضح حالة الاتصال ولا يدّعي توفر خريطة offline. إضافة MBTiles تحتاج اختيار نطاق التغطية ثم تضمين الملف أو تنزيله من داخل التطبيق.

## بناء تطبيق Android من GitHub Actions

ملف البناء موجود في `.github/workflows/build.yml` في جذر المستودع، وليس داخل `flutter_app`.

1. ارفع **مجلد المشروع بالكامل** إلى GitHub، بحيث يظهر `app` و`static` و`flutter_app` و`.github` في المستوى الرئيسي.
2. افتح `Actions` ثم `Build Flutter APK`.
3. اضغط `Run workflow`.
4. في خانة `api_base` اكتب عنوان جهاز الكمبيوتر على الشبكة المحلية، مثل:
   `http://192.168.1.20:8000`
5. بعد نجاح العملية، حمّل Artifact باسم `app-release-apk`.

سيقوم Workflow بإنشاء ملفات Android الناقصة تلقائياً، وتثبيت صلاحيات الموقع والإنترنت، ثم بناء APK.

## حل مشكلة اتصال الهاتف

العنوان `10.0.2.2` خاص بمحاكي Android وليس بالهاتف الحقيقي. عند تشغيل الخادم على الكمبيوتر:

1. اعرف عنوان IPv4 للكمبيوتر عبر `ipconfig`، مثلاً `192.168.1.20`.
2. شغّل FastAPI باستخدام `--host 0.0.0.0`.
3. اجعل الهاتف والكمبيوتر على نفس شبكة Wi-Fi.
4. داخل التطبيق افتح رمز الإعدادات وأدخل:
   `http://192.168.1.20:8000`
5. إذا لم يتصل، اسمح لـ Python أو المنفذ 8000 في Windows Firewall.

قبل إضافة عنوان جديد، يجب أن تكون خدمة Photon المحلية تعمل؛ فهي التي تحول العنوان إلى إحداثيات. إذا كانت متوقفة سيظهر الآن تنبيه واضح داخل التطبيق بدلاً من `FormatException` أو `Internal Server Error`.

يحفظ التطبيق عنوان الخادم الذي أدخلته، لذلك لا تحتاج إلى إعادة بناء APK عند تغيير الشبكة.

## إدخال الشحنات بالماسح

من تطبيق الهاتف اضغط أيقونة QR في أعلى الشاشة، ووجّه الكاميرا إلى الباركود. التطبيق يرسل القيمة مباشرة إلى `/api/orders/from-barcode` ثم يعمل geocoding ويضيف الشحنة.

أفضل صيغة للباركود هي JSON مثل:

```json
{"tracking_number":"A-100","customer_name":"أحمد","address":"شارع النصر 10 مدينة نصر"}
```

إذا كان الباركود يحتوي العنوان كنص عادي فسيُستخدم النص كعنوان. أما إذا كان يحتوي رقم تتبع فقط، فلا يمكن استخراج العنوان منه دون API خاص بشركة الشحن؛ رقم التتبع ليس عنواناً بحد ذاته.
