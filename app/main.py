from __future__ import annotations

import io
import math
import re
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from xml.etree.ElementTree import Element, SubElement, tostring

import httpx
import pytesseract
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, Response
from fastapi.staticfiles import StaticFiles
from PIL import Image
from pydantic import BaseModel, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    photon_url: str = "http://localhost:2322"
    osrm_url: str = "http://localhost:5000"
    database_path: str = "data/delivery.db"
    max_orders: int = 50
    tesseract_cmd: str = ""
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")


settings = Settings()
db_path = Path(settings.database_path)
db_path.parent.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="RoutePilot Local", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.mount("/static", StaticFiles(directory=Path(__file__).parent.parent / "static"), name="static")


class DriverIn(BaseModel):
    name: str = Field(min_length=2, max_length=100)
    phone: str = Field(default="", max_length=30)


class Driver(DriverIn):
    id: str
    status: str
    shipment_count: int


class OrderIn(BaseModel):
    customer_name: str = Field(min_length=1, max_length=120)
    address: str = Field(min_length=3, max_length=500)
    driver_id: str | None = None
    notes: str = Field(default="", max_length=500)


class Location(BaseModel):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)


class RouteRequest(BaseModel):
    start: Location
    order_ids: list[str] = Field(min_length=1, max_length=50)


def connect() -> sqlite3.Connection:
    connection = sqlite3.connect(db_path)
    connection.row_factory = sqlite3.Row
    return connection


def init_db() -> None:
    with connect() as connection:
        connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS drivers (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, phone TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'available', created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS orders (
                id TEXT PRIMARY KEY, customer_name TEXT NOT NULL, address TEXT NOT NULL,
                notes TEXT NOT NULL DEFAULT '', driver_id TEXT, status TEXT NOT NULL DEFAULT 'pending',
                latitude REAL, longitude REAL, geocoded_label TEXT, created_at TEXT NOT NULL,
                FOREIGN KEY(driver_id) REFERENCES drivers(id)
            );
            """
        )


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def geocode_result(feature: dict[str, Any]) -> dict[str, Any]:
    coordinates = feature.get("geometry", {}).get("coordinates", [])
    if len(coordinates) != 2:
        raise ValueError("Photon returned an invalid coordinate pair")
    return {
        "longitude": float(coordinates[0]),
        "latitude": float(coordinates[1]),
        "label": feature.get("properties", {}).get("name")
        or feature.get("properties", {}).get("street")
        or "Photon result",
    }


async def geocode(address: str) -> dict[str, Any]:
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            response = await client.get(
                f"{settings.photon_url.rstrip('/')}/api",
                params={"q": address, "limit": 3},
            )
        response.raise_for_status()
    except httpx.RequestError as exc:
        raise HTTPException(
            status_code=503,
            detail="خدمة Photon غير متاحة. شغّل Photon المحلي ثم أعد المحاولة.",
        ) from exc
    except httpx.HTTPStatusError as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Photon returned HTTP {exc.response.status_code}.",
        ) from exc
    features = response.json().get("features", [])
    if not features:
        raise HTTPException(status_code=422, detail=f"No Photon result for address: {address}")
    return geocode_result(features[0])


async def osrm_route(points: list[tuple[float, float]]) -> dict[str, Any]:
    coordinates = ";".join(f"{longitude},{latitude}" for longitude, latitude in points)
    url = f"{settings.osrm_url.rstrip('/')}/route/v1/driving/{coordinates}"
    try:
        async with httpx.AsyncClient(timeout=30) as client:
            response = await client.get(
                url,
                params={"overview": "full", "geometries": "geojson", "steps": "false"},
            )
        response.raise_for_status()
    except httpx.RequestError as exc:
        raise HTTPException(
            status_code=503,
            detail="خدمة OSRM غير متاحة. شغّل OSRM المحلي ثم أعد المحاولة.",
        ) from exc
    except httpx.HTTPStatusError as exc:
        raise HTTPException(
            status_code=502,
            detail=f"OSRM returned HTTP {exc.response.status_code}.",
        ) from exc
    payload = response.json()
    if payload.get("code") != "Ok" or not payload.get("routes"):
        raise HTTPException(status_code=502, detail="OSRM could not calculate a route")
    return payload["routes"][0]


def haversine(a: tuple[float, float], b: tuple[float, float]) -> float:
    radius = 6371.0
    lat1, lon1 = math.radians(a[1]), math.radians(a[0])
    lat2, lon2 = math.radians(b[1]), math.radians(b[0])
    dlat, dlon = lat2 - lat1, lon2 - lon1
    value = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * radius * math.asin(math.sqrt(value))


def stop_key(address: str) -> str:
    normalized = re.sub(r"[\s،,؛;]+", " ", address.casefold()).strip()
    building = re.search(r"\b\d+[a-zا-ي]?\b", normalized)
    if not building:
        return normalized
    street = re.sub(r"\b\d+[a-zا-ي]?\b", " ", normalized)
    street = re.sub(r"\b(?:شقة|شقه|دور|وحدة|وحده|apartment|apt|floor|unit)\b", " ", street)
    street_name = re.sub(r"\s+", " ", street).strip()
    return f"{street_name}|{building.group(0)}"


def order_to_dict(row: sqlite3.Row) -> dict[str, Any]:
    return dict(row)


def driver_to_dict(row: sqlite3.Row, count: int) -> dict[str, Any]:
    return {**dict(row), "shipment_count": count}


init_db()


@app.get("/", response_class=HTMLResponse)
async def dashboard() -> str:
    return (Path(__file__).parent.parent / "static" / "index.html").read_text(encoding="utf-8")


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/api/drivers", response_model=list[Driver])
async def list_drivers() -> list[dict[str, Any]]:
    with connect() as connection:
        rows = connection.execute(
            "SELECT d.*, COUNT(o.id) AS shipment_count FROM drivers d "
            "LEFT JOIN orders o ON o.driver_id = d.id AND o.status != 'delivered' GROUP BY d.id ORDER BY d.created_at DESC"
        ).fetchall()
    return [driver_to_dict(row, row["shipment_count"]) for row in rows]


@app.post("/api/drivers", response_model=Driver, status_code=201)
async def create_driver(payload: DriverIn) -> dict[str, Any]:
    driver_id = f"drv_{uuid.uuid4().hex[:10]}"
    with connect() as connection:
        connection.execute(
            "INSERT INTO drivers(id,name,phone,created_at) VALUES(?,?,?,?)",
            (driver_id, payload.name, payload.phone, now()),
        )
    return {"id": driver_id, **payload.model_dump(), "status": "available", "shipment_count": 0}


@app.put("/api/drivers/{driver_id}", response_model=Driver)
async def update_driver(driver_id: str, payload: DriverIn) -> dict[str, Any]:
    with connect() as connection:
        cursor = connection.execute(
            "UPDATE drivers SET name=?, phone=? WHERE id=?",
            (payload.name, payload.phone, driver_id),
        )
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Driver not found")
        row = connection.execute(
            "SELECT d.*, COUNT(o.id) AS shipment_count FROM drivers d "
            "LEFT JOIN orders o ON o.driver_id=d.id AND o.status != 'delivered' "
            "WHERE d.id=? GROUP BY d.id",
            (driver_id,),
        ).fetchone()
    return driver_to_dict(row, row["shipment_count"])


@app.delete("/api/drivers/{driver_id}", status_code=204)
async def delete_driver(driver_id: str) -> Response:
    with connect() as connection:
        assigned = connection.execute(
            "SELECT COUNT(*) FROM orders WHERE driver_id=? AND status != 'delivered'",
            (driver_id,),
        ).fetchone()[0]
        if assigned:
            raise HTTPException(status_code=409, detail="لا يمكن حذف مندوب لديه شحنات مفتوحة")
        cursor = connection.execute("DELETE FROM drivers WHERE id=?", (driver_id,))
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Driver not found")
    return Response(status_code=204)


@app.get("/api/orders")
async def list_orders() -> list[dict[str, Any]]:
    with connect() as connection:
        rows = connection.execute(
            "SELECT o.*, d.name AS driver_name FROM orders o LEFT JOIN drivers d ON d.id=o.driver_id ORDER BY o.created_at DESC"
        ).fetchall()
    return [order_to_dict(row) for row in rows]


@app.post("/api/orders", status_code=201)
async def create_order(payload: OrderIn) -> dict[str, Any]:
    if payload.driver_id:
        with connect() as connection:
            if not connection.execute("SELECT 1 FROM drivers WHERE id=?", (payload.driver_id,)).fetchone():
                raise HTTPException(status_code=404, detail="Driver not found")
    location = await geocode(payload.address)
    order_id = f"ord_{uuid.uuid4().hex[:10]}"
    with connect() as connection:
        connection.execute(
            "INSERT INTO orders(id,customer_name,address,notes,driver_id,latitude,longitude,geocoded_label,created_at) "
            "VALUES(?,?,?,?,?,?,?,?,?)",
            (order_id, payload.customer_name, payload.address, payload.notes, payload.driver_id,
             location["latitude"], location["longitude"], location["label"], now()),
        )
    return {"id": order_id, **payload.model_dump(), **location, "status": "pending"}


@app.post("/api/orders/from-image", status_code=201)
async def create_order_from_image(
    customer_name: str,
    driver_id: str | None = None,
    file: UploadFile = File(...),
) -> dict[str, Any]:
    content = await file.read()
    try:
        image = Image.open(io.BytesIO(content))
        if settings.tesseract_cmd:
            pytesseract.pytesseract.tesseract_cmd = settings.tesseract_cmd
        extracted = pytesseract.image_to_string(image, lang="ara+eng").strip()
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"Tesseract could not read the image: {exc}") from exc
    if not extracted:
        raise HTTPException(status_code=422, detail="No text was extracted from the invoice")
    return await create_order(OrderIn(customer_name=customer_name, address=extracted, driver_id=driver_id))


@app.post("/api/routes/optimize")
async def optimize_route(payload: RouteRequest) -> dict[str, Any]:
    with connect() as connection:
        placeholders = ",".join("?" for _ in payload.order_ids)
        rows = connection.execute(
            f"SELECT * FROM orders WHERE id IN ({placeholders})", payload.order_ids
        ).fetchall()
    if len(rows) != len(payload.order_ids):
        raise HTTPException(status_code=404, detail="One or more order IDs were not found")
    orders = {row["id"]: order_to_dict(row) for row in rows}
    groups: dict[str, list[dict[str, Any]]] = {}
    for order_id in payload.order_ids:
        order = orders[order_id]
        groups.setdefault(stop_key(order["address"]), []).append(order)
    stops = []
    for key, grouped_orders in groups.items():
        stops.append({
            "id": f"stop_{uuid.uuid4().hex[:10]}",
            "key": key,
            "latitude": sum(item["latitude"] for item in grouped_orders) / len(grouped_orders),
            "longitude": sum(item["longitude"] for item in grouped_orders) / len(grouped_orders),
            "orders": grouped_orders,
        })
    remaining = list(range(len(stops)))
    current = (payload.start.longitude, payload.start.latitude)
    ordered_stops: list[dict[str, Any]] = []
    while remaining:
        next_index = min(
            remaining,
            key=lambda item: haversine(current, (stops[item]["longitude"], stops[item]["latitude"])),
        )
        next_stop = stops[next_index]
        ordered_stops.append(next_stop)
        current = (next_stop["longitude"], next_stop["latitude"])
        remaining.remove(next_index)
    points = [(payload.start.longitude, payload.start.latitude)] + [
        (item["longitude"], item["latitude"]) for item in ordered_stops
    ]
    route = await osrm_route(points)
    ordered: list[dict[str, Any]] = []
    for index, stop in enumerate(ordered_stops, start=1):
        stop["sequence"] = index
        for item in stop["orders"]:
            item["stop_id"] = stop["id"]
            item["stop_sequence"] = index
            ordered.append(item)
    return {
        "orders": ordered,
        "stops": ordered_stops,
        "distance_meters": route["distance"],
        "duration_seconds": route["duration"],
        "geometry": route.get("geometry", {"type": "LineString", "coordinates": []}),
        "algorithm": "nearest-neighbor + OSRM route",
    }


@app.post("/api/routes/gpx")
async def export_gpx(payload: RouteRequest) -> Response:
    optimized = await optimize_route(payload)
    gpx = Element("gpx", {"version": "1.1", "creator": "RoutePilot Local", "xmlns": "http://www.topografix.com/GPX/1/1"})
    metadata = SubElement(gpx, "metadata")
    SubElement(metadata, "name").text = "RoutePilot delivery route"
    track = SubElement(gpx, "trk")
    SubElement(track, "name").text = "Delivery route"
    segment = SubElement(track, "trkseg")
    start_point = SubElement(segment, "trkpt", {"lat": str(payload.start.latitude), "lon": str(payload.start.longitude)})
    SubElement(start_point, "name").text = "Start"
    for stop in optimized["stops"]:
        point = SubElement(segment, "trkpt", {"lat": str(stop["latitude"]), "lon": str(stop["longitude"])})
        SubElement(point, "name").text = f"{stop['sequence']}. {len(stop['orders'])} deliveries"
        SubElement(point, "desc").text = " | ".join(item["address"] for item in stop["orders"])
    content = tostring(gpx, encoding="utf-8", xml_declaration=True)
    return Response(content, media_type="application/gpx+xml", headers={"Content-Disposition": 'attachment; filename="routepilot-route.gpx"'})
