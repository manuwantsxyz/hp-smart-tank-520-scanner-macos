# Por qué el escáner de la HP Smart Tank 520 falla en macOS

Síntomas con Captura de Imagen, Vista Previa o el escaneo de Configuración del Sistema:

- "Waiting for scanner" / "Esperando al escáner" que no termina nunca.
- *Failed to open a connection to the device (-21345)*.
- A veces funciona y a veces no; el escaneo se cuelga a la mitad; el escáner "desaparece".

## Cómo escanea esta impresora

La Smart Tank 520 no usa un protocolo de escáner propio. Escanea con **eSCL** (también llamado AirScan o Mopria), que es **HTTP con XML**:

- `GET /eSCL/ScannerCapabilities`
- `POST /eSCL/ScanJobs`
- `GET …/NextDocument`

Por la red eso va por TCP. **Por USB** va por **IPP-over-USB**: la impresora tiene interfaces USB de clase 7/1/4, y por sus endpoints *bulk* viaja el mismo HTTP.

## Qué hace macOS

macOS no habla con esas interfaces directamente desde cada app. Las toma un servicio del sistema, **`ippusbd`**. Ese servicio levanta un proxy HTTP en `localhost` y lo anuncia por Bonjour como escáner de red (`_uscan._tcp`). Captura de Imagen usa ese proxy a través de su módulo AirScan, como si la impresora estuviera en la red.

## La falla

En USB hay **un solo canal**: las respuestas salen en el mismo orden en que entraron los pedidos. `ippusbd` comparte ese canal entre las conexiones de las apps, pero **cuando una app se desconecta sin leer completa su respuesta, no descarta lo que quedó pendiente**.

Ejemplos de cuándo pasa:

- se cancela un escaneo;
- se cierra la ventana;
- vence un *timeout*;
- el sistema hace una consulta de estado y la abandona.

Lo que quedó pendiente le llega a la conexión siguiente como respuesta a otro pedido. Desde ese momento todo queda **corrido una respuesta**. Captura de Imagen recibe XML o datos que no corresponden a lo que pidió y queda en "Waiting for scanner", o falla al abrir la conexión con `-21345`.

El estado se "arregla" solo cuando se reinicia el canal: al apagar y prender la impresora, al desconectar el USB o cuando `ippusbd` se reinicia. Por eso **a veces funciona y a veces no**.

## ¿Y el driver de HP?

El módulo de escáner que instala HP ("HP Scanner 3") no incluye el identificador USB de este modelo (`03f0:4554`). Para macOS la impresora queda en manos de AirScan y `ippusbd`, así que el software de HP no cambia nada.

## ¿Se puede arreglar?

**No desde afuera.** El problema está en un componente del sistema operativo, así que lo tiene que corregir Apple. HP no puede arreglarlo con un driver, porque la impresora hace lo que corresponde.

Lo que sí se puede hacer es **no pasar por `ippusbd`**. Eso hace esta app:

1. Toma la interfaz IPP-over-USB directamente con libusb, solo mientras escanea.
2. Antes de cada pedido **descarta lo que haya quedado pendiente** en el canal. La impresora también manda paquetes de longitud cero, así que lee hasta que el canal queda en silencio.
3. Lee **de a un paquete USB** (512 bytes). En macOS, una lectura grande que vence antes de que llegue un paquete corto pierde los datos parciales, y eso desincroniza el canal.
4. Si se cancela a mitad, vacía el canal y borra el trabajo en la impresora (`DELETE` del *job*), así el cabezal vuelve y el siguiente escaneo arranca limpio.
5. Antes de escanear espera a que el escáner esté en `Idle`, porque el cabezal tarda unos segundos en volver.
6. No reinicia el USB: en esta impresora un reset hace desaparecer la interfaz 0. La app prefiere las interfaces IPP-USB de número más alto.

Mientras la app escanea, otras apps que quieran usar el escáner reciben "ocupado", y al revés. Por eso conviene tener cerrada Captura de Imagen.
