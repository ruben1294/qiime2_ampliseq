#!/usr/bin/env bash
# =============================================================================
#  descargar_datos_prueba.sh
#  Autor: Rubén Castañeda-Martínez
# -----------------------------------------------------------------------------
#  Descarga un conjunto de datos pequeño y estándar (nf-core/test-datasets) para probar
#  el flujo de punta a punta. Elige el caso según el marcador:
#    16s: 16S pareado (primers 515F/806R, igual que marcador_16s.yaml)
#    its: ITS single-end de Illumina (3 muestras)
#  Para 18S no hay set de prueba incluido en nf-core/test-datasets, usa tus
#  propios FASTQ (o el set 16s para una prueba, sin valor biológico).
#  Los archivos se guardan en CARPETA_FASTQ y se renombran para que el script 01
#  los reconozca. El entorno (local/hpc) es independiente: el mismo dato sirve.
#
#  Uso:   bash scripts/descargar_datos_prueba.sh 16s
#         bash scripts/descargar_datos_prueba.sh its --force   (reemplaza lo que haya)
# =============================================================================
set -euo pipefail

DIR_PROYECTO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR_PROYECTO"
source "configuracion/parametros.sh"

source "scripts/lib/registro.sh"
iniciar_registro "descargar_datos_prueba"
activar_trap_errores

# Argumentos: el caso (16s|its) y el opcional --force
CASO=""; FORCE="no"
for arg in "$@"; do
    case "$arg" in
        16s|its) CASO="$arg" ;;
        18s) log_error "no hay set de prueba 18S en nf-core/test-datasets. Usa tus propios FASTQ, o baja el set 16s solo para probar la plomería del flujo."; exit 1 ;;
        --force) FORCE="si" ;;
        *) log_error "argumento desconocido: '$arg' (usa 16s o its, y --force)"; exit 1 ;;
    esac
done
[ -z "$CASO" ] && { log_error "falta el caso. Uso: bash scripts/descargar_datos_prueba.sh <16s|its> [--force]"; exit 1; }

BASE="https://raw.githubusercontent.com/nf-core/test-datasets/ampliseq/testdata"
DEST="$CARPETA_FASTQ"
mkdir -p "$DEST"

# No pisar datos previos sin permiso
if compgen -G "$DEST/*.fastq.gz" >/dev/null 2>&1; then
    if [ "$FORCE" = "si" ]; then
        log_warn "Borrando los .fastq.gz previos de $DEST"
        rm -f "$DEST"/*.fastq.gz
    else
        log_error "$DEST ya tiene archivos .fastq.gz. Usa --force para reemplazarlos."
        exit 1
    fi
fi

# Descarga un archivo con curl o wget
bajar() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$out"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$url" -O "$out"
    else
        log_error "no encontré curl ni wget para descargar"; exit 1
    fi
    log_info "  $(basename "$out")  ($(du -h "$out" | cut -f1))"
}

cabecera_registro "DATOS DE PRUEBA ($CASO). Proyecto: $PROYECTO"

case "$CASO" in
    16s)
        log_info "16S pareado de Illumina (4 muestras, primers 515F/806R)"
        for pre in 1_S103_L001 1a_S103_L001 2_S115_L001 2a_S115_L001; do
            bajar "$BASE/${pre}_R1_001.fastq.gz" "$DEST/${pre}_R1_001.fastq.gz"
            bajar "$BASE/${pre}_R2_001.fastq.gz" "$DEST/${pre}_R2_001.fastq.gz"
        done
        log_info "Ajusta en configuracion/parametros.sh:"
        log_info "   MARCADOR=\"16s\"   DISENO_LECTURAS=\"paired\""
        log_info "   (marcador_16s.yaml ya trae 515F/806R; cambia la base a una rápida si quieres)"
        ;;
    its)
        log_info "ITS single-end de Illumina (3 muestras)"
        for n in 1 2 3; do
            bajar "$BASE/it-its_${n}.fastq.gz" "$DEST/it${n}_R1.fastq.gz"
        done
        log_info "Ajusta en configuracion/parametros.sh:"
        log_info "   MARCADOR=\"its\"   DISENO_LECTURAS=\"single\""
        log_info "   Si cutadapt descarta casi todo por los primers, agrega"
        log_info "   EXTRA_PARAMS=\"--retain_untrimmed\" para que la prueba corra igual."
        ;;
esac

log_info "Listo. Datos en: $DEST"
log_info "Siguiente paso:"
log_info "   bash scripts/01_generar_samplesheet.sh"
log_info "   bash scripts/03_ejecutar_ampliseq.sh --dry-run   (revisa el comando)"
log_info "   bash scripts/03_ejecutar_ampliseq.sh             (corre la prueba)"
