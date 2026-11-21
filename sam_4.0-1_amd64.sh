#!/bin/bash

# sam_RC_ver4_23ene2020_00:20

# =============================================================================
#  NOTAS DE LA REVISIÓN (19-nov-2026)
#  Se mantiene la UX (pantallas, textos, orden de pasos) y la mecánica:
#  listar por extensión -> comparar contra lista de nombres -> mover a
#  /tmp/SAMMOVED/ (el archivo previo se renombra con sufijo _N) -> reportes
#  -> "bonus" fdupes.
#
#  Seguridad
#   - Se eliminó la evaluación aritmética de nombres de archivo (inyección de
#     comandos vía "[[ nombre -gt N ]]" con un archivo hostil en /tmp/SAMMOVED).
#   - /tmp/SAMMOVED se crea con modo 700 y se verifica que no sea un enlace
#     simbólico ni pertenezca a otro usuario. /tmp/samflattxtfile (predecible)
#     se reemplazó por mktemp con limpieza automática.
#   - Los nombres de archivo ya no pasan por tr/xargs/glob: se usan listas
#     separadas por NUL (nombres con espacios, comillas, \, *, [ ], saltos de
#     línea ya no se corrompen ni mueven archivos equivocados).
#   - dos2unix se aplica a la copia temporal, no al archivo original del usuario.
#  Eficiencia
#   - Comparación en una sola pasada con grep -Fx (antes: 4 procesos por
#     archivo y bucle doble), du en lote, sin expr/rev/cut/xargs en bucles.
#  Errores corregidos
#   - Línea en blanco extra al final del reporte "filesfound" (i <= N).
#   - MAX nunca se reiniciaba entre archivos; "010" se leía como octal.
#   - Bucle infinito si /media/$USER no existe; división por cero en DISKCOST.
#   - "Files Effectively MOVED" listaba archivos cuyo mv había fallado.
#   - El comando de ayuda mostraba awk '{print }' ($1 se expandía a vacío).
# =============================================================================

# -----------------------------------------------------------------------------
# 1. CÓDIGOS ANSI (reemplazan los cientos de $( echo -e ... ) del original;
#    la salida en pantalla es idéntica pero sin lanzar un subproceso por color)
# -----------------------------------------------------------------------------
RED_BG=$'\e[41m'; GREEN_BG=$'\e[42m'; BLUE_BG=$'\e[44m'; PURPLE_BG=$'\e[45m'
GRAY_BG=$'\e[100m'; LRED_BG=$'\e[101m'; BG_OFF=$'\e[49m'
BOLD=$'\e[1m'; ITALIC=$'\e[3m'; UL=$'\e[4m'; UL_OFF=$'\e[24m'; RESET=$'\e[0m'
LRED_FG=$'\e[91m'; FG_OFF=$'\e[39m'; HILITE=$'\033[33;7m'

# -----------------------------------------------------------------------------
# 2. VARIABLES GLOBALES Y RUTAS
# -----------------------------------------------------------------------------
USER=${USER:-$(id -un)}          # algunos entornos (cron, contenedores) no definen USER
USUARIO=$USER
MOVEDESTDIR="/tmp/SAMMOVED/"
SAMHOME="$HOME/SAM"
COMPAREDIR="$SAMHOME/compare"
REPORTSDIR="$SAMHOME/reports"
ANOMLOG="$SAMHOME/logs/flattxtfile_anomalous_records_history.log"
SUMMARY="$SAMHOME/logs/report_SUMMARY_activity_for_${USER}.log"

BASEDIRID="-100"
FILEID="-100"
FILESYSTEM="100"
DATEstartprogram=$(date +%Y_%b_%d_%H:%M:%S)
BASHVER=${BASH_VERSINFO[0]}      # versión del bash que realmente ejecuta el script
TMPFLAT=""; TMPNAMES=""; TMPSTEMS=""

# -----------------------------------------------------------------------------
# 3. FUNCIONES
# -----------------------------------------------------------------------------

# Borra los temporales al salir (normal, error o Ctrl+C).
CLEANUP () {
	rm -f -- "$TMPFLAT" "$TMPNAMES" "$TMPSTEMS"
}
trap CLEANUP EXIT

# Espera una tecla. $1 = texto (por defecto el más usado en el programa).
WAIT_KEY () {
	read -n 1 -s -r -p "${BOLD}${1:-PRESS ANY KEY to continue...}${RESET}"
}

# Lee de stdin una lista separada por NUL y la deja en el arreglo NUL_LIST.
# Es la forma segura de manejar nombres con espacios, comillas, \, *, etc.
LOAD_NUL_LIST () {
	NUL_LIST=()
	local item
	while IFS= read -r -d '' item; do
		NUL_LIST+=("$item")
	done
}

# Valida que $1 sea un entero no negativo (solo dígitos, máx. 9).
IS_POSITIVE_INT () {
	[[ "$1" =~ ^[0-9]{1,9}$ ]]
}

# Comprueba si hay internet (con tiempo límite: antes podía colgarse).
AREWEONLINE () {
	if echo -e "GET http://google.com HTTP/1.0\n\n" | nc -w 5 google.com 80 > /dev/null 2>&1; then
		ONLINE="on"
	else
		ONLINE="off"
	fi
}

# Avisa que falta un programa requerido ($1) y que se va a instalar.
MESSAGE1 () {
	clear
	echo ""
	echo "The program ${RED_BG}\"$1\" is not installed${BG_OFF}, now we run the software installer, so"
	echo "perhaps the system will request us to enter ${GREEN_BG}$USER${BG_OFF}'s SUDO password (permission),"
	echo "so, if the system asks for this password and you do not have it or do not have this"
	echo "permission, please go find a systems Administrator and tell him/her about it..."
	echo ""
	WAIT_KEY "PRESS ANY KEY to continue... "
	echo ""
	echo ""
}

# Avisa que se necesita internet para instalar los programas requeridos.
MESSAGE3 () {
	clear
	echo ""
	echo "For this program to work correctly, we need to install some software but we are not getting"
	echo "internet connection."
	echo "Please verify that we have a valid internet connection so we can install the required software."
	echo "Then run ${PURPLE_BG}SAM${BG_OFF} software again."
	echo ""
	exit 1
}

# Calcula el tiempo transcurrido (ENDTIME-STARTTIME) en la unidad mayor entera.
ANALYSISTIMECALC () {
	ANALYSISTIME=$(( ENDTIME - STARTTIME ))
	if (( ANALYSISTIME >= 86400 )); then
		ANALYSISTIME=$(( ANALYSISTIME / 86400 )); FORMAT="days"
	elif (( ANALYSISTIME >= 3600 )); then
		ANALYSISTIME=$(( ANALYSISTIME / 3600 )); FORMAT="hours"
	elif (( ANALYSISTIME >= 60 )); then
		ANALYSISTIME=$(( ANALYSISTIME / 60 )); FORMAT="minutes"
	else
		FORMAT="seconds"
	fi
	echo "Time spent: $ANALYSISTIME $FORMAT"
}

# ¿Está instalado el paquete $1? (consulta exacta a dpkg, sin falsos positivos)
IS_PKG_INSTALLED () {
	[[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" == ii* ]]
}

# Elige la unidad de tamaño para $1 (en KB). Deja resultado en
# SU_FORMAT (nombre), SU_DIVIDER (divisor) y SU_SUFFIX (sufijo).
SET_SIZE_UNIT () {
	if (( $1 >= 1048576 )); then
		SU_FORMAT="Gigabytes"; SU_DIVIDER=1048576; SU_SUFFIX="GB"
	elif (( $1 >= 1024 )); then
		SU_FORMAT="Megabytes"; SU_DIVIDER=1024; SU_SUFFIX="MB"
	else
		SU_FORMAT="Kilobytes"; SU_DIVIDER=1; SU_SUFFIX="KB"
	fi
}

# Pantalla y menú de selección del sistema de archivos base (USB u hogar).
ASSIGN_BASEDIR () {
	until (( FILESYSTEM == 0 || FILESYSTEM == 1 )); do
		read -n 1 -s -r -p "Press ${GREEN_BG}\"0\"${BG_OFF} for ${GREEN_BG}USB external hard disks/pen drives${BG_OFF} or ${GREEN_BG}\"1\"${BG_OFF} for ${GREEN_BG}${USUARIO}${BG_OFF}'s home folder and hit enter: " FILESYSTEM
		echo ""
		IS_POSITIVE_INT "$FILESYSTEM" || FILESYSTEM="100"
	done
	if (( FILESYSTEM == 0 )); then
		FILESYSTEM="/media/$USER"
	else
		FILESYSTEM="$HOME"
	fi

	# Directorios de primer nivel (no ocultos), ordenados, separados por NUL.
	LOAD_NUL_LIST < <(find "$FILESYSTEM" -maxdepth 1 -type d -not -path '*/\.*' -print0 2> /dev/null | sort -z)
	BASEDIR=("${NUL_LIST[@]}")

	# Si no hay nada que elegir (p. ej. no hay USB montado) antes el programa
	# quedaba en un bucle infinito pidiendo un ID imposible.
	if (( ${#BASEDIR[@]} == 0 )); then
		echo ""
		echo "There are no directories to select inside $FILESYSTEM (is the USB drive mounted?)."
		echo "Nothing to do here, start over again and try another file system."
		echo ""
		exit 1
	fi

	echo ""
	echo "Please take a close look at the ${HILITE}highlighted IDs${RESET} and its associated ${PURPLE_BG}directory${BG_OFF}:"
	for (( i=0; i<${#BASEDIR[@]}; i++ )); do
		echo "Base directory ID ${HILITE}${i}${RESET} : ${BASEDIR[$i]} "
	done
	echo ""
	echo "${RED_BG}NOTE:${BG_OFF} If you select $FILESYSTEM as the base folder, then the search will start at that same level and will include ALL subdirectories"
	echo "      below, it may take a BIG WHILE to construct the file list. So pay special attention when selecting the base folder (Or perhaps"
	echo "      that is what you need?)."
	echo ""
}

# Pide el ID del directorio base; si no es válido lo deja en -100.
SELECT_BF () {
	read -r -p "Input ${HILITE}ID number${RESET} from above which will be the Base directory to be scanned for ${PURPLE_BG}directories${BG_OFF} (minimum ${HILITE}\"0\"${RESET} to maximum ${HILITE}\"$(( ${#BASEDIR[@]} - 1 ))\"${RESET}) and hit enter: " BASEDIRID
	if IS_POSITIVE_INT "$BASEDIRID"; then
		BASEDIRID=$(( 10#$BASEDIRID ))   # "010" ya no se interpreta como octal
	else
		BASEDIRID="-100"
	fi
}

# Pide el ID del archivo de texto plano; si no es válido lo deja en -100.
SELECT_FILE () {
	read -r -p "Input the ${HILITE}File ID${RESET} to load and read for the comparison (minimum ${HILITE}\"0\"${RESET} to maximum ${HILITE}\"$(( ${#FLATTXTFILE[@]} - 1 ))\"${RESET} ) and hit enter: " FILEID
	if IS_POSITIVE_INT "$FILEID"; then
		FILEID=$(( 10#$FILEID ))
	else
		FILEID="-100"
	fi
}

# Pide la extensión a buscar (las comillas de "pdf"/"PDF" se perdían en el original).
INPUT_FILEEXT () {
	read -r -p "Now, only type one extension (case insensitive) for the type of files you want to search (e.g.: pdf or PDF): " FILEEXT
}

# Mueve UN archivo ($1) a $MOVEDESTDIR. Si ya existe uno con ese nombre, el
# existente se renombra a NOMBRE_N (N = mayor sufijo numérico actual + 1) y el
# nuevo ocupa el nombre original. Solo se anota en el reporte si el mv funcionó.
MOVE_ONE_FILE () {
	local src="$1" name dest item rest max newsuf
	name=${src##*/}
	dest="$MOVEDESTDIR$name"

	if [[ -e "$dest" || -L "$dest" ]]; then
		# Busca sufijos numéricos exactos NOMBRE_<dígitos> (sin evaluar aritmética).
		max=0
		for item in "$dest"_*; do
			rest=${item#"$dest"_}
			if [[ "$rest" =~ ^[0-9]{1,9}$ ]] && (( 10#$rest > max )); then
				max=$(( 10#$rest ))
			fi
		done
		newsuf=$(( max + 1 ))
		if mv -- "$dest" "${dest}_${newsuf}" && mv -- "$src" "$MOVEDESTDIR"; then
			printf '%s with NEWSUFIX _%s\n' "$src" "$newsuf" >> "$MOVEDFILES"
		fi
	else
		if mv -- "$src" "$MOVEDESTDIR"; then
			printf '%s\n' "$src" >> "$MOVEDFILES"
		fi
	fi
}

# -----------------------------------------------------------------------------
# 4. VERIFICACIÓN DEL SISTEMA OPERATIVO (Debian/Ubuntu y derivados)
# -----------------------------------------------------------------------------
# Familia del SO: se cargan ID e ID_LIKE de os-release (en subshell) y se acepta
# si "debian" o "ubuntu" aparece como palabra completa en cualquiera de los dos.
HOSTFAMILY=$( . /etc/os-release 2>/dev/null; echo "$ID $ID_LIKE" )
if [[ " $HOSTFAMILY " != *" debian "* && " $HOSTFAMILY " != *" ubuntu "* ]]; then
	clear
	echo ""
	echo "${RED_BG}We are not running a Debian based Operating System${BG_OFF} so for now we cannot continue."
	echo "Future versions of this program will do nicer things like running on a OS family"
	echo "different from Debian/Ubuntu."
	echo "Please run this program on a Debian/Ubuntu based system like:"
	echo "${GREEN_BG}Debian OS${BG_OFF}"
	echo "${GREEN_BG}Devuan${BG_OFF}"
	echo "${GREEN_BG}Pardus${BG_OFF}"
	echo "${GREEN_BG}Linux Mint${BG_OFF}"
	echo "${GREEN_BG}Peppermint OS${BG_OFF}"
	echo "${GREEN_BG}Ubuntu${BG_OFF} (or derivatives like Kubuntu, Edubuntu, Lubuntu, etc.)"
	echo "${GREEN_BG}MX Linux${BG_OFF}"
	echo "${GREEN_BG}Linux Lite${BG_OFF}"
	echo "And many other etcs..."
	echo ""
	echo "Please take the script from where you run this program and copy it to another Linux Workstation."
	echo ""
	echo "You can validate if it is a Debian/Ubuntu derivative if you run a simple command from a terminal"
	echo "like the one you can see below."
	echo ""
	echo "Once on a terminal, all you have to do is run the following command (do not include the double quotes):"
	echo ""
	# \$1 escapado: en el original se expandía a vacío y el comando mostrado quedaba roto.
	echo "\" ${ITALIC}grep -E '^(ID|ID_LIKE)=' /etc/os-release${RESET} \""	echo ""
	echo "(to copy the command above, select it with your mouse using the left click button and on your"
	echo "keyboard press the combination keys: \"Ctrl+Shift+c\")"
	echo ""
	echo "Thank you for using SAM."
	echo ""
	exit 1
fi

# -----------------------------------------------------------------------------
# 5. DIRECTORIOS DE TRABAJO
# -----------------------------------------------------------------------------

# Destino de los archivos movidos. Está en /tmp (lugar compartido y predecible),
# por eso se crea privado (700) y se rechaza si es un enlace simbólico o si
# pertenece a otro usuario (ataque de pre-creación / symlink).
MOVEDIR_NOSLASH=${MOVEDESTDIR%/}
if [ ! -e "$MOVEDIR_NOSLASH" ] && [ ! -L "$MOVEDIR_NOSLASH" ]; then
	mkdir -m 700 -- "$MOVEDIR_NOSLASH" || exit 1
fi
if [ -L "$MOVEDIR_NOSLASH" ] || [ ! -d "$MOVEDIR_NOSLASH" ] || [ ! -O "$MOVEDIR_NOSLASH" ]; then
	echo ""
	echo "${RED_BG}ATTENTION!${BG_OFF} $MOVEDESTDIR exists but it is not a regular directory owned by $USER"
	echo "(or it is a symbolic link), so for security reasons we cannot continue."
	echo "Please contact your SysAdmin."
	echo ""
	exit 1
fi

# Árbol de SAM en el hogar del usuario.
mkdir -p -- "$REPORTSDIR/filesfound" "$REPORTSDIR/filestomove" "$REPORTSDIR/movedfiles"

# Si "compare" no existe es la primera ejecución: se crea y se avisa al usuario.
if [ ! -e "$COMPAREDIR/" ]; then
	mkdir -p -- "$COMPAREDIR"
	clear
	echo ""
	echo "${GREEN_BG}This is the first time SAM is run on this machine${BG_OFF}, or SAM's home directories"
	echo "have been deleted for some reason..."
	echo "Now I am creating the base directories/files I need to run the program."
	echo ""
	echo "${BOLD}ATTENTION:${RESET} ${RED_BG}Right now${BG_OFF}, inside $HOME/SAM/compare directory, copy the file"
	echo "containing the names of the files we are going to search for."
	echo "This is required for the program to work correctly and you will be asked"
	echo "for it later."
	echo "So before continuing, please do this. You can make use of your favourite file manager..."
	echo ""
	WAIT_KEY "If you already copied the file press any key to continue..."
fi

# Logs: carpeta, historial de registros anómalos y resumen de actividad.
mkdir -p -- "$SAMHOME/logs"
touch -- "$ANOMLOG" "$SUMMARY"

# -----------------------------------------------------------------------------
# 6. ESPACIO DISPONIBLE EN DESTINO (valor en KB, aunque el nombre diga BYTES)
# -----------------------------------------------------------------------------
BYTESAVAIL=$( df --output=avail "$MOVEDESTDIR" | tail -n 1 | tr -d ' ' )

# -----------------------------------------------------------------------------
# 7. ADVERTENCIAS: bash < 4 / ejecución como root
#    (se mantiene el if/elif original: el aviso de root no sale si bash < 4)
# -----------------------------------------------------------------------------
if (( BASHVER < 4 )); then
	clear
	echo ""
	echo "*****************************************************************"
	echo "** You are using BASH version less than 4, so it is possible   **"
	echo "** that the behaviour of the program will not be what you      **"
	echo "** would expect from it.                                       **"
	echo "** You were advised.                                           **"
	echo "*****************************************************************"
	echo ""
	echo ""
	WAIT_KEY
elif [[ $UID = 0 ]]; then
	clear
	echo ""
	echo "****************************************************************"
	echo "* You're running this program as ROOT! please press \"Ctrl+C\"   *"
	echo "* NOW, to terminate this program!                              *"
	echo "****************************************************************"
	echo ""
	echo "****************************************************************"
	echo "IF YOU CONTINUE AS ROOT BE ADVISED THAT YOU ARE ON YOUR OWN    *"
	echo "****************************************************************"
	echo ""
	echo ""
	WAIT_KEY
fi

# -----------------------------------------------------------------------------
# 8. PROGRAMAS REQUERIDOS: dos2unix, moreutils, dc, fdupes
#    (un solo bucle en vez de cuatro bloques casi idénticos; mismo orden y
#    mismos mensajes que el original)
# -----------------------------------------------------------------------------
MISSINGPKGS=()
for PROGRAMREQ in dos2unix moreutils dc fdupes; do
	IS_PKG_INSTALLED "$PROGRAMREQ" || MISSINGPKGS+=("$PROGRAMREQ")
done

if (( ${#MISSINGPKGS[@]} > 0 )); then
	AREWEONLINE
	if [ "$ONLINE" = "off" ]; then
		MESSAGE3
	else
		for PROGRAMREQ in "${MISSINGPKGS[@]}"; do
			MESSAGE1 "$PROGRAMREQ"
			sudo apt install "$PROGRAMREQ"
		done
	fi
fi

# -----------------------------------------------------------------------------
# 9. PANTALLA DE BIENVENIDA
# -----------------------------------------------------------------------------
clear
echo "Hello ${GREEN_BG}${USUARIO^^}${BG_OFF}, and Welcome to ${PURPLE_BG}SAM${BG_OFF} (${PURPLE_BG}S${BG_OFF}earch ${PURPLE_BG}A${BG_OFF}nd ${PURPLE_BG}M${BG_OFF}ove) Release Candidate ver. 4.0"
echo ""
echo "Copyright (C) ${LRED_FG}Marco A. Rodriguez G.${FG_OFF}, September 2019. You should have received a copy of the GNU General Public License along with this program."
echo "If not, see <https://www.gnu.org/licenses/>. This file is named \"COPYING\"."
echo ""
echo "Please report bugs, ideas and/or suggestions about this program to: ${LRED_FG}zopeck@riseup.net${FG_OFF}"
echo ""
echo "${UL}What we do here:${UL_OFF}"
echo ""
echo "1. ${BLUE_BG}Read${BG_OFF} selected LOCAL ORIGIN directory RECURSIVELY searching for a certain file extension pattern with which we will create a list of files"
echo "   (with full path name and extension)."
echo "2. Then we ${BLUE_BG}Compare${BG_OFF} this list against a list of file names stored in a LOCAL flat text file (one file name per line without path name and"
echo "   extension)."
echo "3. From the comparison, we ${BLUE_BG}get the location${BG_OFF} (full path and file name including extension) of those file names which match the ones read in"
echo "   the flat text file from the previous step."
echo "4. Lastly, with the information acquired from the previous step, we ${BLUE_BG}MOVE${BG_OFF} the matched files found to a pre-selected LOCAL destination."
echo ""
echo "Right now, we are able to read from LOCAL USB external hard disks/pen drives and internal drives in the most common locations (${GREEN_BG}/media/$USER${BG_OFF} or"
echo "${GREEN_BG}${USUARIO}${BG_OFF}'s home directory and subdirectories) and MOVE the files to the local directory ${GREEN_BG}$MOVEDESTDIR${BG_OFF}"
echo ""
echo "At this moment, we read the list of filenames to compare against the search with a file stored in ${GREEN_BG}$HOME/SAM/compare/${BG_OFF}, so before continuing"
echo "please put a copy of this file in the indicated location. This has to be a flat TXT file, and must have one filename per line, without extension,"
echo "something similar to this (the dots in the lines below also represent other file names):"
echo ""
echo "start of quote"
echo "${GRAY_BG}filename 1${BG_OFF}"
echo "${GRAY_BG}This is another file${BG_OFF}"
echo "${GRAY_BG}the facts about life ver. 3${BG_OFF}"
echo "${GRAY_BG}.${BG_OFF}"
echo "${GRAY_BG}.${BG_OFF}"
echo "end of quote"
echo ""
echo "${BOLD}VERY IMPORTANT${RESET}: If in doubt about any of the steps that follow, please remember that you can always press the combination keys ${BOLD}\"Ctrl + C\"${RESET} on your"
echo "keyboard to finish the program immediately, although, we do not advise to do this if e.g. the system already started to do something like analyzing"
echo "data. So if you need to terminate the program immediately, be sure to do it when for example, the program is still waiting for you to input some"
echo "information."
echo ""
WAIT_KEY
echo ""

# =============================================================================
# PASO 1: elegir el directorio base y generar la lista de archivos por extensión
# =============================================================================
clear
echo "${BOLD}STEP ONE:${RESET} ${UL}Create the list of files${RESET}"
echo ""
echo "The selection made here will be used to recursively search a base file system for a specific file extension pattern of which you will"
echo "be asked for briefly. With this information, we will create a file list including path and extension of each file. Later on, we use"
echo "this list as a base to look for a specific number of files of the same type. When a match is found then we take the file found to"
echo "populate a \"To Move\" list."
echo ""

ASSIGN_BASEDIR

# Repite la pregunta hasta que el ID esté entre 0 y (cantidad - 1).
while (( BASEDIRID < 0 )) || (( BASEDIRID > ${#BASEDIR[@]} - 1 )); do
	SELECT_BF
done

BASEDIRECTORY="${BASEDIR[$BASEDIRID]}"

echo ""
echo "The base directory selected is: " "$BASEDIRECTORY"
echo ""

# --- Extensión a buscar ------------------------------------------------------
echo "Input the ${BLUE_BG}file extension${BG_OFF} to look for in the selected sub-directory $BASEDIRECTORY: "

while [ -z "$FILEEXT" ]; do
	INPUT_FILEEXT
done

# Versión de la extensión apta para nombres de archivo (evita "/" en rutas de reportes).
FILEEXT_RPT=${FILEEXT//\//_}

echo ""
echo "${RED_BG}NOTE:${BG_OFF} Depending on the depth of the directory structure and number of files to read, this may take some time, so please"
echo "      be patient."
echo ""
CURRDATE=$(date +%Y_%b_%d_%H:%M:%S)
STARTTIME=$(date '+%s')
echo "Analysis started $CURRDATE"

# --- Búsqueda recursiva (lista separada por NUL, sin tr ni expansión de globs) -
LOAD_NUL_LIST < <(find "$BASEDIRECTORY" -type f -iname "*.$FILEEXT" -print0 2> /dev/null)
FILELIST=("${NUL_LIST[@]}")

echo ""
echo "Number of $FILEEXT files found: " "${#FILELIST[@]}"
echo "${LRED_BG}Gathering information, please wait... ${BG_OFF}"
echo ""
if (( ${#FILELIST[@]} == 0 )); then
	echo "Nothing to do here, start over again and try another file system/directory or type of file."
	echo ""
	exit 1
else
	# Reporte "Files found": una sola escritura (antes una por archivo y con una
	# línea vacía de más por el "<=" del bucle).
	ORIGINFLFP="$REPORTSDIR/filesfound/${USER}_filetype_${FILEEXT_RPT}_${CURRDATE}.txt"
	printf '%s\n' "${FILELIST[@]}" >> "$ORIGINFLFP"
	ENDTIME=$(date '+%s')

	ANALYSISTIMECALC

	echo ""
fi
WAIT_KEY

# =============================================================================
# PASO 2: elegir el archivo de texto plano con los nombres a buscar
# =============================================================================
clear
echo "${BOLD}STEP TWO:${RESET} ${UL}Load a Local Flat TXT file containing the names of the files to search${RESET}"
echo ""
echo "Right now, we are able to load a flat text file with the list of file names from the \"$HOME/SAM/compare\" directory. So please, if you did not"
echo "yet, then before continue press ${BOLD}\"Ctrl + C\"${RESET} right now to finish the program, proceed to copy the file in that location and then start"
echo "the program over again. Below you have a list of files from that directory so you can select the file using the associated \"${HILITE}File ID:${RESET}\"."
echo "The names in this file will be looked for in the list of files to move we made in the previous Step."
echo ""

# Archivos regulares (no ocultos, excepto los report_*.txt) dentro de "compare".
LOAD_NUL_LIST < <(find "$COMPAREDIR" -maxdepth 1 -not -path '*/\.*' -type f ! -iname 'report_*.txt' -print0)
FLATTXTFILE=("${NUL_LIST[@]}")

echo "Number of files found inside $HOME/SAM/compare: " "${#FLATTXTFILE[@]}"
echo ""
if (( ${#FLATTXTFILE[@]} == 0 )); then
	echo "File ID: There are no files inside the selected directory so..."
	echo "Please verify that you copied the Flat Text file in $HOME/SAM/compare"
	echo ""
	exit 1
else
	echo "Please take a close look at the ${HILITE}highlighted IDs${RESET} and its associated file:"
	echo ""
	for (( i=0; i<${#FLATTXTFILE[@]}; i++ )); do
		echo "File ID: ${HILITE}${i}${RESET} ${FLATTXTFILE[$i]}"
	done
	echo ""

	while (( FILEID < 0 )) || (( FILEID > ${#FLATTXTFILE[@]} - 1 )); do
		SELECT_FILE
	done

	FLATTXTFILESEL="${FLATTXTFILE[$FILEID]}"

	echo ""
	echo "The selected file is: " "$FLATTXTFILESEL"

	# Se trabaja sobre una COPIA temporal privada (mktemp): se normaliza el fin de
	# línea Windows->Unix y se ordena sin duplicados. El archivo original del
	# usuario ya no se modifica. (Reemplaza cp + sort + sponge sobre /tmp/samflattxtfile.)
	TMPFLAT=$(mktemp -t samflattxtfile.XXXXXX) || exit 1
	cp -- "$FLATTXTFILESEL" "$TMPFLAT"
	dos2unix -q "$TMPFLAT"
	sort -u "$TMPFLAT" -o "$TMPFLAT"
fi
echo ""
WAIT_KEY

# =============================================================================
# PASO 3: cruzar la lista de archivos (Paso 1) con los nombres (Paso 2)
# =============================================================================
clear
echo "${BOLD}STEP THREE:${RESET} ${UL}Create the file list with the file names we have to move${RESET}"
echo ""
echo "${LRED_BG}Analyzing data, please wait... ${BG_OFF} This may take some time depending on the number of files."
echo ""
echo "Analysis started: " "$(date +%Y_%b_%d_%H:%M:%S)"

# --- Nombres a buscar: se descartan líneas vacías y "rm -rf" (se registran) ---
FLATTXTCONT=()
FLATTXTLINENUMBER=1
while IFS= read -r LINESFLATTXTCONT; do
	if [[ -z "$LINESFLATTXTCONT" ]] || [[ "$LINESFLATTXTCONT" = *"rm -rf"* ]]; then
		if [ -z "$LINESFLATTXTCONT" ]; then
			MESSAGE2="\"white space\""
		else
			MESSAGE2="\"$LINESFLATTXTCONT\" (hidden malicious code)"
		fi
		echo "$USER" "$CURRDATE" "$FLATTXTFILESEL" "$FILEEXT" "line no." "$FLATTXTLINENUMBER" "had: " "$MESSAGE2" " so it was discarded" >> "$ANOMLOG"
	else
		FLATTXTCONT+=("$LINESFLATTXTCONT")
	fi
	FLATTXTLINENUMBER=$(( FLATTXTLINENUMBER + 1 ))
done < "$TMPFLAT"

STARTTIME=$(date '+%s')
FILESTOMOVE=()

if (( ${#FLATTXTCONT[@]} > 0 )); then
	TMPNAMES=$(mktemp -t samnames.XXXXXX) || exit 1
	TMPSTEMS=$(mktemp -t samstems.XXXXXX) || exit 1
	printf '%s\n' "${FLATTXTCONT[@]}" > "$TMPNAMES"

	# Para cada archivo se calcula su nombre sin ruta y sin la última extensión
	# (misma regla del original: rev|cut|cut|rev). Una línea por archivo; si el
	# nombre trae un salto de línea no puede coincidir con ningún nombre -> "".
	for FOUNDFILE in "${FILELIST[@]}"; do
		STEM=${FOUNDFILE##*/}
		STEM=${STEM%.*}
		[[ "$STEM" == *$'\n'* ]] && STEM=""
		printf '%s\n' "$STEM"
	done > "$TMPSTEMS"

	# Comparación exacta (sensible a mayúsculas) en UNA sola pasada. grep devuelve
	# los números de línea coincidentes; "tac" los invierte para respetar el
	# orden original (de último a primero), del que depende la numeración _N.
	while IFS= read -r LINENO_MATCH; do
		FILESTOMOVE+=( "${FILELIST[$(( LINENO_MATCH - 1 ))]}" )
	done < <(LC_ALL=C grep -naFx -f "$TMPNAMES" "$TMPSTEMS" | cut -d: -f1 | tac)
fi

# Tamaño total (KB de uso en disco, igual que "du" por archivo en el original),
# calculado en lote. -l cuenta cada enlace duro por separado, como antes.
if (( ${#FILESTOMOVE[@]} > 0 )); then
	BYTESTOMOVE=$( printf '%s\0' "${FILESTOMOVE[@]}" | du -kls --files0-from=- 2> /dev/null | awk '{s += $1} END {print s + 0}' )
else
	BYTESTOMOVE=0
fi

echo "Analysis ended:   " "$(date +%Y_%b_%d_%H:%M:%S)"
echo ""
ENDTIME=$(date '+%s')
ANALYSISTIMECALC

echo ""
if (( ${#FILESTOMOVE[@]} == 0 )); then
	echo "${BLUE_BG}There are NO FILES TO MOVE${BG_OFF}, please review the flat text file with filenames against the selected Origin folder, or select the"
	echo "proper flat text file to load in order to compare..."
	echo "Also, may be you or someone else has already run the \"Compare file\" and the files you are looking for have already been"
	echo "moved to $MOVEDESTDIR. Please take a look at the \"$HOME/SAM/compare\" folder and look at the files listed there and compare"
	echo "the contents of those files against the existing files in the $MOVEDESTDIR directory."
	echo ""
	exit 0
else
	echo "The number of files we have to move is: " "${#FILESTOMOVE[@]}"
fi

# Reporte "Files to move".
FILESTOMOVER="$REPORTSDIR/filestomove/${USER}_filetype_${FILEEXT_RPT}_${CURRDATE}.txt"
printf '%s\n' "${FILESTOMOVE[@]}" >> "$FILESTOMOVER"
echo ""

WAIT_KEY

# =============================================================================
# PASO 4: verificar espacio y mover los archivos
# =============================================================================

# Costo del movimiento como % del espacio libre (protegido contra división por cero).
if (( BYTESAVAIL > 0 )); then
	DISKCOST=$(( BYTESTOMOVE * 100 / BYTESAVAIL ))
else
	DISKCOST=100
fi

# Unidades para mostrar tamaños (mover / disponible).
SET_SIZE_UNIT "$BYTESTOMOVE"
SIZEFORMATMOVE=$SU_FORMAT; DIVIDERMOVE=$SU_DIVIDER; SIZEMOVESUFIX=$SU_SUFFIX
SET_SIZE_UNIT "$BYTESAVAIL"
SIZEFORMATAVAIL=$SU_FORMAT; DIVIDERAVAIL=$SU_DIVIDER; SIZEAVAILSUFIX=$SU_SUFFIX

if (( DISKCOST > 90 )); then
	clear
	echo ""
	echo "******************************************************"
	echo "** ATTENTION! The cost of moving the selected files **"
	echo "** is bigger than 90% of the available free disk    **"
	echo "** space in the destination: $MOVEDESTDIR         **"
	echo "** Consider dividing the quantity of moving files   **"
	echo "** to smaller chunks.                               **"
	echo "##################################################"
	echo ""
	echo "Total size of files to move in $SIZEFORMATMOVE: " "$(( BYTESTOMOVE / DIVIDERMOVE ))"
	echo "Total available size of the destination directory in $SIZEFORMATAVAIL: " "$(( BYTESAVAIL / DIVIDERAVAIL ))"
	echo "Please contact your SysAdmin"
	echo ""
	exit 1
fi

clear
echo ""
echo "${BOLD}STEP FOUR:${RESET} ${UL}Moving the files to a pre-selected destination${RESET}"
echo ""
echo "In order to be brief, right now this version of the program MOVES the files to:"
echo ""
echo "${BLUE_BG}$MOVEDESTDIR${BG_OFF}"
echo ""
echo "Future versions of the program may support nicer things like allowing the user to select a destination directory for the files being moved."
echo ""
echo "${LRED_BG}LAST MINUTE WARNING:${BG_OFF} If you continue to move the found files, it can be undone only manually, reviewing the report files, renaming the"
echo "files and moving them back to their original location, so if you want, you may here press ${BOLD}\"Ctrl + C\"${RESET} to finish the program immediately"
echo "or any other key to continue and proceed to move the files."
echo "If you move the files by mistake, as stated above you can always review the report files and undo the moving manually."
echo ""
echo "${GREEN_BG}NOTE 1:${BG_OFF} YOU HAVE BEEN WARNED."
echo "${GREEN_BG}NOTE 2:${BG_OFF} As the files are being moved to \"${BLUE_BG}$MOVEDESTDIR${BG_OFF}\", if you would like to keep a copy of them, you have to do it right after the"
echo "        moving operation because this directory is being cleaned regularly by the Operating System (normally daily or after a reboot)."
echo "        Failing to do so after the moving operation will result in unavoidably loose of those files."
echo ""
WAIT_KEY "PRESS \"Ctrl + C\" to abort or ANY KEY to continue..."
echo ""
echo "${LRED_BG}Moving files, please wait... ${BG_OFF}"
echo ""
CURRDATE=$(date +%Y_%b_%d_%H:%M:%S)
STARTTIME=$(date '+%s')
echo "Moving files started at: $CURRDATE"

# Reporte "Moved files" (la ruta se fija antes del bucle, que la usa en MOVE_ONE_FILE).
MOVEDFILES="$REPORTSDIR/movedfiles/${USER}_filetype_${FILEEXT_RPT}_${CURRDATE}.txt"

# Un mv directo por archivo (antes: echo + xargs + mv, con problemas de comillas).
for FILETOMOVE in "${FILESTOMOVE[@]}"; do
	MOVE_ONE_FILE "$FILETOMOVE"
done

echo ""
ENDTIME=$(date '+%s')
ANALYSISTIMECALC
echo "to move ${#FILESTOMOVE[@]} files."

echo "${LRED_BG}IT'S DONE${BG_OFF}"
echo ""
WAIT_KEY

# =============================================================================
# EPÍLOGO: resumen de la sesión
# =============================================================================
clear
echo "" >> "$SUMMARY"
echo ""
{
	echo "Program started: ""$DATEstartprogram"
	echo "By user: ""$USER"
	echo "File system base to read recursively for sub-directories: ""$FILESYSTEM"
	echo "Sub-directory selected to read recursively for files inside $FILESYSTEM: ""$BASEDIRECTORY"
	echo "Flat text file loaded with filenames to search inside ""$BASEDIRECTORY"": ""$FLATTXTFILESEL"
	echo "Type of files to search inside ""$BASEDIRECTORY"": ""$FILEEXT"
	echo "Number of files found to move: ""${#FILESTOMOVE[@]}"
	echo "Total size of the files moved in $SIZEFORMATMOVE (or WTS total size freed in the origin filesystem): ""$( dc -e "2 k $BYTESTOMOVE $DIVIDERMOVE / p" )" "$SIZEMOVESUFIX"
	echo "Time spent to move ${#FILESTOMOVE[@]} files: ""$ANALYSISTIME" "$FORMAT"
	echo "Size available in the destination file system in $SIZEFORMATAVAIL: ""$( dc -e "2 k $BYTESAVAIL $DIVIDERAVAIL / p" )" "$SIZEAVAILSUFIX"
} >> "$SUMMARY"

echo "=========================="
echo "This Session Report Files:"
echo "=========================="
echo ""
echo "-----------------------------------------------------------------------------------------------------------------------"
echo "Location of this Session's \"Summary\": "
echo "$SUMMARY"
echo "-----------------------------------------------------------------------------------------------------------------------"
echo "Location of the \"Files found\": "
echo "$ORIGINFLFP"
echo "-----------------------------------------------------------------------------------------------------------------------"
echo "Location of the \"Files TO Move\": "
echo "$FILESTOMOVER"
echo "-----------------------------------------------------------------------------------------------------------------------"
echo "Location of the \"Files Effectively MOVED\": "
echo "$MOVEDFILES"
echo "-----------------------------------------------------------------------------------------------------------------------"
echo "Log file of anomalous records found in the TXT flat file: "
echo "$ANOMLOG"
echo "-----------------------------------------------------------------------------------------------------------------------"
echo ""
echo "If you are on an Xterm terminal, you can always select the wholename with your mouse, right click on it, select \"Copy\""
echo "and later on another terminal paste the selection using the combination keys \"Ctrl+Shift+C\" and use a program of your"
echo "liking like cat, etc."
echo "If you feel comfortable with the terminal, you can navigate to the listed locations to find your files."
echo ""
WAIT_KEY
clear
echo ""
echo '**************************************************'
echo '**************************************************'
echo '********   S P E C I A L    B O N U S    *********'
echo '**************************************************'
echo '**************************************************'
echo ""
echo "If you want, right now we can FIND and DELETE ALL DUPLICATE files in $MOVEDESTDIR, preserving ONLY the first file in the"
echo "set of matching files..."
echo "This CAN NOT be undone, so if you are not COMPLETELY sure, press \"n\""
echo ""
echo "Do you want me to delete ALL duplicate files?"
echo ""

# Solo acepta "y" o "n" (el while original tenía una condición siempre verdadera).
until [[ "$DELDUPFILES" == "y" || "$DELDUPFILES" == "n" ]]; do
	read -n 1 -s -r -p "Press ${GREEN_BG}\"y\"${BG_OFF} to ${GREEN_BG}delete all duplicates${BG_OFF} or ${GREEN_BG}\"n\"${BG_OFF} to ${GREEN_BG}exit${BG_OFF} (no changes will be made): " DELDUPFILES
	echo ""
done
if [ "$DELDUPFILES" = "y" ]; then
	echo ""
	echo "Are you ABSOLUTELY sure? This is your last chance..."
	echo ""
	WAIT_KEY "PRESS \"Ctrl + C\" to abort or ANY KEY to continue..."
	# Se conserva "2>&1 > /dev/null": stdout se descarta pero los errores siguen visibles.
	fdupes -AqdN -r "$MOVEDESTDIR" 2>&1 > /dev/null
	echo ""
	echo ""
fi

echo "${LRED_BG}IT'S DONE${BG_OFF}"
echo ""

exit 0
