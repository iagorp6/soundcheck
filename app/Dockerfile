# Usa uma imagem base leve do Python
FROM python:3.9-slim

# Define o diretório de trabalho
WORKDIR /app

# Copia o arquivo de dependências
COPY requirements.txt .

# Instala as dependências
RUN pip install --no-cache-dir -r requirements.txt

# Copia o código da aplicação
COPY app.py .

# Expõe a porta da aplicação
EXPOSE 8080

# Comando para iniciar a aplicação
CMD ["python", "app.py"]