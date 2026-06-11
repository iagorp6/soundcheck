#!/bin/bash

set -e

echo "=== Iniciando Rollback ==="

# 1. Para o container atual, se existir
echo "1. Parando versão com problema..."
docker stop minha-app 2>/dev/null || true
docker rm minha-app 2>/dev/null || true

# 2. Verifica se existe versão anterior
if ! docker images | grep -q "sre-app.*previous"; then
    echo "❌ Nenhuma versão anterior encontrada!"
    exit 1
fi

# 3. Inicia a versão anterior
echo "2. Restaurando versão anterior..."
docker run -d -p 8080:8080 --name minha-app sre-app:previous

# 4. Aguarda inicialização
echo "3. Aguardando aplicação iniciar..."
sleep 5

# 5. Testa
echo "4. Testando aplicação..."
if curl -sf http://localhost:8080/health > /dev/null; then
    echo "✅ Rollback concluído com sucesso!"
else
    echo "❌ Rollback falhou!"
    exit 1
fi