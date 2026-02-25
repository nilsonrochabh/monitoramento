#!/bin/bash

# Configurações
API_URL="https://10.70.96.9"
API_FILE="/api/file/"
API_MESSAGE="/api/message/"
LOG_FILE="/opt/monitoramento/logs/processamento.log"

# Arquivo recebido
ARQUIVO="$1"

# Função para log
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Verificações iniciais
if [ -z "$ARQUIVO" ]; then
    log "ERRO: Nenhum arquivo especificado"
    exit 1
fi

if [ ! -f "$ARQUIVO" ]; then
    log "ERRO: Arquivo não encontrado: $ARQUIVO"
    exit 1
fi

log "=========================================="
log "Iniciando processamento: $(basename "$ARQUIVO")"
log "API URL: $API_URL"

# Informações do arquivo
NOME_ARQUIVO=$(basename "$ARQUIVO")
TAMANHO=$(stat -c%s "$ARQUIVO")
MIME_TYPE=$(file --mime-type -b "$ARQUIVO")
EXTENSAO="${NOME_ARQUIVO##*.}"

log "Nome: $NOME_ARQUIVO"
log "Tamanho: $TAMANHO bytes"
log "Tipo MIME: $MIME_TYPE"
log "Extensão: $EXTENSAO"

# Testar conectividade (opcional, não crítico)
HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" "$API_URL/api/file/")
log "Código HTTP da API: $HTTP_CODE"

# PASSO 1: Upload do arquivo - CORRIGIDO: usando "fileup" em vez de "file"
log "Enviando para API de arquivo: $API_URL$API_FILE"

UPLOAD_RESPONSE=$(curl -k -s  -X POST "$API_URL$API_FILE" \
    -F "fileup=@$ARQUIVO" 2>&1)  # ALTERADO: fileup ao invés de file

CURL_EXIT=$?

if [ $CURL_EXIT -ne 0 ]; then
    log "ERRO: Falha no upload (código curl: $CURL_EXIT)"
    log "Resposta: $UPLOAD_RESPONSE"
    exit 1
fi

if [ -z "$UPLOAD_RESPONSE" ]; then
    log "ERRO: Resposta vazia da API"
    exit 1
fi

log "Resposta do upload: $UPLOAD_RESPONSE"

# Extrair FILE_ID da resposta
FILE_ID=""

# Tentar diferentes padrões de extração
if echo "$UPLOAD_RESPONSE" | grep -q '"id":"[^"]*\.lpcnet"'; then
    FILE_ID=$(echo "$UPLOAD_RESPONSE" | sed -n 's/.*"id":"\([^"]*\.lpcnet\)".*/\1/p')
    log "Tipo: Áudio (formato lpcnet)"
elif echo "$UPLOAD_RESPONSE" | grep -q '"id":"[^"]*\.vvc"'; then
    FILE_ID=$(echo "$UPLOAD_RESPONSE" | sed -n 's/.*"id":"\([^"]*\.vvc\)".*/\1/p')
    log "Tipo: Arquivo (formato vvc)"
else
    FILE_ID=$(echo "$UPLOAD_RESPONSE" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    [ -z "$FILE_ID" ] && FILE_ID=$(echo "$UPLOAD_RESPONSE" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
fi

if [ -z "$FILE_ID" ]; then
    TIMESTAMP=$(date +%s)
    if [[ "$MIME_TYPE" == audio/* ]]; then
        FILE_ID="${TIMESTAMP}.lpcnet"
    else
        FILE_ID="${TIMESTAMP}.vvc"
    fi
    log "AVISO: ID não encontrado, usando gerado: $FILE_ID"
fi

log "File ID obtido: $FILE_ID"

# PASSO 2: Preparar mensagem com formato ISO 8601 UTC
SENT_AT=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
log "sent_at: $SENT_AT"

# Determinar o tipo de conteúdo para o nome da mensagem
case "$MIME_TYPE" in
    audio/*)
        MSG_NAME="🎵 Áudio: $NOME_ARQUIVO"
        ;;
    image/*)
        MSG_NAME="🖼️ Imagem: $NOME_ARQUIVO"
        ;;
    text/*)
        MSG_NAME="📝 Texto: $NOME_ARQUIVO"
        ;;
    *)
        MSG_NAME="📄 Arquivo: $NOME_ARQUIVO"
        ;;
esac

# Escapar aspas no nome do arquivo se houver
NOME_ARQUIVO_ESCAPED=$(echo "$NOME_ARQUIVO" | sed 's/"/\\"/g')

# Construir JSON da mensagem
MESSAGE_JSON=$(cat <<EOF
{
    "name": "$MSG_NAME",
    "text": "Arquivo recebido em $(date '+%d/%m/%Y %H:%M:%S')",
    "dest": ["estacao10"],
    "file": "$NOME_ARQUIVO_ESCAPED",
    "fileid": "$FILE_ID",
    "mimetype": "$MIME_TYPE",
    "draft": false,
    "sent_at": "$SENT_AT",
    "orig": "PU2UIT-6"
}
EOF
)

log "Payload da mensagem: $MESSAGE_JSON"
log "Enviando mensagem para: $API_URL$API_MESSAGE"

# PASSO 3: Enviar mensagem
MESSAGE_RESPONSE=$(curl -k -s --max-time 30 -X POST "$API_URL$API_MESSAGE" \
    -H "Content-Type: application/json" \
    -d "$MESSAGE_JSON")

if [ $? -ne 0 ]; then
    log "ERRO: Falha no envio da mensagem"
    exit 1
fi

log "Resposta da mensagem: $MESSAGE_RESPONSE"

# Extrair ID da mensagem
MESSAGE_ID=$(echo "$MESSAGE_RESPONSE" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
[ -n "$MESSAGE_ID" ] && log "Mensagem ID: $MESSAGE_ID"

log "Processamento concluído com sucesso!"
log "=========================================="

exit 0