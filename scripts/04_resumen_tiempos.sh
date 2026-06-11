#!/usr/bin/env bash
# =============================================================================
#  04_resumen_tiempos.sh
#  Autor: Rubén Castañeda-Martínez
# -----------------------------------------------------------------------------
#  Arma una tabla de tiempos por paso a partir del execution_trace_*.txt que
#  genera Nextflow en resultados/pipeline_info/. Agrupa las tareas por proceso
#  (DADA2, cutadapt, etc.), las ordena de mayor a menor tiempo y resume tareas,
#  tiempo total y promedio, %cpu máximo y RAM pico. Es el equivalente a la tabla
#  que antes armabas con 'time', pero por proceso y con más detalle.
#
#  Escribe dos archivos junto al trace (con su mismo sello de tiempo):
#     resumen_tiempos_<sello>.tsv   tabla separada por tabs (para reusar)
#     resumen_tiempos_<sello>.txt   tabla alineada y legible
#
#  Uso:   bash scripts/04_resumen_tiempos.sh                  (usa el trace más reciente)
#         bash scripts/04_resumen_tiempos.sh <ruta_al_trace.txt>
# =============================================================================
set -euo pipefail

DIR_PROYECTO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR_PROYECTO"
source "configuracion/parametros.sh"

source "scripts/lib/registro.sh"
iniciar_registro "04_resumen_tiempos"
activar_trap_errores

cabecera_registro "RESUMEN DE TIEMPOS. Proyecto: $PROYECTO"

# 1) Elegir el trace: el que se pase como argumento o el más reciente de pipeline_info
DIR_INFO="$SALIDA/pipeline_info"
if [ "$#" -ge 1 ]; then
    case "$1" in
        -h|--help) log_info "Uso: bash scripts/04_resumen_tiempos.sh [ruta_al_trace.txt]"; exit 0 ;;
    esac
    TRACE="$1"
    [ -f "$TRACE" ] || { log_error "no existe el archivo de trace: $TRACE"; exit 1; }
else
    [ -d "$DIR_INFO" ] || { log_error "no existe $DIR_INFO. ¿Ya corriste el script 03?"; exit 1; }
    # ls -t ordena por fecha de modificación; el primero es el más reciente
    mapfile -t TRAZAS < <(ls -1t "$DIR_INFO"/execution_trace_*.txt 2>/dev/null || true)
    TRACE="${TRAZAS[0]:-}"
    [ -n "$TRACE" ] || { log_error "no encontré ningún execution_trace_*.txt en $DIR_INFO. ¿Ya corriste el script 03?"; exit 1; }
fi
log_info "Trace: $TRACE"

# 2) Derivar el sello del nombre del trace para nombrar las salidas igual que la corrida
nombre_trace="$(basename "$TRACE")"
sello_trace="${nombre_trace#execution_trace_}"; sello_trace="${sello_trace%.txt}"
[ "$sello_trace" = "$nombre_trace" ] && sello_trace="$SELLO"

dir_salida="$(dirname "$TRACE")"
TSV="$dir_salida/resumen_tiempos_${sello_trace}.tsv"
TXT="$dir_salida/resumen_tiempos_${sello_trace}.txt"

# 3) Avisos sobre el contenido del trace
n_tareas="$(awk -F'\t' 'NR>1{c++} END{print c+0}' "$TRACE")"
if [ "$n_tareas" -eq 0 ]; then
    log_warn "el trace no contiene tareas registradas; nada que resumir."
    exit 0
fi
n_cache="$(awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)if($i=="status")s=i; next} s&&$s=="CACHED"{c++} END{print c+0}' "$TRACE")"
if [ "$n_cache" -gt 0 ]; then
    log_warn "el trace tiene $n_cache tareas cacheadas (corrida con -resume): muestran el tiempo de"
    log_warn "  la corrida anterior. Para tiempos limpios, mide una corrida completa sin caché."
fi

# 4) Agregar por proceso (awk), ordenar por tiempo total (sort) y dar formato (awk)
# Pasada 1: convierte tiempos/memoria a número y acumula por proceso.
#   columnas localizadas por encabezado, por si cambia el orden de trace.fields
agregar='
function to_sec(s,  n,i,a,t,v,tot){
    if(s=="-"||s=="") return -1
    tot=0; n=split(s,a," ")
    for(i=1;i<=n;i++){ t=a[i]
        if(t ~ /ms$/){v=substr(t,1,length(t)-2); tot+=v/1000}
        else if(t ~ /d$/){v=substr(t,1,length(t)-1); tot+=v*86400}
        else if(t ~ /h$/){v=substr(t,1,length(t)-1); tot+=v*3600}
        else if(t ~ /m$/){v=substr(t,1,length(t)-1); tot+=v*60}
        else if(t ~ /s$/){v=substr(t,1,length(t)-1); tot+=v}
    }
    return tot
}
function to_mb(s,  n,a,v,u){
    if(s=="-"||s==""||s=="0") return 0
    n=split(s,a," "); if(n<2) return 0
    v=a[1]; u=a[2]
    if(u=="B")  return v/1048576
    if(u=="KB") return v/1024
    if(u=="MB") return v
    if(u=="GB") return v*1024
    if(u=="TB") return v*1048576
    return v
}
NR==1{
    for(i=1;i<=NF;i++) h[$i]=i
    c_name = h["name"] ? h["name"] : h["process"]
    c_stat = h["status"]
    c_rt   = h["realtime"] ? h["realtime"] : h["duration"]
    c_cpu  = h["%cpu"]
    c_rss  = h["peak_rss"]
    next
}
{
    proc = $c_name
    sub(/ \(.*\)$/,"",proc)          # quitar el tag por-muestra entre paréntesis
    np = split(proc,pp,":"); proc = pp[np]   # quedarnos con el último componente
    sec = to_sec(c_rt ? $c_rt : "-"); if(sec<0) sec=0
    cpu = c_cpu ? $c_cpu : "0"; sub(/%/,"",cpu); cpu = cpu+0
    rss = c_rss ? to_mb($c_rss) : 0
    cnt[proc]++
    tot[proc]+=sec
    if(cpu>cmax[proc]) cmax[proc]=cpu
    if(rss>rmax[proc]) rmax[proc]=rss
    if(c_stat && $c_stat=="CACHED") cch[proc]++
}
END{
    for(p in cnt)
        printf "%.3f\t%s\t%d\t%d\t%.3f\t%.1f\t%.3f\n", \
            tot[p], p, cnt[p], cch[p], (cnt[p]?tot[p]/cnt[p]:0), cmax[p], rmax[p]
}
'

# Pasada 2: da formato humano, calcula anchos, escribe el TSV y la tabla alineada.
formatear='
function fmt_t(s,  hh,mm,ss,out){
    if(s<0) return "-"
    s=int(s+0.5); hh=int(s/3600); s-=hh*3600; mm=int(s/60); ss=s-mm*60
    out=""
    if(hh>0) out=out hh "h "
    if(mm>0||hh>0) out=out mm "m "
    out=out ss "s"
    return out
}
function fmt_mb(mb){
    if(mb<=0) return "-"
    if(mb>=1024) return sprintf("%.1f GB", mb/1024)
    return sprintf("%.0f MB", mb)
}
BEGIN{
    hdr[1]="proceso"; hdr[2]="tareas"; hdr[3]="cacheadas"; hdr[4]="tiempo_total"
    hdr[5]="tiempo_prom"; hdr[6]="cpu_max"; hdr[7]="ram_pico"
    nc=7
    for(c=1;c<=nc;c++){ cell[0,c]=hdr[c]; w[c]=length(hdr[c]) }
    nr=0
}
{
    nr++
    cell[nr,1]=$2
    cell[nr,2]=$3
    cell[nr,3]=$4
    cell[nr,4]=fmt_t($1)
    cell[nr,5]=fmt_t($5)
    cell[nr,6]=sprintf("%.0f%%",$6)
    cell[nr,7]=fmt_mb($7)
    gtot+=$1; gcnt+=$3; gcch+=$4
    for(c=1;c<=nc;c++){ l=length(cell[nr,c]); if(l>w[c]) w[c]=l }
}
END{
    nr++
    cell[nr,1]="TOTAL"; cell[nr,2]=gcnt; cell[nr,3]=gcch
    cell[nr,4]=fmt_t(gtot); cell[nr,5]=""; cell[nr,6]=""; cell[nr,7]=""
    for(c=1;c<=nc;c++){ l=length(cell[nr,c]); if(l>w[c]) w[c]=l }

    # TSV: encabezado, filas y total separados por tabs
    for(r=0;r<=nr;r++){
        line=""
        for(c=1;c<=nc;c++){ line=line cell[r,c]; if(c<nc) line=line "\t" }
        print line > tsv
    }
    # Tabla alineada a stdout: proceso a la izquierda, números a la derecha
    for(r=0;r<=nr;r++){
        out=""
        for(c=1;c<=nc;c++){
            if(c==1) out=out sprintf("%-*s", w[c], cell[r,c])
            else     out=out sprintf("  %*s", w[c], cell[r,c])
        }
        print out
    }
}
'

awk -F'\t' "$agregar" "$TRACE" \
    | sort -t$'\t' -k1,1nr \
    | awk -F'\t' -v tsv="$TSV" "$formatear" > "$TXT"

# 5) Mostrar la tabla y dónde quedó
log_info "Tareas en el trace: $n_tareas"
log_info "Resumen por proceso (ordenado por tiempo total):"
echo
cat "$TXT"
echo
log_info "tiempo_total y tiempo_prom usan el 'realtime' de Nextflow (cómputo real de la tarea)."
log_info "El TOTAL es la suma de tiempos de tarea; el reloj de pared real es menor por el paralelismo."
log_info "Tabla (tabs): $TSV"
log_info "Tabla (texto): $TXT"
log_info "Reportes visuales de la misma corrida en: $DIR_INFO/ (timeline y report .html)"
