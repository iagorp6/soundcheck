import sys
import os

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../app")))

from app import app


def test_health_endpoint():
    client = app.test_client()
    response = client.get("/health")

    assert response.status_code == 200

    data = response.get_json()
    assert data["status"] == "healthy"
    assert "timestamp" in data


def test_home_endpoint():
    client = app.test_client()
    response = client.get("/")

    assert response.status_code == 200

    data = response.get_json()
    assert "message" in data