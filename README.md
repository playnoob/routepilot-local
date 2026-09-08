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
uvicorn app.main:app --reload
```

افتح `http://127.0.0.1:8000`. توثيق الـ API متاح في `/docs`.

## المسارات المهمة

- `GET/POST /api/drivers`: إدارة المندوبين.
- `GET/POST /api/orders`: عرض وإضافة شحنة مع Photon.
- `POST /api/orders/from-image`: رفع صورة فاتورة عبر Tesseract ثم geocoding.
- `POST /api/routes/optimize`: ترتيب الشحنات من موقع البداية.
- `POST /api/routes/gpx`: تنزيل ملف GPX لفتحه في OsmAnd أو Organic Maps.

الخوارزمية الحالية تستخدم nearest-neighbor لترتيب 50 نقطة بسرعة، ثم تتحقق من المسار النهائي عبر OSRM.

## بناء تطبيق Android من GitHub Actions

ملف البناء موجود في `.github/workflows/build.yml` في جذر المستودع، وليس داخل `flutter_app`.

1. ارفع **مجلد المشروع بالكامل** إلى GitHub، بحيث يظهر `app` و`static` و`flutter_app` و`.github` في المستوى الرئيسي.
2. افتح `Actions` ثم `Build Flutter APK`.
3. اضغط `Run workflow`.
4. في خانة `api_base` اكتب عنوان جهاز الكمبيوتر على الشبكة المحلية، مثل:
   `http://192.168.1.20:8000`
5. بعد نجاح العملية، حمّل Artifact باسم `app-release-apk`.

سيقوم Workflow بإنشاء ملفات Android الناقصة تلقائياً، تثبيت صلاحية الموقع، ثم بناء APK. يجب أن يكون الهاتف والكمبيوتر على نفس شبكة Wi-Fi، وأن يسمح Windows Firewall بالمنفذ 8000.
