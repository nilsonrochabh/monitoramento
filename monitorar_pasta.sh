#!/bin/bash

# Configurações
PASTA_MONITORADA="/opt/monitoramento/pasta_monitorada"
LOG_FILE="/opt/monitoramento/logs/monitor.log"
SCRIPT_PROCESSAR="/opt/monitoramento/processar_arquivo.sh"

# Função para log
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Verificar se a pasta existe
if [ ! -d "$PASTA_MONITORADA" ]; then
    log "ERRO: Pasta $PASTA_MONITORADA não existe"
    exit 1
fi

# Verificar se inotifywait está instalado
if ! command -v inotifywait &> /dev/null; then
    log "ERRO: inotify-tools não instalado"
    exit 1
fi

log "=== INICIANDO MONITORAMENTO DA PASTA: $PASTA_MONITORADA ==="

# Monitorar a pasta - versão corrigida
inotifywait -m -e create -e moved_to --format '%f' "$PASTA_MONITORADA" | while read FILENAME
do
    # Ignorar arquivos vazios
    [ -z "$FILENAME" ] && continue
    
    # Ignorar diretórios
    [ -d "$PASTA_MONITORADA/$FILENAME" ] && continue
    
    # Ignorar arquivos temporários
    [[ "$FILENAME" == *.tmp ]] || [[ "$FILENAME" == *.swp ]] || [[ "$FILENAME" == *.part ]] || [[ "$FILENAME" == *~ ]] && continue
    
    # Caminho completo do arquivo
    ARQUIVO="$PASTA_MONITORADA/$FILENAME"
    
    log "Novo arquivo detectado: $FILENAME"
    
    # Aguardar um momento para garantir que o arquivo foi completamente escrito
    sleep 2
    
    # Verificar se o arquivo ainda existe
    if [ -f "$ARQUIVO" ]; then
        log "Processando: $ARQUIVO"
        # Executar o script processador em background
        "$SCRIPT_PROCESSAR" "$ARQUIVO" &
    else
        log "AVISO: Arquivo $FILENAME não existe mais"
    fi
done
