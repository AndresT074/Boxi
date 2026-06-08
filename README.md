# Boxi

**Ecosistema de Gestión de Inventario, Ventas y Catálogo Web para Emprendedores**  
*Lleva tu negocio al siguiente nivel con la tecnología de Boxi.*

[![Descárgalo en Google Play](https://img.shields.io/badge/Google_Play-Descargar_App-green?logo=google-play&logoColor=white&style=for-the-badge)](https://play.google.com/store/apps/details?id=com.andres074.boxi)

---

## 📝 Descripción del Proyecto

**Boxi** es el ecosistema digital diseñado para transformar la manera en que los emprendedores y dueños de negocios gestionan su operación. Olvida los registros manuales y los sistemas complejos; Boxi centraliza tu inventario, ventas y presencia online en una herramienta ágil, intuitiva y potente.

Con Boxi, el control total de tu comercio está en la palma de tu mano, permitiendo una transición digital sin fricciones y un control riguroso de la rentabilidad comercial tanto de forma local como en la nube.

---

## 🚀 Ecosistema de Funciones Inteligentes

*   📦 **Inventario Maestro:** Registra productos con fotografía, gestiona costos de adquisición y precios de venta, y mantén un stock inteligente (con soporte para variantes complejas) que se actualiza en tiempo real de forma local mediante SQLite.

*   🌐 **Venta y Catálogo Web:** Genera tu propia tienda online en segundos (`https://boxi-catalogo.web.app/catalogo/?id=USER_ID`). Comparte tu catálogo digital mediante un link y recibe pedidos directamente en la aplicación.

*   📋 **Gestión Operativa de Pedidos:** Optimiza tu flujo de trabajo organizando tus ventas locales y solicitudes de la web por estados: *Pendiente*, *Entregado sin Pago* o *Completado*.

*   📄 **Imagen Corporativa en PDF:** Generación vectorial de catálogos y recibos en formato PDF A4 optimizado (cuadrícula de 2x2). Incluye encuadre de fotos con "Efecto Vitrina", exclusión automática de emojis incompatibles e hipervínculos interactivos hacia la tienda de aplicaciones.

*   👥 **Directorio Estratégico:** Administra tu base de datos de clientes y vendedores de forma organizada.

*   📊 **Analítica de Rentabilidad:** Visualización automatizada del costo de bodega, ganancias proyectadas y cálculo nativo de métricas de rentabilidad comercial (ganancia neta, Markup y Margen Neto).

---

## 👑 Experiencia Boxi Pro (Suscripción Premium)

Optimiza tu operación con nuestras funciones exclusivas en la nube:

*   ☁️ **Sincronización Multi-dispositivo:** Respaldo automático en la nube de Firebase (Cloud Firestore) con gestión de cola de trabajo offline para acceder a tus datos desde cualquier lugar.

*   🎨 **Identidad Visual:** Incluye el logo de tu empresa en todos tus recibos y en tu catálogo web.

*   🚫 **Cero Interrupciones:** Una experiencia fluida, libre de anuncios y enfocada 100% en la productividad de tu negocio.

---

## ❓ ¿Para quién es Boxi?

Diseñada para la versatilidad, Boxi es el aliado ideal para tiendas de moda, tecnología, suministros, ventas por catálogo, emprendimientos digitales y comercios que buscan una transición digital eficiente y organizada.

---

## 🛠️ Tecnologías y Librerías Utilizadas

*   **Framework Principal:** [Flutter](https://flutter.dev/) (Lenguaje de programación Dart).
*   **Persistencia Local:** `sqflite` (SQLite) y `shared_preferences`.
*   **Servicios en la Nube:** Firebase Core, Firebase Auth, Cloud Firestore y Firebase Cloud Messaging (FCM).
*   **Analítica de Datos:** Google Analytics para Firebase (Segmentación de audiencias para retención).
*   **Generación de Documentos:** `pdf` y `printing` para exportación de catálogos.
*   **Interoperabilidad:** `share_plus` y `url_launcher` para integración con WhatsApp y APIs de compartición.

---

## 🔒 Configuración de Entorno y Seguridad

> ⚠️ **Aviso de Seguridad:** Por políticas de privacidad y protocolos de seguridad, las credenciales del entorno de producción y los archivos de firma de la aplicación (archivos `google-services.json`, `service_account.json` y el almacén de claves `upload-keystore.jks`) han sido excluidos de este repositorio público mediante el archivo `.gitignore` para prevenir fugas de información o comprometer la seguridad del ecosistema.

Para compilar o ejecutar el proyecto en un entorno local de desarrollo con sus propios servicios:

1.  Cree un proyecto en su consola de Firebase y active Firestore, Authentication y Cloud Messaging.
2.  Descargue el archivo `google-services.json` y ubíquelo en la ruta `android/app/`.
3.  Genere sus propias llaves de firmado e ingrese las variables de entorno en el archivo `key.properties`.
4.  Ejecute el comando `flutter pub get` para descargar los paquetes y compile la aplicación.
