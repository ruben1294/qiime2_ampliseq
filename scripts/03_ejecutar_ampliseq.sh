#!/usr/bin/env bash
# =============================================================================
#  03_ejecutar_ampliseq.sh
#  Autor: Rubén Castañeda-Martínez
# -----------------------------------------------------------------------------
#  Ejecuta el pipeline nf-core/ampliseq. Lee las dos decisiones de
#  configuracion/parametros.sh (entorno y marcador) y lanza Nextflow con la
#  versión fija:
#    entorno  → perfil y recursos (-profile / -c recursos_<entorno>.config)
#    marcador → parámetros del análisis (-params-file marcador_<marcador>.yaml)
#  Guarda el comando exacto, el log y una copia de los parámetros usados.
#
#  Uso:   bash scripts/03_ejecutar_ampliseq.sh
#         bash scripts/03_ejecutar_ampliseq.sh --dry-run   (solo prepara, no corre)
#         bash scripts/03_ejecutar_ampliseq.sh -y          (no pide confirmación)
# =============================================================================
set -euo pipefail

DIR_PROYECTO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR_PROYECTO"
source "configuracion/parametros.sh"

# Reutilizamos $SELLO para que la evidencia de la corrida comparta la marca de tiempo
source "scripts/lib/registro.sh"
source "scripts/lib/entorno.sh"
source "scripts/lib/marcador.sh"
iniciar_registro "03_ejecutar_ampliseq"

# Definimos el entorno donde correrá el pipeline y el marcador a analizar
seleccionar_entorno    # fija MOTOR y CONFIG_RECURSOS
seleccionar_marcador   # fija CONFIG_MARCADOR
activar_trap_errores

# Opciones de línea de comandos
DRY_RUN="no"; ASUMIR_SI="no"
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN="si" ;;
        -y|--yes)  ASUMIR_SI="si" ;;
        *) log_error "Argumento desconocido: '$arg' (usa --dry-run o -y)"; exit 1 ;;
    esac
done

# Activamos el entorno con Nextflow y Java
if command -v conda >/dev/null 2>&1; then
    source "$(conda info --base)/etc/profile.d/conda.sh"
    conda activate "$ENV_LANZADOR" 2>/dev/null \
        || { log_error "no existe el entorno '$ENV_LANZADOR'. Corre antes: bash scripts/00_instalar_dependencias.sh"; exit 1; }
fi
command -v nextflow >/dev/null 2>&1 || { log_error "Nextflow no disponible. Corre: bash scripts/00_instalar_dependencias.sh"; exit 1; }

# Guardamos cachés en el disco grande, para no llenar el disco del sistema
export NXF_SINGULARITY_CACHEDIR="$DIR_PROYECTO/.cache/singularity"
export NXF_CONDA_CACHEDIR="$DIR_PROYECTO/.cache/conda"
mkdir -p "$NXF_SINGULARITY_CACHEDIR" "$NXF_CONDA_CACHEDIR" registros "$SALIDA"

# 1) Validaciones básicas
case "$MOTOR" in
    docker|singularity|apptainer|conda) : ;;
    *) log_error "MOTOR no válido: '$MOTOR' (usa docker, singularity, apptainer o conda)"; exit 1 ;;
esac

# Que el motor responda antes de empezar. En HPC el maestro (nodo5) solo manda
# las tareas a SLURM y el motor corre en los nodos de cómputo (nodo27, nodo28),
# así que aquí solo se exige 'sbatch'. En local el motor sí corre en esta máquina.
if [ "$ENTORNO" = "hpc" ]; then
    command -v sbatch >/dev/null 2>&1 \
        || { log_error "ENTORNO=hpc pero no encontré 'sbatch'. Lanza desde un nodo del clúster (p. ej. nodo5)."; exit 1; }
    case "$MOTOR" in
        docker)
            log_info "Docker corre en los nodos de cómputo (nodo27, nodo28); el maestro solo orquesta." ;;
        singularity|apptainer)
            command -v apptainer >/dev/null 2>&1 || command -v singularity >/dev/null 2>&1 \
                || log_warn "MOTOR=$MOTOR: no veo Singularity/Apptainer en el maestro. Si Nextflow no puede preparar las imágenes, cárgalo con 'module load'." ;;
    esac
else
    case "$MOTOR" in
        docker)
            if ! docker info >/dev/null 2>&1; then
                log_error "MOTOR=docker pero Docker no responde. Abre Docker Desktop y activa la"
                log_error "  integración con esta distro: Settings → Resources → WSL integration."
                exit 1
            fi
            ;;
        singularity|apptainer)
            if ! command -v apptainer >/dev/null 2>&1 && ! command -v singularity >/dev/null 2>&1; then
                log_error "MOTOR=$MOTOR pero no encontré Singularity/Apptainer en el PATH."
                exit 1
            fi
            ;;
    esac
fi

# Existencia de los archivos de cada decisión
[ -f "$CONFIG_RECURSOS" ] || { log_error "no existe el archivo de recursos: $CONFIG_RECURSOS"; exit 1; }
[ -f "$CONFIG_MARCADOR" ] || { log_error "no existe el archivo de parámetros: $CONFIG_MARCADOR"; exit 1; }

# 2) Leemos lo necesario para validar y mostrar del archivo YAML
FW="$(leer_yaml FW_primer "$CONFIG_MARCADOR")"
RV="$(leer_yaml RV_primer "$CONFIG_MARCADOR")"
REGION="$(leer_yaml cut_its "$CONFIG_MARCADOR")"          # vacío en 16S
TAXONOMIA="$(leer_yaml dada_ref_taxonomy "$CONFIG_MARCADOR")"

[ -z "$FW" ] && { log_error "FW_primer vacío en $CONFIG_MARCADOR"; exit 1; }
if [ "$DISENO_LECTURAS" = "paired" ] && [ -z "$RV" ]; then
    log_error "RV_primer vacío para diseño pareado. Revisa $CONFIG_MARCADOR"; exit 1
fi
if [ "$MARCADOR" = "its" ]; then
    case "$REGION" in
        its1|its2|full) : ;;
        *) log_error "cut_its inválido en $CONFIG_MARCADOR: '$REGION' (usa its1, its2 o full)"; exit 1 ;;
    esac
fi

# 3) Determinamos la entrada (samplesheet o carpeta)
ENTRADA=()
if [ "$USAR_SAMPLESHEET" = "si" ]; then
    [ -f "$SAMPLESHEET" ] || { log_error "no existe $SAMPLESHEET. Corre: bash scripts/01_generar_samplesheet.sh"; exit 1; }
    ENTRADA=( --input "$SAMPLESHEET" )
else
    ENTRADA=( --input_folder "$CARPETA_FASTQ" )
fi

# 4) Ensamblamos el comando de Nextflow para correr el pipeline
#   recursos por -c (entorno) y parámetros por -params-file (marcador)
CMD=( nextflow run nf-core/ampliseq
      -r "$VERSION_PIPELINE"
      -profile "$MOTOR"
      -params-file "$CONFIG_MARCADOR"
      -c "$CONFIG_RECURSOS"
      "${ENTRADA[@]}"
      --outdir "$SALIDA"
      -resume
      -ansi-log false )

# Lecturas ITS pareadas: avisa a ampliseq del posible read-through
[ "$MARCADOR" = "its" ] && [ "$DISENO_LECTURAS" = "paired" ] && CMD+=( --illumina_pe_its )
# Primers dobles (toggle de parametros.sh)
[ "$DOBLE_PRIMER" = "si" ] && CMD+=( --double_primer )
# Metadatos (solo si existe el archivo)
[ -n "$METADATA" ] && [ -f "$METADATA" ] && CMD+=( --metadata "$METADATA" )
# Parámetros extra del usuario (avanzado)
if [ -n "$EXTRA_PARAMS" ]; then
    # shellcheck disable=SC2206
    CMD+=( $EXTRA_PARAMS )
fi

# 5) Copia de los parámetros usados (evidencia por corrida)
cp "$CONFIG_MARCADOR" "$SALIDA/params_usados_${SELLO}.yaml"

# 6) Mostramos el resumen
cabecera_registro "EJECUCIÓN DE nf-core/ampliseq. Proyecto: $PROYECTO"
log_info "  Pipeline:        nf-core/ampliseq r${VERSION_PIPELINE}"
log_info "  Entorno:         $ENTORNO  (recursos: $CONFIG_RECURSOS)"
log_info "  Marcador:        $MARCADOR  (parámetros: $CONFIG_MARCADOR)"
log_info "  Motor:           $MOTOR"
log_info "  Entrada:         ${ENTRADA[*]}"
log_info "  Primers:         FW=$FW${RV:+  RV=$RV}"
[ "$MARCADOR" = "its" ] && log_info "  Región ITS:      $REGION"
log_info "  Taxonomía:       $TAXONOMIA"
log_info "  Metadatos:       ${METADATA:-(ninguno)}"
log_info "  Salida:          $SALIDA"
log_info "  Comando completo:"
log_info "    ${CMD[*]}"
log_info "=========================================================================="

# Guardamos el comando exacto, para efectos de reproducibilidad y trazabilidad
echo "${CMD[*]}" > "registros/comando_${SELLO}.txt"

if [ "$DRY_RUN" = "si" ]; then
    log_info "[--dry-run] Todo preparado. No se ejecutó Nextflow."
    log_info "Para correr de verdad: bash scripts/03_ejecutar_ampliseq.sh"
    exit 0
fi

# 7) Confirmación de marcador y primers
# Solo pregunta si hay terminal y no se pasó -y, para no lanzar el análisis con
# valores por defecto sin confirmarlos con quien hizo la secuenciación.
if [ "$ASUMIR_SI" != "si" ] && [ -t 0 ]; then
    echo
    read -r -p "¿Confirmas MARCADOR=$MARCADOR y PRIMERS FW=$FW${RV:+ RV=$RV}? [s/N] " RESP
    case "${RESP:-}" in
        s|S|si|SI|Si|y|Y|yes) : ;;
        *) log_warn "Cancelado por el usuario. Ajusta la configuración y vuelve a intentarlo."; exit 0 ;;
    esac
fi

# 8) Ejecutamos y registramos el log
log_info "Lanzando Nextflow… (el log se guarda en $LOG_OUT y $LOG_ERR)"
"${CMD[@]}" # Este comando es el que corre todo el pipeline

log_info "=========================================================================="
log_info "Análisis terminado"
log_info "   Resultados:  $SALIDA/"
log_info "   Reporte:     $SALIDA/multiqc/  y  $SALIDA/summary_report/"
log_info "   Info de la corrida (versiones, tiempos): $SALIDA/pipeline_info/"
log_info "=========================================================================="
