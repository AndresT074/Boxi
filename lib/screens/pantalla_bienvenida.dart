import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:local_auth/local_auth.dart';
import '../database/db_helper.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'dart:ui';
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:path_provider/path_provider.dart';
import 'pantalla_principal.dart';
import 'pantalla_login.dart';
import 'pantalla_premium.dart';
import 'servicio_auth.dart';
import 'servicio_nube.dart';
import 'servicio_respaldo.dart';

// ============================================================
// SERVICIO DE CONTRASEÑA ADMIN (Firebase + SQLite offline)
// ============================================================
class ServicioContrasenaAdmin {
  static const _colUsuarios = 'usuarios';

  // Función interna para generar Hash
  static String _generarHash(String texto) {
    return sha256.convert(utf8.encode(texto)).toString();
  }

  // 1. Validar contraseña (Soporta migración de texto plano a Hash)
  static Future<bool> validarPassword(String passwordIngresada, String uid) async {
    final prefs = await SharedPreferences.getInstance();
    String? guardada = prefs.getString('admin_password');
    if (guardada == null) return false;

    // A. ¿Coincide con el Hash? (Formato nuevo)
    if (guardada == _generarHash(passwordIngresada)) {
      return true;
    }

    // B. ¿Coincide con el texto plano? (Formato antiguo - Migración)
    if (guardada == passwordIngresada) {
      await actualizarPassword(uid, passwordIngresada); // Esto guarda el nuevo hash
      return true;
    }

    return false;
  }

  // 2. Validar respuesta secreta (Soporta migración)
  static Future<bool> validarRespuesta(String respuestaIngresada) async {
    final prefs = await SharedPreferences.getInstance();
    String? guardada = prefs.getString('admin_respuesta');
    if (guardada == null) return false;

    String respuestaNormalizada = respuestaIngresada.toLowerCase().trim();
    
    if (guardada == _generarHash(respuestaNormalizada)) return true;
    if (guardada == respuestaNormalizada) {
      // Migración silenciosa
      await prefs.setString('admin_respuesta', _generarHash(respuestaNormalizada));
      return true;
    }
    return false;
  }

  // 3. Guardar contraseña (Ya con hash)
  static Future<void> guardar({
    required String uid,
    required String password,
    required String pregunta,
    required String respuesta,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    String hashPass = _generarHash(password);
    String hashResp = _generarHash(respuesta.toLowerCase().trim());

    await prefs.setString('admin_password', hashPass);
    await prefs.setString('admin_pregunta', pregunta);
    await prefs.setString('admin_respuesta', hashResp);
    await prefs.setBool('admin_biometria_activa', false);

    try {
      await FirebaseFirestore.instance.collection(_colUsuarios).doc(uid).set({
        'admin_password': hashPass,
        'admin_pregunta': pregunta,
        'admin_respuesta': hashResp,
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  static Future<void> eliminar(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('admin_password');
    await prefs.remove('admin_pregunta');
    await prefs.remove('admin_respuesta');

    try {
      await FirebaseFirestore.instance.collection(_colUsuarios).doc(uid).update({
        'admin_password': FieldValue.delete(),
        'admin_pregunta': FieldValue.delete(),
        'admin_respuesta': FieldValue.delete(),
      });
    } catch (_) {}
  }

  static Future<void> sincronizarDesdeNube(String uid) async {
    try {
      final doc = await FirebaseFirestore.instance.collection(_colUsuarios).doc(uid).get();
      final prefs = await SharedPreferences.getInstance();

      // Si el usuario no existe en Firebase, borramos rastro local
      if (!doc.exists) {
        await prefs.remove('admin_password');
        await prefs.remove('admin_pregunta');
        await prefs.remove('admin_respuesta');
        await prefs.remove('admin_biometria_activa');
        return;
      }
      
      final data = doc.data() as Map<String, dynamic>;

      // Si tiene pass en la nube la guardamos, si NO tiene, la borramos localmente
      if (data.containsKey('admin_password')) {
        await prefs.setString('admin_password', data['admin_password']);
      } else {
        await prefs.remove('admin_password');
      }

      if (data.containsKey('admin_pregunta')) {
        await prefs.setString('admin_pregunta', data['admin_pregunta']);
      } else {
        await prefs.remove('admin_pregunta');
      }

      if (data.containsKey('admin_respuesta')) {
        await prefs.setString('admin_respuesta', data['admin_respuesta']);
      } else {
        await prefs.remove('admin_respuesta');
      }
    } catch (_) {}
  }

  static Future<void> actualizarPassword(String uid, String nuevaPass) async {
    String hashPass = _generarHash(nuevaPass);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('admin_password', hashPass);
    try {
      await FirebaseFirestore.instance.collection(_colUsuarios).doc(uid).update({'admin_password': hashPass});
    } catch (_) {}
  }

  static Future<void> actualizarBiometria(bool activa) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('admin_biometria_activa', activa);
    // Ya no necesita el uid porque es local, como acordamos.
  }
}
// ============================================================
// PANTALLA BIENVENIDA
// ============================================================
class PantallaBienvenida extends StatefulWidget {
  const PantallaBienvenida({super.key});
  @override
  State<PantallaBienvenida> createState() => _PantallaBienvenidaState();
}

class _PantallaBienvenidaState extends State<PantallaBienvenida>
    with SingleTickerProviderStateMixin {
  final TextEditingController _nombreController = TextEditingController();
  String _nombreNegocio = "NOMBREDETUNEGOCIOAQUI";
  String _logoPath = "";
  ImageProvider? _imageCached;
  bool _mostrarModalNombre = false;
  bool _esPremium = false;
  late AnimationController _controller;
  bool _cargandoDatos = false;
  final LocalAuthentication _localAuth = LocalAuthentication();

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 5))
          ..repeat();
    _iniciarApp();
  }

  Future<void> _iniciarApp() async {
    await _cargarConfig();
    _registrarIngresoYVerificarActualizacion();
    _sincronizarAlEntrar();
    _verificarReembolsosEnSilencio();
  }

  @override
  void dispose() {
    _controller.dispose();
    _nombreController.dispose();
    super.dispose();
  }

  Future<void> _cargarConfig() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    // 🔥 SOLUCIÓN ESTABLE: Una sola carpeta pública. Si falla, usa la privada.
    final appDir = await getApplicationDocumentsDirectory();
    String rutaFinal = '${appDir.path}/Boxi';
    
    try {
      Directory pubDir = Directory('/storage/emulated/0/Pictures/Boxi');
      if (!await pubDir.exists()) await pubDir.create(recursive: true);
      
      // 🔥 PRUEBA DE ESCRITURA MEJORADA: En Android 11+ los archivos sin extensión 
      // de imagen son bloqueados en la carpeta Pictures. Usamos un .jpg para la prueba.
      File testFile = File('${pubDir.path}/test_access.jpg');
      await testFile.writeAsBytes([0]);
      await testFile.delete();
      rutaFinal = pubDir.path; 
    } catch (e) {
      debugPrint("Carpeta pública bloqueada, usando directorio seguro: $e");
      Directory intDir = Directory(rutaFinal);
      if (!await intDir.exists()) await intDir.create(recursive: true);
    }
    
    await prefs.setString('local_boxi_path', rutaFinal);

    String nuevoNombre = prefs.getString('nombre_negocio') ?? "NOMBREDETUNEGOCIOAQUI";
    String nuevaPath = prefs.getString('logo_path') ?? "";
    bool nuevoPremium = prefs.getBool('es_premium') ?? false;

    if (nuevaPath != _logoPath || _imageCached == null) {
      if (nuevaPath.isNotEmpty) {
        // 🔥 Buscamos la ruta segura y legible de forma no bloqueante y unificada
        String? rutaSegura = await ServicioNube.obtenerRutaLegibleSegura(nuevaPath);

        if (rutaSegura != null) {
          _imageCached = FileImage(File(rutaSegura));
        } else {
          if (nuevaPath.startsWith('http')) {
            _imageCached = NetworkImage(nuevaPath);
            // Si no existe localmente, mandamos a descargar de fondo
            ServicioNube.descargarFotoIndividualEnSegundoPlano(nuevaPath, rutaFinal);
          } else if (nuevaPath.length > 500) {
            try { _imageCached = MemoryImage(base64Decode(nuevaPath)); } catch (_) { _imageCached = null; }
          } else {
            _imageCached = null;
          }
        }
      } else {
        _imageCached = null;
      }
    }

    setState(() {
      _nombreNegocio = (nuevoNombre == "nombredenegocioaqui") ? "NOMBREDETUNEGOCIOAQUI" : nuevoNombre;
      _logoPath = nuevaPath;
      _esPremium = nuevoPremium;
    });
  }

  Future<void> _sincronizarAlEntrar() async {
    User? user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      if (mounted) setState(() => _cargandoDatos = true);
      await _cargarConfig();
      
      try {
        await _sincronizacionSilenciosa(user);
        await ServicioContrasenaAdmin.sincronizarDesdeNube(user.uid);
        await _registrarIngresoYVerificarActualizacion();
      } catch (e) {
        debugPrint("Error en inicio: $e");
      } finally {
        if (mounted) setState(() => _cargandoDatos = false); // 🔥 Asegura apagar el loader siempre
      }
    }
  }

  Future<void> _sincronizacionSilenciosa(User user) async {
    try {
      if (!await ServicioNube.tieneInternet()) {
        debugPrint("Sin conexión a internet. Saltando sincronización silenciosa.");
        return; 
      }

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      String hoy = DateTime.now().toIso8601String().substring(0, 10);
      String nombreActual =
          prefs.getString('nombre_negocio') ?? "NOMBREDETUNEGOCIOAQUI";
      bool necesitaPerfil = prefs.getString('ultima_val_nube') != hoy ||
          nombreActual == "NOMBREDETUNEGOCIOAQUI" ||
          nombreActual == "nombredenegocioaqui";
      if (necesitaPerfil) {
        await ServicioNube.descargarPerfilNube(user.uid);
        await ServicioAuth.actualizarEstadoPremiumNube(user.uid);
        await prefs.setString('ultima_val_nube', hoy);
        await _cargarConfig();
      }
      _esPremium = prefs.getBool('es_premium') ?? false;
      
      // Eliminar campos antiguos obsoletos
      await FirebaseFirestore.instance.collection('usuarios').doc(user.uid).update({
        'plan': FieldValue.delete(),
        'fecha_ultimo_ingreso': FieldValue.delete(),
        'ultima_modificacion': FieldValue.delete(),
      });

      if (_esPremium) {
        String llaveDescarga = "descarga_completa_${user.uid}";
        bool yaDescargoTodo = prefs.getBool(llaveDescarga) ?? false;
        if (!yaDescargoTodo) {
          
          // 1. Descargamos el catálogo web
          await ServicioNube.importarCatalogoDesdeRTDB(user.uid);

          // 2. Intentamos descargar datos privados desde RTDB
          await ServicioNube.descargarDatosPrivadosRTDB();

          // 3. Verificamos si realmente se descargó algo desde RTDB
          final dbLocal = await DBHelper.instance.database;
          final clientesLocales = await dbLocal.query('clientes', limit: 1);
          final pedidosLocales = await dbLocal.query('pedidos', limit: 1);

          if (clientesLocales.isEmpty && pedidosLocales.isEmpty) {
            // 4. Si RTDB estaba vacío, significa que es la primera migración.
            // Descargamos todo tu historial desde Firestore (solo ocurre 1 vez).
            debugPrint("☁️ Primer inicio: Migrando historial desde Firestore a Realtime...");
            await ServicioNube.descargarTodoDesdeNube();
            
            // 5. Lo subimos de inmediato a RTDB para que las próximas veces consuma 0 lecturas.
            await ServicioNube.respaldarDatosPrivadosRTDB();
          }
          
          await prefs.setBool('migracion_definitiva_completa_v6', false); 
          await ServicioNube.migrarVariantesAlJSONyCarpetas(); 
          
          await prefs.setBool(llaveDescarga, true);
          await prefs.setBool('primera_carga_completada_${user.uid}', true);
          final userDoc = await FirebaseFirestore.instance.collection('usuarios').doc(user.uid).get();
          if (userDoc.exists) {
            final data = userDoc.data() as Map<String, dynamic>;
            final modProd = (data['ultima_mod_productos'] as Timestamp?)?.toDate().toIso8601String();
            final modPed = (data['ultima_mod_pedidos'] as Timestamp?)?.toDate().toIso8601String();
            if (modProd != null) await prefs.setString('ultima_mod_productos_local_${user.uid}', modProd);
            if (modPed != null) await prefs.setString('ultima_mod_pedidos_local_${user.uid}', modPed);
          }
        } else {
          await ServicioNube.rescatarDatosPerdidosFirestore(user.uid);
        }
        
        await ServicioNube.migrarTodoACloudinary();
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint("Error en sincronización silenciosa: $e");
    }
  }
  
  Future<void> _verificarReembolsosEnSilencio() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final prefs = await SharedPreferences.getInstance();
    String hoy = DateTime.now().toIso8601String().substring(0, 10);
    String? ultimaVerificacion =
        prefs.getString('ultima_verificacion_reembolso');
    if (ultimaVerificacion == hoy) return;

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('usuarios')
          .doc(user.uid)
          .get();
      if (!userDoc.exists) return;

      final data = userDoc.data() as Map<String, dynamic>;
      bool esPremiumNube = data['es_premium'] ?? false;
      String? orderId = data['order_id'];

      if (!esPremiumNube || orderId == null || !orderId.startsWith("GPA"))
        return;

      final InAppPurchase iap = InAppPurchase.instance;
      final bool disponible = await iap.isAvailable();
      if (!disponible) return;
      bool tieneReciboActivo = false;
      StreamSubscription<List<PurchaseDetails>>? sub;

      final completer = Completer<bool?>();

      sub = iap.purchaseStream.listen((compras) async {
        for (var p in compras) {
          if (p.productID == 'boxi_premium_pro' &&
              (p.status == PurchaseStatus.purchased ||
                  p.status == PurchaseStatus.restored)) {
            tieneReciboActivo = true;
          }
        }
        if (!completer.isCompleted) completer.complete(tieneReciboActivo);
        sub?.cancel();
      });

      await iap.restorePurchases();
      final bool? resultado = await completer.future
          .then<bool?>((v) => v)
          .timeout(const Duration(seconds: 15), onTimeout: () => null);

      sub.cancel();
      if (resultado == null) return;

      if (resultado == false) {
        final batch = FirebaseFirestore.instance.batch();
        batch.update(
            FirebaseFirestore.instance
                .collection('usuarios')
                .doc(user.uid),
            {
              'es_premium': false,
              'order_id': FieldValue.delete(),
              'motivo_degradacion': 'reembolso_confirmado_google'
            });
        batch.update(
            FirebaseFirestore.instance
                .collection('compras_realizadas')
                .doc(orderId),
            {
              'estado': 'reembolsada',
              'fecha_reembolso': DateTime.now().toIso8601String(),
            });
        await batch.commit();

        final prefs2 = await SharedPreferences.getInstance();
        await prefs2.setBool('es_premium', false);
        if (mounted) setState(() => _esPremium = false);
      }

      await prefs.setString('ultima_verificacion_reembolso', hoy);
    } catch (e) {
      debugPrint("Error verificando integridad: $e");
    }
  }

  Future<void> _registrarIngresoYVerificarActualizacion() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (!await ServicioNube.tieneInternet()) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      String hoy = DateTime.now().toIso8601String().substring(0, 10);
      String? ultimoRegistro = prefs.getString('ultimo_registro_firestore');
      String? versionGuardada = prefs.getString('version_app_registrada');
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      String versionActual = '${packageInfo.version}+${packageInfo.buildNumber}';
      bool nombreYaSincronizado = prefs.getBool('nombre_sincronizado_nube_${user.uid}') ?? false;
      bool necesitaActualizarDia = (ultimoRegistro != hoy);
      bool necesitaActualizarVersion = (versionGuardada != versionActual);
      
      if (necesitaActualizarDia || necesitaActualizarVersion || !nombreYaSincronizado) {
        Map<String, dynamic> datosAEnviar = {};
        
        if (necesitaActualizarDia) {
          datosAEnviar['ultima_actividad'] = FieldValue.serverTimestamp();
        }
        if (necesitaActualizarVersion) {
          datosAEnviar['version_app'] = versionActual;
        }
        if (!nombreYaSincronizado) {
          String nombreLocal = prefs.getString('nombre_negocio') ?? "MI NEGOCIO";
          String logoLocal = prefs.getString('logo_path') ?? "";
          
          datosAEnviar['nombre_negocio'] = nombreLocal;
          datosAEnviar['logo_path'] = logoLocal.startsWith('http') ? logoLocal : "";
        }
        
        await FirebaseFirestore.instance
            .collection('usuarios')
            .doc(user.uid)
            .set(datosAEnviar, SetOptions(merge: true))
            .timeout(const Duration(seconds: 5));
            
        if (necesitaActualizarDia) {
          await prefs.setString('ultimo_registro_firestore', hoy);
        }
        if (necesitaActualizarVersion) {
          await prefs.setString('version_app_registrada', versionActual);
        }
        
        // 🔥 Marcamos que el nombre ya quedó respaldado en la nube
        await prefs.setBool('nombre_sincronizado_nube_${user.uid}', true);
      }

      AppUpdateInfo info = await InAppUpdate.checkForUpdate();
      if (info.updateAvailability == UpdateAvailability.updateAvailable) { 
        await InAppUpdate.performImmediateUpdate();
      }
    } catch (e) {
      debugPrint("Error en registro o actualización: $e");
    }
  }

  Future<void> _seleccionarLogo() async {
    if (!_esPremium) {
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => const PantallaPremium()));
      return;
    }

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,        // permite altura libre en landscape
      builder: (ctx) {
        final bottom = MediaQuery.of(ctx).viewInsets.bottom;
        final safePad = MediaQuery.of(ctx).padding.bottom;
        return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(bottom: bottom),
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              padding: EdgeInsets.fromLTRB(20, 20, 20, 16 + safePad),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1B2A),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withOpacity(0.15)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 16),
                  const Text("LOGO DEL NEGOCIO",
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          letterSpacing: 1)),
                  const SizedBox(height: 16),
                  InkWell(
                    onTap: () async {
                      Navigator.pop(context);
                      await _cargarImagenLogo();
                    },
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.cyanAccent.withOpacity(0.07),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: Colors.cyanAccent.withOpacity(0.25)),
                      ),
                      child: const Row(children: [
                        Icon(Icons.photo_library_rounded,
                            color: Colors.cyanAccent, size: 22),
                        SizedBox(width: 14),
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text("CARGAR IMAGEN",
                                  style: TextStyle(
                                      color: Colors.cyanAccent,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12)),
                              Text("Selecciona desde la galería",
                                  style: TextStyle(
                                      color: Colors.white38, fontSize: 10)),
                            ])),
                        Icon(Icons.chevron_right,
                            color: Colors.cyanAccent, size: 18),
                      ]),
                    ),
                  ),
                  if (_imageCached != null) ...[
                    const SizedBox(height: 10),
                    InkWell(
                      onTap: () async {
                        Navigator.pop(context);
                        await _eliminarLogo();
                      },
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withOpacity(0.07),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                              color: Colors.redAccent.withOpacity(0.25)),
                        ),
                        child: const Row(children: [
                          Icon(Icons.delete_outline_rounded,
                              color: Colors.redAccent, size: 22),
                          SizedBox(width: 14),
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text("ELIMINAR LOGO",
                                    style: TextStyle(
                                        color: Colors.redAccent,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12)),
                                Text("Volver al ícono predeterminado",
                                    style: TextStyle(
                                        color: Colors.white38, fontSize: 10)),
                              ])),
                          Icon(Icons.chevron_right,
                              color: Colors.redAccent, size: 18),
                        ]),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _cargarImagenLogo() async {
    await Permission.photos.request();

    final XFile? image = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      imageQuality: 90,
    );
    if (image == null) return;
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(children: [
            SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white)),
            SizedBox(width: 12),
            Text("Procesando e instalando logo..."),
          ]),
          duration: Duration(seconds: 5),
          backgroundColor: Color(0xFF0D1B2A),
        ),
      );
    }

    try {
      String logoDest = image.path;

      // 🔥 SI ES PREMIUM, SE SUBE A CLOUDINARY PARA QUE SEA LIVIANO Y SE VEA EN LA WEB
      if (_esPremium) {
        logoDest = await ServicioNube.subirImagenACloudinary(image.path);
        if (logoDest.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Error al subir el logo a la nube"), backgroundColor: Colors.red));
          }
          return;
        }
      } else {
        // Si es gratuito, lo copiamos a la carpeta persistente local
        try {
          final appDir = await getApplicationDocumentsDirectory();
          final File tempFile = File(image.path);
          final String fileName = "logo_${DateTime.now().millisecondsSinceEpoch}.png";
          final File nuevaImagen = await tempFile.copy('${appDir.path}/$fileName');
          logoDest = nuevaImagen.path;
        } catch (e) {
          logoDest = image.path;
        }
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('logo_path', logoDest);

      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        setState(() {
          _logoPath = logoDest;
          _imageCached = logoDest.startsWith('http')
              ? NetworkImage(logoDest)
              : FileImage(File(logoDest)) as ImageProvider;
        });
      }

      if (FirebaseAuth.instance.currentUser != null) {
        await ServicioNube.actualizarPerfilNegocioNube(_nombreNegocio, logoDest);
      }

      // 🔥 RECOMPILAMOS EL CATÁLOGO WEB AUTOMÁTICAMENTE SI ES PREMIUM
      if (_esPremium) {
        await ServicioNube.compilarYSubirCatalogoRTDB();
      }

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error al procesar el logo: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _eliminarLogo() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('logo_path');
    setState(() {
      _logoPath = "";
      _imageCached = null;
    });
    if (FirebaseAuth.instance.currentUser != null) {
      ServicioNube.actualizarPerfilNegocioNube(_nombreNegocio, "");
    }
  }

  void _clickCloud() async {
    User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      Navigator.push(context,
              MaterialPageRoute(builder: (_) => const PantallaLogin()))
          .then((_) => _sincronizarAlEntrar());
    } else {
      if (!_esPremium) {
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const PantallaPremium()));
      } else {
        _sincronizarAlEntrar();
      }
    }
  }

  void _gestionarCierreSesion() {
    if (_esPremium) {
      _confirmarSalidaFinal();
    } else {
      _mostrarAdvertenciaOffline();
    }
  }

  void _mostrarAdvertenciaOffline() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF041E42),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Colors.orangeAccent, width: 2)),
        title: const Row(children: [
          Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
          SizedBox(width: 10),
          Text("¡DATOS EN PELIGRO!",
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold))
        ]),
        content: const Text(
            "Tus datos NO están en la nube. Si cierras sesión ahora, perderás tu inventario permanentemente.",
            style: TextStyle(color: Colors.white70, fontSize: 13)),
        actions: [
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.teal,
                minimumSize: const Size(double.infinity, 45)),
            onPressed: () {
              Navigator.pop(ctx);
              ServicioRespaldo.exportarBaseDeDatos(context);
            },
            icon: const Icon(Icons.download, color: Colors.white, size: 18),
            label: const Text("EXPORTAR RESPALDO LOCAL",
                style: TextStyle(color: Colors.white, fontSize: 12)),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amberAccent,
                minimumSize: const Size(double.infinity, 45)),
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const PantallaPremium()));
            },
            icon: const Icon(Icons.stars, color: Colors.black, size: 18),
            label: const Text("SUBIR A PRO (NUBE) 👑",
                style: TextStyle(
                    color: Colors.black,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 5),
          TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _confirmarSalidaFinal();
              },
              child: const Text("CERRAR SESIÓN Y BORRAR TODO",
                  style: TextStyle(color: Colors.redAccent, fontSize: 10))),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("CANCELAR",
                  style: TextStyle(color: Colors.white38, fontSize: 11))),
        ],
      ),
    );
  }

  void _confirmarSalidaFinal() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text("¿Cerrar Sesión?",
            style: TextStyle(color: Colors.white)),
        content: Text(
            _esPremium
                ? "Tu sesión se cerrará, pero tus datos quedarán guardados en este celular para un acceso rápido."
                : "Al cerrar sesión, tus datos locales se borrarán por seguridad.",
            style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("CANCELAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              // 🔥 1. CAPTURAR EL UID ANTES DE QUE PASE A NULL
              final user = FirebaseAuth.instance.currentUser;
              final String? uid = user?.uid; 

              // 🔥 2. LIBERAR MEMORIA RAM Y BLOQUEOS DE ARCHIVOS
              PaintingBinding.instance.imageCache.clear();
              PaintingBinding.instance.imageCache.clearLiveImages();

              // 🔥 3. CERRAR SESIÓN EN FIREBASE
              await ServicioAuth.cerrarSesion();

              // 🔥 4. ESPERA DE SEGURIDAD (500ms)
              await Future.delayed(const Duration(milliseconds: 500));

              final prefs = await SharedPreferences.getInstance();

              // 🔥 5. BORRAR BANDERAS DE USUARIO CON LA VARIABLE "uid" CAPTURADA AL INICIO
              if (uid != null) {
                await prefs.remove("descarga_completa_$uid");
                await prefs.remove("primera_carga_completada_$uid");
                await prefs.remove('ultima_mod_productos_local_$uid');
                await prefs.remove('ultima_mod_pedidos_local_$uid');
                await prefs.remove('ultima_mod_categorias_local_$uid');
              }
              
              await prefs.remove('admin_password');
              await prefs.remove('admin_pregunta');
              await prefs.remove('admin_respuesta');
              await prefs.remove('admin_biometria_activa');
              await prefs.remove('migracion_definitiva_completa_v6');
              await prefs.remove('datos_descargados');

              // 🔥 6. LIMPIEZA DE TABLAS LOCALES
              try {
                await DBHelper.instance.limpiarTablas();
              } catch (e) {
                debugPrint("Error limpiando BD local: $e");
              }

              // 🔥 7. DESTRUCCIÓN ABSOLUTA DE LAS CARPETAS
              try {
                String pathBoxi = prefs.getString('local_boxi_path') ?? "/storage/emulated/0/Pictures/Boxi";
                
                Future<void> aniquilarCarpeta(Directory dir) async {
                  if (!await dir.exists()) return;
                  try {
                    final List<FileSystemEntity> entidades = dir.listSync(recursive: true);
                    for (FileSystemEntity entity in entidades) {
                      if (entity is File) {
                        try {
                          await entity.delete();
                        } catch (_) {}
                      }
                    }
                    try { await dir.delete(recursive: true); } catch (_) {}
                  } catch (_) {}
                }

                await aniquilarCarpeta(Directory(pathBoxi));
                await aniquilarCarpeta(Directory('/storage/emulated/0/Pictures/Boxi'));
                
                final appDir = await getApplicationDocumentsDirectory();
                await aniquilarCarpeta(Directory('${appDir.path}/Boxi'));
                
                debugPrint("🗑️ Carpetas Boxi vaciadas y eliminadas en cero absoluto.");
              } catch (e) {
                debugPrint("Error eliminando carpetas: $e");
              }

              Navigator.pop(ctx);
              
              if (mounted) {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const PantallaBienvenida()),
                  (route) => false,
                );
              }
            },
            child: const Text("SÍ, SALIR",
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _abrirModalEditar() {
    setState(() {
      _nombreController.text = _nombreNegocio;
      _mostrarModalNombre = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final double h = MediaQuery.of(context).size.height;
    User? user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => CustomPaint(
              painter: FondoMovimientoPainter(_controller.value),
              child: Container(),
            ),
          ),
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Container(color: Colors.black.withOpacity(0.4)),
          ),
          SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 30),
                child: SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildLogo(h * 0.14),
                      SizedBox(height: h * 0.015),
                      _buildTituloNegocio(),
                      const Text("SISTEMA DE GESTIÓN PROFESIONAL",
                          style: TextStyle(
                              color: Colors.white38,
                              fontSize: 9,
                              letterSpacing: 3)),
                      if (user != null) ...[
                        const SizedBox(height: 5),
                        Text(user.email ?? "",
                            style: const TextStyle(
                                color: Colors.cyanAccent,
                                fontSize: 10,
                                fontWeight: FontWeight.w300)),
                      ],
                      SizedBox(height: h * 0.025),
                      _botonCloud(user != null),
                      SizedBox(height: h * 0.04),
                      if (_cargandoDatos)
                        Column(
                          children: [
                            const CircularProgressIndicator(
                                color: Colors.cyanAccent),
                            const SizedBox(height: 15),
                            const Text("Cargando tu negocio...",
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 12)),
                            SizedBox(height: h * 0.04),
                          ],
                        )
                      else ...[
                        _buildAccionCard("MODO VENTAS", Colors.orangeAccent,
                            Icons.shopping_cart, () => _acceder(false)),
                        SizedBox(height: h * 0.01),
                        _buildAccionCard(
                            "ADMINISTRACIÓN",
                            Colors.cyanAccent,
                            Icons.admin_panel_settings,
                            () => _acceder(true),
                            esAdmin: true),
                      ],
                      SizedBox(height: h * 0.03),
                      if (user != null)
                        TextButton.icon(
                          onPressed: _gestionarCierreSesion,
                          icon: const Icon(Icons.power_settings_new,
                              color: Colors.white24, size: 16),
                          label: const Text("CERRAR SESIÓN",
                              style: TextStyle(
                                  color: Colors.white24,
                                  fontSize: 10,
                                  letterSpacing: 1)),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_mostrarModalNombre) _buildModalNombre(),
        ],
      ),
    );
  }

  Widget _buildLogo(double size) {
    return GestureDetector(
      onTap: _seleccionarLogo,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Container(
            width: size + 10,
            height: size + 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: SweepGradient(
                startAngle: 0,
                endAngle: 2 * pi,
                transform: GradientRotation(_controller.value * 2 * pi),
                colors: const [
                  Color(0xFF00E5FF),
                  Color(0xFFFF9800),
                  Color(0xFFE91E63),
                  Color(0xFF00E5FF),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.cyanAccent.withOpacity(
                      0.35 + 0.15 * sin(_controller.value * 2 * pi)),
                  blurRadius: 25,
                  spreadRadius: 3,
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black,
                ),
                child: CircleAvatar(
                  radius: size / 2,
                  backgroundColor: Colors.white.withOpacity(0.05),
                  backgroundImage: _imageCached,
                  child: _imageCached == null
                      ? Icon(Icons.storefront_rounded,
                          color: Colors.white70, size: size * 0.4)
                      : null,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTituloNegocio() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(width: 40),
        Flexible(
          child: Text(_nombreNegocio.toUpperCase(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1)),
        ),
        IconButton(
          onPressed: _abrirModalEditar,
          icon: const Icon(Icons.edit, color: Colors.white24, size: 18),
        )
      ],
    );
  }

  Widget _buildAccionCard(String t, Color c, IconData i, VoidCallback onTap,
      {bool esAdmin = false}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Row(
          children: [
            Icon(i, color: c, size: 22),
            const SizedBox(width: 15),
            Expanded(
              child: Text(t,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13)),
            ),
            if (esAdmin)
              GestureDetector(
                onTap: () => _abrirPanelSeguridad(),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.08),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Icon(Icons.settings,
                      color: Colors.white54, size: 16),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _botonCloud(bool conectado) {
    Color colorBoton = conectado
        ? (_esPremium ? Colors.greenAccent : Colors.orangeAccent)
        : Colors.white38;
    String textoBoton = conectado
        ? (_esPremium ? "NUBE SINCRONIZADA" : "PASA A PREMIUM")
        : "CONECTAR NUBE";

    return InkWell(
      onTap: _clickCloud,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          color: colorBoton.withOpacity(0.1),
          border: Border.all(color: colorBoton.withOpacity(0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
                conectado
                    ? (_esPremium ? Icons.cloud_done : Icons.cloud_off)
                    : Icons.cloud_queue,
                color: colorBoton,
                size: 14),
            const SizedBox(width: 10),
            Text(textoBoton,
                style: TextStyle(
                    color: colorBoton,
                    fontSize: 10,
                    fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  void _acceder(bool admin) {
    if (FirebaseAuth.instance.currentUser == null) {
      Navigator.push(context,
              MaterialPageRoute(builder: (_) => const PantallaLogin()))
          .then((_) => _sincronizarAlEntrar());
      return;
    }

    if (admin) {
      _verificarAccesoAdmin();
    } else {
      Navigator.pushReplacement(context,
          MaterialPageRoute(builder: (_) => PantallaPrincipal(esAdmin: false)));
    }
  }

 Future<void> _verificarAccesoAdmin() async {
    final prefs = await SharedPreferences.getInstance();
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) return;
    String? password = prefs.getString('admin_password');
    if (password == null) {
      if (mounted) {
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (_) => const PantallaPrincipal(esAdmin: true)));
      }
      return;
    }

    bool biometriaActiva = prefs.getBool('admin_biometria_activa') ?? false;

    // INTENTO DE BIOMETRÍA / PIN
    if (biometriaActiva) {
      try {
        // Quitamos el if (availableBiometrics.isNotEmpty) 
        // porque en muchos dispositivos esto falla aunque tengan PIN.
        bool autenticado = await _localAuth.authenticate(
          localizedReason: 'Acceso a Administración',
          options: const AuthenticationOptions(
            biometricOnly: false, // CLAVE: False permite PIN, Patrón o Contraseña
            stickyAuth: true,
            useErrorDialogs: true,
          ),
        );
        
        if (autenticado && mounted) {
          Navigator.pushReplacement(context,
              MaterialPageRoute(builder: (_) => const PantallaPrincipal(esAdmin: true)));
          return;
        }
      } catch (e) {
        debugPrint("Error de biometría: $e");
        // Si hay error, simplemente ignoramos y seguimos al diálogo manual
      }
    }
    _abrirDialogoPasswordManual(user);
  }

  // Extraemos el diálogo a una función independiente para mayor claridad
  void _abrirDialogoPasswordManual(User user) {
    if (!mounted) return;
    final passCtrl = TextEditingController();
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        scrollable: true, 
        backgroundColor: const Color(0xFF0D1B2A),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Colors.cyanAccent, width: 1)),
        title: const Text("🔑 ACCESO ADMINISTRADOR",
            style: TextStyle(color: Colors.white, fontSize: 14)),
        content: _campoSeguro(passCtrl, "Contraseña", Icons.lock),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("CANCELAR", style: TextStyle(color: Colors.white38))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent),
            onPressed: () async {
              if (await ServicioContrasenaAdmin.validarPassword(passCtrl.text.trim(), user.uid)) {
                Navigator.pop(ctx);
                
                // 🔥 NUEVO: Lógica de recomendación de seguridad
                final prefs = await SharedPreferences.getInstance();
                bool biometriaActiva = prefs.getBool('admin_biometria_activa') ?? false;
                bool noRecordar = prefs.getBool('no_preguntar_biometria') ?? false;

                if (!biometriaActiva && !noRecordar) {
                  _mostrarSugerenciaBiometriaDesdeIngreso();
                } else {
                  _navegarAPrincipal();
                }
              } else {
                _mostrarMensajeAlerta(
                  ctx, 
                  "ERROR", 
                  "La contraseña ingresada es incorrecta.", 
                  esError: true
                );
              }
            },
            child: const Text("ENTRAR",
                style: TextStyle(
                    color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _mostrarSugerenciaBiometriaDesdeIngreso() async {
    bool puedeHuella = false;
    try { puedeHuella = await _localAuth.canCheckBiometrics; } catch (_) {}
    if (!puedeHuella) {
      _navegarAPrincipal();
      return;
    }

    bool noRecordarCheckbox = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSt) => AlertDialog(
          backgroundColor: const Color(0xFF0D1B2A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Colors.greenAccent, width: 1)),
          title: const Row(children: [
            Icon(Icons.fingerprint, color: Colors.greenAccent),
            SizedBox(width: 10),
            Text("¿Activar Huella o PIN?", style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Puedes entrar de forma segura y más rápida la próxima vez usando tu huella dactilar o el PIN de tu dispositivo.",
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 15),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text("No volver a recordarme", style: TextStyle(color: Colors.white54, fontSize: 11)),
                value: noRecordarCheckbox,
                activeColor: Colors.greenAccent,
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: (val) {
                  setSt(() => noRecordarCheckbox = val ?? false);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final prefs = await SharedPreferences.getInstance();
                if (noRecordarCheckbox) {
                  await prefs.setBool('no_preguntar_biometria', true);
                }
                Navigator.pop(ctx);
                _navegarAPrincipal();
              },
              child: const Text("AHORA NO", style: TextStyle(color: Colors.white38)),
            ),
            ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.greenAccent),
                        onPressed: () async {
                          final prefs = await SharedPreferences.getInstance();
                          
                          try {
                            // 🔥 NUEVO: Forzamos la autenticación biométrica real para verificarla antes de dar acceso
                            bool autenticado = await _localAuth.authenticate(
                              localizedReason: 'Confirmar activación de seguridad',
                              options: const AuthenticationOptions(
                                biometricOnly: false,
                                stickyAuth: true,
                                useErrorDialogs: true,
                              ),
                            );

                            if (autenticado) {
                              await ServicioContrasenaAdmin.actualizarBiometria(true);
                              if (noRecordarCheckbox) {
                                await prefs.setBool('no_preguntar_biometria', true);
                              }
                              Navigator.pop(ctx); // Cierra diálogo de recomendación
                              
                              // Muestra diálogo de éxito centrado
                              _mostrarMensajeAlerta(
                                context, 
                                "¡ÉXITO!", 
                                "La seguridad biométrica ha sido registrada y activada con éxito."
                              );
                              
                              // Navegamos tras un pequeño delay
                              Future.delayed(const Duration(seconds: 2), () {
                                _navegarAPrincipal();
                              });
                            } else {
                              _mostrarMensajeAlerta(
                                ctx, 
                                "AUTENTICACIÓN REQUERIDA", 
                                "Debes colocar tu huella dactilar o PIN para activar la biometría.",
                                esError: true
                              );
                            }
                          } catch (e) {
                            debugPrint("Error activando biometría: $e");
                            _mostrarMensajeAlerta(
                              ctx, 
                              "ERROR", 
                              "Tu dispositivo no admite o no tiene configurada la huella/PIN.",
                              esError: true
                            );
                          }
                        },
                        child: const Text("ACTIVAR", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                      ),
          ],
        ),
      ),
    );
  }

  void _mostrarMensajeAlerta(BuildContext context, String titulo, String mensaje, {bool esError = false}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1B2A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: esError ? Colors.redAccent : Colors.greenAccent, width: 1),
        ),
        title: Row(
          children: [
            Icon(
              esError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
              color: esError ? Colors.redAccent : Colors.greenAccent,
              size: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                titulo,
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Text(
          mensaje,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: esError ? Colors.redAccent : Colors.greenAccent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              "ACEPTAR",
              style: TextStyle(color: esError ? Colors.white : Colors.black, fontWeight: FontWeight.bold, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  void _navegarAPrincipal() {
    if (mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const PantallaPrincipal(esAdmin: true)));
    }
  }

  Widget _buildModalNombre() {
    return Scaffold(
      backgroundColor: Colors.black54,
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom),
            child: Container(
              margin: const EdgeInsets.all(35),
              padding: const EdgeInsets.all(25),
              decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(25),
                  border: Border.all(color: Colors.white12)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text("NOMBRE DEL NEGOCIO",
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _nombreController,
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center,
                    autofocus: true,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.05),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(15),
                          borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orangeAccent,
                        minimumSize: const Size(double.infinity, 50)),
                    onPressed: () async {
                      String n = _nombreController.text.trim();
                      if (n.isEmpty) n = "NOMBREDETUNEGOCIOAQUI";
                      final p = await SharedPreferences.getInstance();
                      await p.setString('nombre_negocio', n);
                      setState(() {
                        _nombreNegocio = n;
                        _mostrarModalNombre = false;
                      });
                      if (FirebaseAuth.instance.currentUser != null) {
                        await ServicioNube.actualizarPerfilNegocioNube(
                            n, _logoPath);
                      }
                    },
                    child: const Text("GUARDAR",
                        style: TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold)),
                  ),
                  TextButton(
                    onPressed: () =>
                        setState(() => _mostrarModalNombre = false),
                    child: const Text("CANCELAR",
                        style: TextStyle(color: Colors.white24)),
                  )
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
  // ============================================================
  // SISTEMA DE SEGURIDAD ADMINISTRACIÓN
  // ============================================================
  Future<void> _abrirPanelSeguridad() async {
    final prefs = await SharedPreferences.getInstance();
    bool tieneContrasena = (prefs.getString('admin_password') != null);
    bool biometriaActiva = prefs.getBool('admin_biometria_activa') ?? false;

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _PanelSeguridadSheet(
        tieneContrasena: tieneContrasena,
        biometriaActiva: biometriaActiva,
        onCrear: _flujoCrearContrasena,
        onCambiar: _flujoCambiarContrasena,
        onOlvide: _flujoOlvideContrasena,
        onDesactivar: _flujoDesactivarContrasena,
        onToggleBiometria: (valor) async {
          await ServicioContrasenaAdmin.actualizarBiometria(valor);
        },
      ),
    );
  }

  Future<void> _mostrarSugerenciaBiometria() async {
    bool puedeHuella = false;
    try {
      puedeHuella = await _localAuth.canCheckBiometrics;
    } catch (_) {}

    if (!puedeHuella || !mounted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("✅ Contraseña creada correctamente"),
            backgroundColor: Colors.green));
      }
      return;
    }

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, 
        backgroundColor: const Color(0xFF0D1B2A),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side:
                const BorderSide(color: Colors.greenAccent, width: 1)),
        title: const Row(children: [
          Icon(Icons.fingerprint, color: Colors.greenAccent),
          SizedBox(width: 8),
          Flexible(
              child: Text("¿Activar Huella / PIN?",
                  style: TextStyle(color: Colors.white, fontSize: 14))),
        ]),
        content: const Text(
            "Puedes entrar a Administración usando tu huella dactilar o PIN del dispositivo. ¿Deseas activarlo?",
            style: TextStyle(color: Colors.white70, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("AHORA NO",
                  style: TextStyle(color: Colors.white38))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent),
            onPressed: () async {
              Navigator.pop(ctx);
              
              // 🔥 SOLUCIÓN: Llama a la función simplificada solo con el valor 'true'
              // Ya no necesitamos el 'user.uid' ni el 'else' porque es local.
              await ServicioContrasenaAdmin.actualizarBiometria(true);

              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text("✅ Contraseña y biometría activadas"),
                    backgroundColor: Colors.green));
              }
            },
            child: const Text("ACTIVAR",
                style: TextStyle(
                    color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _flujoCrearContrasena() async {
    if (!mounted) return;
    Navigator.pop(context);
    final passCtrl = TextEditingController();
    final pass2Ctrl = TextEditingController();
    final pregCtrl = TextEditingController();
    final respCtrl = TextEditingController();
    final passErrorNotifier = ValueNotifier<String?>(null);

    await showDialog(
      context: context,
      builder: (ctx) {
        // Detectamos la orientación
        bool isLandscape = MediaQuery.of(ctx).orientation == Orientation.landscape;

        return Dialog(
          backgroundColor: const Color(0xFF0D1B2A),
          insetPadding: EdgeInsets.symmetric(horizontal: 10, vertical: isLandscape ? 5 : 20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Colors.cyanAccent, width: 0.5)),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("🔐 CREAR CONTRASEÑA", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: isLandscape ? 12 : 14)),
                const SizedBox(height: 15),
                
                // --- SECCIÓN DE CONTRASEÑAS ---
                if (isLandscape) 
                  Row(children: [
                    Expanded(child: _campoSeguro(passCtrl, "Contraseña", Icons.lock)),
                    const SizedBox(width: 10),
                    Expanded(child: _campoSeguro(pass2Ctrl, "Confirmar", Icons.lock_outline)),
                  ])
                else ...[
                  _campoSeguro(passCtrl, "Nueva contraseña", Icons.lock),
                  const SizedBox(height: 10),
                  _campoSeguro(pass2Ctrl, "Confirmar contraseña", Icons.lock_outline),
                ],

                ValueListenableBuilder<String?>(
                  valueListenable: passErrorNotifier,
                  builder: (_, err, __) => err != null ? Text(err, style: const TextStyle(color: Colors.redAccent, fontSize: 10)) : const SizedBox.shrink(),
                ),
                
                const SizedBox(height: 10),
                const Divider(color: Colors.white10),
                const SizedBox(height: 10),

                // --- SECCIÓN DE PREGUNTA Y RESPUESTA ---
                if (isLandscape)
                  Row(children: [
                    Expanded(child: _campoTexto(pregCtrl, "Pregunta En caso de olvidar respuesta", Icons.help_outline)),
                    const SizedBox(width: 10),
                    Expanded(child: _campoTexto(respCtrl, "Respuesta secreta", Icons.vpn_key)),
                  ])
                else ...[
                  _campoTexto(pregCtrl, "Pregunta (ej: ¿Nombre de mi mascota?)", Icons.help_outline),
                  const SizedBox(height: 10),
                  _campoTexto(respCtrl, "Respuesta secreta", Icons.vpn_key),
                ],

                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR", style: TextStyle(color: Colors.white38))),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent, padding: const EdgeInsets.symmetric(horizontal: 30)),
                      onPressed: () async {
                        if (passCtrl.text != pass2Ctrl.text) { passErrorNotifier.value = "No coinciden"; return; }
                        final user = FirebaseAuth.instance.currentUser;
                        if (user != null) {
                          await ServicioContrasenaAdmin.guardar(uid: user.uid, password: passCtrl.text.trim(), pregunta: pregCtrl.text.trim(), respuesta: respCtrl.text.trim());
                        }
                        Navigator.pop(ctx);
                        if (mounted) await _mostrarSugerenciaBiometria();
                      },
                      child: const Text("GUARDAR", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                    ),
                  ],
                )
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _flujoCambiarContrasena() async {
    if (!mounted) return;
    Navigator.pop(context);
    final actualCtrl = TextEditingController();
    final nuevaCtrl = TextEditingController();
    final nueva2Ctrl = TextEditingController();
    final errorNotifier = ValueNotifier<String?>(null);

    await showDialog(
      context: context,
      builder: (ctx) {
        bool isLandscape = MediaQuery.of(ctx).orientation == Orientation.landscape;

        return Dialog(
          backgroundColor: const Color(0xFF0D1B2A),
          insetPadding: EdgeInsets.symmetric(horizontal: 10, vertical: isLandscape ? 5 : 20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Colors.purpleAccent, width: 0.5)),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("🔑 CAMBIAR CONTRASEÑA", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: isLandscape ? 12 : 14)),
                const SizedBox(height: 15),
                
                _campoSeguro(actualCtrl, "Contraseña actual", Icons.lock),
                const SizedBox(height: 10),
                const Divider(color: Colors.white10),
                const SizedBox(height: 10),

                if (isLandscape)
                  Row(children: [
                    Expanded(child: _campoSeguro(nuevaCtrl, "Nueva contraseña", Icons.lock_outline)),
                    const SizedBox(width: 10),
                    Expanded(child: _campoSeguro(nueva2Ctrl, "Confirmar nueva", Icons.lock_outline)),
                  ])
                else ...[
                  _campoSeguro(nuevaCtrl, "Nueva contraseña", Icons.lock_outline),
                  const SizedBox(height: 10),
                  _campoSeguro(nueva2Ctrl, "Confirmar nueva contraseña", Icons.lock_outline),
                ],

                ValueListenableBuilder<String?>(
                  valueListenable: errorNotifier,
                  builder: (_, err, __) => err != null ? Padding(padding: const EdgeInsets.only(top: 8), child: Text(err, style: const TextStyle(color: Colors.redAccent, fontSize: 10))) : const SizedBox.shrink(),
                ),

                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR", style: TextStyle(color: Colors.white38))),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.purpleAccent),
                      onPressed: () async {
                        final prefs = await SharedPreferences.getInstance();
                        if (actualCtrl.text.trim() != prefs.getString('admin_password')) { errorNotifier.value = "❌ Contraseña actual incorrecta"; return; }
                        if (nuevaCtrl.text.isEmpty) { errorNotifier.value = "Ingresa una nueva contraseña"; return; }
                        if (nuevaCtrl.text != nueva2Ctrl.text) { errorNotifier.value = "Las contraseñas no coinciden"; return; }
                        
                        final user = FirebaseAuth.instance.currentUser;
                        if (user != null) await ServicioContrasenaAdmin.actualizarPassword(user.uid, nuevaCtrl.text.trim());
                        Navigator.pop(ctx);
                      },
                      child: const Text("CAMBIAR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ],
                )
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _flujoOlvideContrasena() async {
    if (!mounted) return;
    Navigator.pop(context);
    final prefs = await SharedPreferences.getInstance();
    String? pregunta = prefs.getString('admin_pregunta');
    final respCtrl = TextEditingController();
    final nuevaCtrl = TextEditingController();
    final nueva2Ctrl = TextEditingController();
    final respErrorNotifier = ValueNotifier<String?>(null);
    final passErrorNotifier = ValueNotifier<String?>(null);
    bool respuestaOk = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          bool isLandscape = MediaQuery.of(ctx).orientation == Orientation.landscape;

          return Dialog(
            backgroundColor: const Color(0xFF0D1B2A),
            insetPadding: EdgeInsets.symmetric(horizontal: 10, vertical: isLandscape ? 5 : 20),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Colors.orangeAccent, width: 0.5)),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("🔓 RECUPERAR ACCESO", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: isLandscape ? 12 : 14)),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(10)),
                    child: Text("❓ $pregunta", style: const TextStyle(color: Colors.cyanAccent, fontSize: 12), textAlign: TextAlign.center),
                  ),
                  const SizedBox(height: 12),
                  _campoTexto(respCtrl, "Tu respuesta", Icons.vpn_key),
                  ValueListenableBuilder<String?>(
                    valueListenable: respErrorNotifier,
                    builder: (_, err, __) => err != null ? Text(err, style: const TextStyle(color: Colors.redAccent, fontSize: 10)) : const SizedBox.shrink(),
                  ),
                  
                  if (respuestaOk) ...[
                    const SizedBox(height: 10),
                    const Divider(color: Colors.white10),
                    const SizedBox(height: 10),
                    if (isLandscape)
                      Row(children: [
                        Expanded(child: _campoSeguro(nuevaCtrl, "Nueva contraseña", Icons.lock)),
                        const SizedBox(width: 10),
                        Expanded(child: _campoSeguro(nueva2Ctrl, "Confirmar", Icons.lock_outline)),
                      ])
                    else ...[
                      _campoSeguro(nuevaCtrl, "Nueva contraseña", Icons.lock),
                      const SizedBox(height: 10),
                      _campoSeguro(nueva2Ctrl, "Confirmar nueva", Icons.lock_outline),
                    ],
                    ValueListenableBuilder<String?>(
                      valueListenable: passErrorNotifier,
                      builder: (_, err, __) => err != null ? Text(err, style: const TextStyle(color: Colors.redAccent, fontSize: 10)) : const SizedBox.shrink(),
                    ),
                  ],

                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR", style: TextStyle(color: Colors.white38))),
                      const SizedBox(width: 10),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: respuestaOk ? Colors.greenAccent : Colors.orangeAccent),
                        onPressed: () async {
                          if (!respuestaOk) {
                            if (await ServicioContrasenaAdmin.validarRespuesta(respCtrl.text.trim())) {
                              respErrorNotifier.value = null;
                              setS(() => respuestaOk = true);
                            } else { respErrorNotifier.value = "❌ Respuesta incorrecta"; }
                            return;
                          }
                          if (nuevaCtrl.text != nueva2Ctrl.text) { passErrorNotifier.value = "No coinciden"; return; }
                          final user = FirebaseAuth.instance.currentUser;
                          if (user != null) await ServicioContrasenaAdmin.actualizarPassword(user.uid, nuevaCtrl.text.trim());
                          Navigator.pop(ctx);
                        },
                        child: Text(respuestaOk ? "GUARDAR" : "VERIFICAR", style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  )
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _flujoDesactivarContrasena() async {
    if (!mounted) return;
    Navigator.pop(context);
    final passCtrl = TextEditingController();
    final errorNotifier = ValueNotifier<String?>(null);

    await showDialog(
      context: context,
      builder: (ctx) {
        bool isLandscape = MediaQuery.of(ctx).orientation == Orientation.landscape;

        return Dialog(
          backgroundColor: const Color(0xFF0D1B2A),
          insetPadding: EdgeInsets.symmetric(horizontal: 10, vertical: isLandscape ? 5 : 20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Colors.redAccent, width: 0.5)),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("🔓 DESACTIVAR PROTECCIÓN", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: isLandscape ? 12 : 14)),
                const SizedBox(height: 15),
                const Text("Ingresa tu contraseña actual para confirmar", style: TextStyle(color: Colors.white54, fontSize: 11), textAlign: TextAlign.center),
                const SizedBox(height: 15),
                
                _campoSeguro(passCtrl, "Tu contraseña", Icons.lock),
                
                ValueListenableBuilder<String?>(
                  valueListenable: errorNotifier,
                  builder: (_, err, __) => err != null ? Padding(padding: const EdgeInsets.only(top: 8), child: Text(err, style: const TextStyle(color: Colors.redAccent, fontSize: 10))) : const SizedBox.shrink(),
                ),

                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR", style: TextStyle(color: Colors.white38))),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                      onPressed: () async {
                        final user = FirebaseAuth.instance.currentUser;
                        if (user != null && await ServicioContrasenaAdmin.validarPassword(passCtrl.text.trim(), user.uid)) {
                          await ServicioContrasenaAdmin.eliminar(user.uid);
                          Navigator.pop(ctx);
                        } else { 
                          errorNotifier.value = "❌ Contraseña incorrecta"; 
                        }
                      },
                      child: const Text("DESACTIVAR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ],
                )
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _campoSeguro(TextEditingController ctrl, String hint, IconData icono) {
    final ocultoNotifier = ValueNotifier<bool>(true);
    return ValueListenableBuilder<bool>(
      valueListenable: ocultoNotifier,
      builder: (_, oculto, __) => TextField(
        controller: ctrl,
        obscureText: oculto,
        style: const TextStyle(color: Colors.white, fontSize: 13), // Texto un poco más pequeño
        decoration: InputDecoration(
          isDense: true, // 👈 Hace el campo más compacto
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), // 👈 Menos altura
          hintText: hint,
          hintStyle: const TextStyle(color: Colors.white38, fontSize: 11),
          prefixIcon: Icon(icono, color: Colors.white38, size: 18),
          suffixIcon: IconButton(
            icon: Icon(oculto ? Icons.visibility_off : Icons.visibility, color: Colors.white38, size: 16),
            onPressed: () => ocultoNotifier.value = !ocultoNotifier.value,
          ),
          filled: true,
          fillColor: Colors.white.withOpacity(0.05),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        ),
      ),
    );
  }

  Widget _campoTexto(TextEditingController ctrl, String hint, IconData icono) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        isDense: true, // 👈
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12), // 👈
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38, fontSize: 11),
        prefixIcon: Icon(icono, color: Colors.white38, size: 18),
        filled: true,
        fillColor: Colors.white.withOpacity(0.05),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      ),
    );
  }
}

// ============================================================
// PANEL DE SEGURIDAD — con Switch de biometría
// ============================================================
class _PanelSeguridadSheet extends StatefulWidget {
  final bool tieneContrasena;
  final bool biometriaActiva;
  final VoidCallback onCrear;
  final VoidCallback onCambiar;
  final VoidCallback onOlvide;
  final VoidCallback onDesactivar;
  final Future<void> Function(bool) onToggleBiometria;

  const _PanelSeguridadSheet({
    required this.tieneContrasena,
    required this.biometriaActiva,
    required this.onCrear,
    required this.onCambiar,
    required this.onOlvide,
    required this.onDesactivar,
    required this.onToggleBiometria,
  });

  @override
  State<_PanelSeguridadSheet> createState() => _PanelSeguridadSheetState();
}

class _PanelSeguridadSheetState extends State<_PanelSeguridadSheet> {
  late bool _biometriaActiva;

  void _mostrarMensajeAlertaLocal(BuildContext context, String titulo, String mensaje, {bool esError = false}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1B2A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: esError ? Colors.redAccent : Colors.greenAccent, width: 1),
        ),
        title: Row(
          children: [
            Icon(
              esError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
              color: esError ? Colors.redAccent : Colors.greenAccent,
              size: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                titulo,
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Text(
          mensaje,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: esError ? Colors.redAccent : Colors.greenAccent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              "ACEPTAR",
              style: TextStyle(color: esError ? Colors.white : Colors.black, fontWeight: FontWeight.bold, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _biometriaActiva = widget.biometriaActiva;
  }

  @override
  Widget build(BuildContext context) {
    // Detectamos el teclado para empujar el contenido
    final keyboardPadding = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboardPadding),
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        decoration: BoxDecoration(
          color: const Color(0xFF0D1B2A),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
          boxShadow: [BoxShadow(color: Colors.cyanAccent.withOpacity(0.1), blurRadius: 30)],
        ),
        child: SingleChildScrollView( // 👈 Ahora el scroll interno es seguro
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 20),
              const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.admin_panel_settings, color: Colors.cyanAccent, size: 18),
                SizedBox(width: 8),
                Text("SEGURIDAD ADMINISTRADOR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1)),
              ]),
              const SizedBox(height: 24),
              if (!widget.tieneContrasena)
                _opcion(context, Icons.add_moderator, "CREAR CONTRASEÑA", "Establece una contraseña + pregunta de seguridad", Colors.cyanAccent, widget.onCrear)
              else ...[
                _switchBiometria(),
                const SizedBox(height: 12),
                _opcion(context, Icons.manage_accounts, "CAMBIAR CONTRASEÑA", "Ingresa la actual y establece una nueva", Colors.purpleAccent, widget.onCambiar),
                const SizedBox(height: 12),
                _opcion(context, Icons.lock_reset, "OLVIDÉ MI CONTRASEÑA", "Recupera acceso con tu pregunta secreta", Colors.orangeAccent, widget.onOlvide),
                const SizedBox(height: 12),
                _opcion(context, Icons.lock_open, "DESACTIVAR CONTRASEÑA", "Elimina la protección de administrador", Colors.redAccent, widget.onDesactivar),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _switchBiometria() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.greenAccent.withOpacity(0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: Colors.greenAccent
                .withOpacity(_biometriaActiva ? 0.4 : 0.15)),
      ),
      child: Row(children: [
        Icon(Icons.fingerprint,
            color: _biometriaActiva
                ? Colors.greenAccent
                : Colors.white38,
            size: 22),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("HUELLA / PIN DEL DISPOSITIVO",
                style: TextStyle(
                    color: _biometriaActiva
                        ? Colors.greenAccent
                        : Colors.white54,
                    fontWeight: FontWeight.bold,
                    fontSize: 12)),
            const Text("Entrar sin escribir contraseña",
                style: TextStyle(color: Colors.white38, fontSize: 10)),
          ]),
        ),
        Switch(
          value: _biometriaActiva,
          onChanged: (valor) async {
            // 🔥 SI EL USUARIO QUIERE ACTIVAR, PRIMERO PEDIMOS LA CONTRASEÑA
            if (valor == true) {
               bool ok = await _pedirPasswordParaValidar(context);
               if (!ok) return; // Si no puso la clave correcta, no activamos nada
            }
            
            // Si llega aquí, es porque ya validamos la contraseña
            setState(() => _biometriaActiva = valor);
            await widget.onToggleBiometria(valor);
          },
          activeColor: Colors.greenAccent,
          inactiveThumbColor: Colors.white38,
          inactiveTrackColor: Colors.white12,
        ),
      ]),
    );
  }

  Future<bool> _pedirPasswordParaValidar(BuildContext context) async {
    final passCtrl = TextEditingController();
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;

    final ocultoNotifier = ValueNotifier<bool>(true);

    bool exito = await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1B2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Colors.greenAccent, width: 0.5)),
        title: const Text("🔑 VERIFICAR CONTRASEÑA", style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
        content: ValueListenableBuilder<bool>(
          valueListenable: ocultoNotifier,
          builder: (_, oculto, __) => TextField(
            controller: passCtrl,
            obscureText: oculto,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              hintText: "Ingresa tu contraseña actual",
              hintStyle: const TextStyle(color: Colors.white38, fontSize: 11),
              prefixIcon: const Icon(Icons.lock, color: Colors.white38, size: 18),
              suffixIcon: IconButton(
                icon: Icon(oculto ? Icons.visibility_off : Icons.visibility, color: Colors.white38, size: 16),
                onPressed: () => ocultoNotifier.value = !ocultoNotifier.value,
              ),
              filled: true,
              fillColor: Colors.white.withOpacity(0.05),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), 
              child: const Text("CANCELAR", style: TextStyle(color: Colors.white38, fontSize: 11))
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.greenAccent),
            onPressed: () async {
              if (await ServicioContrasenaAdmin.validarPassword(passCtrl.text.trim(), user.uid)) {
                Navigator.pop(ctx, true);
              } else {
                Navigator.pop(ctx, false);
                // 🔥 Alerta de error local
                _mostrarMensajeAlertaLocal(context, "ERROR", "La contraseña es incorrecta.", esError: true);
              }
            },
            child: const Text("VALIDAR", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 11)),
          )
        ],
      ),
    ) ?? false;

    // 🔥 Alerta de éxito local (Se mostrará centrada en pantalla al activarse correctamente)
    if (exito && mounted) {
      _mostrarMensajeAlertaLocal(
        context, 
        "¡ÉXITO!", 
        "La seguridad biométrica ha sido registrada y activada con éxito."
      );
    }

    return exito;
  }

  Widget _opcion(BuildContext ctx, IconData icono, String titulo, String sub,
      Color color, VoidCallback accion) {
    return InkWell(
      onTap: accion,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: color.withOpacity(0.07),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Row(children: [
          Icon(icono, color: color, size: 22),
          const SizedBox(width: 14),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(titulo,
                    style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                        fontSize: 12)),
                Text(sub,
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 10)),
              ])),
          Icon(Icons.chevron_right,
              color: color.withOpacity(0.5), size: 18),
        ]),
      ),
    );
  }
}

// ============================================================
// FONDO ANIMADO
// ============================================================
class FondoMovimientoPainter extends CustomPainter {
  final double animationValue;
  FondoMovimientoPainter(this.animationValue);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 80);
    _draw(canvas, size, paint, const Color(0xFFFF9800).withOpacity(0.4), 0.2,
        0.3, 170, 1.0);
    _draw(canvas, size, paint, const Color(0xFF2196F3).withOpacity(0.35), 0.8,
        0.2, 230, 1.4);
    _draw(canvas, size, paint, const Color(0xFFE91E63).withOpacity(0.4), 0.4,
        0.8, 190, 0.8);
  }

  void _draw(Canvas canvas, Size size, Paint paint, Color color, double dx,
      double dy, double r, double s) {
    paint.color = color;
    double x =
        size.width * dx + (sin(animationValue * 2 * pi * s) * 70);
    double y =
        size.height * dy + (cos(animationValue * 2 * pi * s) * 70);
    canvas.drawCircle(Offset(x, y), r, paint);
  }

  @override
  bool shouldRepaint(FondoMovimientoPainter old) => true;
}