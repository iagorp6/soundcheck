from flask import Flask, jsonify
import os
from datetime import datetime
import time

app = Flask(__name__)

# Métricas simples
metrics = {
    "total_requests": 0,
    "successful_requests": 0,
    "failed_requests": 0,
    "start_time": time.time()
}

@app.route('/')
def home():
    metrics["total_requests"] += 1
    metrics["successful_requests"] += 1
    
    return jsonify({
        "message": "Aplicação SRE Nível 1",
        "version": os.getenv("APP_VERSION", "1.0.0")
    })

@app.route('/health')
def health():
    uptime_seconds = time.time() - metrics["start_time"]
    
    return jsonify({
        "status": "healthy",
        "uptime_seconds": round(uptime_seconds, 2),
        "timestamp": datetime.now().isoformat()
    })

@app.route('/metrics')
def get_metrics():
    """Endpoint com métricas da aplicação"""
    uptime_seconds = time.time() - metrics["start_time"]
    
    # Calcula taxa de sucesso
    if metrics["total_requests"] > 0:
        success_rate = (metrics["successful_requests"] / metrics["total_requests"]) * 100
    else:
        success_rate = 100.0
    
    return jsonify({
        "total_requests": metrics["total_requests"],
        "successful_requests": metrics["successful_requests"],
        "failed_requests": metrics["failed_requests"],
        "success_rate_percent": round(success_rate, 2),
        "uptime_seconds": round(uptime_seconds, 2),
        "uptime_minutes": round(uptime_seconds / 60, 2)
    })

@app.errorhandler(Exception)
def handle_error(error):
    """Captura erros e atualiza métricas"""
    metrics["total_requests"] += 1
    metrics["failed_requests"] += 1
    
    return jsonify({
        "error": str(error)
    }), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)