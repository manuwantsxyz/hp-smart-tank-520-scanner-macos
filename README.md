# Escáner Libre

App de macOS para escanear con la **HP Smart Tank 520** por USB **sin los drivers de HP** y sin pasar por el servicio de macOS que la deja colgada en "Waiting for scanner" / "Esperando al escáner".

La experiencia es la de **Captura de Imagen**: vista previa del vidrio, seleccionar un área y escanear solo esa parte en alta resolución. Además suma:

- **Varias selecciones** en un mismo escaneo (un archivo por elemento), con **detección automática** del documento o de cada foto, y corrección de inclinación.
- **Proporciones fijas** para redes: 1:1, 4:5, 9:16, 16:9, 1.91:1 y más, verticales y horizontales. El archivo sale con la proporción exacta (por ejemplo 1080 × 1350).
- **Modo Documento PDF** para libros y documentos largos: página por página, opción de dividir un libro abierto en 2 páginas, escaneo continuo con tiempo para dar vuelta la hoja, reordenar arrastrando y **PDF con texto buscable** (OCR en español e inglés).
- Color, escala de grises y blanco y negro, rotación, brillo, contraste, nitidez y umbral.
- Guardar como JPEG, PNG, TIFF, HEIC o PDF. **Abrir con** cualquier app (Affinity, Photoshop, Vista Previa…), **Copiar** al portapapeles o arrastrar la miniatura.

> No está afiliada a HP Inc. "HP" y "Smart Tank" son marcas de HP Inc. y se mencionan solo para indicar compatibilidad.

## Requisitos

- macOS 14 Sonoma o posterior, en Mac con Apple Silicon o Intel.
- La impresora conectada **por cable USB**.
- Nada más: la app no necesita Python, Homebrew ni drivers.

**Probada con:** HP Smart Tank 520 (USB `03f0:4554`, se reporta como "Smart Tank 520_540 series").

**Debería funcionar con:** otras impresoras que escanean por eSCL sobre IPP-over-USB (otras Smart Tank, DeskJet y ENVY recientes de HP, y modelos de otras marcas con "AirPrint/AirScan por USB"). No están probadas. Si probás una, contame en un *issue* si funcionó.

## Instalación

1. Descargá `Escaner-Libre-…-macOS.zip` de [Releases](../../releases) y descomprimilo.
2. Mové **Escáner Libre.app** a Aplicaciones.
3. La primera vez macOS va a decir que no puede verificar al desarrollador, porque la app no está notarizada por Apple. Para abrirla:
   - En Finder, **clic derecho → Abrir → Abrir**.
   - Si no aparece la opción: **Configuración del Sistema → Privacidad y seguridad**, bajá hasta el aviso de "Escáner Libre" y elegí **Abrir igual**.
   - O desde la Terminal: `xattr -dr com.apple.quarantine "/Applications/Escáner Libre.app"`

Mientras escaneás, cerrá **Captura de Imagen** y **Vista Previa**: el escáner atiende a una sola app por vez.

## Uso rápido

| Acción | Cómo |
|---|---|
| Vista previa del vidrio | **Vista general** (⌥⌘R) |
| Elegir un área | Arrastrar sobre la vista previa. Con ⇧ o ⌘ se agregan más áreas |
| Fijar proporción | Detalles → Área → **Proporción**. El botón ↔ cambia entre vertical y horizontal |
| Escanear | **Escanear** (⌘R). Cancelar con ⌘. |
| Libro / PDF de varias páginas | Modo **Documento PDF** (⌘B) → **Escanear página** → **Guardar PDF** (⌘S) |
| Copiar el último escaneo | **Copiar** o ⌘C |

## ¿Por qué no anda bien con el driver de HP / Captura de Imagen?

La impresora no usa un driver de escáner tradicional. Escanea con **eSCL**, que es HTTP con XML, a través del USB (IPP-over-USB). En macOS ese canal pasa por un proxy del sistema, `ippusbd`, que **se desincroniza**: si una app se desconecta antes de leer toda una respuesta, la siguiente app recibe la respuesta vieja. A partir de ahí Captura de Imagen queda en "Waiting for scanner" o falla con el error `-21345`.

Además, el módulo "HP Scanner 3" de HP no incluye a este modelo. Esta app habla eSCL directamente con el USB usando libusb, descarta lo que haya quedado pendiente en el canal y lee de a un paquete. Por eso escanea siempre igual.

El diagnóstico completo está en [docs/diagnostico.md](docs/diagnostico.md).

## Compilar desde el código

Necesitás las Command Line Tools de Xcode (`xcode-select --install`).

```sh
app/build.sh             # → app/build/Escáner Libre.app (universal)
app/build.sh --install   # además la copia a ~/Applications
app/build.sh --release   # además arma dist/Escaner-Libre-<versión>-macOS.zip
app/tests/run.sh         # pruebas; las que usan el escáner necesitan la impresora conectada
app/tests/run.sh --offline
```

`build.sh` descarga y compila **libusb** (versión fija, con verificación SHA-256) como biblioteca universal y la incluye dentro de la app. Para firmar con una identidad de desarrollador: `SIGN_ID="Developer ID Application: …" app/build.sh --release`.

### Estructura

```
app/        App SwiftUI: Backend.swift (driver eSCL por USB), Model, interfaz, procesamiento de imagen, PDF y OCR
app/tests/  Pruebas (con y sin escáner)
cli/        Versión de línea de comandos en Python (hpscan.py), con la que empezó el proyecto
scripts/    Compilación de libusb
docs/       Diagnóstico del problema con macOS
```

### Línea de comandos (opcional)

```sh
brew install libusb && python3 -m venv .venv && .venv/bin/pip install pyusb
cli/escanear -o ~/Desktop/documento.pdf --dpi 300
.venv/bin/python cli/hpscan.py info
```

## Licencia

[MIT](LICENSE). La app incluye **libusb** (LGPL-2.1) como biblioteca dinámica separada: ver [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

### In English

**Escáner Libre** is a macOS app (UI in Spanish) for scanning with an **HP Smart Tank 520** over USB without HP drivers. It speaks eSCL over IPP-over-USB directly with a bundled libusb, which works around macOS's `ippusbd` proxy desyncing ("Waiting for scanner", error -21345). It offers an Image Capture–style overview and region scanning, aspect-ratio presets for social media, multi-page searchable PDFs, and Open With / Copy. It needs macOS 14+ (Apple Silicon or Intel). The app is unsigned: right-click → Open the first time. Other eSCL-over-USB printers may work but are untested.
