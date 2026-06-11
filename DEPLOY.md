\# Guia de Deploy e Rollback



Este documento descreve o processo de deploy, monitoramento e rollback da aplicação SRE Nível 1.



\## Como fazer deploy



\### 1. Construir e testar localmente



```bash

docker build -t sre-app:1.0.0 app/

docker run -p 8080:8080 sre-app:1.0.0

