import sys
sys.path.insert(0, '../app')

from app import app
import pytest

@pytest.fixture
def client():
    app.config['TESTING'] = True
    with app.test_client() as client:
        yield client

def test_home_endpoint(client):
    """Testa se o endpoint principal funciona"""
    response = client.get('/')
    assert response.status_code == 200
    data = response.get_json()
    assert 'message' in data
    assert 'version' in data

def test_health_endpoint(client):
    """Testa se o endpoint de saúde funciona"""
    response = client.get('/health')
    assert response.status_code == 200
    data = response.get_json()
    assert data['status'] == 'healthy'
    assert 'uptime_seconds' in data
    assert 'timestamp' in data

def test_metrics_endpoint(client):
    """Testa se o endpoint de métricas funciona"""
    response = client.get('/metrics')
    assert response.status_code == 200
    data = response.get_json()
    assert 'total_requests' in data
    assert 'successful_requests' in data
    assert 'failed_requests' in data
    assert 'success_rate_percent' in data
    assert 'uptime_seconds' in data
    assert 'uptime_minutes' in data

def test_request_counter(client):
    """Testa se o contador de requisições funciona"""
    metrics_before = client.get('/metrics').get_json()
    total_before = metrics_before['total_requests']

    client.get('/')

    metrics_after = client.get('/metrics').get_json()
    total_after = metrics_after['total_requests']

    assert total_after > total_before