# SAM (Search And Move) v4.0

**SAM** es una utilidad interactiva en Bash diseñada para entornos GNU/Linux (Debian/Ubuntu y derivados) que automatiza la búsqueda recursiva, auditoría y movimiento masivo de archivos basándose en patrones de extensión y listas de cotejo en texto plano.

Incluye mecanismos defensivos de seguridad de POSIX, prevención de inyección de comandos, control estricto de permisos en directorios temporales y desduplicación opcional mediante `fdupes`.

---

## 🚀 Características principales

* **Filtrado dinámico por extensión:** Búsqueda recursiva en directorios base (unidades USB montadas en `/media/$USER` o el `HOME` del usuario).
* **Comparación por listas planas (Flat TXT):** Cruza el árbol de archivos encontrados contra una lista de nombres simples almacenada en `~/SAM/compare/`.
* **Manejo seguro de caracteres especiales:** Procesamiento de rutas y nombres mediante delimitación por `NUL` (`find -print0` y `read -d ''`), preservando espacios, comillas, barras y caracteres complejos sin corrupción.
* **Seguridad y auditoría defensiva:**
  * Creación del directorio de destino (`/tmp/SAMMOVED/`) con permisos estrictos `700` y validación de propiedad para evitar ataques de pre-creación o enlaces simbólicos.
  * Sanitización de registros anómalos o comandos maliciosos inyectados en listas de texto plano.
  * Uso de archivos temporales seguros aislados mediante `mktemp`.
* **Gestión inteligente de colisiones:** En caso de coincidencia de nombres en el destino, preserva las versiones anteriores renombrando el archivo existente con un sufijo numérico progresivo (`_N`).
* **Bonus de desduplicación:** Integración final opcional con `fdupes` para limpiar archivos duplicados en el directorio de destino.

---

## 🛠️ Requisitos del sistema

SAM requiere un entorno Bash (v4.0+) sobre distribuciones basadas en **Debian / Ubuntu** (Debian, Devuan, Ubuntu, Linux Mint, MX Linux, SparkyLinux, etc.).

El script verifica automáticamente la presencia de las siguientes dependencias e intenta instalarlas si es necesario:

* `dos2unix`
* `moreutils`
* `dc`
* `fdupes`

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

