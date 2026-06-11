#!/bin/bash

echo "=== Monitor de Saúde da Aplicação ==="
echo ""

# Cores para output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Verifica se a aplicação está respondendo
echo "1. Verificando saúde da aplicação..."
HEALTH=$(curl -s http://localhost:8080/health)

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Aplicação está saudável${NC}"
    echo "$HEALTH" | python -m json.tool
else
    echo -e "${RED}✗ Aplicação não está respondendo${NC}"
    exit 1
fi

echo ""
echo "2. Métricas da aplicação..."
METRICS=$(curl -s http://localhost:8080/metrics)
echo "$METRICS" | python -m json.tool

echo ""
echo "3. Verificando taxa de sucesso..."
SUCCESS_RATE=$(echo "$METRICS" | python -c "import sys, json; print(json.load(sys.stdin)['success_rate_percent'])")

python -c "exit(0 if float('$SUCCESS_RATE') >= 95.0 else 1)"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Taxa de sucesso: $SUCCESS_RATE% (OK)${NC}"
else
    echo -e "${RED}✗ Taxa de sucesso: $SUCCESS_RATE% (BAIXA)${NC}"
fi