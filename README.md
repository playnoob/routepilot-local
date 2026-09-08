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

سيقوم Workflow بإنشاء ملفات Android الناقصة تلقائياً، وتثبيت صلاحيات الموقع والإنترنت، ثم بناء APK.

## حل مشكلة اتصال الهاتف

العنوان `10.0.2.2` خاص بمحاكي Android وليس بالهاتف الحقيقي. عند تشغيل الخادم على الكمبيوتر:

1. اعرف عنوان IPv4 للكمبيوتر عبر `ipconfig`، مثلاً `192.168.1.20`.
2. شغّل FastAPI باستخدام `--host 0.0.0.0`.
3. اجعل الهاتف والكمبيوتر على نفس شبكة Wi-Fi.
4. داخل التطبيق افتح رمز الإعدادات وأدخل:
   `http://192.168.1.20:8000`
5. إذا لم يتصل، اسمح لـ Python أو المنفذ 8000 في Windows Firewall.

يحفظ التطبيق عنوان الخادم الذي أدخلته، لذلك لا تحتاج إلى إعادة بناء APK عند تغيير الشبكة.
