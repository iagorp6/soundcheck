#!/bin/bash

set -e  # Para na primeira falha

VERSION=$1

if [ -z "$VERSION" ]; then
    echo "Uso: ./deploy.sh <versão>"
    echo "Exemplo: ./deploy.sh 1.0.0"
    exit 1
fi

echo "=== Deploy da versão $VERSION ==="

# 1. Salva a versão anterior, caso exista um container rodando
echo "1. Verificando versão anterior..."
OLD_IMAGE=$(docker inspect --format='{{.Config.Image}}' minha-app 2>/dev/null || true)

if [ -n "$OLD_IMAGE" ]; then
    echo "Versão anterior encontrada: $OLD_IMAGE"
    docker tag "$OLD_IMAGE" sre-app:previous
else
    echo "Nenhuma versão anterior encontrada. Este pode ser o primeiro deploy."
fi

# 2. Build da nova imagem
echo "2. Construindo imagem..."
docker build -t sre-app:$VERSION app/

# 3. Para o container antigo, se existir
echo "3. Parando container antigo..."
docker stop minha-app 2>/dev/null || true
docker rm minha-app 2>/dev/null || true

# 4. Inicia o novo container
echo "4. Iniciando nova versão..."
docker run -d -p 8080:8080 --name minha-app \
    -e APP_VERSION=$VERSION \
    sre-app:$VERSION

# 5. Aguarda inicialização
echo "5. Aguardando aplicação iniciar..."
sleep 5

# 6. Testa o health check
echo "6. Testando health check..."
for i in {1..5}; do
    if curl -sf http://localhost:8080/health > /dev/null; then
        echo "✅ Deploy concluído com sucesso!"
        echo "Versão $VERSION está rodando"
        exit 0
    fi
    echo "Tentativa $i/5 falhou, aguardando..."
    sleep 2
done

echo "❌ Deploy falhou! Execute o rollback."
exit 1