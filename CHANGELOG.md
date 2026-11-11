# Cambios

## 0.10.0 — Periodo de prueba (tester) y licencia premium
- **Cabrio pasa a periodo de prueba hasta el 9 de febrero de 2027.** Es gratis durante ese periodo; después, cada app costará 10 USD (pago único). Al abrirla por primera vez se explica con una ventana clara; en el panel hay una línea discreta («Versión de prueba · quedan N días · Premium: 10 USD») y en el menú del ícono, «Obtener premium…» e «Introducir clave…». En los últimos 14 días se muestra un recordatorio una vez al día.
- **Activación con clave, sin internet.** La clave se verifica en tu Mac (firma ECDSA P-256); nada se envía. Ajustes tiene una pestaña «Licencia» con el estado, «Obtener premium», «Introducir clave…» y «Quitar licencia». Una licencia nunca caduca.
- **Al terminar la prueba** aparece una ventana que pide la clave y ninguna acción se ejecuta (comprimir, dividir, OCR, proteger, convertir, renombrar, zip), ni las reglas automáticas; las reglas, el historial y tus archivos se conservan intactos y no se borra nada. Retrasar el reloj del Mac no reactiva la prueba.
- Sin llamadas de red: solo se abre la página de compra en tu navegador. Se corrigió el texto de Acerca de, que decía «sin límites» y «la licencia llegará más adelante».

## 0.9.2 — Seguridad
- **Las reglas de carpetas ya no se disparan a sí mismas.** «Convertir a JPG» sobre una carpeta vigilada ya no crea `a-2.jpg`, `a-2-2.jpg`… sin fin: ignora lo que Cabrio mismo genera, no convierte un archivo que ya tiene el formato destino y deja de procesar un archivo tras 3 pasadas en 60 s, avisando en la regla. Lo mismo ocurre con reglas que se mueven archivos entre sí.
- **Las reglas por antigüedad ya no actúan sobre archivos recién llegados.** Antes, un `.dmg` antiguo copiado a Descargas podía ir a la Papelera a los 2 segundos. Ahora solo actúan en el barrido programado o con «Ejecutar ahora».
- **Las reglas que mandan a la Papelera o dependen de la antigüedad piden aprobación** («Aprobar…», con la cuenta de archivos afectados) antes de actuar solas. Las reglas de estos tipos que ya tenías quedan pendientes hasta que las apruebes.
- No se pueden vigilar carpetas como `/`, tu carpeta personal, `/Applications` o `~/Library`.
- **Un PDF dañado o malicioso ya no cierra Cabrio.** El lector de PDF valida estructura, tamaños y dimensiones, y limita memoria y recursión; ante un archivo así muestra un error. Los PDF normales se comprimen y protegen igual que antes.
- El historial ya no guarda en memoria la contraseña de los PDF protegidos, y un fallo al generar el cifrado produce un error en lugar de un PDF dañado.

## 0.9.1 — Corrección
- Los botones principales («Mostrar en Finder», «Proteger», «Comprimir»…) no se leían en modo oscuro: el texto y el fondo tenían casi el mismo color. Ahora usan un estilo propio que invierte los colores del tema (revisado en claro y en oscuro, con el estado desactivado).

## 0.9.0 — Distribución
- Acción rápida del Finder «Cabrio» (clic derecho → Acciones rápidas → Cabrio): abre en Cabrio los archivos o carpetas seleccionados, incluso con la app cerrada. Se instala o se quita desde Ajustes y desde la bienvenida; `QuickAction/make-workflow.py` la regenera.
- Cabrio ahora recibe archivos desde el Finder («Abrir con», `open -b`, arrastrar al Dock).
- Hardened runtime con `Distribution/Cabrio.entitlements` (Apple Events para leer la selección del Finder); firma ad hoc en desarrollo o Developer ID con `CABRIO_SIGN_ID`.
- `make-release.sh`: app universal firmada, DMG con ícono (`Cabrio-X.Y.Z.dmg` y `Cabrio.dmg`), y con credenciales firma el DMG, notariza con `notarytool` y le pone el sello.
- Textos de permisos de Escritorio, Descargas y Documentos, en español e inglés.
- `DISTRIBUCION.md`: qué falta de tu lado (cuenta de pago, certificado, perfil de notarización), Sparkle y cobro, y por qué la App Store exige rediseño por el sandbox.
- Verificado: la app firmada arranca desde el DMG con hardened runtime y recibe archivos.

## 0.8.1 — Inglés
- Interfaz completa en inglés (`Resources/en.lproj`): panel, Ajustes, bienvenida, reglas, menús, avisos y todos los mensajes de error del núcleo. El español sigue siendo el idioma base y la clave; macOS elige según el idioma del sistema (cualquier otro idioma cae en español).
- Los textos del núcleo ahora pasan por `tr()` (también las subcarpetas que crean las reglas: «Imágenes» / «Images»).
- Prueba de cobertura: falla si el código usa una clave sin traducción, si los marcadores de formato no coinciden o si queda una traducción sin uso.
- Portugués (pt-BR) queda fuera por ahora.

## 0.8.0 — Reglas de carpetas
- Reglas por carpeta vigilada (FSEvents): condiciones por tipo, extensión, palabras en el nombre (sin distinguir mayúsculas ni tildes), antigüedad y tamaño, combinadas con «y». Una regla sin criterios no coincide con nada.
- Acciones: mover a una carpeta (con subcarpeta por año, mes o tipo), enviar a la Papelera y convertir imágenes (copia; el original se conserva). Nunca se borra de forma permanente ni se pisa un archivo: si el nombre existe se añade «-2».
- Cuidado con lo que se toca: ignora archivos ocultos y descargas a medias (.crdownload, .part…), espera a que el archivo deje de crecer, solo mira los hijos directos de la carpeta (sin bucles con la carpeta de destino) y la primera regla que coincide gana.
- Reglas por antigüedad: se revisan al arrancar y cada 30 minutos, porque un archivo viejo no genera eventos.
- Todo queda en el historial y se puede deshacer, incluso lo enviado a la Papelera (se restaura desde donde quedó). El historial ahora se guarda en disco: «Deshacer» sobrevive a cerrar la app.
- Pestaña Reglas en Ajustes: lista con interruptores, editor con «Probar» (qué archivos coinciden ahora), «Ejecutar ahora» con confirmación y recuento, plantillas (capturas, PDF, instaladores viejos, HEIC a JPG) y actividad reciente con «Deshacer». Interruptor general también en el panel.
- Sin plantillas activas por defecto: no hay reglas hasta que las creas y las guardas.
- 63 pruebas, con un caso de extremo a extremo en disco real (FSEvents mueve una captura sin intervención y se deshace; Papelera real con restauración).
- Límites: reglas guardadas en JSON (el `cabrio.md` prevé SwiftData); sin avisos del sistema cuando una regla actúa; no vigila subcarpetas; las reglas con carpetas protegidas (Descargas, Escritorio) pueden pedir permiso a macOS la primera vez.

## 0.7.0 — Ajustes y bienvenida
- Ventana de Ajustes con cuatro pestañas: General (abrir al iniciar sesión, sufijo de los resultados con ejemplo en vivo), Formatos y calidad (calidad de imagen, nivel o meta por defecto de PDF y video, HEVC, idiomas del OCR), Atajos y Acerca de.
- El sufijo `_cabrio` ya es configurable y se lee en cada operación; se limpia de «/», «:» y caracteres de control, y con sufijo vacío nunca se pisa el original.
- Atajo global (por defecto ⌃⌥⌘C, configurable): abre Cabrio con la selección actual del Finder (AppleScript; pide el permiso de Automatización, con estado visible y aviso en el panel si falta).
- Bienvenida de primer arranque: privacidad, tres beneficios y puesta en marcha (abrir al iniciar sesión, permiso del Finder); se puede volver a ver desde Ajustes o el menú.
- Clic derecho (o ⌃clic) en el ícono: Ajustes, Bienvenida y Salir. Botón de engranaje en el panel.
- 49 pruebas (incluye atajos, sufijo y preferencias). Pantallas revisadas con capturas renderizadas.
- Pendiente de esta versión: pestañas Recetas y Reglas de carpetas (llegan con sus módulos), y el permiso de Descargas y el clic derecho del Finder (dependen del sandbox/extensión).

## 0.6.0 — Renombrar por lotes
- «Renombrar» disponible para cualquier selección (archivos y carpetas), con plantilla: `{name}`, `{n}` / `{n:3}` (contador con ceros), `{date}` / `{date:yyyyMMdd}`, `{created}`, `{parent}`; más buscar y reemplazar, mayúsculas/minúsculas/título, número inicial y orden por nombre (natural: img2 antes que img10) o por fecha.
- Vista previa «antes → después» en el panel antes de tocar nada, con errores de plantilla en rojo y plantillas de ejemplo.
- Nunca pisa archivos: si el destino existe o dos nombres coinciden se añade «-2», «-3». La extensión se conserva. Nombres normalizados (NFC) y sin caracteres no válidos.
- Cambios de nombre cruzados (1→2 y 2→3) y de solo mayúsculas pasan por nombres temporales.
- Si algo falla a mitad, todo vuelve a su nombre; nunca se usa la Papelera con archivos renombrados. «Deshacer» devuelve cada archivo a su nombre y se niega (sin cambiar nada) si el nombre viejo está ocupado o el archivo ya no está.
- 45 pruebas, entre ellas renombrado en disco real con tildes, ñ y emoji.

## 0.5.0 — Imágenes, video y audio
- Imágenes: «Convertir formato» (JPG, PNG, HEIC) con pantalla de opciones, «Comprimir» (reescala y recomprime conservando el formato), «Reducir a 1600 px», «Quitar fondo» (Vision, PNG transparente) y «Unir en un PDF».
- Video (AVFoundation): comprimir a MP4 por nivel o por meta de tamaño (bitrate calculado, hasta 4 intentos; si el codificador llega a su piso se reduce la resolución), con opción HEVC; «Convertir a MP4» mantiene calidad. Conserva audio, duración y orientación.
- Audio: «Extraer audio» de un video y «Convertir a M4A» desde otros formatos.
- Si la meta de tamaño es imposible, se guarda el mínimo logrado y se avisa, con «Cambiar la meta».
- 36 pruebas; el video de prueba se genera en el propio test. Quitar fondo probado numéricamente con 3 fotos HEIC reales.
- Límites: sin WebP (ImageIO de macOS no lo escribe; haría falta libwebp), sin MP3 (fase 2), sin comprimir audio por separado.
- Corregido en el camino: `URL.resourceValues` devolvía un tamaño en caché para el mismo URL.

## 0.4.0 — Proteger PDF
- Proteger con contraseña (AES de 128 bits) y quitar una contraseña conocida (también la vacía, para PDF con solo restricciones de edición; sirve la del usuario o la del propietario).
- Se cifran solo cadenas y streams sobre los bytes originales: PDFKit, al reescribir con contraseña, dañaba el texto y cambiaba pesos, así que no se usa.
- Comprobado con 4 PDF reales (incluye xref en stream y objetos comprimidos): Vista Previa/PDFKit los abre con la contraseña, el texto es idéntico y la ida y vuelta devuelve el mismo texto.
- La contraseña vive solo en memoria (`SecretRef`): no sale en descripciones ni se codifica en el historial.
- Límites: no quita cifrado AES de 256 bits (V5); contraseñas con tildes o ñ se abren con Cabrio pero PDFKit/Vista Previa no las acepta (ni siquiera al escribirlas), y la app lo avisa.

## 0.3.0 — Comprimir PDF
- Comprimir por nivel (baja, media, alta) o por meta de tamaño («menos de 2 MB»), uno o varios PDF.
- Solo se recomprimen las imágenes (JPEG y Flate de 8 bits, escalando según el tamaño de página); texto, vectores, enlaces y metadatos se copian byte a byte.
- Meta por búsqueda binaria sobre una escalera de 6 ajustes (300→72 dpi, calidad 0,8→0,4). Si no se alcanza, se guarda el mínimo logrado y el panel avisa, con «Cambiar la meta».
- Si no hay nada que ganar, se entrega el original sin cambios y se avisa («ya estaba optimizado»).
- El panel muestra antes → después y el porcentaje ahorrado.
- Lector propio de PDF: tablas xref clásicas y de tipo stream, objetos comprimidos y actualizaciones incrementales. PDF cifrados: se dejan sin cambios.
- Probado con 4 PDF reales (texto idéntico y mismas páginas tras comprimir). Sin qpdf: no se optimiza la estructura, solo las imágenes.
- Límite: PDF con casi solo texto y fuentes (p. ej. 469 KB sin imágenes) no se reducen.

## 0.2.0 — Dividir y OCR
- Dividir PDF: una página por archivo o por rangos («1-3, 5, 8-»); el resultado es una carpeta `nombre_cabrio`.
- Hacer buscable (OCR con Vision, español/inglés/portugués): la página original queda intacta y se añade texto invisible; las páginas que ya traen texto no se reconocen de nuevo.
- Barra de progreso real en el panel; la cola publica el avance.
- 19 pruebas (incluye un OCR real sobre una imagen con texto).
- Límite conocido: el OCR redibuja las páginas, así que se pierden marcadores, enlaces y formularios del PDF original.

## 0.1.0 — primera base
- Proyecto SwiftPM por capas (Domain, Ports, Application, Adapters, App) según cabrio.md §6.
- Panel en la barra de menú con arrastre al ícono y al panel; kit de marca integrado.
- Acciones: unir PDF, imágenes a PDF, convertir imágenes (JPG/PNG/HEIC), reducir a 1600 px, ZIP limpio para Windows.
- Cola de trabajos cancelable, historial en memoria y «Deshacer» (a la Papelera).
- 13 pruebas (dominio/aplicación con dobles; adaptadores con archivos reales).
