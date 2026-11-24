# SAM (Search And Move) v7.0

**SAM** es una herramienta CLI interactiva y ultra-eficiente desarrollada en Bash y Perl para buscar, catalogar, mover y deduplicar archivos por extensión y lista de nombres en sistemas GNU/Linux basados en Debian/Ubuntu.

Diseñado desde sus orígenes para entornos donde el rendimiento, el bajo consumo de memoria y la integridad de los datos son críticos, SAM maneja sin problemas cientos de miles de archivos con nombres "no convencionales" (espacios, saltos de línea, caracteres especiales, comillas y secuencias de escape).

---

## 🚀 Características Principales

- **Mapeo y Coincidencia Segura**: Procesamiento mediante listas delimitadas por `NUL` (`\0`), eliminando cualquier riesgo de inyección de comandos o corrupción de rutas.
- **Deduplicación en Flujo por Sesión**: Algoritmo defensivo en Perl con comparación byte a byte (`lstat` + buffer de 4KB + verificación completa) que conserva la base y preserva contenidos distintos.
- **Detección de Enlaces Rotos**: Rastrea y reporta enlaces simbólicos que hayan quedado huérfanos dentro del directorio analizado tras el movimiento, ofreciendo su limpieza opcional.
- **Bajo Consumo de RAM**: Procesamiento por disco/flujo con algoritmos de ordenamiento externo (`sort -z`), ideal para sistemas con recursos limitados.
- **Normalización Automática**: Conversión transparente de finales de línea Windows/DOS (`dos2unix`) en copias temporales aisladas sin alterar los archivos originales.

---

## 📋 Requisitos del Sistema

- **Sistema Operativo**: Debian, Ubuntu, Linux Mint, SparkyLinux, MX Linux o cualquier derivado basado en Debian.
- **Dependencias**: `dos2unix`, `moreutils`, `dc`, `perl-base`.

---

## 📦 Instalación

### Desde paquete `.deb` (Recomendado)
```bash
sudo dpkg -i sam_4.0-1_all.deb
sudo apt-get install -f
```

### Manual
```bash
git clone [https://github.com/zopeck/sam.git](https://github.com/zopeck/sam.git)
cd sam
chmod +x usr/local/bin/sam.sh
sudo cp usr/local/bin/sam.sh /usr/local/bin/sam
```

---

## 📂 Estructura de directorios de trabajo
Al ejecutarse por primera vez, SAM crea automáticamente la siguiente estructura en el espacio de usuario:
```text
~/SAM/
├── compare/       # Aquí se colocan los archivos .txt con los nombres a buscar
├── reports/       # Reportes de auditoría generados por cada sesión
│   ├── filesfound/
│   ├── filestomove/
│   └── movedfiles/
└── logs/          # Historial de registros anómalos y resumen de actividad
```
Los archivos procesados se mueven a la ubicación local segura:/tmp/SAMMOVED/

---

## 💻 Modo de uso:
- Paso 1: Crea un archivo de texto plano en ~/SAM/compare/ con los NOMBRES de los archivos a buscar, SIN su extension y un solo nombre por linea (por ejemplo: si el archivo a buscar es "recomendaciones_al_dia.txt" el nombre que se debe colocar es "recomendaciones_al_dia", sin las comillas dobles).
- Paso 2: Ejecuta el script, y selecciona el origen a escanear: Puede ser un dispositivo USB externo (pendrive, SSD o disco mecanico) o un directorio de tu home.
- Paso 3: De el origen del paso 2, selecciona el directorio a escanear, el escaneo del directorio base seleccionado es recursivo (/media/$USER o $HOME).
- Paso 4: Ingresa una extension para escanear, con la cual se generara el catalogo de busqueda (solo la extension "a secas": pdf, doc, txt, mp3, jpg, etc.).
- Paso 5: Selecciona el archivo que contiene los nombres de archivo a escanear, que creaste en el paso 1, de ahi se leeran y cargaran los nombres de archivos a buscar obtenidos del escaneo que genero el catalogo en el paso 4.
- Paso 6: De los nombres del paso 1 y de las extensiones del paso 4, se busca en el catalogo, y, si surgen coincidencias, se indicara la cantidad de archivos para mover al directorio temporal. Si no hubieran coincidencias, el programa termina indicandolo ("there are NO FILES TO MOVE").
- Paso 7: El programa indica que los archivos seram movidos a "/tmp/SAMMOVED/", pero se puede terminar el programa presionando la combinacion de teclas "Ctrl+C".
- Paso 8: Se indica una serie de reportes para validacion: Archivos encontrados, donde fueron encontrados, archivos efectivamente movidos.
- Bonus / Cleanup: Opción de deduplicar los archivos movidos a /tmp/SAMMOVED/ preservando copias únicas y opción de limpiar enlaces rotos.

---

## 📜 Licencia y Autoria:
- Autor: "Mark" Marco A. Rodriguez G. (@zopeck, zopeck@gmail.com)
- Licencia: GNU General Public License v3.0 (GPLv3). Consulta el archivo COPYING para más detalles.
