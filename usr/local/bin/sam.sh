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
#   - Movimiento en lote (MOVE_ALL_FILES): plan de nombres en memoria, un solo
#     proceso para todos los renombrados y reporte escrito una vez (antes: un
#     mv, un glob del destino y una escritura al reporte por cada archivo).
#   - Movimiento y borrado en flujo: los datos de la sesión van a un archivo en disco y
#     un solo proceso perl hace el trabajo (memoria acotada aunque haya cientos de miles
#     de archivos). Borrado: se deja la base y una copia por cada contenido distinto.
#   - Enlaces simbólicos que el movimiento dejó rotos: se avisa al final con un reporte
#     (~/SAM/reports/brokenlinks) y se ofrece borrarlos.
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
# Datos de la sesión EN DISCO (no en arreglos): directorio de trabajo temporal dentro de
# $SAMHOME y archivo con el registro "base -> copia" de lo movido en esta ejecución.
SAMWORK=""; SAMSESSION=""

# -----------------------------------------------------------------------------
# 3. FUNCIONES
# -----------------------------------------------------------------------------

# Borra los temporales al salir (normal, error o Ctrl+C).
CLEANUP () {
	rm -f -- "$TMPFLAT" "$TMPNAMES" "$TMPSTEMS"
	[[ -n "$SAMWORK" && "$SAMWORK" == "$SAMHOME"/work.* && -d "$SAMWORK" ]] && rm -rf -- "$SAMWORK"
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
# -----------------------------------------------------------------------------
# MOVIMIENTO Y BORRADO EN FLUJO (memoria acotada, datos de la sesión en DISCO)
#
#  * La lista de la sesión (qué copia se movió y cuál es su base) se escribe a un
#    archivo en $SAMWORK (dentro de $SAMHOME, en disco), no a arreglos de bash.
#  * El movimiento lo hace UN solo proceso perl que lee la lista por stdin. Su única
#    memoria es un contador por nombre con sufijo _N: crece con la cantidad de
#    NOMBRES distintos, no con la de archivos. "¿Ya existe?" se pregunta al sistema
#    de archivos (un lstat), no a una tabla en RAM.
#  * El borrado ordena ese archivo con "sort" (ordenamiento externo: si no cabe en
#    memoria usa archivos temporales) y lo procesa grupo por grupo (un grupo = un
#    nombre base). Solo se guarda en memoria el grupo en curso.
#
# Reglas del borrado, por cada grupo (base + sus copias de ESTA sesión, en el
# orden en que se movieron, es decir, de menor a mayor sufijo):
#   1) la base NUNCA se borra;
#   2) una copia idéntica (byte a byte) a la base se borra;
#   3) entre las copias que difieren de la base, de las idénticas entre sí se deja
#      solo la de menor sufijo;
#   4) el contenido distinto se conserva siempre. Nada fuera de la sesión se toca.
# Se borra únicamente si queda en disco un archivo idéntico, así que un fallo no
# puede destruir contenido único.
# -----------------------------------------------------------------------------
read -r -d '' SAM_PERL_MOVER <<'PERLEOF' || true
use strict; use warnings; use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL);
my ($destdir, $report, $session) = @ARGV;           # $destdir termina en "/"
$/ = "\0";

sub split_name {                                    # "a.b.txt" -> ("a.b", ".txt"); "Makefile" -> ("Makefile", "")
	my $i = rindex($_[0], '.');
	return $i < 0 ? ($_[0], '') : (substr($_[0], 0, $i), substr($_[0], $i));
}
my %maxsuf;                                         # "base\x01.ext" -> mayor N de base_N.ext
sub note_name {
	my ($b, $e) = split_name($_[0]);
	if ($b =~ /^(.*)_([0-9]{1,9})\z/s) {
		my ($k, $n) = ("$1\x01$e", $2 + 0);
		$maxsuf{$k} = $n if $n > ($maxsuf{$k} // 0);
	}
}
sub copy_move {                                     # otro sistema de archivos (EXDEV): copiar, verificar, borrar origen
	my ($s, $t) = @_;
	return 0 if -l $s || !-f $s;
	my @st = stat($s) or return 0;
	sysopen(my $in, $s, O_RDONLY) or return 0;
	sysopen(my $dst, $t, O_WRONLY|O_CREAT|O_EXCL, $st[2] & 07777) or do { close $in; return 0; };
	my ($ok, $buf, $total) = (1, '', 0);
	while ($ok) {
		my $n = sysread($in, $buf, 1 << 20);
		if (!defined $n) { $ok = 0; last; }
		last if $n == 0;
		my $off = 0;
		while ($off < $n) {
			my $w = syswrite($dst, $buf, $n - $off, $off);
			if (!defined $w) { $ok = 0; last; }
			$off += $w;
		}
		$total += $n;
	}
	close $in;
	$ok = 0 unless close($dst) && $total == $st[7];
	if ($ok) {
		chmod($st[2] & 07777, $t); utime($st[8], $st[9], $t); chown($st[4], $st[5], $t);
		$ok = unlink($s) ? 1 : 0;
	}
	unlink($t) unless $ok;
	return $ok;
}
sub move_one {                                      # nunca pisa un archivo existente
	my ($s, $t) = @_;
	return 0 if -e $t || -l $t;
	return 1 if rename($s, $t);
	return copy_move($s, $t) if $!{EXDEV};
	return 0;
}

opendir(my $dh, $destdir) or die "SAM: cannot read $destdir: $!\n";
while (defined(my $e = readdir $dh)) { note_name($e) unless $e eq '.' || $e eq '..'; }
closedir $dh;

open(my $rep, '>>', $report)  or die "SAM: cannot write $report: $!\n";
open(my $ses, '>>', $session) or die "SAM: cannot write $session: $!\n";
my ($moved, $failed) = (0, 0);
while (defined(my $src = <STDIN>)) {
	chomp $src;
	my ($name) = $src =~ m{([^/]*)\z};
	my $dest = $destdir . $name;
	if (-e $dest || -l $dest) {                     # nombre ocupado -> nombre_N.ext (la primera copia no se toca)
		my ($b, $e) = split_name($name);
		my $n = ($maxsuf{"$b\x01$e"} // 0) + 1;
		my $tname = "${b}_${n}${e}";
		if (move_one($src, $destdir . $tname)) {
			note_name($tname); $moved++;
			print $rep "$src with NEWSUFIX _$n\n";
			print $ses "$dest\x01$destdir$tname\0";
		} else { $failed++; print STDERR "SAM: could not move: $src\n"; }
	} else {
		if (move_one($src, $dest)) {
			note_name($name); $moved++;
			print $rep "$src\n";
		} else { $failed++; print STDERR "SAM: could not move: $src\n"; }
	}
}
close $rep; close $ses;
print "$moved $failed\n";
PERLEOF

MOVE_ALL_FILES () {
	local RESULT
	MOVED_OK=0; MOVED_FAIL=0
	: > "$SAMSESSION"
	(( ${#FILESTOMOVE[@]} > 0 )) || return 0
	RESULT=$( printf '%s\0' "${FILESTOMOVE[@]}" | perl -e "$SAM_PERL_MOVER" -- "$MOVEDESTDIR" "$MOVEDFILES" "$SAMSESSION" )
	if [[ "$RESULT" =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
		MOVED_OK=${BASH_REMATCH[1]}; MOVED_FAIL=${BASH_REMATCH[2]}
	fi
}

read -r -d '' SAM_PERL_DELETER <<'PERLEOF' || true
use strict; use warnings;
$/ = "\0";
sub fp {                                            # huella barata: tamaño + primeros 4 KB
	my @st = stat($_[0]) or return undef;
	open(my $f, '<:raw', $_[0]) or return undef;
	my $buf = ''; my $r = read($f, $buf, 4096); close $f;
	return defined $r ? "$st[7]:$buf" : undef;
}
sub same {                                          # comparación completa byte a byte
	open(my $fa, '<:raw', $_[0]) or return 0;
	open(my $fb, '<:raw', $_[1]) or return 0;
	my ($x, $y);
	while (1) {
		my $ra = read($fa, $x, 1 << 20);
		my $rb = read($fb, $y, 1 << 20);
		return 0 unless defined $ra && defined $rb;
		return 0 if $ra != $rb || $x ne $y;
		return 1 if $ra == 0;
	}
}
my ($del, $kept, $nobase) = (0, 0, 0);
my ($curbase, $basegood, %reps);                    # %reps: huella -> [archivos que SE QUEDAN con ese contenido]
while (defined(my $rec = <STDIN>)) {
	chomp $rec;
	my $i = index($rec, "\x01"); next if $i < 0;
	my ($base, $copy) = (substr($rec, 0, $i), substr($rec, $i + 1));
	if (!defined $curbase || $base ne $curbase) {   # empieza un grupo nuevo
		$curbase = $base; %reps = (); $basegood = 0;
		if (-f $base && !-l $base) {
			my $k = fp($base);
			if (defined $k) { $reps{$k} = [$base]; $basegood = 1; }
		}
	}
	next if !-f $copy || -l $copy;                  # la copia ya no está: nada que hacer
	if (!$basegood) { $nobase++; next; }            # sin base verificable no se borra nada
	my $k = fp($copy);
	if (!defined $k) { $kept++; next; }
	my $dup = 0;
	if ($reps{$k}) { for my $r (@{ $reps{$k} }) { if (same($r, $copy)) { $dup = 1; last; } } }
	if ($dup) { $del++ if unlink($copy); }
	else      { push @{ $reps{$k} }, $copy; $kept++; }
}
print "$del $kept $nobase\n";
PERLEOF

DELETE_SESSION_DUPLICATES () {
	local RESULT
	DELETED=0; KEPTDIFF=0; NOBASE=0
	[[ -s "$SAMSESSION" ]] || return 0
	RESULT=$( LC_ALL=C sort -z -s -t $'\x01' -k1,1 -S 64M -T "$SAMWORK" "$SAMSESSION" | perl -e "$SAM_PERL_DELETER" )
	if [[ "$RESULT" =~ ^([0-9]+)\ ([0-9]+)\ ([0-9]+)$ ]]; then
		DELETED=${BASH_REMATCH[1]}; KEPTDIFF=${BASH_REMATCH[2]}; NOBASE=${BASH_REMATCH[3]}
	fi
}

# -----------------------------------------------------------------------------
# ENLACES SIMBÓLICOS ROTOS POR EL MOVIMIENTO
# Mover un archivo deja colgando los enlaces simbólicos que apuntaban a él. Para
# identificar SOLO los que rompió esta sesión (y no los que ya estaban rotos) se
# toma una lista de enlaces rotos del directorio escaneado ANTES de mover y otra
# DESPUÉS; la diferencia son los nuevos. Todo va a archivos en disco (memoria
# constante). Solo se ven los enlaces que estén dentro del directorio escaneado.
# -----------------------------------------------------------------------------
BROKEN_N=0; BROKENREPORT=""

SNAPSHOT_BROKEN_LINKS () {                          # $1 = archivo de salida (rutas ordenadas, separadas por NUL)
	find "$BASEDIRECTORY" -xtype l -print0 2> /dev/null | LC_ALL=C sort -z -S 64M -T "$SAMWORK" > "$1"
}

FIND_NEW_BROKEN_LINKS () {                          # llamar justo DESPUÉS de mover
	BROKEN_N=0; BROKENREPORT=""
	SNAPSHOT_BROKEN_LINKS "$SAMWORK/links_after.bin"
	LC_ALL=C comm -z -13 "$SAMWORK/links_before.bin" "$SAMWORK/links_after.bin" > "$SAMWORK/links_broken.bin"
	BROKEN_N=$(tr -cd '\0' < "$SAMWORK/links_broken.bin" | wc -c)
	if (( BROKEN_N > 0 )); then
		mkdir -p -- "$REPORTSDIR/brokenlinks"
		BROKENREPORT="$REPORTSDIR/brokenlinks/${USER}_filetype_${FILEEXT_RPT}_${CURRDATE}.txt"
		xargs -0 -a "$SAMWORK/links_broken.bin" ls -ld -- >> "$BROKENREPORT" 2> /dev/null
	fi
}

SHOW_BROKEN_LINKS () {                              # llamar al FINAL, antes del mensaje de cierre
	local ANSWER="" f DELETEDLINKS=0
	(( BROKEN_N > 0 )) || return 0
	echo ""
	echo "${BOLD}Broken symbolic links${RESET}"
	echo "Moving files left $BROKEN_N symbolic link(s) pointing to files that are no longer in their original place."
	echo "Only links inside $BASEDIRECTORY are checked. Report with the full list (link -> target):"
	echo "$BROKENREPORT"
	echo ""
	until [[ "$ANSWER" == "y" || "$ANSWER" == "n" ]]; do
		read -n 1 -s -r -p "Press ${GREEN_BG}\"y\"${BG_OFF} to ${GREEN_BG}delete these $BROKEN_N broken link(s)${BG_OFF} or ${GREEN_BG}\"n\"${BG_OFF} to ${GREEN_BG}keep them${BG_OFF}: " ANSWER
		echo ""
	done
	if [[ "$ANSWER" == "y" ]]; then
		# Solo se borra lo que SIGUE siendo un enlace y SIGUE roto (por si algo cambió mientras tanto).
		while IFS= read -r -d '' f; do
			[[ -L "$f" && ! -e "$f" ]] && printf '%s\0' "$f"
		done < "$SAMWORK/links_broken.bin" > "$SAMWORK/links_confirmed.bin"
		xargs -0 -a "$SAMWORK/links_confirmed.bin" rm -f -- 2> /dev/null
		while IFS= read -r -d '' f; do
			[[ -L "$f" ]] || DELETEDLINKS=$(( DELETEDLINKS + 1 ))
		done < "$SAMWORK/links_confirmed.bin"
		echo "Broken links deleted: $DELETEDLINKS"
	else
		echo "No links were deleted. You can review them in the report above."
	fi
	echo ""
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
# 8. PROGRAMAS REQUERIDOS: dos2unix, moreutils, dc, perl-base
#    (un solo bucle en vez de cuatro bloques casi idénticos; mismo orden y
#    mismos mensajes que el original)
# -----------------------------------------------------------------------------
MISSINGPKGS=()
for PROGRAMREQ in dos2unix moreutils dc perl-base; do
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

	# Pista frecuente: cada línea del archivo se compara contra el nombre del archivo SIN su
	# última extensión; si las líneas traen la extensión (p. ej. "reporte_1.txt") no coinciden.
	EXTHINT=0; EXTSAMPLE=""
	for LINEHINT in "${FLATTXTCONT[@]}"; do
		if [[ "${LINEHINT,,}" == *".${FILEEXT,,}" ]]; then
			EXTHINT=$(( EXTHINT + 1 ))
			[[ -z "$EXTSAMPLE" ]] && EXTSAMPLE="$LINEHINT"
		fi
	done
	if (( EXTHINT > 0 )); then
		echo "${HILITE}Hint:${RESET} $EXTHINT line(s) of the selected file end in \".$FILEEXT\" (for example: \"$EXTSAMPLE\")."
		echo "SAM compares each line against the file name WITHOUT its extension, so please write the names without \".$FILEEXT\""
		echo "(for example \"${EXTSAMPLE%.*}\" instead of \"$EXTSAMPLE\") and try again."
		echo ""
	fi
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

# Reporte "Moved files" (la ruta se fija antes de mover, porque MOVE_ALL_FILES la usa).
MOVEDFILES="$REPORTSDIR/movedfiles/${USER}_filetype_${FILEEXT_RPT}_${CURRDATE}.txt"

# Directorio de trabajo en disco para esta sesión (se borra solo al salir, ver CLEANUP).
SAMWORK=$(mktemp -d "$SAMHOME/work.XXXXXX") || exit 1
SAMSESSION="$SAMWORK/session.bin"

# Enlaces simbólicos que ya estaban rotos ANTES de mover (para no atribuirnos esos).
SNAPSHOT_BROKEN_LINKS "$SAMWORK/links_before.bin"

# Movimiento en flujo (un solo proceso; ver MOVE_ALL_FILES).
MOVE_ALL_FILES

# Enlaces que el movimiento dejó rotos (lista y reporte; el aviso se muestra al final).
FIND_NEW_BROKEN_LINKS

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

	# -------------------------------------------------------------------------
	# DEDUPLICACIÓN AISLADA POR SESIÓN (ver DELETE_SESSION_DUPLICATES)
	# Por cada nombre: se conserva la base y, de las copias distintas a ella, una sola por
	# cada contenido distinto (la de menor sufijo). Solo se tocan archivos de ESTA sesión.
	TIMEFORMAT=$'\nDeletion time: %R s (real) | %U s (user) | %S s (sys)'
	time DELETE_SESSION_DUPLICATES
	echo ""
	echo "Duplicates deleted: $DELETED (the base of each group, and one copy of each distinct content, were kept)."
	(( KEPTDIFF > 0 )) && echo "Kept because their content differs from the base (one per distinct content): $KEPTDIFF"
	(( NOBASE > 0 )) && echo "Kept because their base file was not found: $NOBASE"
	echo ""
	echo ""
fi

# Aviso (y borrado opcional) de los enlaces simbólicos que quedaron rotos por el movimiento.
SHOW_BROKEN_LINKS

echo "${LRED_BG}IT'S DONE${BG_OFF}"
echo ""

exit 0
