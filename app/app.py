from flask import Flask, jsonify
import os
from datetime import datetime

app = Flask(__name__)

# Contador simples de requisições
request_count = 0

@app.route('/')
def home():
    global request_count
    request_count += 1
    return jsonify({
        "message": "Aplicação SRE Nível 1",
        "version": os.getenv("APP_VERSION", "1.0.0"),
        "total_requests": request_count
    })

@app.route('/health')
def health():
    return jsonify({
        "status": "healthy",
        "timestamp": datetime.now().isoformat()
    })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)