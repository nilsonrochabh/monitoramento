#!/bin/bash

# Configurações
API_URL="https://10.70.96.9"
API_FILE="/api/file/"
API_MESSAGE="/api/message"
PASTA_MONITORADA="/opt/monitoramento/pasta_monitorada"
LOG_FILE="/opt/monitoramento/logs/processamento.log"

# Arquivo recebido (passado como parâmetro)
ARQUIVO="$1"

# Função para log
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}
# Verificar se o parâmetro foi passado
if [ -z "$ARQUIVO" ]; then
    log "ERRO: Nenhum arquivo especificado"
    exit 1
fi

# Verificar se o arquivo existe
if [ ! -f "$ARQUIVO" ]; then
    log "ERRO: Arquivo não encontrado: $ARQUIVO"
    exit 1
fi

# Verificar se o arquivo tem tamanho maior que zero
if [ ! -s "$ARQUIVO" ]; then
    log "ERRO: Arquivo vazio: $ARQUIVO"
    exit 1
fi

# Função principal
processar_arquivo() {
    local arquivo="$1"
    
    # Verificações básicas
    [ ! -f "$arquivo" ] && { log "ERRO: Arquivo não encontrado - $arquivo"; return 1; }
    
    # Ignorar arquivos temporários e scripts
    [[ "$arquivo" == *.tmp ]] || [[ "$arquivo" == *.swp ]] || [[ "$arquivo" == *.sh ]] && return 0
    
    # Informações do arquivo
    local nome=$(basename "$arquivo")
    local tamanho=$(stat -c%s "$arquivo" 2>/dev/null || echo "0")
    local mime=$(file --mime-type -b "$arquivo" 2>/dev/null || echo "application/octet-stream")
    
    log "=========================================="
    log "Processando: $nome"
    log "Tamanho: $tamanho bytes"
    log "Tipo: $mime"
    
    # PASSO 1: Upload do arquivo
    log "Enviando para API de arquivo..."
    
    local upload_response=$(curl -s -k -X POST "$API_URL$API_FILE" \
        -F "file=@$arquivo" \
        -F "filename=$nome" \
        -F "mimetype=$mime")
    
    if [ $? -ne 0 ] || [ -z "$upload_response" ]; then
        log "ERRO: Falha no upload"
        return 1
    fi
    
    log "Upload OK: $upload_response"
    
    # Extrair ID da resposta
    local file_id=$(echo "$upload_response" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
    [ -z "$file_id" ] && file_id=$(echo "$upload_response" | grep -o '"id":[0-9]*' | cut -d':' -f2)
    [ -z "$file_id" ] && file_id="$(date +%s).vvc"  # ID alternativo se não vier da API
    
    log "File ID: $file_id"
    
    # PASSO 2: Preparar mensagem
    local sent_at=$(date '+%a %b %d %Y %H:%M:%S GMT-0300 (Horário Padrão de Brasília)')
    local nome_api=$(echo "$nome" | sed 's/"/\\"/g')  # Escapar aspas se houver
    
    # Criar JSON da mensagem
    local message_json=$(cat <<EOF
{
    "name": "Arquivo: $nome_api",
    "text": "Arquivo recebido em $(date '+%d/%m/%Y %H:%M:%S')",
    "dest": ["estacao10"],
    "file": "$nome_api",
    "fileid": "$file_id",
    "mimetype": "$mime",
    "draft": false,
    "sent_at": "$sent_at",
    "orig": "PU2UIT-6"
}
EOF
)
    
    # PASSO 3: Enviar mensagem
    log "Enviando para API de mensagem..."
    
    local message_response=$(curl -s -k -X POST "$API_URL$API_MESSAGE" \
        -H "Content-Type: application/json" \
        -d "$message_json")
    
    if [ $? -ne 0 ]; then
        log "ERRO: Falha no envio da mensagem"
        return 1
    fi
    
    log "Mensagem enviada: $message_response"
    
    # Extrair ID da mensagem (opcional)
    local msg_id=$(echo "$message_response" | grep -o '"id":[0-9]*' | cut -d':' -f2)
    log "Mensagem ID: $msg_id"
    
    log "Processamento concluído com sucesso!"
    log "=========================================="
    
    # Opcional: mover arquivo processado
    # mv "$arquivo" "/opt/monitoramento/processados/"
    
    return 0
}

# Executar processamento
processar_arquivo "$ARQUIVO"
exit $?