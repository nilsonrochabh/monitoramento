#!/bin/bash

# Prevenir processamento de arquivos .snac (evita loop)
[[ "$1" == *.snac ]] && exit 0

# Configurações
API_URL="https://192.168.0.101"
API_FILE="/api/file/"
API_MESSAGE="/api/message/"
LOG_FILE="/opt/monitoramento/logs/processamento.log"
PASTA_PROCESSADOS="/opt/monitoramento/processados"

# CONFIGURAÇÃO DO VIRTUALENV
VENV_PATH="/home/nil/projetos/compressao/venv/"
COMPRESS_SCRIPT="/opt/monitoramento/compress.py"

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

# Criar pasta de processados se não existir
if [ ! -d "$PASTA_PROCESSADOS" ]; then
    mkdir -p "$PASTA_PROCESSADOS"
    log "Pasta de processados criada: $PASTA_PROCESSADOS"
fi

log "=========================================="
log "Iniciando processamento: $(basename "$ARQUIVO")"

# Informações do arquivo
NOME_ARQUIVO=$(basename "$ARQUIVO")
TAMANHO=$(stat -c%s "$ARQUIVO")
MIME_TYPE=$(file --mime-type -b "$ARQUIVO")
EXTENSAO="${NOME_ARQUIVO##*.}"

log "Nome: $NOME_ARQUIVO"
log "Tamanho: $TAMANHO bytes"
log "Tipo MIME: $MIME_TYPE"
log "Extensão: $EXTENSAO"

# PASSO 1: Verificar se é arquivo de áudio para comprimir
ARQUIVO_PARA_ENVIAR=""
NOME_ARQUIVO_ENVIAR=""
MIME_TYPE_ENVIAR=""
ARQUIVO_COMPRIMIDO=""  # Para controlar se foi comprimido

if [[ "$MIME_TYPE" == audio/* ]] || [[ "$EXTENSAO" == "mp3" ]] || [[ "$EXTENSAO" == "wav" ]] || [[ "$EXTENSAO" == "ogg" ]] || [[ "$EXTENSAO" == "m4a" ]]; then
    log "Arquivo de áudio detectado. Iniciando compressão para .snac..."
    
    # Verificar se script de compressão existe
    if [ ! -f "$COMPRESS_SCRIPT" ]; then
        log "ERRO: Script de compressão não encontrado: $COMPRESS_SCRIPT"
        exit 1
    fi
    
    # Função para executar Python no virtualenv
    executar_python_venv() {
        local script="$1"
        local arquivo="$2"
        
        if [ -d "$VENV_PATH" ] && [ -f "$VENV_PATH/bin/activate" ]; then
            log "Ativando virtualenv: $VENV_PATH"
            (
                source "$VENV_PATH/bin/activate"
                python "$script" "$arquivo"
            )
            return $?
        else
            log "AVISO: Virtualenv não encontrado em $VENV_PATH, usando python3 system"
            python3 "$script" "$arquivo"
            return $?
        fi
    }
    
    # Executar compressão com virtualenv
    log "Executando compressão: $COMPRESS_SCRIPT $ARQUIVO"
    COMPRESS_OUTPUT=$(executar_python_venv "$COMPRESS_SCRIPT" "$ARQUIVO" 2>&1)
    COMPRESS_EXIT=$?
    
    if [ $COMPRESS_EXIT -ne 0 ]; then
        log "ERRO: Falha na compressão (código: $COMPRESS_EXIT)"
        log "Saída: $COMPRESS_OUTPUT"
        exit 1
    fi
    
    log "Compressão concluída: $COMPRESS_OUTPUT"
    
    # O arquivo comprimido tem extensão .snac no mesmo diretório
    ARQUIVO_COMPRIMIDO="${ARQUIVO%.*}.snac"
    
    if [ ! -f "$ARQUIVO_COMPRIMIDO" ]; then
        log "ERRO: Arquivo comprimido não encontrado: $ARQUIVO_COMPRIMIDO"
        exit 1
    fi
    
    # USAR O ARQUIVO COMPRIMIDO PARA ENVIO
    ARQUIVO_PARA_ENVIAR="$ARQUIVO_COMPRIMIDO"
    NOME_ARQUIVO_ENVIAR=$(basename "$ARQUIVO_COMPRIMIDO")
    MIME_TYPE_ENVIAR="application/octet-stream"
    
    TAMANHO_COMPRIMIDO=$(stat -c%s "$ARQUIVO_COMPRIMIDO")
    log "Arquivo comprimido gerado: $NOME_ARQUIVO_ENVIAR"
    log "Tamanho original: $TAMANHO bytes"
    log "Tamanho comprimido: $TAMANHO_COMPRIMIDO bytes"
    
    if [ $TAMANHO -gt 0 ]; then
        ECONOMIA=$(( (TAMANHO - TAMANHO_COMPRIMIDO) * 100 / TAMANHO ))
        log "Taxa de compressão: ${ECONOMIA}% reduzido"
    fi
    
else
    # Não é áudio, enviar o arquivo original
    ARQUIVO_PARA_ENVIAR="$ARQUIVO"
    NOME_ARQUIVO_ENVIAR="$NOME_ARQUIVO"
    MIME_TYPE_ENVIAR="$MIME_TYPE"
    log "Arquivo não é áudio, enviando original"
fi

# Verificar se temos um arquivo para enviar
if [ -z "$ARQUIVO_PARA_ENVIAR" ] || [ ! -f "$ARQUIVO_PARA_ENVIAR" ]; then
    log "ERRO: Nenhum arquivo válido para enviar"
    exit 1
fi

log "Arquivo a ser enviado: $NOME_ARQUIVO_ENVIAR"
log "MIME type para envio: $MIME_TYPE_ENVIAR"

# Testar conectividade (opcional, não crítico)
#HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" "$API_URL/api/file/" 2>/dev/null || echo "000")
#log "Código HTTP da API: $HTTP_CODE"

# PASSO 2: Upload do arquivo
log "Enviando para API de arquivo: $API_URL$API_FILE"


UPLOAD_RESPONSE=$(curl -k -s -X POST "$API_URL$API_FILE" \
    -F "fileup=@$ARQUIVO_PARA_ENVIAR" 2>&1)

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

# PASSO 3: Preparar mensagem com formato ISO 8601 UTC
SENT_AT=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
log "sent_at: $SENT_AT"

# Determinar o tipo de conteúdo para o nome da mensagem
NOME_EXIBICAO="$NOME_ARQUIVO"

if [[ "$ARQUIVO_PARA_ENVIAR" == *.snac ]]; then
    MSG_NAME="🎵 Áudio (comprimido SNAC): $NOME_EXIBICAO"
    MIME_TYPE_MSG="$MIME_TYPE"  # Mantém o MIME original na mensagem
else
    case "$MIME_TYPE" in
        audio/*)
            MSG_NAME="🎵 Áudio: $NOME_EXIBICAO"
            ;;
        image/*)
            MSG_NAME="🖼️ Imagem: $NOME_EXIBICAO"
            ;;
        text/*)
            MSG_NAME="📝 Texto: $NOME_EXIBICAO"
            ;;
        *)
            MSG_NAME="📄 Arquivo: $NOME_EXIBICAO"
            ;;
    esac
    MIME_TYPE_MSG="$MIME_TYPE"
fi

# Escapar aspas no nome do arquivo se houver
NOME_EXIBICAO_ESCAPED=$(echo "$NOME_EXIBICAO" | sed 's/"/\\"/g')

# Construir JSON da mensagem
MESSAGE_JSON=$(cat <<EOF
{
    "name": "$MSG_NAME",
    "text": "Arquivo recebido em $(date '+%d/%m/%Y %H:%M:%S')",
    "dest": ["estacao10"],
    "file": "$NOME_EXIBICAO_ESCAPED",
    "fileid": "$FILE_ID",
    "mimetype": "$MIME_TYPE_MSG",
    "draft": false,
    "sent_at": "$SENT_AT",
    "orig": "PU2UIT-6"
}
EOF
)

log "Payload da mensagem: $MESSAGE_JSON"
log "Enviando mensagem para: $API_URL$API_MESSAGE"

# PASSO 4: Enviar mensagem
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

# PASSO 5: Mover arquivos para pasta de processados
log "Movendo arquivos para pasta de processados..."

# Data para organização (opcional)
DATA_PASTA=$(date +%Y%m%d)
DESTINO_COMPLETO="$PASTA_PROCESSADOS/$DATA_PASTA"



# Ou usar apenas a pasta processados sem subpastas
DESTINO="$PASTA_PROCESSADOS"

# Mover arquivo original
if [ -f "$ARQUIVO" ]; then
    mv "$ARQUIVO" "$DESTINO/"
    log "Arquivo original movido: $NOME_ARQUIVO → $DESTINO/"
fi

# Mover arquivo comprimido .snac se existir
if [ -n "$ARQUIVO_COMPRIMIDO" ] && [ -f "$ARQUIVO_COMPRIMIDO" ]; then
    mv "$ARQUIVO_COMPRIMIDO" "$DESTINO/"
    log "Arquivo comprimido movido: $(basename "$ARQUIVO_COMPRIMIDO") → $DESTINO/"
fi

log "Processamento concluído com sucesso!"
log "=========================================="

exit 0