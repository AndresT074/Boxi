import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:sqflite/sqflite.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import '../database/db_helper.dart';
import 'pantalla_inventario.dart';
import 'pantalla_registrar_pedido.dart';
import 'pantalla_gestion_pedidos.dart';
import 'pantalla_vendedores.dart';
import 'pantalla_clientes.dart';
import 'pantalla_presupuestos.dart';
import 'pantalla_bienvenida.dart';
import 'pantalla_premium.dart';
import 'servicio_respaldo.dart';
import 'servicio_auth.dart';
import 'servicio_nube.dart';
import 'servicio_tema.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'servicio_anuncios.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'servicio_notificaciones.dart';

class PantallaPrincipal extends StatefulWidget {
  final bool esAdmin;
  const PantallaPrincipal({super.key, this.esAdmin = true});
  @override
  State<PantallaPrincipal> createState() => _PantallaPrincipalState();
}

class _PantallaPrincipalState extends State<PantallaPrincipal>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> productos = [];
  List<Map<String, dynamic>> filtrados = [];
  List<Map<String, dynamic>> carrito = [];
  final Map<int, TextEditingController> _cantControllers = {};
  int _cantidadSolicitudes = 0;
  bool _primeraCargaSolicitudes = true;
  StreamSubscription? _subSolicitudes;
  StreamSubscription<DocumentSnapshot>? _subPerfil;
  String _logoPath = "";
  ImageProvider? _logoImageCached; // 🔥 Caché de imagen para evitar parpadeo
  String _nombreNegocio = "MI NEGOCIO";
  bool _esPremium = false;
  bool _estaBuscando = false;
  bool _procesandoImagen = false;
  bool _mostrarAvisoReorganizar = true;
  Timer? _timerReorden;
  double _alturaCarrito = 150.0;
  final double _minAltura = 0;
  bool _aplicarDescuentoGlobal = false;
  double _descuentoGlobalPct = 0.0;
  int _badgeInventario = 0;
  int _badgePedidos = 0;
  int _columnasIndex = 1;
  final List<int> _colsVertical = [4, 3, 2, 1];
  final List<int> _colsHorizontal = [8, 5, 3, 1];
  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _nombreController = TextEditingController();
  bool _mostrarModalNombre = false;
  final Map<int, Uint8List> _fotoCache = {};
  List<Map<String, dynamic>> categorias = [];
  Map<String, bool> categoriasExpandidas = {};
  final ScrollController _mainScroll = ScrollController();
  Timer? _autoScrollTimer;
  Timer? _dragTimer;
  bool _isDragging = false;
  Offset? _startPos;
  final Set<String> _categoriasEnModoEliminacion = {};

  @override
  void initState() {
    super.initState();
    ServicioNotificaciones.inicializar();
    ServicioNube.procesarColaOffline();
    _cargarConfig();
    _cargar();
    _intentarSincronizacionNube();
    _escucharSolicitudes();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _nombreController.dispose();
    _timerReorden?.cancel();
    _subSolicitudes?.cancel();
    _subPerfil?.cancel();
    _searchCtrl.dispose();
    _mainScroll.dispose();
    _autoScrollTimer?.cancel();
    _dragTimer?.cancel();
    for (var ctrl in _cantControllers.values) {
      ctrl.dispose();
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ServicioNube.procesarColaOffline();
      
      debugPrint("▶️ App en primer plano, verificando cambios en nube...");
    }
  }
  
  Future<void> _cargarConfig() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await prefs.setString('user_uid', user.uid);
    }

    String nombre = prefs.getString('nombre_negocio') ?? "MI NEGOCIO";
    String nuevaPath = prefs.getString('logo_path') ?? "";
    bool nuevoPremium = prefs.getBool('es_premium') ?? false;

    // 🔥 CACHÉ INTELIGENTE: Solo decodifica si el logo realmente cambió
    if (nuevaPath != _logoPath || _logoImageCached == null) {
      if (nuevaPath.isNotEmpty) {
        if (nuevaPath.length > 500) {
          try {
            _logoImageCached = MemoryImage(base64Decode(nuevaPath));
          } catch (e) {
            _logoImageCached = null;
          }
        } else if (File(nuevaPath).existsSync()) {
          _logoImageCached = FileImage(File(nuevaPath));
        }
      } else {
        _logoImageCached = null;
      }
    }

    setState(() {
      _nombreNegocio = (nombre == "nombredenegocioaqui") ? "MI NEGOCIO" : nombre;
      _logoPath = nuevaPath;
      _esPremium = nuevoPremium;
    });
    FirebaseAnalytics.instance.setUserProperty(
      name: 'nombre_negocio', 
      value: _nombreNegocio
    );
  }

  Future<void> _cargar() async {
    final db = await DBHelper.instance.database;
    
    try { await db.execute('ALTER TABLE categorias ADD COLUMN orden INTEGER DEFAULT 0'); } catch (_) {}
    
    // 🔥 Añadida 'foto_path' a la consulta principal para evitar lecturas repetitivas
    final data = await db.query('productos',
        columns: ['id', 'nombre', 'precio_compra', 'precio_venta', 'descuento', 'stock', 'descripcion', 'variantes', 'orden', 'activo', 'ultima_modificacion', 'categoria', 'foto_path'],
        where: 'activo = 1', orderBy: 'orden ASC, id DESC');
    
    final catData = await db.query('categorias', orderBy: 'orden ASC, id DESC');
    
    List<Map<String, dynamic>> datosEditables =
        data.map((e) => Map<String, dynamic>.from(e)).toList();
    bool necesitaForzarNube = false;
    for (int i = 0; i < datosEditables.length; i++) {
      if (datosEditables[i]['orden'] == null) {
        datosEditables[i]['orden'] = i;
        await db.update('productos', {'orden': i},
            where: 'id = ?', whereArgs: [datosEditables[i]['id']]);
        necesitaForzarNube = true;
      }
    }
    if (necesitaForzarNube && _esPremium) {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        WriteBatch batchNube = FirebaseFirestore.instance.batch();
        for (var p in datosEditables) {
          DocumentReference doc = FirebaseFirestore.instance
              .collection('usuarios')
              .doc(user.uid)
              .collection('productos')
              .doc(p['id'].toString());
          batchNube.set(doc, {'orden': p['orden']}, SetOptions(merge: true));
        }
        await batchNube.commit();
      }
    }
    int productosAgotados = 0;
    for (var p in datosEditables) {
      String varStr = p['variantes']?.toString() ?? "";
      if (varStr.length > 5) {
        try {
          var dec = jsonDecode(varStr);
          if (dec.isNotEmpty && !dec[0].containsKey('grupo')) {
            for (var o in dec) {
              if ((o['stock'] as int) <= 0) productosAgotados++;
            }
          } else {
            for (var g in dec) {
              if (!g.containsKey('grupo')) continue;
              for (var o in g['opciones']) {
                if ((o['stock'] as int) <= 0) productosAgotados++;
              }
            }
          }
        } catch (e) {}
      } else {
        if ((p['stock'] as int? ?? 0) <= 0) productosAgotados++;
      }
    }
    var pedData = await db.rawQuery(
        "SELECT COUNT(*) as c FROM pedidos WHERE estado IN ('Pendiente', 'Entregado sin Pago')");
    int pedidosAtascados = Sqflite.firstIntValue(pedData) ?? 0;
    if (!mounted) return;
    setState(() {
      categorias = catData.map((e) => Map<String, dynamic>.from(e)).toList();
      productos = datosEditables;
      filtrados = List.from(datosEditables);
      _badgeInventario = productosAgotados;
      _badgePedidos = pedidosAtascados;
      _aplicarFiltro();
    });
  }

  void _escucharSolicitudes() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (_subSolicitudes != null) return;
    
    _subSolicitudes = FirebaseFirestore.instance
        .collection('solicitudes')
        .where('adminId', isEqualTo: user.uid)
        .where('estado', isEqualTo: 'pendiente')
        .snapshots()
        .listen(
          (snap) {
            final ahora = DateTime.now();
            WriteBatch batch = FirebaseFirestore.instance.batch();
            bool hayExpirados = false;
            
            if (!_primeraCargaSolicitudes) {
              for (var change in snap.docChanges) {
                if (change.type == DocumentChangeType.added) {
                  SharedPreferences.getInstance().then((prefs) {
                    prefs.setString('ultima_revision_pedidos',
                        DateTime.now().toIso8601String());
                  });
                }
              }
            }
            _primeraCargaSolicitudes = false;
            
            for (var doc in snap.docs) {
              final data = doc.data();
              if (data.containsKey('expireAt')) {
                Timestamp expireAt = data['expireAt'];
                if (expireAt.toDate().isBefore(ahora)) {
                  batch.delete(doc.reference);
                  hayExpirados = true;
                }
              }
            }
            if (hayExpirados) batch.commit();
            if (mounted) {
              setState(() => _cantidadSolicitudes = snap.docs.length);
            }
          },
          onError: (e) =>
              debugPrint("Error suscripción solicitudes web: $e"),
        );
  }

  Future<void> _sincronizarSoloSiHayCambios() async {
    if (!_esPremium) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (!await ServicioNube.tieneInternet()) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final userDoc = await FirebaseFirestore.instance.collection('usuarios').doc(user.uid).get(const GetOptions(source: Source.server));
      
      if (!userDoc.exists) return;
      final data = userDoc.data() as Map<String, dynamic>;
      final Timestamp? ultimaMod = data['ultima_mod_productos'] as Timestamp?;
      final String? ultimaModLocal = prefs.getString('ultima_mod_productos_local_${user.uid}');
      String? ultimaModStr = ultimaMod?.microsecondsSinceEpoch.toString(); 
      
      final Timestamp? ultimaModPed = data['ultima_mod_pedidos'] as Timestamp?;
      final String? ultimaModPedLocal = prefs.getString('ultima_mod_pedidos_local_${user.uid}');
      String? ultimaModPedStr = ultimaModPed?.microsecondsSinceEpoch.toString();
      
      final Timestamp? ultimaModAjust = data['ultima_mod_ajustes'] as Timestamp?;
      final String? ultimaModAjustLocal = prefs.getString('ultima_mod_ajustes_local_${user.uid}');
      String? ultimaModAjustStr = ultimaModAjust?.microsecondsSinceEpoch.toString();

      final Timestamp? ultimaModCat = data['ultima_mod_categorias'] as Timestamp?;
      final String? ultimaModCatLocal = prefs.getString('ultima_mod_categorias_local_${user.uid}');
      String? ultimaModCatStr = ultimaModCat?.microsecondsSinceEpoch.toString();
      
      bool cambioAjust = ultimaModAjustStr != null && ultimaModAjustStr != ultimaModAjustLocal;
      bool cambioProd = ultimaModStr != null && ultimaModStr != ultimaModLocal;
      bool cambioPed = ultimaModPedStr != null && ultimaModPedStr != ultimaModPedLocal;
      bool cambioCat = ultimaModCatStr != null && ultimaModCatStr != ultimaModCatLocal;

      // 3. Por último se hace la evaluación en el IF
      if (!cambioProd && !cambioPed && !cambioAjust && !cambioCat) {
        debugPrint("☁️ Nube al día. 0 lecturas consumidas.");
        return; 
      }

      if (cambioProd) {
        await ServicioNube.sincronizarBorradosFisicos(user.uid, 'productos');
        await ServicioNube.descargarSoloModificados(user.uid, 'productos', 'ultima_modificacion');
        // 🔥 Fotos de variantes removidas de la carga rápida para evitar bloqueos por OutOfMemory
        await prefs.setString('ultima_mod_productos_local_${user.uid}', ultimaModStr);
      }

      if (cambioPed) {
        await ServicioNube.sincronizarBorradosFisicos(user.uid, 'pedidos');
        await ServicioNube.descargarSoloModificados(user.uid, 'pedidos', 'ultima_modificacion');
        await ServicioNube.sincronizarBorradosFisicos(user.uid, 'detalle_pedidos');
        await ServicioNube.descargarSoloModificados(user.uid, 'detalle_pedidos', 'ultima_modificacion');
        await ServicioNube.limpiarFantasmasNubeYLocal(user.uid);
        await prefs.setString('ultima_mod_pedidos_local_${user.uid}', ultimaModPedStr);
        debugPrint("📦 Pedidos y Detalles sincronizados.");
      }

      if (cambioAjust) {
        await ServicioNube.sincronizarBorradosFisicos(user.uid, 'ajustes_capital');
        await ServicioNube.descargarSoloModificados(user.uid, 'ajustes_capital', 'ultima_modificacion');
        await prefs.setString('ultima_mod_ajustes_local_${user.uid}', ultimaModAjustStr);
        debugPrint("💰 Capital de reinversión sincronizado.");
      }

      if (cambioCat) {
        await ServicioNube.sincronizarBorradosFisicos(user.uid, 'categorias');
        await ServicioNube.descargarSoloModificados(user.uid, 'categorias', 'ultima_modificacion');
        await prefs.setString('ultima_mod_categorias_local_${user.uid}', ultimaModCatStr);
      }
      _cargar();
    } catch (e) {
      debugPrint("Error de sincronización: $e");
    }
  }

  Future<void> _guardarOrden() async {
    if (!mounted) return; 
    
    final db = await DBHelper.instance.database;
    final List<Map<String, dynamic>> productosBD = await db.query('productos', columns: ['id', 'orden']);
    
    Batch batchLocal = db.batch();
    List<Map<String, dynamic>> productosCambiados = [];

    for (int i = 0; i < filtrados.length; i++) {
      int idActual = filtrados[i]['id'];
      var prodOriginal = productosBD.firstWhere((p) => p['id'] == idActual);
      
      if (prodOriginal['orden'] != i) {
        filtrados[i]['orden'] = i; 
        batchLocal.update('productos', {'orden': i}, where: 'id = ?', whereArgs: [idActual]);
        productosCambiados.add(filtrados[i]); 
      }
    }
    
    await batchLocal.commit(noResult: true);
    if (!mounted) return; 
    setState(() => productos = List.from(filtrados));
    
    if (_esPremium && productosCambiados.isNotEmpty) {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        WriteBatch batchNube = FirebaseFirestore.instance.batch();
        for (var p in productosCambiados) {
          DocumentReference doc = FirebaseFirestore.instance
              .collection('usuarios').doc(user.uid)
              .collection('productos').doc(p['id'].toString());
          batchNube.set(doc, {
            'orden': p['orden'],
            'ultima_modificacion': FieldValue.serverTimestamp()
          }, SetOptions(merge: true));
        }
        batchNube.update(FirebaseFirestore.instance.collection('usuarios').doc(user.uid), 
          {'ultima_mod_productos': FieldValue.serverTimestamp()});
        await batchNube.commit();
      }
    }
  }

  void _onReorderCategoria(List<Map<String, dynamic>> sublista, int oldIndex, int newIndex) {
    setState(() {
      final item = sublista.removeAt(oldIndex);
      sublista.insert(newIndex, item);
      
      // Reordenamos globalmente para que tu _guardarOrden original funcione perfecto
      String? catNombre = item['categoria'];
      int primerIndice = filtrados.indexWhere((p) => p['categoria'] == catNombre);
      if (primerIndice != -1) {
        filtrados.removeWhere((p) => p['categoria'] == catNombre);
        filtrados.insertAll(primerIndice, sublista);
      }
    });
    
    _timerReorden?.cancel();
    _timerReorden = Timer(const Duration(seconds: 3), () {
      _guardarOrden(); // Llama a tu función original intacta
    });
  }

  Future<void> _validarYProcesarVenta(double total) async {
    List<String> advertencias = [];
    for (var item in carrito) {
      if (item['es_domicilio'] == true) continue;
      int cantidadPedida = item['cantidad'] ?? 0;
      int stockDisponible = 0;
      var prodEnBD = productos.firstWhere(
          (p) => p['id'] == item['id'],
          orElse: () => {});
      if (prodEnBD.isNotEmpty) {
        if (item['es_variante'] == true &&
            item['g_index'] != null &&
            item['o_index'] != null) {
          try {
            List<dynamic> grps = jsonDecode(prodEnBD['variantes']);
            stockDisponible =
                grps[item['g_index']]['opciones'][item['o_index']]['stock'];
          } catch (e) {
            stockDisponible = item['stock_real'] ?? 0;
          }
        } else {
          stockDisponible = prodEnBD['stock'] ?? 0;
        }
      } else {
        stockDisponible = item['stock_real'] ?? item['stock'] ?? 0;
      }
      if (cantidadPedida > stockDisponible) {
        advertencias.add(
            "• ${item['nombre']}\n   (Pides: $cantidadPedida | Tienes: $stockDisponible)");
      }
    }
    if (advertencias.isNotEmpty) {
      bool continuar = await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: Colors.orange, size: 28),
                  SizedBox(width: 10),
                  Expanded(
                      child: Text("Stock Insuficiente",
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 18))),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                        "Estás intentando vender más de lo que tienes en inventario para:",
                        style: TextStyle(fontSize: 13)),
                    const SizedBox(height: 15),
                    Text(advertencias.join("\n\n"),
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Colors.red)),
                    const SizedBox(height: 20),
                    const Text(
                        "¿Deseas continuar y registrar la venta de todas formas?",
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text("NO, REVISAR",
                        style: TextStyle(
                            color: Colors.grey,
                            fontWeight: FontWeight.bold))),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10))),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text("SÍ, CONTINUAR",
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ) ??
          false;
      if (!continuar) return;
    }
    if (!mounted) return;
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => PantallaRegistrarPedido(
                carrito: carrito, totalPedido: total))).then((c) {
      if (c == true) {
        setState(() => carrito.clear());
        _cargar();
      }
    });
  }

  void _compartirCatalogo() async {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    final prefs = await SharedPreferences.getInstance();
    
    String savedFull = prefs.getString('whatsapp_admin') ?? "";
    String indicativo = prefs.getString('whatsapp_admin_indicativo') ?? "";
    String numero = prefs.getString('whatsapp_admin_numero') ?? "";

    // 🔥 REEMPLAZA ESTE BLOQUE:
    if (indicativo.isEmpty && numero.isEmpty && savedFull.isNotEmpty) {
      if (savedFull.startsWith('1') && savedFull.length == 11) {
        // 🇺🇸/🇨🇦 USA y Canadá (Indicativo de 1 dígito + 10 de celular)
        indicativo = '1';
        numero = savedFull.substring(1);
      } else if (savedFull.length >= 12) {
        // 🇲🇽/🇨🇴 Mayoría de Latam (Indicativo de 2 o 3 dígitos + 10 de celular)
        indicativo = savedFull.substring(0, savedFull.length - 10);
        numero = savedFull.substring(savedFull.length - 10);
      } else if (savedFull.length == 11) {
        // 🇪🇸/🇵🇪/🇨🇱 España, Perú, Chile, etc. (Indicativo de 2 dígitos + 9 de celular)
        indicativo = savedFull.substring(0, 2);
        numero = savedFull.substring(2);
      } else {
        // Fallback para números que no cumplan las longitudes estándar
        numero = savedFull;
      }
    }

    final TextEditingController indicativoCtrl = TextEditingController(text: indicativo);
    final TextEditingController numeroCtrl = TextEditingController(text: numero);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          Icon(Icons.screen_share, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1), size: 28),
          const SizedBox(width: 10),
          Expanded(child: Text("Compartir Catálogo", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: isOscuro ? Colors.white : Colors.black))),
        ]),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_esPremium) ...[
                const Text("Configura tu número para recibir pedidos online y comparte tu catálogo web, o descarga la versión en PDF."),
                const SizedBox(height: 15),
                const Text("Número de WhatsApp para pedidos:", style: TextStyle(fontSize: 12)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: indicativoCtrl,
                        keyboardType: TextInputType.number,
                        style: TextStyle(color: isOscuro ? Colors.white : Colors.black),
                        decoration: InputDecoration(
                          prefixText: "+ ",
                          prefixStyle: TextStyle(color: isOscuro ? Colors.white : Colors.black, fontWeight: FontWeight.bold),
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 5,
                      child: TextField(
                        controller: numeroCtrl,
                        keyboardType: TextInputType.phone,
                        style: TextStyle(color: isOscuro ? Colors.white : Colors.black),
                        decoration: const InputDecoration(
                          hintText: "ej: 3123456789",
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                const Text("Genera un PDF con todos tus productos y compártelo con tus clientes."),
                const SizedBox(height: 15),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.orange.withOpacity(0.5))
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.star, color: Colors.orange),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          "Sube a Premium para activar tu Catálogo Web interactivo y recibir pedidos directamente en tu WhatsApp.",
                          style: TextStyle(fontSize: 12, color: isOscuro ? Colors.white70 : Colors.black87),
                        ),
                      ),
                    ],
                  ),
                )
              ]
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actionsPadding: const EdgeInsets.only(bottom: 15, left: 15, right: 15),
        actions: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _generarYCompartirPdfCatalogo();
                      },
                      icon: const Icon(Icons.picture_as_pdf, size: 18),
                      label: const Text("CATÁLOGO PDF", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _esPremium ? Colors.green : Colors.orange,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        if (!_esPremium) {
                          Navigator.push(context, MaterialPageRoute(builder: (_) => const PantallaPremium()));
                          return;
                        }
                        
                        String indClean = indicativoCtrl.text.trim().replaceAll(RegExp(r'\D'), '');
                        String numClean = numeroCtrl.text.trim().replaceAll(RegExp(r'\D'), '');
                        String numeroCompleto = "$indClean$numClean";

                        if (indClean.isEmpty || numClean.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("⚠️ Ingresa un número válido para tu catálogo web.")));
                          return;
                        }

                        await prefs.setString('whatsapp_admin_indicativo', indClean);
                        await prefs.setString('whatsapp_admin_numero', numClean);
                        await prefs.setString('whatsapp_admin', numeroCompleto);

                        final user = FirebaseAuth.instance.currentUser;
                        if (user != null) {
                          await FirebaseFirestore.instance.collection('usuarios').doc(user.uid).set(
                            {'whatsapp_admin': numeroCompleto}, SetOptions(merge: true)
                          );
                          String link = "https://boxi-catalogo.web.app/catalogo/?id=${user.uid}";
                          Share.share("📦 ¡Hola! Te comparto mi catálogo. Haz tus pedidos aquí:\n\n$link");
                        }
                      },
                      icon: Icon(_esPremium ? Icons.public : Icons.stars, size: 18),
                      label: Text(_esPremium ? "CATÁLOGO WEB" : "VER PREMIUM", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10)),
                    ),
                  ),
                ],
              ),
              // 🔥 NUEVO: Botón Guardar independiente (Solo visible si es Premium)
              if (_esPremium) ...[
                const SizedBox(height: 10),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () async {
                    String indClean = indicativoCtrl.text.trim().replaceAll(RegExp(r'\D'), '');
                    String numClean = numeroCtrl.text.trim().replaceAll(RegExp(r'\D'), '');
                    String numeroCompleto = "$indClean$numClean";

                    if (indClean.isEmpty || numClean.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("⚠️ Completa el indicativo y el número.")));
                      return;
                    }

                    await prefs.setString('whatsapp_admin_indicativo', indClean);
                    await prefs.setString('whatsapp_admin_numero', numClean);
                    await prefs.setString('whatsapp_admin', numeroCompleto);

                    final user = FirebaseAuth.instance.currentUser;
                    if (user != null) {
                      await FirebaseFirestore.instance.collection('usuarios').doc(user.uid).set(
                        {'whatsapp_admin': numeroCompleto}, SetOptions(merge: true)
                      );
                    }
                    
                    Navigator.pop(ctx);
                    
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("✅ Configuración guardada correctamente"), backgroundColor: Colors.green)
                      );
                    }
                  },
                  icon: const Icon(Icons.save, size: 16),
                  label: const Text("GUARDAR CONFIGURACIÓN", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                ),
              ],
              const SizedBox(height: 5),
              TextButton(
                onPressed: () => Navigator.pop(ctx), 
                child: const Text("CANCELAR", style: TextStyle(color: Colors.grey))
              )
            ],
          )
        ],
      ),
    );
  }

  Future<void> _generarYCompartirPdfCatalogo() async {
    if (productos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No hay productos activos para el catálogo.")));
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(color: Color(0xFF0D47A1)),
            SizedBox(width: 20),
            Text("Diseñando catálogo..."),
          ],
        ),
      ),
    );

    try {
      final pdf = pw.Document();
      final prefs = await SharedPreferences.getInstance();
      final String nombreNeg = prefs.getString('nombre_negocio') ?? "MI NEGOCIO";

      // 1. Cargar el Logo del Negocio
      pw.MemoryImage? logoPdf;
      if (_logoPath.isNotEmpty) {
        try {
          if (_logoPath.length > 500) {
            logoPdf = pw.MemoryImage(base64Decode(_logoPath));
          } else {
            final file = File(_logoPath);
            if (file.existsSync()) logoPdf = pw.MemoryImage(await file.readAsBytes());
          }
        } catch (_) {}
      }

      // 2. Extraer datos locales e imágenes de productos (CERO LECTURAS EN NUBE)
      final db = await DBHelper.instance.database;
      Map<int, pw.MemoryImage> imagenesPdf = {};
      final dbProds = await db.query('productos', columns: ['id', 'foto_path'], where: 'activo = 1');
      
      int contador = 0;
      for (var row in dbProds) {
        int id = row['id'] as int;
        String fotoPath = row['foto_path']?.toString() ?? "";
        if (fotoPath.isNotEmpty) {
          try {
            if (fotoPath.length > 500) {
              imagenesPdf[id] = pw.MemoryImage(base64Decode(fotoPath));
            } else {
              final file = File(fotoPath);
              if (file.existsSync()) {
                imagenesPdf[id] = pw.MemoryImage(await file.readAsBytes());
              }
            }
          } catch (_) {}
        }
        
        contador++;
        if (contador % 5 == 0) await Future.delayed(const Duration(milliseconds: 1));
      }

      // 3. Filtro para limpiar Emojis (Evita los cuadros con la X)
      String limpiarTexto(String texto) {
        return texto.replaceAll(RegExp(r'[^\x00-\x7F\xA0-\xFF]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      }

      // 4. Cálculos optimizados para cuadrícula de 2x2 sin dejar espacio muerto
      const double margenPagina = 22.0; 
      const double espacioEntreCartas = 14.0;
      final double anchoCarta = (PdfPageFormat.a4.width - (margenPagina * 2) - espacioEntreCartas) / 2;

      // 5. Construcción del PDF
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(margenPagina),
          header: (context) => pw.Container(
            padding: const pw.EdgeInsets.only(bottom: 10),
            margin: const pw.EdgeInsets.only(bottom: 15),
            decoration: const pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(color: PdfColors.blue900, width: 2))
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text("CATÁLOGO DE PRODUCTOS", style: pw.TextStyle(fontSize: 21, fontWeight: pw.FontWeight.bold, color: PdfColors.blue900)),
                    pw.SizedBox(height: 2),
                    pw.Text(limpiarTexto(nombreNeg).toUpperCase(), style: pw.TextStyle(fontSize: 12, color: PdfColors.grey700)),
                  ]
                ),
                if (logoPdf != null)
                  pw.Container(
                    width: 42, height: 42,
                    decoration: pw.BoxDecoration(
                      shape: pw.BoxShape.circle,
                      image: pw.DecorationImage(image: logoPdf, fit: pw.BoxFit.cover)
                    )
                  )
              ]
            )
          ),
          footer: (context) => pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              pw.Divider(color: PdfColors.grey300, thickness: 1),
              pw.SizedBox(height: 5),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.UrlLink(
                    destination: "https://play.google.com/store/apps/details?id=com.andres074.boxi",
                    child: pw.Row(
                      children: [
                        pw.Text("Creado con ", style: const pw.TextStyle(color: PdfColors.grey600, fontSize: 10)),
                        pw.Text("Boxi", style: pw.TextStyle(color: PdfColors.blue, fontSize: 10, fontWeight: pw.FontWeight.bold)),
                        pw.Text(" - Descarga aquí", style: const pw.TextStyle(color: PdfColors.blueAccent, fontSize: 10, decoration: pw.TextDecoration.underline)),
                      ]
                    )
                  ),
                  pw.Text('Página ${context.pageNumber} de ${context.pagesCount}', style: const pw.TextStyle(color: PdfColors.grey, fontSize: 10))
                ]
              )
            ]
          ),
          build: (context) {
            return [
              pw.Wrap(
                spacing: espacioEntreCartas,
                runSpacing: espacioEntreCartas,
                children: productos.map((p) {
                  double precioOriginal = (p['precio_venta'] as num).toDouble();
                  double desc = (p['descuento'] ?? 0).toDouble();
                  double precioFinal = precioOriginal - (precioOriginal * (desc / 100));
                  
                  String nombreLimpio = limpiarTexto(p['nombre'].toString().toUpperCase());
                  String descLimpia = limpiarTexto(p['descripcion']?.toString() ?? "");
                  
                  pw.MemoryImage? imgProv = imagenesPdf[p['id']];

                  // EXTRAER VARIANTES ACTIVAS
                  List<Map<String, dynamic>> gruposVariantes = [];
                  if (p['variantes'] != null && p['variantes'].toString().length > 5) {
                    try {
                      var dec = jsonDecode(p['variantes']);
                      if (dec.isNotEmpty && !dec[0].containsKey('grupo')) {
                        var opcionesActivas = dec.where((o) => (o['activo'] ?? true) == true).toList();
                        if (opcionesActivas.isNotEmpty) {
                          gruposVariantes.add({'grupo': 'Opciones', 'opciones': opcionesActivas});
                        }
                      } else {
                        for (var g in dec) {
                          var opcionesActivas = (g['opciones'] as List).where((o) => (o['activo'] ?? true) == true).toList();
                          if (opcionesActivas.isNotEmpty) {
                            gruposVariantes.add({'grupo': g['grupo'], 'opciones': opcionesActivas});
                          }
                        }
                      }
                    } catch (e) {}
                  }

                  return pw.Container(
                    width: anchoCarta,
                    decoration: pw.BoxDecoration(
                      color: PdfColors.white,
                      borderRadius: const pw.BorderRadius.all(pw.Radius.circular(10)),
                      border: pw.Border.all(color: PdfColors.grey300, width: 1),
                    ),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        // 🔥 IMAGEN TIPO ESTUDIO (Altura perfecta a 165 con fondo vitrina gris claro)
                        pw.Container(
                          height: 165, 
                          width: double.infinity,
                          padding: const pw.EdgeInsets.all(6),
                          decoration: const pw.BoxDecoration(
                            color: PdfColors.grey200, // <--- Fondo gris enmarca perfectamente la foto sin perderse
                            borderRadius: pw.BorderRadius.vertical(top: pw.Radius.circular(9)),
                          ),
                          child: imgProv == null 
                            ? pw.Center(child: pw.Text("SIN IMAGEN", style: const pw.TextStyle(color: PdfColors.grey500, fontSize: 11))) 
                            : pw.Center(child: pw.Image(imgProv, fit: pw.BoxFit.contain)),
                        ),
                        
                        pw.Divider(height: 1, thickness: 1, color: PdfColors.grey300), 

                        // DETALLES Y VARIANTES (Optimizado a 8px vertical para un ajuste perfecto)
                        pw.Container(
                          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Text(
                                nombreLimpio, 
                                style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12, color: PdfColors.black), 
                                maxLines: 2
                              ),
                              pw.SizedBox(height: 4),
                              
                              if (descLimpia.isNotEmpty) ...[
                                pw.Text(descLimpia, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700), maxLines: 2), 
                                pw.SizedBox(height: 6),
                              ] else ...[
                                pw.SizedBox(height: 4),
                              ],

                              // RENDERIZAR CAPSULITAS DE VARIANTES
                              if (gruposVariantes.isNotEmpty) ...[
                                ...gruposVariantes.map((g) {
                                  String nombreGrupo = g['grupo'].toString().trim();
                                  String labelGrupo = (nombreGrupo.toLowerCase() == 'opciones' || nombreGrupo.isEmpty)
                                      ? "Disponibles:"
                                      : "Disponible en ${limpiarTexto(nombreGrupo)}:";

                                  return pw.Column(
                                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                                    children: [
                                      pw.Text(
                                        labelGrupo,
                                        style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.grey600)
                                      ),
                                      pw.SizedBox(height: 3),
                                      pw.Wrap(
                                        spacing: 4,
                                        runSpacing: 4,
                                        children: (g['opciones'] as List).map((o) {
                                          return pw.Container(
                                            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                            decoration: pw.BoxDecoration(
                                              color: PdfColors.grey100,
                                              border: pw.Border.all(color: PdfColors.grey300),
                                              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4))
                                            ),
                                            child: pw.Text(
                                              limpiarTexto(o['nombre'].toString()), 
                                              style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey800)
                                            )
                                          );
                                        }).toList()
                                      ),
                                      pw.SizedBox(height: 6),
                                    ]
                                  );
                                }).toList(),
                              ],
                              
                              pw.Divider(color: PdfColors.grey200, thickness: 1),
                              pw.SizedBox(height: 4),
                              
                              // PRECIOS
                              if (desc > 0) ...[
                                pw.Row(
                                  children: [
                                    pw.Text("\$${precioOriginal.toStringAsFixed(0)}", style: const pw.TextStyle(fontSize: 10, color: PdfColors.red, decoration: pw.TextDecoration.lineThrough)),
                                    pw.SizedBox(width: 4),
                                    pw.Container(
                                      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
                                      decoration: const pw.BoxDecoration(color: PdfColors.red, borderRadius: pw.BorderRadius.all(pw.Radius.circular(3))),
                                      child: pw.Text("-$desc%", style: pw.TextStyle(color: PdfColors.white, fontSize: 8, fontWeight: pw.FontWeight.bold))
                                    ),
                                  ]
                                ),
                                pw.SizedBox(height: 2),
                              ],
                              pw.Text("\$${precioFinal.toStringAsFixed(0)}", style: pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold, color: PdfColors.green700)),
                            ]
                          )
                        )
                      ]
                    )
                  );
                }).toList(),
              )
            ];
          }
        )
      );

      final output = await getTemporaryDirectory();
      final file = File("${output.path}/Catalogo_$nombreNeg.pdf");
      await file.writeAsBytes(await pdf.save());

      if (mounted) Navigator.pop(context);

      await Share.shareXFiles([XFile(file.path)], text: '📦 Aquí tienes nuestro catálogo de productos.');

      if (!_esPremium && mounted) {
        ServicioAnuncios.mostrarAnuncioIntersticial(() {});
      }

    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error al generar PDF: $e")));
      }
    }
  }

  Future<void> _intentarSincronizacionNube() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final prefs = await SharedPreferences.getInstance();

    String? ultimoUid = prefs.getString('ultimo_uid_registrado');
    if (ultimoUid != null && ultimoUid != user.uid) {
      await DBHelper.instance.limpiarTablas();
      await prefs.remove('datos_descargados');
      await prefs.remove('primera_carga_completada_$ultimoUid');
    }
    await prefs.setString('ultimo_uid_registrado', user.uid);
    await prefs.setString('user_uid', user.uid);

    try {
      String? fcmToken = await FirebaseMessaging.instance.getToken();
      if (fcmToken != null) {
        await FirebaseFirestore.instance
            .collection('usuarios').doc(user.uid)
            .set({'fcm_token': fcmToken}, SetOptions(merge: true));
      }
    } catch (e) { debugPrint("Error FCM: $e"); }

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('usuarios').doc(user.uid).get();
      bool esPremiumNube = userDoc.exists ? (userDoc.data()?['es_premium'] ?? false) : false;
      await prefs.setBool('es_premium', esPremiumNube);
      if (mounted) setState(() => _esPremium = esPremiumNube);
    } catch (e) { debugPrint("Error leyendo premium: $e"); }
    bool yaDescargoTodo = prefs.getBool("descarga_completa_${user.uid}") ?? false;
    
    if (_esPremium && !yaDescargoTodo && await ServicioNube.tieneInternet()) {
      try {
        await ServicioNube.descargarTodoDesdeNube();
        await ServicioNube.limpiarFantasmasNubeYLocal(user.uid); 
        await prefs.setBool("descarga_completa_${user.uid}", true);
        await prefs.setBool("primera_carga_completada_${user.uid}", true);
        
        final userDoc = await FirebaseFirestore.instance.collection('usuarios').doc(user.uid).get();
        if (userDoc.exists) {
          final data = userDoc.data() as Map<String, dynamic>;
          final modProd = (data['ultima_mod_productos'] as Timestamp?)?.microsecondsSinceEpoch.toString();
          final modPed = (data['ultima_mod_pedidos'] as Timestamp?)?.microsecondsSinceEpoch.toString();
          final modCat = (data['ultima_mod_categorias'] as Timestamp?)?.microsecondsSinceEpoch.toString();
          if (modProd != null) await prefs.setString('ultima_mod_productos_local_${user.uid}', modProd);
          if (modPed != null) await prefs.setString('ultima_mod_pedidos_local_${user.uid}', modPed);
          if (modCat != null) await prefs.setString('ultima_mod_categorias_local_${user.uid}', modCat);
        }
        await _cargar();
      } catch (e) {
        debugPrint("Error forzando descarga inicial en Principal: $e");
      }
    } else {
      _sincronizarSoloSiHayCambios();
    }
  }

  void _aplicarFiltro() {
    setState(() {
      if (_estaBuscando && _searchCtrl.text.isNotEmpty) {
        filtrados = productos
            .where((p) => p['nombre']
                .toString()
                .toLowerCase()
                .contains(_searchCtrl.text.toLowerCase()))
            .toList();
      } else {
        filtrados = productos;
      }
    });
  }

  Future<void> _cambiarLogo() async {
    if (_procesandoImagen) return;
    if (!_esPremium) {
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => const PantallaPremium()));
      return;
    }
    setState(() => _procesandoImagen = true);
    try {
      await Permission.photos.request();
      final XFile? image = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 400,
          maxHeight: 400,
          imageQuality: 70);
      if (image != null) {
        final bytes = await image.readAsBytes();
        String base64 = base64Encode(bytes);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('logo_path', base64);
        setState(() {
          _logoPath = base64;
          _logoImageCached = MemoryImage(bytes); // 🔥 Guardamos en el caché de memoria
        });
        if (FirebaseAuth.instance.currentUser != null) {
          await ServicioNube.actualizarPerfilNegocioNube(
              _nombreNegocio, base64);
        }
      }
    } finally {
      setState(() => _procesandoImagen = false);
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
                  minimumSize: const Size(double.infinity, 40)),
              onPressed: () {
                Navigator.pop(ctx);
                ServicioRespaldo.exportarBaseDeDatos(context);
              },
              icon: const Icon(Icons.download, color: Colors.white, size: 18),
              label: const Text("CREAR COPIA LOCAL",
                  style: TextStyle(color: Colors.white, fontSize: 11))),
          const SizedBox(height: 8),
          ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amberAccent,
                  minimumSize: const Size(double.infinity, 40)),
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const PantallaPremium()));
              },
              icon: const Icon(Icons.stars, color: Colors.black, size: 18),
              label: const Text("SUBIR A PRO (NUBE) 👑",
                  style: TextStyle(
                      color: Colors.black,
                      fontSize: 11,
                      fontWeight: FontWeight.bold))),
          const Divider(color: Colors.white12),
          TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _confirmarSalidaFinal();
              },
              child: const Text("SALIR Y BORRAR TODO",
                  style: TextStyle(color: Colors.redAccent, fontSize: 11))),
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
              final user = FirebaseAuth.instance.currentUser;
              final prefs = await SharedPreferences.getInstance();
              if (user != null) {
                await prefs.remove("descarga_completa_${user.uid}");
                await prefs.remove('ultima_mod_productos_local_${user.uid}');
                await prefs.remove('ultima_mod_pedidos_local_${user.uid}');
                debugPrint("🗑️ Banderas eliminadas para el usuario ${user.uid}");
              }
              Navigator.pop(ctx);
              if (!_esPremium) {
                await DBHelper.instance.limpiarTablas();
                await prefs.remove('datos_descargados');
              }
              await ServicioAuth.cerrarSesion();
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

  void _actualizarCarrito(Map<String, dynamic> p, int cambio,
      {String? cartId, Map<String, dynamic>? variantData}) {
    setState(() {
      String uniqueId = cartId ?? p['id'].toString();
      int idx = carrito.indexWhere(
          (i) => (i['cart_id'] ?? i['id'].toString()) == uniqueId);
      if (idx == -1 && cambio > 0) {
        carrito.add({
          ...p,
          'cart_id': uniqueId,
          'cantidad': cambio,
          if (variantData != null) ...variantData
        });
      } else if (idx != -1) {
        carrito[idx]['cantidad'] += cambio;
        if (carrito[idx]['cantidad'] <= 0) carrito.removeAt(idx);
      }
    });
  }

  Future<bool> _confirmarRegresoBienvenida() async {
    bool salir = false;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("¿Volver al Inicio?"),
        content: const Text("Se guardará tu carrito actual."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("CANCELAR")),
          ElevatedButton(
              onPressed: () {
                salir = true;
                Navigator.pop(ctx);
              },
              child: const Text("SÍ, VOLVER")),
        ],
      ),
    );
    return salir;
  }

  Future<void> _moverProductoACategoria(int productoId, String? nuevaCategoria) async {
    final db = await DBHelper.instance.database;
    await db.update('productos', {'categoria': nuevaCategoria}, where: 'id = ?', whereArgs: [productoId]);

    if (_esPremium && FirebaseAuth.instance.currentUser != null) {
      FirebaseFirestore.instance.collection('usuarios').doc(FirebaseAuth.instance.currentUser!.uid)
        .collection('productos').doc(productoId.toString())
        .set({'categoria': nuevaCategoria, 'ultima_modificacion': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    }
    _cargar();
  }

  Future<void> _cambiarEstadoCategoria(int idCat, bool activo) async {
    final db = await DBHelper.instance.database;
    int val = activo ? 1 : 0;
    await db.update('categorias', {'activo': val, 'ultima_modificacion': DateTime.now().toIso8601String()}, where: 'id = ?', whereArgs: [idCat]);

    if (_esPremium && FirebaseAuth.instance.currentUser != null) {
      FirebaseFirestore.instance.collection('usuarios').doc(FirebaseAuth.instance.currentUser!.uid)
        .collection('categorias').doc(idCat.toString())
        .set({'activo': val, 'ultima_modificacion': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    }
    _cargar();
  }

  Future<void> _eliminarCategoria(int idCat, String nombreCat) async {
    final db = await DBHelper.instance.database;
    await db.delete('categorias', where: 'id = ?', whereArgs: [idCat]);
    await db.rawUpdate('UPDATE productos SET categoria = NULL WHERE categoria = ?', [nombreCat]);

    if (_esPremium && FirebaseAuth.instance.currentUser != null) {
      String uid = FirebaseAuth.instance.currentUser!.uid;
      WriteBatch batch = FirebaseFirestore.instance.batch();
      batch.delete(FirebaseFirestore.instance.collection('usuarios').doc(uid).collection('categorias').doc(idCat.toString()));
      // Limpiar nube sin leer (solo escribimos nulo en los productos afectados)
      for (var p in productos.where((p) => p['categoria'] == nombreCat)) {
         batch.set(FirebaseFirestore.instance.collection('usuarios').doc(uid).collection('productos').doc(p['id'].toString()),
          {'categoria': null, 'ultima_modificacion': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      }
      batch.commit();
    }
    _cargar();
  }

  Future<void> _guardarOrdenCategorias() async {
    final db = await DBHelper.instance.database;
    Batch batch = db.batch();
    for (int i = 0; i < categorias.length; i++) {
      categorias[i]['orden'] = i;
      batch.update('categorias', {'orden': i}, where: 'id = ?', whereArgs: [categorias[i]['id']]);
    }
    await batch.commit(noResult: true);
    
    if (_esPremium && FirebaseAuth.instance.currentUser != null) {
      WriteBatch batchNube = FirebaseFirestore.instance.batch();
      String uid = FirebaseAuth.instance.currentUser!.uid;
      for (var c in categorias) {
        batchNube.set(FirebaseFirestore.instance.collection('usuarios').doc(uid).collection('categorias').doc(c['id'].toString()), 
          {'orden': c['orden'], 'ultima_modificacion': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      }
      batchNube.commit();
    }
  }

  void _confirmarSacarDeCategoria(Map<String, dynamic> p) {
    String? catNombre = p['categoria'];
    if (catNombre == null) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: const Text("Sacar de categoría", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        content: Text("¿Deseas sacar el producto \"${p['nombre']}\" de la categoría \"$catNombre\"?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx), 
            child: const Text("CANCELAR", style: TextStyle(color: Colors.grey))
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            onPressed: () {
              Navigator.pop(ctx);
              _moverProductoACategoria(p['id'], null); // Pasa la categoría a nulo (Sin categoría)
            },
            child: const Text("SÍ, SACAR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          )
        ],
      )
    );
  }

  void _mostrarDialogoAnadirProductosExistentes(String categoriaNombre) {
    List<int> seleccionados = [];
    TextEditingController searchCtrl = TextEditingController();
    String busqueda = "";

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStateDialog) {
          final isOscuro = Theme.of(context).brightness == Brightness.dark;
          
          // Filtrar productos: que no tengan categoría Y que coincidan con la búsqueda
          final prodsDisponibles = productos.where((p) {
            bool sinCat = p['categoria'] == null;
            bool coincideBusqueda = p['nombre'].toString().toLowerCase().contains(busqueda.toLowerCase());
            return sinCat && coincideBusqueda;
          }).toList();

          return AlertDialog(
            backgroundColor: Theme.of(context).cardColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
            contentPadding: const EdgeInsets.all(20),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Añadir a $categoriaNombre", style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                const SizedBox(height: 15),
                // 🔥 BARRA DE BÚSQUEDA MODERNA
                TextField(
                  controller: searchCtrl,
                  onChanged: (v) => setStateDialog(() => busqueda = v),
                  style: TextStyle(fontSize: 14, color: isOscuro ? Colors.white : Colors.black),
                  decoration: InputDecoration(
                    hintText: "Buscar producto...",
                    hintStyle: const TextStyle(fontSize: 14, color: Colors.grey),
                    prefixIcon: const Icon(Icons.search, color: Colors.grey),
                    suffixIcon: busqueda.isNotEmpty 
                      ? IconButton(
                          icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                          onPressed: () {
                            searchCtrl.clear();
                            setStateDialog(() => busqueda = "");
                          },
                        ) 
                      : null,
                    filled: true,
                    fillColor: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade100,
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(15),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              // Limitamos la altura para que el teclado no colapse el modal
              height: MediaQuery.of(context).size.height * 0.45, 
              child: prodsDisponibles.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.inventory_2_outlined, size: 50, color: Colors.grey.shade400),
                          const SizedBox(height: 10),
                          Text(
                            busqueda.isNotEmpty ? "No se encontraron coincidencias" : "No hay productos disponibles para añadir.", 
                            textAlign: TextAlign.center, 
                            style: const TextStyle(color: Colors.grey, fontSize: 13)
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: prodsDisponibles.length,
                      itemBuilder: (context, idx) {
                        final p = prodsDisponibles[idx];
                        final isSel = seleccionados.contains(p['id']);
                        final String fotoPath = p['foto_path']?.toString() ?? "";
                        final double precioVenta = (p['precio_venta'] as num).toDouble();

                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: isSel 
                                ? (isOscuro ? Colors.cyanAccent.withOpacity(0.1) : Colors.blue.withOpacity(0.05))
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(
                              color: isSel 
                                  ? (isOscuro ? Colors.cyanAccent : Colors.blue) 
                                  : (isOscuro ? Colors.white10 : Colors.grey.shade200)
                            )
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            onTap: () {
                              setStateDialog(() {
                                if (isSel) {
                                  seleccionados.remove(p['id']);
                                } else {
                                  seleccionados.add(p['id']);
                                }
                              });
                            },
                            // 🔥 MINIATURA DE IMAGEN
                            leading: Container(
                              width: 45, height: 45,
                              decoration: BoxDecoration(
                                color: isOscuro ? Colors.black26 : Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: fotoPath.isEmpty
                                  ? const Icon(Icons.image, color: Colors.grey, size: 20)
                                  : (fotoPath.length > 500
                                      ? Image.memory(base64Decode(fotoPath), fit: BoxFit.cover, gaplessPlayback: true)
                                      : Image.file(File(fotoPath), fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_,__,___) => const Icon(Icons.broken_image, size: 20))),
                            ),
                            title: Text(
                              p['nombre'], 
                              style: TextStyle(fontSize: 13, fontWeight: isSel ? FontWeight.bold : FontWeight.w600),
                              maxLines: 2, overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              "\$${precioVenta.toStringAsFixed(0)}", 
                              style: TextStyle(fontSize: 11, color: isOscuro ? Colors.greenAccent : Colors.green, fontWeight: FontWeight.bold)
                            ),
                            trailing: Checkbox(
                              activeColor: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
                              checkColor: isOscuro ? Colors.black : Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                              value: isSel,
                              onChanged: (val) {
                                setStateDialog(() {
                                  if (val == true) seleccionados.add(p['id']);
                                  else seleccionados.remove(p['id']);
                                });
                              },
                            ),
                          ),
                        );
                      },
                    ),
            ),
            actionsPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx), 
                child: const Text("CANCELAR", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold))
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isOscuro ? Colors.cyanAccent.shade700 : const Color(0xFF0D47A1), 
                  foregroundColor: isOscuro ? Colors.black : Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)
                ),
                onPressed: seleccionados.isEmpty ? null : () async {
                  Navigator.pop(ctx);
                  final db = await DBHelper.instance.database;
                  
                  // Mostrar un indicador de carga si son muchos
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Añadiendo productos..."), duration: Duration(milliseconds: 500)));

                  Batch batchLocal = db.batch();
                  for (int pid in seleccionados) {
                    batchLocal.update('productos', {'categoria': categoriaNombre}, where: 'id = ?', whereArgs: [pid]);
                  }
                  await batchLocal.commit(noResult: true);

                  if (_esPremium && FirebaseAuth.instance.currentUser != null) {
                    WriteBatch batch = FirebaseFirestore.instance.batch();
                    String uid = FirebaseAuth.instance.currentUser!.uid;
                    for (int pid in seleccionados) {
                      batch.set(FirebaseFirestore.instance.collection('usuarios').doc(uid).collection('productos').doc(pid.toString()),
                        {'categoria': categoriaNombre, 'ultima_modificacion': FieldValue.serverTimestamp()}, SetOptions(merge: true));
                    }
                    await batch.commit();
                  }
                  _cargar(); // Refresca la pantalla principal
                },
                // 🔥 INDICADOR DE CANTIDAD DINÁMICO
                child: Text(
                  seleccionados.isEmpty ? "AÑADIR" : "AÑADIR (${seleccionados.length})", 
                  style: const TextStyle(fontWeight: FontWeight.w900)
                ),
              ),
            ],
          );
        }
      )
    );
  }

  void _mostrarModalCrearCategoria({Map<String, dynamic>? categoriaAEditar}) {
    TextEditingController nombreCtrl = TextEditingController(text: categoriaAEditar != null ? categoriaAEditar['nombre'] : "");
    List<int> prodsSeleccionados = [];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStateDialog) {
          final isOscuro = Theme.of(context).brightness == Brightness.dark;
          return AlertDialog(
            backgroundColor: Theme.of(context).cardColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text(categoriaAEditar == null ? "Crear Categoría" : "Editar Categoría", style: const TextStyle(fontWeight: FontWeight.bold)),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nombreCtrl,
                    autofocus: true,
                    style: TextStyle(color: isOscuro ? Colors.white : Colors.black),
                    decoration: InputDecoration(
                      labelText: "Nombre de la categoría",
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))
                    ),
                  ),
                  const SizedBox(height: 15),
                  if (categoriaAEditar == null && productos.any((p) => p['categoria'] == null)) ...[
                    const Align(alignment: Alignment.centerLeft, child: Text("Añadir productos:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                    const SizedBox(height: 5),
                    Flexible(
                      child: Container(
                        decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(10)),
                        child: ListView(
                          shrinkWrap: true,
                          children: productos.where((p) => p['categoria'] == null).map((p) {
                            return CheckboxListTile(
                              title: Text(p['nombre'], style: const TextStyle(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                              value: prodsSeleccionados.contains(p['id']),
                              onChanged: (v) => setStateDialog(() { if (v == true) prodsSeleccionados.add(p['id']); else prodsSeleccionados.remove(p['id']); }),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ]
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0D47A1), foregroundColor: Colors.white),
                onPressed: () async {
                  String n = nombreCtrl.text.trim();
                  if (n.isEmpty) return;
                  final db = await DBHelper.instance.database;
                  
                  if (categoriaAEditar == null) {
                    // 🔥 LÓGICA MAGISTRAL: Empuja las demás hacia abajo y crea la nueva en orden 0 (Arriba)
                    final allCats = await db.query('categorias', orderBy: 'orden ASC');
                    Batch batchLocal = db.batch();
                    for (int i = 0; i < allCats.length; i++) {
                      batchLocal.update('categorias', {'orden': i + 1}, where: 'id = ?', whereArgs: [allCats[i]['id']]);
                    }
                    await batchLocal.commit(noResult: true);

                    int catId = await db.insert('categorias', {'nombre': n, 'activo': 1, 'orden': 0, 'ultima_modificacion': DateTime.now().toIso8601String()});
                    for (int pid in prodsSeleccionados) await db.update('productos', {'categoria': n}, where: 'id = ?', whereArgs: [pid]);
                    
                    if (_esPremium && FirebaseAuth.instance.currentUser != null) {
                      WriteBatch batch = FirebaseFirestore.instance.batch();
                      String uid = FirebaseAuth.instance.currentUser!.uid;
                      
                      batch.set(FirebaseFirestore.instance.collection('usuarios').doc(uid).collection('categorias').doc(catId.toString()),
                        {'id': catId, 'nombre': n, 'activo': 1, 'orden': 0, 'ultima_modificacion': FieldValue.serverTimestamp()}, SetOptions(merge: true));
                      
                      for (var c in allCats) {
                        batch.set(
                          FirebaseFirestore.instance.collection('usuarios').doc(uid).collection('categorias').doc(c['id'].toString()),
                          {'orden': (c['orden'] as int? ?? 0) + 1}, 
                          SetOptions(merge: true),
                        );
                      }

                      for (int pid in prodsSeleccionados) {
                        batch.set(FirebaseFirestore.instance.collection('usuarios').doc(uid).collection('productos').doc(pid.toString()),
                          {'categoria': n, 'ultima_modificacion': FieldValue.serverTimestamp()}, SetOptions(merge: true));
                      }
                      await batch.commit();
                    }
                  } else {
                    String nombreAntiguo = categoriaAEditar['nombre'];
                    await db.update('categorias', {'nombre': n, 'ultima_modificacion': DateTime.now().toIso8601String()}, where: 'id = ?', whereArgs: [categoriaAEditar['id']]);
                    await db.rawUpdate('UPDATE productos SET categoria = ? WHERE categoria = ?', [n, nombreAntiguo]);
                    
                    if (_esPremium && FirebaseAuth.instance.currentUser != null) {
                      WriteBatch batch = FirebaseFirestore.instance.batch();
                      String uid = FirebaseAuth.instance.currentUser!.uid;
                      batch.set(FirebaseFirestore.instance.collection('usuarios').doc(uid).collection('categorias').doc(categoriaAEditar['id'].toString()),
                        {'nombre': n, 'ultima_modificacion': FieldValue.serverTimestamp()}, SetOptions(merge: true));
                      for (var p in productos.where((p) => p['categoria'] == nombreAntiguo)) {
                         batch.set(FirebaseFirestore.instance.collection('usuarios').doc(uid).collection('productos').doc(p['id'].toString()),
                          {'categoria': n, 'ultima_modificacion': FieldValue.serverTimestamp()}, SetOptions(merge: true));
                      }
                      await batch.commit();
                    }
                  }
                  if(mounted) Navigator.pop(ctx);
                  _cargar();
                },
                child: Text(categoriaAEditar == null ? "CREAR" : "GUARDAR")
              )
            ],
          );
        }
      )
    );
  }

  void _mostrarAgradecimiento() {
    const correo = "Revisordecuenta@gmail.com";
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          const Icon(Icons.favorite, color: Colors.redAccent),
          const SizedBox(width: 8),
          Text("Usuario Premium",
              style:
                  TextStyle(color: isOscuro ? Colors.white : Colors.black))
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Gracias por tu apoyo querido usuario Premium 🙌\n\nSugerencias o problemas:",
              style: TextStyle(
                  color: isOscuro ? Colors.white70 : Colors.black87),
            ),
            const SizedBox(height: 15),
            InkWell(
              onTap: () {
                Clipboard.setData(const ClipboardData(text: correo));
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Correo copiado 📋")));
              },
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: isOscuro
                        ? Colors.white.withOpacity(0.05)
                        : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: isOscuro
                            ? Colors.white10
                            : Colors.transparent)),
                child: Row(children: [
                  Icon(Icons.email,
                      size: 18,
                      color:
                          isOscuro ? Colors.cyanAccent : Colors.black54),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(correo,
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                              color:
                                  isOscuro ? Colors.white : Colors.black))),
                  Icon(Icons.copy,
                      size: 16,
                      color: isOscuro ? Colors.white38 : Colors.grey)
                ]),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text("CERRAR",
                  style: TextStyle(
                      color: isOscuro
                          ? Colors.cyanAccent
                          : const Color(0xFF0D47A1),
                      fontWeight: FontWeight.bold)))
        ],
      ),
    );
  }

  // 🔥 Nuevo método asíncrono que carga datos completos y muestra el modal
  void _mostrarDetalleProducto(Map<String, dynamic> p_parcial) async {
    final db = await DBHelper.instance.database;
    final res = await db.query('productos', where: 'id = ?', whereArgs: [p_parcial['id']]);
    if (res.isEmpty || !mounted) return;
    final p = res.first; // Tenemos el producto completo con su foto gigante

    double precioOriginal = (p['precio_venta'] as num?)?.toDouble() ?? 0.0;
    double costo = (p['precio_compra'] as num?)?.toDouble() ?? 0.0;
    double descPct = (p['descuento'] as num?)?.toDouble() ?? 0.0;
    double precioFinal = precioOriginal - (precioOriginal * (descPct / 100));
    bool generaPerdida = descPct > 0 && precioFinal < costo;
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    String fotoPath = p['foto_path']?.toString() ?? "";
    String nombreProd = p['nombre']?.toString() ?? "Producto sin nombre";
    String descProd = p['descripcion']?.toString() ?? "";

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  fotoPath.length > 500
                      ? GestureDetector(
                          onTap: () => _ampliarImagen(context, fotoPath, nombreProd),
                          child: Container(
                            color: Colors.black, 
                            width: double.infinity,
                            height: 280,
                            child: Image.memory(base64Decode(fotoPath), fit: BoxFit.contain),
                          ),
                        )
                      : Container(height: 250, width: double.infinity, color: isOscuro ? Colors.white10 : Colors.grey.shade200, child: const Icon(Icons.image, size: 60, color: Colors.grey)),
                  if (descPct > 0)
                    Positioned(
                      top: 15, left: 15,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(10)),
                        child: Text("OFERTA -${descPct.toStringAsFixed(0)}%", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          // 🔥 TOQUE PARA COPIAR TÍTULO
                          child: GestureDetector(
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: nombreProd));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text("Nombre del producto copiado 📋"), duration: Duration(seconds: 1)),
                              );
                            },
                            child: Tooltip(
                              message: "Toca para copiar",
                              child: Text(nombreProd, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: isOscuro ? Colors.white : Colors.black)),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.share, size: 28, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)),
                          onPressed: () => _compartirProducto(p),
                        ),
                      ],
                    ),
                    const SizedBox(height: 15),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (descPct > 0) ...[
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("Precio Original", style: TextStyle(fontSize: 11, color: isOscuro ? Colors.white54 : Colors.grey)),
                              Text("\$${precioOriginal.toStringAsFixed(0)}", 
                                style: const TextStyle(fontSize: 16, color: Colors.red, decoration: TextDecoration.lineThrough, fontWeight: FontWeight.w600)),
                            ],
                          ),
                          const SizedBox(width: 20),
                        ],
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(descPct > 0 ? "Precio con Descuento" : "Precio de Venta", 
                              style: TextStyle(fontSize: 11, color: isOscuro ? Colors.white54 : Colors.grey)),
                            Text("\$${precioFinal.toStringAsFixed(0)}", 
                              style: TextStyle(
                                fontSize: 28, 
                                color: descPct > 0 
                                  ? (isOscuro ? Colors.greenAccent : Colors.green) 
                                  : (isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)), 
                                fontWeight: FontWeight.w900
                              )),
                          ],
                        ),
                      ],
                    ),
                    if (generaPerdida)
                      Container(
                        margin: const EdgeInsets.only(top: 15),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.red.withOpacity(0.3))),
                        child: Row(
                          children: [
                            const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 20),
                            const SizedBox(width: 8),
                            const Expanded(child: Text("Este descuento genera pérdidas.", style: TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold))),
                          ],
                        ),
                      ),
                    const SizedBox(height: 25),
                    Text("Descripción (Toca para copiar):", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: isOscuro ? Colors.blue.shade200 : Colors.blueGrey)),
                    const SizedBox(height: 8),
                    // 🔥 TOQUE PARA COPIAR DESCRIPCIÓN
                    GestureDetector(
                      onTap: () {
                        if (descProd.trim().isNotEmpty) {
                          Clipboard.setData(ClipboardData(text: descProd));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text("Descripción copiada 📋"), duration: Duration(seconds: 1)),
                          );
                        }
                      },
                      child: Tooltip(
                        message: "Toca para copiar",
                        child: Text(
                          descProd.trim().isNotEmpty 
                              ? descProd 
                              : "No hay descripción disponible.",
                          style: TextStyle(fontSize: 15, color: isOscuro ? Colors.white70 : Colors.black87, height: 1.4),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isOscuro ? Colors.white12 : const Color(0xFF0D47A1), 
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)), 
                    padding: const EdgeInsets.symmetric(vertical: 15)
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: Text("CERRAR", style: TextStyle(color: isOscuro ? Colors.white70 : Colors.white, fontWeight: FontWeight.bold)),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _compartirProducto(Map<String, dynamic> p) async {
    try {
      String nombre = p['nombre']?.toString() ?? "Producto";
      String descripcion = p['descripcion']?.toString() ?? "";
      String imgData = p['foto_path']?.toString() ?? "";
      
      String text = "*$nombre*\n";
      if (descripcion.trim().isNotEmpty) {
        text += "\n📝 $descripcion\n";
      }
      
      double precioOriginal = (p['precio_venta'] as num?)?.toDouble() ?? 0.0;
      double descPct = (p['descuento'] as num?)?.toDouble() ?? 0.0;
      double precioFinal = precioOriginal - (precioOriginal * (descPct / 100));

      if (descPct > 0) {
        text += "\n❌ Antes: ~\$${precioOriginal.toStringAsFixed(0)}~";
        text += "\n🔥 *AHORA: \$${precioFinal.toStringAsFixed(0)}* (-${descPct.toStringAsFixed(0)}%)";
      } else {
        text += "\n💰 *Precio: \$${precioFinal.toStringAsFixed(0)}*";
      }

      final db = await DBHelper.instance.database;
      final List<Map<String, dynamic>> fotosDb = await db.query(
        'fotos_variantes',
        where: 'producto_id = ?',
        whereArgs: [p['id']],
      );

      List<String> fotosSeleccionadasBase64 = [];
      bool procederACompartir = true;
      bool? compartirSeleccion;

      if (fotosDb.isNotEmpty && mounted) {
        // 1. FILTRAR DUPLICADOS EN MEMORIA PARA EVITAR REPETIDOS
        final Set<String> seenPhotos = {};
        final List<Map<String, dynamic>> fotosFiltradas = [];
        for (var f in fotosDb) {
          final String base64Str = f['foto_base64'] as String? ?? '';
          if (base64Str.isNotEmpty && !seenPhotos.contains(base64Str)) {
            seenPhotos.add(base64Str);
            fotosFiltradas.add(f);
          }
        }

        // 2. PRE-DECODIFICAR IMÁGENES UNA SOLA VEZ PARA ELIMINAR EL PARPADEO COMPLETAMENTE
        final List<Uint8List> decodedBytesList = [];
        for (var f in fotosFiltradas) {
          decodedBytesList.add(base64Decode(f['foto_base64'] as String));
        }

        final Map<int, bool> seleccionadas = {};
        for (int i = 0; i < fotosFiltradas.length; i++) {
          seleccionadas[i] = true; // Todo seleccionado por defecto
        }

        // Diálogo refinado
        compartirSeleccion = await showDialog<bool?>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => StatefulBuilder(
            builder: (context, setSt) {
              final isOscuro = Theme.of(context).brightness == Brightness.dark;
              return AlertDialog(
                backgroundColor: Theme.of(context).cardColor,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                title: const Text("Compartir fotos de variantes", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                content: SizedBox(
                  width: double.maxFinite,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: fotosFiltradas.length,
                    itemBuilder: (c, idx) {
                      final f = fotosFiltradas[idx];
                      final String nombreVar = f['variante_nombre']?.toString() ?? 'Variante';
                      return CheckboxListTile(
                        activeColor: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
                        secondary: Container(
                          width: 40, height: 40,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: Colors.grey.shade300),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Image.memory(
                            decodedBytesList[idx], // USA EL LOGOTIPO PRE-DECODIFICADO (Cero parpadeos)
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          ),
                        ),
                        title: Text(nombreVar, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        value: seleccionadas[idx] ?? false,
                        onChanged: (val) {
                          setSt(() => seleccionadas[idx] = val ?? false);
                        },
                      );
                    },
                  ),
                ),
                actions: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isOscuro ? Colors.cyanAccent.shade700 : const Color(0xFF0D47A1),
                          shape: const StadiumBorder(),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: () => Navigator.pop(ctx, true), // Compartir selección
                        child: Text("COMPARTIR CON VARIANTES", style: TextStyle(color: isOscuro ? Colors.black : Colors.white, fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false), // Sólo foto principal
                        child: const Text("SÓLO FOTO PRINCIPAL", style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, null), // CANCELA TODO EL FLUJO
                        child: const Text("CANCELAR", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  )
                ],
              );
            },
          ),
        );

        if (compartirSeleccion == null) {
          // El usuario presionó CANCELAR, abortamos todo de inmediato.
          procederACompartir = false;
        } else if (compartirSeleccion == true) {
          seleccionadas.forEach((idx, seleccionado) {
            if (seleccionado) {
              fotosSeleccionadasBase64.add(fotosFiltradas[idx]['foto_base64'] as String);
            }
          });
        }
      }

      if (!procederACompartir) return; // Detiene la ejecución si se canceló

      List<XFile> files = [];
      final tempDir = Directory.systemTemp; 

      // 🔥 EXCLUSIÓN ESTRICTA: Separamos la compilación de archivos según la selección del usuario
      if (compartirSeleccion == false) {
        // Opción A: Solo compartimos la foto principal
        if (imgData.isNotEmpty) {
          if (imgData.length > 500) {
            final bytes = base64Decode(imgData);
            final file = File('${tempDir.path}/prod_share_${p['id']}.png');
            await file.writeAsBytes(bytes);
            files.add(XFile(file.path));
          } else if (File(imgData).existsSync()) {
            files.add(XFile(imgData));
          }
        }
      } else {
        // Opción B: Compartimos exclusivamente las variantes seleccionadas (sin la principal)
        for (int i = 0; i < fotosSeleccionadasBase64.length; i++) {
          try {
            final bytes = base64Decode(fotosSeleccionadasBase64[i]);
            final file = File('${tempDir.path}/var_share_${p['id']}_$i.png');
            await file.writeAsBytes(bytes);
            files.add(XFile(file.path));
          } catch (e) {
            debugPrint("Error escribiendo foto variante temporal: $e");
          }
        }
      }

      if (files.isNotEmpty) {
        await Share.shareXFiles(files, text: text);
      } else {
        await Share.share(text);
      }
    } catch (e) {
      debugPrint("Error al compartir: $e");
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Error al compartir el producto")));
    }
  }

  @override
  Widget build(BuildContext context) {
    bool esHorizontal = MediaQuery.of(context).orientation == Orientation.landscape;
    double total = carrito.fold(0, (sum, i) => sum + (i['precio_venta'] * i['cantidad']));
    List<int> listaActual = esHorizontal ? _colsHorizontal : _colsVertical;
    int columnasActuales = listaActual[_columnasIndex % listaActual.length];
    User? user = FirebaseAuth.instance.currentUser;
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _confirmarRegresoBienvenida() && mounted) {
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const PantallaBienvenida()));
        }
      },
      child: Stack( // 🔥 Envolvemos el Scaffold en un Stack para poder superponer el modal
        children: [
          Scaffold(
            resizeToAvoidBottomInset: !_estaBuscando, 
            appBar: AppBar(backgroundColor: isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1),
              titleSpacing: 0,
              leading: widget.esAdmin ? null : IconButton(
                icon: const Icon(Icons.arrow_back), 
                onPressed: () async {
                  if (await _confirmarRegresoBienvenida()) {
                    if(mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const PantallaBienvenida()));
                  }
                }
              ),
              title: _estaBuscando 
                ? Padding(
                    padding: const EdgeInsets.only(left: 15),
                    child: TextField(
                      controller: _searchCtrl, 
                      autofocus: true, 
                      decoration: const InputDecoration(hintText: 'Buscar...', border: InputBorder.none, hintStyle: TextStyle(color: Colors.white70)), 
                      style: const TextStyle(color: Colors.white), 
                      onChanged: (v) => _aplicarFiltro()
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children:[
                        const Icon(Icons.home_rounded, color: Colors.white, size: 22),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            widget.esAdmin ? 'Inicio' : 'Ventas', 
                            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              actions: [
                if (widget.esAdmin)
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 35),
                    icon: Icon(Icons.share, size: 22, color: _esPremium ? Colors.greenAccent : Colors.white70),
                    tooltip: "Compartir Catálogo Web",
                    onPressed: _compartirCatalogo,
                  ),
                IconButton(
                  icon: Icon(_estaBuscando ? Icons.close : Icons.search), 
                  onPressed: () => setState(() { 
                    _estaBuscando = !_estaBuscando; // Al darle close, esto pasa a false
                    if (!_estaBuscando) {
                      _searchCtrl.clear();
                      _aplicarFiltro();
                    }
                  })
                ),
                if (_esPremium) 
                  InkWell(
                    onTap: _mostrarAgradecimiento,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(border: Border.all(color: Colors.amberAccent), borderRadius: BorderRadius.circular(8), color: Colors.amber.withOpacity(0.2)),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children:[
                          Icon(Icons.stars, color: Colors.amberAccent, size: 14), 
                          SizedBox(width: 4), 
                          Text("PREMIUM", style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 10))
                        ]
                      ),
                    ),
                  )
                else 
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 35),
                    icon: const Icon(Icons.stars, color: Colors.white70, size: 22), 
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PantallaPremium()))
                  ),
                IconButton(
                  padding: const EdgeInsets.only(right: 8, left: 4),
                  constraints: const BoxConstraints(minWidth: 35),
                  icon: Icon(columnasActuales == 1 ? Icons.view_stream : Icons.grid_view_rounded, size: 22), 
                  onPressed: () => setState(() => _columnasIndex = (_columnasIndex + 1) % 4)
                ),
              ],
            ),
            drawer: widget.esAdmin ? _buildDrawer(user) : null,
            
            body: SafeArea(
              child: esHorizontal 
                ? Row(
                    children:[
                      Expanded(flex: 7, child: _construirVistaProductos(columnasActuales, esHorizontal)),
                      Container(width: 1, color: Colors.grey[300]),
                      Expanded(
                        flex: 3, 
                        child: Column(
                          children: [
                            Expanded(child: _buildCarritoUI(total, esHorizontal)),
                            _buildPieCarrito(),
                          ],
                        )
                      ),
                    ]
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      double alturaPie = 180.0; // Aproximado del pie con botones
                      double alturaBarra = 20.0;
                      double espacioDisponible = constraints.maxHeight;
                      double alturaRenderCarrito = _alturaCarrito;
                      if (espacioDisponible < (_alturaCarrito + alturaPie + 50)) {
                        alturaRenderCarrito = (espacioDisponible - alturaPie - alturaBarra - 20).clamp(0, _alturaCarrito);
                      }

                      return Column(
                        children:[
                          Expanded(
                            child: Stack(
                              children: [
                                Container(
                                  color: Theme.of(context).scaffoldBackgroundColor,
                                  child: _construirVistaProductos(columnasActuales, esHorizontal),
                                ),
                              ],
                            ),
                          ),
                          if (espacioDisponible > 300)
                            GestureDetector(
                              behavior: HitTestBehavior.opaque, // ← evita que se "escape" el toque
                              onVerticalDragUpdate: (details) {
                                setState(() {
                                  double maxAllowedH = constraints.maxHeight - 220.0;
                                  // Aplicamos resistencia cuando está en los extremos
                                  double nuevaAltura = _alturaCarrito - details.delta.dy;
                                  if (nuevaAltura < _minAltura) {
                                    nuevaAltura = _minAltura; // tope duro en 0
                                  } else if (nuevaAltura > maxAllowedH) {
                                    nuevaAltura = maxAllowedH; // tope duro en máximo
                                  }
                                  _alturaCarrito = nuevaAltura;
                                });
                              },
                              onVerticalDragEnd: (details) {
                                // Snap: si está muy cerca de 0, cierra del todo; si está muy cerca del max, abre del todo
                                double maxAllowedH = constraints.maxHeight - 220.0;
                                setState(() {
                                  if (_alturaCarrito < 40) _alturaCarrito = _minAltura;
                                  if (_alturaCarrito > maxAllowedH - 40) _alturaCarrito = maxAllowedH;
                                });
                              },
                              child: Container(
                                width: double.infinity,
                                height: 20,
                                color: isOscuro ? Colors.white10 : const Color.fromARGB(54, 2, 159, 238),
                                child: Center(
                                  child: Container(
                                    width: 50,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: isOscuro ? Colors.white24 : const Color.fromARGB(59, 12, 2, 32),
                                      borderRadius: BorderRadius.circular(10)
                                    )
                                  ),
                                ),
                              ),
                            ),
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 120), // ← suaviza el movimiento final
                              curve: Curves.easeOut,
                              height: alturaRenderCarrito,
                              child: _buildCarritoUI(total, esHorizontal)
                            ),
                          _buildPieCarrito(),
                        ],
                      );
                    }
                  ),
            ),
          ),
          
          // 🔥 Si _mostrarModalNombre es true, se dibuja por encima del Scaffold
          if (_mostrarModalNombre) _buildModalNombre(),
        ],
      ),
    );
  }

  Widget _tile(IconData i, String t, Widget s, {int badgeCount = 0, Color badgeColor = Colors.red}) {
    return ListTile(
      leading: Icon(i, color: const Color(0xFF0D47A1)), 
      title: Text(t, style: const TextStyle(fontSize: 13)), 
      trailing: badgeCount > 0 
        ? Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: badgeColor, shape: BoxShape.circle),
            child: Text('$badgeCount', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
          )
        : null,
      onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => s)).then((_) => _cargar()); }
    );
  }

  Widget _buildDrawer(User? user) {
    return Drawer(
      child: Column(
        children: [
          Container(
            color: const Color(0xFF041E42),
            child: SafeArea(
              bottom: false,
              child: Container( // 🔥 Quitamos el InkWell de aquí
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 15),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center, 
                  children:[
                    // 🔥 InkWell SOLO en la bolita del logo
                    InkWell(
                      onTap: _cambiarLogo,
                      borderRadius: BorderRadius.circular(50),
                      child: AnimatedBuilder(
                        animation: ModalRoute.of(context) != null ? const AlwaysStoppedAnimation(0) : const AlwaysStoppedAnimation(0),
                        builder: (context, child) => child!,
                        child: _LogoAnimado(logoProv: _logoImageCached), // 🔥 Usamos el caché de memoria para evitar parpadeo
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text("Toca la imagen para cambiarla", textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 9)),
                    const SizedBox(height: 10),
                    
                    // 🔥 InkWell para editar el nombre del negocio
                    InkWell(
                      onTap: _abrirModalEditar,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  _nombreNegocio.toUpperCase(), 
                                  textAlign: TextAlign.center, 
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(Icons.edit, color: Colors.white54, size: 14), // Lapicito
                          ],
                        ),
                      ),
                    ),

                    if (user != null) ...[
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          user.email ?? "", 
                          textAlign: TextAlign.center, 
                          style: TextStyle(
                            color: _esPremium ? Colors.amberAccent : Colors.white54, 
                            fontWeight: _esPremium ? FontWeight.bold : FontWeight.normal,
                            fontSize: 11
                          )
                        ),
                      ),
                    ],
                  ]
                ),
              ),
            ),
          ),
          
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero, 
              children:[
                _tile(Icons.inventory, 'Inventario', const PantallaInventario(), badgeCount: _badgeInventario, badgeColor: Colors.red),
                _tile(Icons.people, 'Vendedores', const PantallaVendedores()),
                _tile(Icons.person_search, 'Clientes', const PantallaClientes()),
                _tile(Icons.receipt_long, 'Gestión Pedidos', const PantallaGestionPedidos(), badgeCount: _badgePedidos, badgeColor: Colors.blue),
                _tile(Icons.bar_chart, 'Finanzas y Reportes', const PantallaPresupuestos()),             
                ValueListenableBuilder<ThemeMode>(
                  valueListenable: ServicioTema.modoTema,
                  builder: (context, modo, _) {
                    bool oscuro = modo == ThemeMode.dark;
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      decoration: BoxDecoration(
                        color: oscuro 
                            ? Colors.white.withOpacity(0.08) 
                            : Colors.white.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(color: Colors.white.withOpacity(0.08)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                        Icon(
                          oscuro ? Icons.dark_mode : Icons.light_mode,
                          color: oscuro ? Colors.amber : Colors.blueGrey,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            oscuro ? "Modo Oscuro" : "Modo Claro",
                            style: TextStyle(
                              color: oscuro ? Colors.white : Colors.black87,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Switch(
                          value: oscuro,
                          onChanged: (v) => ServicioTema.alternar(v),
                          activeColor: Colors.amber,
                          inactiveTrackColor: Colors.grey.shade300,
                        ),
                        ],
                      ),
                    );
                  },
                ),
                const Divider(),
                ListTile(
                  leading: Icon(Icons.share, color: _esPremium ? Colors.green : Colors.orange), 
                  title: Row(
                    children:[
                      const Text("Mi Catálogo Web", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      if (!_esPremium) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: Colors.orange.withOpacity(0.2), borderRadius: BorderRadius.circular(5)),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children:[
                              Icon(Icons.lock_outline, size: 10, color: Colors.orange),
                              SizedBox(width: 2),
                              Text("PRO", style: TextStyle(color: Colors.orange, fontSize: 9, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        )
                      ]
                    ],
                  ),
                  onTap: () { Navigator.pop(context); _compartirCatalogo(); }
                ),
                ListTile(leading: const Icon(Icons.backup, color: Colors.teal), title: const Text("Crear copia de seguridad", style: TextStyle(fontSize: 13)), onTap: () { Navigator.pop(context); ServicioRespaldo.exportarBaseDeDatos(context); }),
                ListTile(leading: const Icon(Icons.restore, color: Colors.orange), title: const Text("Cargar copia de seguridad", style: TextStyle(fontSize: 13)), onTap: () { Navigator.pop(context); ServicioRespaldo.importarBaseDeDatos(context, _cargar); }),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.home_work_rounded, color: Color(0xFF0D47A1)), 
                  title: const Text('Volver al Inicio', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)), 
                  onTap: () async { 
                    if (await _confirmarRegresoBienvenida()) {
                      if(mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const PantallaBienvenida())); 
                    }
                  }
                ),
                ListTile(leading: const Icon(Icons.power_settings_new, color: Colors.red), title: const Text("Cerrar Sesión", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 13)), onTap: _gestionarCierreSesion),
                const SizedBox(height: 10),
              ]
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCarritoUI(double total, bool esHorizontal) {
    List<Map<String, dynamic>> carritoOrdenado = List.from(carrito);
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark; // Variable detectada
    carritoOrdenado.sort((a, b) {
      if (a['es_domicilio'] == true) return 1;
      if (b['es_domicilio'] == true) return -1;
      return 0;
    });
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor, 
      child: Column(children:[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: isOscuro ? Colors.white.withOpacity(0.05) : Colors.blue.shade50.withOpacity(0.1),
          child: Row(children:[
            Icon(
              Icons.shopping_cart_outlined, 
              size: 18, 
              color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)
            ),
            const SizedBox(width: 6),
            Text(
              'CARRITO', 
              style: TextStyle(
                fontWeight: FontWeight.bold, 
                color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)
              )
            ),
            const Spacer(),
            if (widget.esAdmin && _cantidadSolicitudes > 0)
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orangeAccent, 
                  foregroundColor: Colors.white, 
                  minimumSize: const Size(0, 30), 
                  shape: const StadiumBorder()
                ),
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PantallaSolicitudes())),
                icon: const Icon(Icons.inbox, size: 14),
                label: Text("$_cantidadSolicitudes WEB", style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
              ),
          ]),
        ),
        Expanded(
          child: ClipRect(
            child: carrito.isEmpty 
            ? const Center(
              child: FittedBox( // ← evita overflow cuando la altura es ~0
                child: Text('Vacío', style: TextStyle(color: Colors.grey)),
              ),
            ) 
            
            : ListView.separated(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
              itemCount: carritoOrdenado.length,
              separatorBuilder: (c, i) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final item = carritoOrdenado[i];
                String idCartKey = item['cart_id'].toString();
                double precioBase = (item['precio_venta'] as num).toDouble();
                bool esDom = item['es_domicilio'] == true;
                double desc = esDom ? 0 : (_aplicarDescuentoGlobal ? _descuentoGlobalPct : (item['descuento'] ?? 0).toDouble());
                double precioFinal = precioBase - (precioBase * (desc / 100));
                final Color colorPrecioCarrito = isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1);
                Widget campoEdicionManual() => SizedBox(
                  width: 45,
                  child: TextFormField(
                    key: ValueKey("edit_${idCartKey}_${item['cantidad']}"),
                    initialValue: "${item['cantidad']}",
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: FontWeight.w900, 
                      fontSize: 15, 
                      color: isOscuro ? Colors.white : Colors.black
                    ),
                    decoration: const InputDecoration(border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero),
                    onFieldSubmitted: (v) {
                      int? nueva = int.tryParse(v);
                      if (nueva != null && nueva >= 1) {
                        int diferencia = nueva - (item['cantidad'] as int);
                        _actualizarCarrito(item, diferencia, cartId: idCartKey);
                      }
                    },
                  ),
                );
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: esHorizontal 
                  ? Column( // --- VISTA HORIZONTAL ---
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item['nombre'], style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : Colors.black), maxLines: 2),
                        Text(
                          desc > 0 
                            ? "(-${_formatDesc(desc)}%) \$${precioFinal.toStringAsFixed(0)}" 
                            : "\$${precioBase.toStringAsFixed(0)}", 
                          style: TextStyle(color: colorPrecioCarrito, fontSize: 11, fontWeight: FontWeight.bold) // ✅ CORREGIDO
                        ),
                        const SizedBox(height: 5),
                        if (!esDom)
                          Row(children: [
                            _btnCant(Icons.remove_circle, Colors.red, () => _actualizarCarrito(item, -1, cartId: idCartKey)),
                            campoEdicionManual(),
                            _btnCant(Icons.add_circle, Colors.green, () => _actualizarCarrito(item, 1, cartId: idCartKey)),
                            const Spacer(),
                            IconButton(icon: const Icon(Icons.delete_outline, size: 18, color: Colors.grey), onPressed: () => setState(() => carrito.removeWhere((x) => x['cart_id'] == idCartKey))),
                          ])
                        else
                          Align(alignment: Alignment.centerRight, child: IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: () => setState(() => carrito.removeWhere((x) => x['es_domicilio'] == true)))),
                      ],
                    )
                  : Row( // --- VISTA VERTICAL ---
                      children:[
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children:[
                          Text(item['nombre'], style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : Colors.black)),
                          Text(
                            desc > 0 
                              ? "(-${_formatDesc(desc)}%) \$${precioFinal.toStringAsFixed(0)}" 
                              : "\$${precioBase.toStringAsFixed(0)}", 
                            style: TextStyle(color: colorPrecioCarrito, fontSize: 11, fontWeight: FontWeight.bold)
                          ),
                        ])),
                        if (esDom)
                          IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: () => setState(() => carrito.removeWhere((x) => x['es_domicilio'] == true)))
                        else
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            _btnCant(Icons.remove_circle, Colors.red, () => _actualizarCarrito(item, -1, cartId: idCartKey)),
                            campoEdicionManual(),
                            _btnCant(Icons.add_circle, Colors.green, () => _actualizarCarrito(item, 1, cartId: idCartKey)),
                            const SizedBox(width: 5),
                            _btnCant(Icons.delete_outline, Colors.grey, () => setState(() => carrito.removeWhere((x) => x['cart_id'] == idCartKey))),
                          ])
                      ],
                    ),
                );
              },
            ),
        ),
        ),
      ]),
    );
  }

  String _formatDesc(double pct) => pct == pct.roundToDouble() 
    ? pct.toStringAsFixed(0) 
    : pct.toStringAsFixed(1);

  Widget _btnCant(IconData icon, Color color, VoidCallback onTap) => 
    IconButton(icon: Icon(icon, size: 22, color: color), onPressed: onTap, constraints: const BoxConstraints(), padding: const EdgeInsets.all(4));

  Widget _buildPieCarrito() {
    double totalCalculado = carrito.fold(0, (sum, i) {
      double precio = (i['precio_venta'] as num).toDouble();
      bool esDom = i['es_domicilio'] == true;
      double desc = esDom ? 0 : (_aplicarDescuentoGlobal ? _descuentoGlobalPct : (i['descuento'] ?? 0).toDouble());
      double precioFinal = precio - (precio * (desc / 100));
      return sum + (precioFinal * (i['cantidad'] as num).toDouble());
    });
    return Container(
      padding: const EdgeInsets.all(12), 
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: const Border(top: BorderSide(color: Colors.black12)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, -2))]
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children:[
        Row(children: [
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _aplicarDescuentoGlobal ? Colors.red.shade100 : Colors.orange.shade50,
                foregroundColor: _aplicarDescuentoGlobal ? Colors.red : Colors.orange.shade900,
                elevation: 0, side: BorderSide(color: _aplicarDescuentoGlobal ? Colors.red : Colors.orange),
                shape: const StadiumBorder(),
              ),
              icon: const Icon(Icons.percent, size: 14), 
              label: Text(_aplicarDescuentoGlobal ? "G. Activo" : "Descuento", style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)), 
              onPressed: () => _mostrarDialogoDescuento()
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade50, foregroundColor: Colors.blue.shade900,
                elevation: 0, side: const BorderSide(color: Colors.blue),
                shape: const StadiumBorder(),
              ),
              icon: const Icon(Icons.motorcycle, size: 14), 
              label: const Text("Domicilio/envío", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)), 
              onPressed: () => _mostrarDialogoDomicilio()
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children:[
          const Text('TOTAL:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.blueGrey)),
          Text('\$${totalCalculado.toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.w900, color: Color.fromARGB(255, 52, 193, 57), fontSize: 20))
        ]),
        const SizedBox(height: 10),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF0D47A1), 
            minimumSize: const Size(double.infinity, 50), 
            elevation: 3,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))
          ),
          onPressed: carrito.isEmpty ? null : () => _validarYProcesarVenta(totalCalculado),
          child: const Text('PROCESAR VENTA', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
        )
      ]),
    );
  }

  void _mostrarDialogoDomicilio() {
    TextEditingController domCtrl = TextEditingController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final isOscuro =
            Theme.of(ctx).brightness == Brightness.dark;

        return AnimatedPadding(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: MediaQuery.of(ctx).viewInsets +
              const EdgeInsets.all(20),
          child: Center(
            child: Material(
              color: Theme.of(ctx).cardColor,
              borderRadius: BorderRadius.circular(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 450,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [

                        /// TITULO
                        Row(
                          children: [
                            Icon(
                              Icons.motorcycle,
                              color: isOscuro
                                  ? Colors.cyanAccent
                                  : Colors.blue,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                "Añadir Domicilio/envío",
                                style: TextStyle(
                                  fontSize: 28,
                                  color: isOscuro
                                      ? Colors.white
                                      : Colors.black,
                                ),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 25),

                        /// CAMPO
                        TextField(
                          controller: domCtrl,
                          autofocus: true,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: "Valor del domicilio",
                            prefixText: "\$ ",
                            border: OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.circular(10),
                            ),
                          ),
                        ),

                        const SizedBox(height: 25),

                        /// BOTONES
                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () {
                                Navigator.pop(ctx);
                              },
                              child: const Text("CANCELAR"),
                            ),
                            const SizedBox(width: 10),
                            ElevatedButton(
                              onPressed: () {
                                double val =
                                    double.tryParse(
                                            domCtrl.text) ??
                                        0;

                                if (val > 0) {
                                  setState(() {
                                    carrito.removeWhere(
                                        (i) =>
                                            i['es_domicilio'] ==
                                            true);

                                    carrito.add({
                                      'id': -1,
                                      'cart_id':
                                          'domicilio',
                                      'nombre':
                                          'Domicilio',
                                      'precio_venta':
                                          val,
                                      'cantidad': 1,
                                      'es_domicilio':
                                          true,
                                      'descuento':
                                          0.0,
                                    });
                                  });
                                }

                                Navigator.pop(ctx);
                              },
                              child: const Text("AÑADIR"),
                            ),
                          ],
                        )
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
  void _mostrarDialogoDescuento() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _DialogoDescuentoCart(
        carritoActual: carrito,
        globalInicial: _aplicarDescuentoGlobal,
        pctInicial: _descuentoGlobalPct,
        onAplicar: (individuales, global, pct) {
          setState(() {
            _aplicarDescuentoGlobal = global;
            _descuentoGlobalPct = pct;
            if (!global && individuales.isNotEmpty) {
              List<Map<String, dynamic>> nuevoCarrito = [];         
              for (var item in carrito) {
                var discData = individuales.firstWhere(
                  (d) => d['cart_id'] == item['cart_id'], 
                  orElse: () => {}
                );
                if (discData.isNotEmpty) {
                  int qtyOriginal = item['cantidad'];
                  int qtyDesc = discData['qty'];
                  double pctDesc = discData['desc'];
                  if (qtyDesc < qtyOriginal) {
                    item['cantidad'] = qtyOriginal - qtyDesc;
                    nuevoCarrito.add(item);
                    var itemConDesc = Map<String, dynamic>.from(item);
                    itemConDesc['cantidad'] = qtyDesc;
                    itemConDesc['descuento'] = pctDesc;
                    itemConDesc['cart_id'] = "${item['cart_id']}_desc_$pctDesc"; 
                    nuevoCarrito.add(itemConDesc);
                  } else {
                    item['descuento'] = pctDesc;
                    nuevoCarrito.add(item);
                  }
                } else {
                  nuevoCarrito.add(item);
                }
              }
              carrito = nuevoCarrito;
            }
          });
        },
      ),
    );
  }
  
  Widget _construirFotoConEtiqueta(Map<String, dynamic> p, int columnas) {
    double descPct = (p['descuento'] ?? 0).toDouble();
    String fotoPath = p['foto_path']?.toString() ?? ""; // 🔥 Extraído directo de la RAM
    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: Stack(
        fit: StackFit.expand, 
        children: [
          _foto(p['id'], fotoPath), // 🔥 Pasamos la ruta de una vez
          if (descPct > 0)
            Positioned(
              top: 8,
              left: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: const BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.only(topRight: Radius.circular(10), bottomRight: Radius.circular(10)),
                  boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4)]
                ),
                child: Text(
                  '-${_formatDesc(descPct)}%',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _foto(int id, String data) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    if (data.isEmpty) {
      return Container(color: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade100, child: const Icon(Icons.image, color: Colors.grey, size: 30));
    }
    
    try {
      if (data.length > 500) {
        _fotoCache[id] = base64Decode(data);
        return Image.memory(_fotoCache[id]!, fit: BoxFit.cover, width: double.infinity, height: double.infinity, gaplessPlayback: true, errorBuilder: (c,e,s) => const Icon(Icons.broken_image));
      }
      final file = File(data);
      if (file.existsSync()) return Image.file(file, fit: BoxFit.cover, width: double.infinity, height: double.infinity, gaplessPlayback: true, errorBuilder: (c,e,s) => const Icon(Icons.broken_image));
    } catch (e) {}
    
    return const Icon(Icons.broken_image, color: Colors.red);
  }

  void _detenerArrastreGlobal() {
    _dragTimer?.cancel();
    _autoScrollTimer?.cancel();
    _isDragging = false;
  }

  Widget _construirVistaProductos(int columnas, bool esHorizontal) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    if (productos.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(25.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.inventory_2_rounded, size: 75, color: isOscuro ? Colors.white24 : Colors.blueGrey.withOpacity(0.3)),
              const SizedBox(height: 20),
              Text("¡Hola! Empieza a crear tus productos desde la sección de inventario", textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white70 : Colors.black54)),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: isOscuro ? Colors.cyanAccent.shade700 : const Color(0xFF0D47A1), foregroundColor: isOscuro ? Colors.black : Colors.white, padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14)),
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PantallaInventario())).then((_) => _cargar()),
                icon: const Icon(Icons.add_shopping_cart_rounded), label: const Text("IR A INVENTARIO", style: TextStyle(fontWeight: FontWeight.w900)),
              ),
            ],
          ),
        ),
      );
    }

    if (filtrados.isEmpty) return const Center(child: Text('Sin productos'));

    Map<String, List<Map<String, dynamic>>> grupos = {'_sin_categoria': []};
    for (var cat in categorias) grupos[cat['nombre']] = [];
    
    for (var p in filtrados) {
      String? cat = p['categoria'];
      if (cat != null && grupos.containsKey(cat)) grupos[cat]!.add(p);
      else grupos['_sin_categoria']!.add(p);
    }

    Widget construirTarjeta(BuildContext context, Map<String, dynamic> p) {
      bool select = carrito.any((item) => item['id'] == p['id']);
      double precioOriginal = (p['precio_venta'] as num).toDouble();
      double desc = (p['descuento'] ?? 0).toDouble();
      double precioFinal = precioOriginal - (precioOriginal * (desc / 100));
      
      // Modo remover activo para este bloque de categoría
      bool modoSacarActivo = p['categoria'] != null && _categoriasEnModoEliminacion.contains(p['categoria']);

      return Card(
        key: ValueKey(p['id']),
        elevation: select ? 8 : 2,
        clipBehavior: Clip.antiAlias,
        color: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: select ? (isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)) : Colors.transparent, width: 1.5)),
        child: Stack(
          children: [
            InkWell(
              onTap: () {
                List<dynamic> gruposVariantes = [];
                if (p['variantes'] != null && p['variantes'].toString().length > 5) {
                  try {
                    var dec = jsonDecode(p['variantes']);
                    if (dec.isNotEmpty && !dec[0].containsKey('grupo')) gruposVariantes = [{'grupo': 'Opciones', 'opciones': dec}];
                    else gruposVariantes = dec;
                  } catch (e) {}
                }
                if (gruposVariantes.isNotEmpty) {
                  showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent, builder: (_) => _DialogoVariantes(
                      producto: p, gruposVariantes: gruposVariantes,
                      onAceptar: (cantidades) { cantidades.forEach((key, qty) { if (qty > 0) {
                          List<String> partes = key.split('_'); int gIdx = int.parse(partes[0]); int oIdx = int.parse(partes[1]);
                          var o = gruposVariantes[gIdx]['opciones'][oIdx];
                          _actualizarCarrito(p, qty, cartId: "${p['id']}_$key", variantData: {'nombre': "${p['nombre']} - ${o['nombre']}", 'es_variante': true, 'g_index': gIdx, 'o_index': oIdx, 'stock_real': o['stock']});
                      }});}));
                } else _actualizarCarrito(p, 1, cartId: p['id'].toString());
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch, 
                children: [
                  Expanded(child: _construirFotoConEtiqueta(p, columnas)), 
                  Padding(padding: const EdgeInsets.all(4.0), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text(p['nombre'], style: TextStyle(fontWeight: FontWeight.bold, fontSize: columnas >= 5 ? 9 : 12), maxLines: 3, overflow: TextOverflow.ellipsis),
                      if (desc > 0) Text('\$$precioOriginal', style: TextStyle(color: isOscuro ? Colors.redAccent.shade100 : Colors.red, fontSize: 10, decoration: TextDecoration.lineThrough)),
                      Text('\$${precioFinal.toStringAsFixed(0)}', style: TextStyle(color: desc > 0 ? (isOscuro ? Colors.greenAccent : Colors.green) : (isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)), fontWeight: FontWeight.bold, fontSize: columnas >= 5 ? 9 : 13)),
                  ])),
                ],
              ),
            ),
            
            Positioned(
              top: 5, right: 5,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 🔥 Si el modo "sacar" está activo para esta categoría, se dibuja la "X"
                  if (widget.esAdmin && modoSacarActivo)
                    InkWell(
                      onTap: () => _confirmarSacarDeCategoria(p),
                      child: Container(
                        margin: const EdgeInsets.only(right: 5),
                        padding: const EdgeInsets.all(6),
                        decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle),
                        child: const Icon(Icons.close_rounded, color: Colors.white, size: 16),
                      ),
                    ),
                  InkWell(
                    onTap: () => _mostrarDetalleProducto(p),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
                      child: const Icon(Icons.remove_red_eye, color: Colors.white, size: 16),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    bool mostrarBanner = widget.esAdmin && _mostrarAvisoReorganizar;

    int offsetTopItems = 0;
    if (mostrarBanner) offsetTopItems++;
    if (widget.esAdmin) offsetTopItems++;

    return Listener(
      onPointerDown: (e) {
        _startPos = e.position;
        _dragTimer = Timer(const Duration(milliseconds: 350), () => _isDragging = true);
      },
      onPointerMove: (e) {
        if (!_isDragging && _startPos != null) {
          if ((e.position - _startPos!).distance > 15) _dragTimer?.cancel();
        }
        if (_isDragging) {
          double y = e.position.dy;
          double h = MediaQuery.of(context).size.height;
          double edge = 150.0;
          
          if (y < edge) { // Scroll Hacia Arriba
            if (_autoScrollTimer == null || !_autoScrollTimer!.isActive) {
              _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
                if (_mainScroll.hasClients) {
                  _mainScroll.jumpTo((_mainScroll.offset - 10).clamp(0.0, _mainScroll.position.maxScrollExtent));
                }
              });
            }
          } else if (y > h - edge) { // Scroll Hacia Abajo
            if (_autoScrollTimer == null || !_autoScrollTimer!.isActive) {
              _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
                if (_mainScroll.hasClients) {
                  _mainScroll.jumpTo((_mainScroll.offset + 10).clamp(0.0, _mainScroll.position.maxScrollExtent));
                }
              });
            }
          } else {
            _autoScrollTimer?.cancel();
          }
        }
      },
      onPointerUp: (e) => _detenerArrastreGlobal(),
      onPointerCancel: (e) => _detenerArrastreGlobal(),
      child: ReorderableListView(
        scrollController: _mainScroll,
        physics: const BouncingScrollPhysics(),
        buildDefaultDragHandles: false,
        onReorder: (oldIndex, newIndex) {
          if (oldIndex < offsetTopItems || newIndex < offsetTopItems) return;
          if (oldIndex >= offsetTopItems + categorias.length) return;
          
          if (newIndex > oldIndex) newIndex -= 1;

          int oldCatIdx = oldIndex - offsetTopItems;
          int newCatIdx = newIndex - offsetTopItems;

          if (newCatIdx >= categorias.length) newCatIdx = categorias.length - 1;

          setState(() {
            final cat = categorias.removeAt(oldCatIdx);
            categorias.insert(newCatIdx, cat);
          });
          _guardarOrdenCategorias();
        },
        children: [
          if (mostrarBanner)
            Container(
              key: const ValueKey('banner_info'),
              width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
              color: isOscuro ? Colors.white.withOpacity(0.05) : Colors.blueGrey.shade50,
              child: Row(
                children: [
                  const Icon(Icons.touch_app, size: 14, color: Colors.blueGrey), const SizedBox(width: 8),
                  const Expanded(child: Text("Mantén presionado para reordenar productos o arrastrar categorías.", style: TextStyle(fontSize: 11, color: Colors.blueGrey))),
                  InkWell(onTap: () => setState(() => _mostrarAvisoReorganizar = false), child: const Icon(Icons.close, size: 16, color: Colors.grey))
                ],
              ),
            ),

          if (widget.esAdmin)
            Padding(
              key: const ValueKey('btn_crear_cat'),
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: isOscuro ? Colors.white10 : Colors.blue.shade50, foregroundColor: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1), elevation: 0, side: BorderSide(color: isOscuro ? Colors.white24 : Colors.blue.shade200)),
                onPressed: () => _mostrarModalCrearCategoria(),
                icon: const Icon(Icons.create_new_folder), label: const Text("Crear Nueva Categoría", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),

          // 1. BLOQUES DE CATEGORÍAS
          ...categorias.asMap().entries.map((entry) {
            int idx = entry.key;
            var cat = entry.value;
            String nombre = cat['nombre'];
            bool isExpanded = categoriasExpandidas[nombre] ?? true;
            bool isActivo = cat['activo'] == 1;
            
            // Calculo hiper-preciso del índice para que no se desfase en el ReorderableListView
            int globalIndex = offsetTopItems + idx;
            bool removalMode = _categoriasEnModoEliminacion.contains(nombre);

            if (!widget.esAdmin && !isActivo) return SizedBox.shrink(key: ValueKey('cat_hide_${cat['id']}'));

            return Container(
              key: ValueKey('cat_${cat['id']}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 🔥 BANNER DE CATEGORÍA ULTRA COMPACTO (Da prioridad al texto)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      // 🔥 Cambiado de Colors.white a un tono azul-grisáceo suave en modo claro
                      color: isOscuro ? const Color.fromARGB(255, 33, 40, 63) : const Color.fromARGB(84, 168, 209, 251), 
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        if (!isOscuro) 
                          BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8, offset: const Offset(0, 3))
                      ],
                      // 🔥 Borde celeste fino en modo claro para enmarcar el banner perfectamente
                      border: Border.all(color: isOscuro ? const Color.fromARGB(213, 49, 162, 227) : const Color.fromARGB(255, 103, 153, 234)), 
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      child: Row(
                        children: [
                          Icon(isExpanded ? Icons.folder_open_rounded : Icons.folder_rounded, color: isActivo ? (isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)) : Colors.grey, size: 26),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              nombre, 
                              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: isActivo ? (isOscuro ? Colors.white : Colors.black87) : Colors.grey),
                              maxLines: 2, // Límite elegante de 2 líneas
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (widget.esAdmin) ...[
                                // Switch empaquetado
                                SizedBox(
                                  height: 24,
                                  width: 38,
                                  child: Transform.scale(
                                    scale: 0.7, // Más pequeño
                                    child: Switch(
                                      value: isActivo, 
                                      activeColor: Colors.green, 
                                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap, 
                                      onChanged: (v) => _cambiarEstadoCategoria(cat['id'], v)
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                
                                // Menú empaquetado
                                SizedBox(
                                  width: 24,
                                  child: PopupMenuButton<String>(
                                    icon: const Icon(Icons.more_vert, color: Colors.grey, size: 22),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(), // Quita el margen obligatorio
                                    onSelected: (val) {
                                      if (val == 'edit') {
                                        _mostrarModalCrearCategoria(categoriaAEditar: cat);
                                      } else if (val == 'delete') {
                                        _eliminarCategoria(cat['id'], nombre);
                                      }
                                    },
                                    itemBuilder: (ctx) => [
                                      const PopupMenuItem(value: 'edit', child: Row(children: [Icon(Icons.edit, size: 16, color: Colors.orangeAccent), SizedBox(width: 8), Text("Editar", style: TextStyle(fontSize: 13))])),
                                      const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline, size: 16, color: Colors.redAccent), SizedBox(width: 8), Text("Eliminar", style: TextStyle(fontSize: 13))])),
                                    ],
                                  ),
                                ),
                              ],
                              
                              const SizedBox(width: 4),
                              
                              // Flecha colapsable empaquetada
                              InkWell(
                                onTap: () => setState(() => categoriasExpandidas[nombre] = !isExpanded),
                                borderRadius: BorderRadius.circular(15),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 6.0),
                                  child: Icon(isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: Colors.grey, size: 24),
                                ),
                              ),
                              
                              if (widget.esAdmin) ...[
                                const SizedBox(width: 2),
                                // 🔥 Arrastre empaquetado + Listener para cerrar todo
                                Listener(
                                  onPointerDown: (_) {
                                    setState(() {
                                      for (var c in categorias) {
                                        categoriasExpandidas[c['nombre']] = false;
                                      }
                                    });
                                  },
                                  child: ReorderableDragStartListener(
                                    index: globalIndex,
                                    child: const Padding(
                                      padding: EdgeInsets.only(left: 4.0, right: 2.0, top: 6.0, bottom: 6.0),
                                      child: Icon(Icons.swap_vert_rounded, color: Colors.grey, size: 24),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  if (isExpanded) ...[
                    if (grupos[nombre]!.isEmpty)
                      const Padding(padding: EdgeInsets.all(20), child: Center(child: Text("Sin productos", style: TextStyle(color: Colors.grey, fontSize: 12))))
                    else widget.esAdmin 
                      ? ReorderableGridView.builder(
                          key: PageStorageKey('grid_$nombre'),
                          physics: const NeverScrollableScrollPhysics(), shrinkWrap: true, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columnas, childAspectRatio: columnas == 1 ? 1.0 : 0.72, crossAxisSpacing: 8, mainAxisSpacing: 8),
                          itemCount: grupos[nombre]!.length,
                          onReorder: (oldIdx, newIdx) => _onReorderCategoria(grupos[nombre]!, oldIdx, newIdx),
                          itemBuilder: (ctx, i) => construirTarjeta(ctx, grupos[nombre]![i]),
                        )
                      : GridView.builder(
                          physics: const NeverScrollableScrollPhysics(), shrinkWrap: true, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columnas, childAspectRatio: columnas == 1 ? 1.0 : 0.72, crossAxisSpacing: 8, mainAxisSpacing: 8),
                          itemCount: grupos[nombre]!.length,
                          itemBuilder: (ctx, i) => construirTarjeta(ctx, grupos[nombre]![i]),
                        ),
                    
                    // 🔥 CONTROLES INLINE DE CADA CATEGORÍA (Añadir y Sacar integrados)
                    if (widget.esAdmin)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
                                  side: BorderSide(color: isOscuro ? Colors.white10 : Colors.grey.shade300),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                                onPressed: () => _mostrarDialogoAnadirProductosExistentes(nombre),
                                icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                                label: const Text("AÑADIR PRODUCTO", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: removalMode ? Colors.redAccent : Colors.grey,
                                  side: BorderSide(color: removalMode ? Colors.redAccent.withOpacity(0.5) : Colors.grey.shade300),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                                onPressed: () {
                                  setState(() {
                                    if (removalMode) {
                                      _categoriasEnModoEliminacion.remove(nombre);
                                    } else {
                                      _categoriasEnModoEliminacion.add(nombre);
                                    }
                                  });
                                },
                                icon: Icon(removalMode ? Icons.cancel_outlined : Icons.remove_circle_outline_rounded, size: 18),
                                label: Text(removalMode ? "CANCELAR" : "SACAR PRODUCTO", style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  
                  const SizedBox(height: 15),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Divider(
                      height: 1, 
                      thickness: 1.5, // 👈 Grosor aumentado para mayor presencia
                      // 🔥 Colores ajustados para que contrasten perfectamente
                      color: isOscuro ? Colors.white24 : Colors.grey.shade400, 
                    ),
                  ),
                  const SizedBox(height: 15),
                ],
              ),
            );
          }).toList(),
          // 2. PRODUCTOS SIN CATEGORÍA
          if (grupos['_sin_categoria']!.isNotEmpty)
            Container(
              key: const ValueKey('grid_sin_cat'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  widget.esAdmin 
                    ? ReorderableGridView.builder(
                        key: const PageStorageKey('rsincat'),
                        physics: const NeverScrollableScrollPhysics(), shrinkWrap: true, padding: const EdgeInsets.all(10),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columnas, childAspectRatio: columnas == 1 ? 1.0 : 0.72, crossAxisSpacing: 8, mainAxisSpacing: 8),
                        itemCount: grupos['_sin_categoria']!.length,
                        onReorder: (oldIdx, newIdx) => _onReorderCategoria(grupos['_sin_categoria']!, oldIdx, newIdx),
                        itemBuilder: (ctx, i) => construirTarjeta(ctx, grupos['_sin_categoria']![i]),
                      )
                    : GridView.builder(
                        physics: const NeverScrollableScrollPhysics(), shrinkWrap: true, padding: const EdgeInsets.all(10),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columnas, childAspectRatio: columnas == 1 ? 1.0 : 0.72, crossAxisSpacing: 8, mainAxisSpacing: 8),
                        itemCount: grupos['_sin_categoria']!.length,
                        itemBuilder: (ctx, i) => construirTarjeta(ctx, grupos['_sin_categoria']![i]),
                      ),
                  
                  const SizedBox(height: 15),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Divider(
                      height: 1, 
                      thickness: 1, 
                      color: isOscuro ? Colors.white.withOpacity(0.08) : Colors.grey.shade200
                    ),
                  ),
                  const SizedBox(height: 15),
                ],
              ),
            ),
            
          // 🔥 ANUNCIO DE VIDEO SILENCIADO (Nativo) - Solo para usuarios gratuitos
          if (!_esPremium && widget.esAdmin)
            const AnuncioNativoWidget(key: ValueKey('admob_native_ad_key')), // <-- Clave añadida

            const SizedBox(key: ValueKey('spacer_end'), height: 100),
        ],
      ),
    );
  }

  void _ampliarImagen(BuildContext context, dynamic imagenSource, String nombre) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(10),
        child: Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(15),
                child: imagenSource is Uint8List 
                  ? Image.memory(imagenSource, fit: BoxFit.contain)
                  : (imagenSource is String && imagenSource.length > 500 
                      ? Image.memory(base64Decode(imagenSource), fit: BoxFit.contain)
                      : Image.file(File(imagenSource), fit: BoxFit.contain)),
              ),
            ),
            Positioned(
              top: 10, right: 10,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 35),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
            Positioned(
              bottom: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                child: Text(nombre, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
  // 🔥 MÉTODOS PARA EDITAR EL NOMBRE
  void _abrirModalEditar() {
    setState(() {
      _nombreController.text = _nombreNegocio;
      _mostrarModalNombre = true;
    });
  }

  Widget _buildModalNombre() {
    return Scaffold(
      backgroundColor: Colors.black54,
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
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
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
                      if (n.isEmpty) n = "MI NEGOCIO";
                      final p = await SharedPreferences.getInstance();
                      await p.setString('nombre_negocio', n);
                      setState(() {
                        _nombreNegocio = n;
                        _mostrarModalNombre = false;
                      });
                      if (FirebaseAuth.instance.currentUser != null) {
                        await ServicioNube.actualizarPerfilNegocioNube(n, _logoPath);
                      }
                    },
                    child: const Text("GUARDAR",
                        style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _mostrarModalNombre = false),
                    child: const Text("CANCELAR", style: TextStyle(color: Colors.white24)),
                  )
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DialogoVariantes extends StatefulWidget {
  final Map<String, dynamic> producto;
  final List<dynamic> gruposVariantes;
  final Function(Map<String, int>) onAceptar;
  const _DialogoVariantes({required this.producto, required this.gruposVariantes, required this.onAceptar});
  @override
  State<_DialogoVariantes> createState() => _DialogoVariantesState();
}

class _DialogoVariantesState extends State<_DialogoVariantes> {
  final Map<String, int> _cantidades = {};
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, Uint8List> _bytesCache = {};
  @override
  void initState() {
    super.initState();
    for (int g = 0; g < widget.gruposVariantes.length; g++) {
      var opciones = widget.gruposVariantes[g]['opciones'] ?? [];
      for (int o = 0; o < opciones.length; o++) {
        String key = "${g}_$o"; 
        _cantidades[key] = 0;
        _controllers[key] = TextEditingController(text: "0");
        String foto = opciones[o]['foto_path']?.toString() ?? "";
        if (foto.length > 50) {
          try { _bytesCache[key] = base64Decode(foto); } catch(e) {}
        }
      }
    }
    Future<void> _cargarFotosDeDB() async {
      final db = await DBHelper.instance.database;
      final fotos = await db.query(
        'fotos_variantes',
        where: 'producto_id = ?',
        whereArgs: [widget.producto['id']],
      );
      for (var f in fotos) {
        String key = "${f['grupo_index']}_${f['opcion_index']}";
        try {
          _bytesCache[key] = base64Decode(f['foto_base64'] as String);
        } catch (_) {}
      }
      if (mounted) setState(() {});
    }
    _cargarFotosDeDB();
  }

  @override
  void dispose() {
    for (var ctrl in _controllers.values) ctrl.dispose();
    super.dispose();
  }

  void _updateQty(String key, int delta) {
    int current = _cantidades[key] ?? 0;
    int newQty = current + delta;
    if (newQty < 0) newQty = 0;
    setState(() {
      _cantidades[key] = newQty;
      _controllers[key]!.text = newQty.toString();
    });
  }

  void _ampliarImagen(BuildContext context, dynamic imagenSource, String nombre) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(10),
        child: Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(15),
                child: imagenSource is Uint8List 
                  ? Image.memory(imagenSource, fit: BoxFit.contain)
                  : (imagenSource is String && imagenSource.length > 500 
                      ? Image.memory(base64Decode(imagenSource), fit: BoxFit.contain)
                      : Image.file(File(imagenSource), fit: BoxFit.contain)),
              ),
            ),
            Positioned(
              top: 10, right: 10,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 35),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
            Positioned(
              bottom: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                child: Text(nombre, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isOscuro = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isOscuro ? const Color(0xFF1A1A2E) : Colors.white, 
        borderRadius: const BorderRadius.vertical(top: Radius.circular(25))
      ),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: isOscuro ? Colors.white24 : Colors.grey[300], borderRadius: BorderRadius.circular(10))),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              widget.producto['nombre'], 
              style: TextStyle(
                fontWeight: FontWeight.w900, 
                fontSize: 18, 
                color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)
              )
            ),
          ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.gruposVariantes.length,
                itemBuilder: (context, gIdx) {
                  var grupo = widget.gruposVariantes[gIdx];
                  List opciones = grupo['opciones'] ?? [];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(grupo['grupo'].toString().toUpperCase(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                      ),
                      ...opciones.asMap().entries.where((entry) => entry.value['activo'] != false).map((entry) {
                        int oIdx = entry.key;
                        var o = entry.value;
                        String key = "${gIdx}_$oIdx";
                        return ListTile(
                          key: ValueKey("tile_$key"),
                          leading: GestureDetector( // 🔥 AGREGADO
                            onTap: () {
                              if (_bytesCache.containsKey(key)) {
                                _ampliarImagen(context, _bytesCache[key], o['nombre']);
                              }
                            },
                            child: Stack( // Usamos stack para poner el icono de lupa
                              children: [
                                Container(
                                  width: 45, height: 45,
                                  decoration: BoxDecoration(
                                    color: Colors.grey[100], 
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: Colors.blue.shade100),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: _bytesCache.containsKey(key) 
                                    ? Image.memory(_bytesCache[key]!, fit: BoxFit.cover, gaplessPlayback: true)
                                    : const Icon(Icons.image, color: Colors.grey),
                                ),
                                if (_bytesCache.containsKey(key))
                                  Positioned(
                                    bottom: 0, right: 0,
                                    child: Container(
                                      decoration: const BoxDecoration(
                                        color: Colors.black45, 
                                        borderRadius: BorderRadius.only(topLeft: Radius.circular(5))
                                      ),
                                      child: const Icon(Icons.zoom_in, color: Colors.white, size: 12),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          title: Text(o['nombre'], 
                            style: TextStyle(
                              fontWeight: FontWeight.bold, 
                              fontSize: 14, 
                              color: isOscuro ? Colors.white : Colors.black87 // ✅ Corregido
                            )
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline, color: Colors.red), 
                                onPressed: () => _updateQty(key, -1),
                                constraints: const BoxConstraints(), padding: const EdgeInsets.all(8),
                              ),
                              SizedBox(
                                width: 40,
                                child: TextFormField(
                                  controller: _controllers[key],
                                  keyboardType: TextInputType.number,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                  decoration: const InputDecoration(isDense: true, border: InputBorder.none),
                                  onChanged: (v) => _cantidades[key] = int.tryParse(v) ?? 0,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.add_circle_outline, color: Colors.green), 
                                onPressed: () => _updateQty(key, 1),
                                constraints: const BoxConstraints(), padding: const EdgeInsets.all(8),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0D47A1), minimumSize: const Size(double.infinity, 50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))),
                onPressed: () { widget.onAceptar(_cantidades); Navigator.pop(context); },
                child: const Text("AÑADIR AL CARRITO", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      );
    }
  }

class PantallaSolicitudes extends StatefulWidget {
  const PantallaSolicitudes({super.key});
  @override
  State<PantallaSolicitudes> createState() => _PantallaSolicitudesState();
}

class _PantallaSolicitudesState extends State<PantallaSolicitudes> {
  bool _procesando = false;

  String _obtenerTiempoRestante(Timestamp? expireAt) {
    if (expireAt == null) return "Sin fecha";
    final DateTime fechaExp = expireAt.toDate();
    final Duration diferencia = fechaExp.difference(DateTime.now());
    if (diferencia.isNegative) return "Expirado";
    if (diferencia.inDays > 0) {
      return "Expira en ${diferencia.inDays} ${diferencia.inDays == 1 ? 'día' : 'días'}";
    } else if (diferencia.inHours > 0) {
      return "Expira en ${diferencia.inHours} h";
    } else {
      return "Expira en ${diferencia.inMinutes} min";
    }
  }

  // 🚀 LOGOTIPO DE WHATSAPP REALISTA Y COMPACTO
  Widget _buildWhatsAppIcon() {
    return Container(
      width: 18,
      height: 18,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      padding: const EdgeInsets.all(2),
      child: const Center(
        child: Icon(
          Icons.phone_rounded,
          size: 11,
          color: Color(0xFF25D366), 
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor, 
      appBar: AppBar(
        title: const Text("PEDIDOS WEB PENDIENTES", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        backgroundColor: isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
      ),
      body: Stack(
        children:[
          StreamBuilder(
            stream: FirebaseFirestore.instance
                .collection('solicitudes')
                .where('adminId', isEqualTo: user?.uid)
                .snapshots(),
            builder: (context, AsyncSnapshot<QuerySnapshot> snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children:[
                      Icon(Icons.inbox_rounded, size: 80, color: Colors.grey[300]),
                      const SizedBox(height: 15),
                      Text("Bandeja vacía", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.grey[400])),
                      const SizedBox(height: 5),
                      Text("No tienes nuevas solicitudes web", style: TextStyle(color: Colors.grey[500])),
                    ],
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 20, top: 10),
                itemCount: snapshot.data!.docs.length,
                itemBuilder: (context, index) {
                  var doc = snapshot.data!.docs[index];
                  var data = doc.data() as Map<String, dynamic>;
                  List prods = data['productos'] ??[];
                  String cliente = data['cliente']['nombre'] ?? 'Sin nombre';
                  String telefono = data['cliente']['telefono'] ?? '';
                  String ciudad = data['cliente']['ciudad'] ?? '';
                  String departamento = data['cliente']['departamento'] ?? '';
                  String totalTxt = "\$${data['total']}";
                  final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
                  
                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    elevation: 4,
                    color: isOscuro ? const Color(0xFF1E2230) : Colors.white,
                    shadowColor: isOscuro ? Colors.transparent : Colors.black12,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(
                        color: isOscuro ? Colors.white.withOpacity(0.08) : Colors.grey.shade200,
                        width: 1.5,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Theme(
                      data: Theme.of(context).copyWith(
                        dividerColor: Colors.transparent,
                        hoverColor: Colors.transparent,
                        splashColor: Colors.transparent,
                      ),
                      child: ExpansionTile(
                        tilePadding: const EdgeInsets.all(16), // Espaciado interno cómodo
                        backgroundColor: Colors.transparent,
                        // 🔥 MODIFICACIÓN CLAVE: Quitamos leading/subtitle y diseñamos la tarjeta
                        // de forma ancha y libre dentro del título del ExpansionTile
                        title: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // NIVEL 1: CABECERA DEL CLIENTE
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      colors: isOscuro 
                                          ? [Colors.cyanAccent, Colors.blueAccent] 
                                          : [const Color(0xFF0D47A1), Colors.blue],
                                    ),
                                  ),
                                  child: CircleAvatar(
                                    radius: 22,
                                    backgroundColor: isOscuro ? const Color(0xFF1E2230) : Colors.white,
                                    child: Icon(Icons.person_rounded, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1), size: 24),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        cliente, 
                                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: isOscuro ? Colors.white : Colors.black87, letterSpacing: 0.3)
                                      ),
                                      const SizedBox(height: 3),
                                      Row(
                                        children: [
                                          Icon(Icons.location_on_rounded, size: 13, color: isOscuro ? Colors.white60 : Colors.grey.shade600),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              "$ciudad ${departamento.isNotEmpty ? '- $departamento' : ''}",
                                              style: TextStyle(color: isOscuro ? Colors.white60 : Colors.grey.shade600, fontSize: 12, fontWeight: FontWeight.w500),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Divider(
                                height: 1, 
                                color: isOscuro ? Colors.white.withOpacity(0.06) : Colors.grey.shade200,
                              ),
                            ),

                            // NIVEL 2: TOTAL Y EXPIRACIÓN EN EXTREMOS
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      "TOTAL PEDIDO", 
                                      style: TextStyle(
                                        fontSize: 9, 
                                        fontWeight: FontWeight.w900, 
                                        color: isOscuro ? Colors.white38 : Colors.grey.shade500,
                                        letterSpacing: 0.5
                                      )
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      totalTxt, 
                                      style: TextStyle(color: isOscuro ? Colors.greenAccent : const Color(0xFF2E7D32), fontWeight: FontWeight.w900, fontSize: 20)
                                    ),
                                  ],
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Colors.orange.withOpacity(isOscuro ? 0.15 : 0.1),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: Colors.orange.withOpacity(0.3), width: 1)
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.access_time_filled_rounded, size: 12, color: Colors.orange),
                                      const SizedBox(width: 4),
                                      Text(
                                        _obtenerTiempoRestante(data['expireAt']),
                                        style: const TextStyle(color: Colors.orange, fontSize: 11, fontWeight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 12),

                            // NIVEL 3: TELÉFONO Y WHATSAPP EN EXTREMOS
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.phone_iphone_rounded, size: 14, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)),
                                    const SizedBox(width: 4),
                                    Text(
                                      "+$telefono",
                                      style: TextStyle(color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1), fontWeight: FontWeight.bold, fontSize: 13),
                                    ),
                                  ],
                                ),
                                if (telefono.isNotEmpty)
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF25D366),
                                      foregroundColor: Colors.white,
                                      elevation: 2,
                                      shadowColor: const Color(0xFF25D366).withOpacity(0.3),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      minimumSize: const Size(0, 32),
                                    ),
                                    onPressed: () => _abrirWhatsApp(telefono, data),
                                    icon: _buildWhatsAppIcon(), // 🔥 LOGOTIPO REAL
                                    label: const Text(
                                      "WhatsApp", 
                                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 0.5)
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                        children:[
                          Container(
                            decoration: BoxDecoration(
                              color: isOscuro ? Colors.black.withOpacity(0.2) : Colors.grey.shade50,
                              border: Border(
                                top: BorderSide(
                                  color: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade200,
                                  width: 1
                                )
                              )
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children:[
                                Row(
                                  children: [
                                    Icon(Icons.receipt_long_rounded, size: 14, color: isOscuro ? Colors.white38 : Colors.grey),
                                    const SizedBox(width: 6),
                                    Text("ARTÍCULOS DEL PEDIDO", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: isOscuro ? Colors.white38 : Colors.grey.shade600, letterSpacing: 0.5)),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                ...prods.map((p) {
                                  double precioOriginal = (p['precio_venta'] as num).toDouble();
                                  double descuento = (p['descuento'] ?? 0).toDouble();
                                  double precioFinal = (p['precio_final'] ?? (precioOriginal - (precioOriginal * (descuento / 100)))).toDouble();
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 12.0),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(color: isOscuro ? Colors.white10 : Colors.grey[200], borderRadius: BorderRadius.circular(6)),
                                          child: Text("x${p['cantidad']}", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: isOscuro ? Colors.white : Colors.black87)),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(p['nombre'], style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: isOscuro ? Colors.white.withOpacity(0.9) : Colors.black87)),
                                              if (descuento > 0)
                                                Padding(
                                                  padding: const EdgeInsets.only(top: 2),
                                                  child: Row(
                                                    children: [
                                                      Container(
                                                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                                        decoration: BoxDecoration(color: Colors.red.withOpacity(0.15), borderRadius: BorderRadius.circular(4)),
                                                        child: Text("-$descuento%", style: TextStyle(color: isOscuro ? Colors.redAccent : Colors.red.shade700, fontSize: 10, fontWeight: FontWeight.bold)),
                                                      ),
                                                      const SizedBox(width: 6),
                                                      Text("\$${precioOriginal.toStringAsFixed(0)}", 
                                                        style: TextStyle(fontSize: 11, color: isOscuro ? const Color(0xB3FFFFFF) : Colors.grey, decoration: TextDecoration.lineThrough)),
                                                    ],
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        Column(
                                          crossAxisAlignment: CrossAxisAlignment.end,
                                          children: [
                                            Text("\$${precioFinal.toStringAsFixed(0)}", 
                                              style: TextStyle(fontWeight: FontWeight.bold, color: descuento > 0 ? (isOscuro ? Colors.greenAccent : Colors.green.shade700) : (isOscuro ? Colors.white : Colors.black87), fontSize: 15)),
                                            Text("Subt: \$${(precioFinal * (p['cantidad'] as int)).toStringAsFixed(0)}", 
                                              style: TextStyle(fontSize: 10, color: isOscuro ? const Color(0xC7FFFFFF) : Colors.grey)),
                                          ],
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                                Divider(height: 25, color: isOscuro ? Colors.white.withOpacity(0.05) : Colors.black12),
                                Row(
                                  children:[
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: isOscuro ? Colors.redAccent : Colors.red,
                                          side: BorderSide(color: isOscuro ? Colors.redAccent.withOpacity(0.5) : Colors.red),
                                          padding: const EdgeInsets.symmetric(vertical: 14),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                                        ),
                                        onPressed: _procesando ? null : () => _rechazarSolicitud(doc.id),
                                        icon: const Icon(Icons.delete_outline_rounded),
                                        label: const Text("DESCARTAR", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: isOscuro ? Colors.greenAccent.shade700 : Colors.green, 
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(vertical: 14),
                                          elevation: 2,
                                          shadowColor: Colors.green.withOpacity(0.3),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                                        ),
                                        onPressed: _procesando ? null : () => _procesarYAceptar(doc.id, data),
                                        icon: const Icon(Icons.check_circle_outline_rounded),
                                        label: const Text("PROCESAR", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                                      ),
                                    ),
                                  ],
                                )
                              ],
                            ),
                          )
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
          if (_procesando)
            Container(
              color: Colors.white.withOpacity(0.7),
              child: const Center(child: CircularProgressIndicator(color: Color(0xFF0D47A1))),
            ),
        ],
      ),
    );
  }

  void _rechazarSolicitud(String docId) async {
    if (!mounted) return;
    setState(() => _procesando = true);
    try {
      await FirebaseFirestore.instance.collection('solicitudes').doc(docId).delete();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Solicitud eliminada"), backgroundColor: Colors.red)
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error al eliminar: $e"), backgroundColor: Colors.red)
      );
    } finally {
      if (mounted) setState(() => _procesando = false);
    }
  }

  void _procesarYAceptar(String docId, Map<String, dynamic> data) async {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    TextEditingController domCtrl = TextEditingController();
    TextEditingController descGlobalCtrl = TextEditingController();
    List prods = data['productos'] ?? [];
    Map<int, TextEditingController> descIndCtrls = {};
    for (int i = 0; i < prods.length; i++) {
      descIndCtrls[i] = TextEditingController();
    }
    bool esDescuentoGlobal = false;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          double domVal = double.tryParse(domCtrl.text) ?? 0;
          double pctGlobal = double.tryParse(descGlobalCtrl.text) ?? 0;
          double nuevoTotal = 0;
          return AlertDialog(
            backgroundColor: Theme.of(context).cardColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text("Ajustes del Pedido Web", 
              style: TextStyle(fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : Colors.black)),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: domCtrl,
                      keyboardType: TextInputType.number,
                      onChanged: (v) => setDialogState(() {}),
                      style: TextStyle(color: isOscuro ? Colors.white : Colors.black),
                      decoration: InputDecoration(
                        labelText: "Valor Domicilio",
                        labelStyle: TextStyle(color: isOscuro ? Colors.white60 : Colors.black54),
                        prefixIcon: Icon(Icons.motorcycle, color: isOscuro ? Colors.cyanAccent : Colors.blue),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 15),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: esDescuentoGlobal 
                            ? (isOscuro ? Colors.orange.withOpacity(0.1) : Colors.orange.shade50) 
                            : (isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade100),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: esDescuentoGlobal ? Colors.orange : (isOscuro ? Colors.white10 : Colors.grey.shade300))
                      ),
                      child: SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(esDescuentoGlobal ? "MODO: DESCUENTO GLOBAL" : "MODO: DESCUENTOS INDIVIDUALES", 
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: esDescuentoGlobal ? Colors.orange : Colors.grey)),
                        value: esDescuentoGlobal,
                        activeColor: Colors.orange,
                        onChanged: (v) => setDialogState(() => esDescuentoGlobal = v),
                      ),
                    ),
                    if (esDescuentoGlobal) ...[
                      const SizedBox(height: 15),
                      TextField(
                        controller: descGlobalCtrl,
                        keyboardType: TextInputType.number,
                        onChanged: (v) => setDialogState(() {}),
                        style: TextStyle(color: isOscuro ? Colors.white : Colors.black),
                        decoration: InputDecoration(
                          labelText: "Porcentaje Global (%)",
                          labelStyle: TextStyle(color: isOscuro ? Colors.white60 : Colors.black54),
                          suffixText: "%",
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.percent, color: Colors.orange),
                        ),
                      ),
                    ],
                    const SizedBox(height: 15),
                    Text("DESGLOSE DE PRODUCTOS", 
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white38 : Colors.grey)),
                    const SizedBox(height: 10),
                    ...prods.asMap().entries.map((entry) {
                      int idx = entry.key;
                      var p = entry.value;
                      double pOriginal = (p['precio_venta'] as num).toDouble();
                      int cant = (p['cantidad'] as int);
                      double descBase = (p['descuento'] ?? 0).toDouble();
                      bool yaTieneDesc = descBase > 0;
                      double pctManual = (double.tryParse(descIndCtrls[idx]!.text) ?? 0);
                      double pctActual = esDescuentoGlobal ? (yaTieneDesc ? descBase : pctGlobal) : (yaTieneDesc ? descBase : pctManual);
                      double pCalculado = pOriginal - (pOriginal * (pctActual / 100));
                      nuevoTotal += (pCalculado * cant);
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: isOscuro ? Colors.white.withOpacity(0.03) : Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: isOscuro ? Colors.white10 : Colors.grey.shade200)
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(p['nombre'], style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : Colors.black)),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      if (pctActual > 0) ...[
                                        Text("\$${pOriginal.toStringAsFixed(0)}", 
                                          style: const TextStyle(fontSize: 11, color: Colors.red, decoration: TextDecoration.lineThrough)),
                                        const Icon(Icons.arrow_right_alt, size: 14, color: Colors.grey),
                                      ],
                                      Text("\$${pCalculado.toStringAsFixed(0)}", 
                                        style: TextStyle(fontSize: 12, color: isOscuro ? Colors.greenAccent : Colors.green, fontWeight: FontWeight.bold)),
                                      Text(" (x$cant)", style: const TextStyle(fontSize: 11, color: Colors.blueGrey)),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            if (!esDescuentoGlobal)
                              Expanded(
                                flex: 1,
                                child: yaTieneDesc 
                                  ? Column(children: [
                                      const Icon(Icons.lock, size: 14, color: Colors.orange),
                                      Text("-$descBase%", style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.orange))
                                    ])
                                  : TextField(
                                      controller: descIndCtrls[idx],
                                      keyboardType: TextInputType.number,
                                      onChanged: (v) => setDialogState(() {}),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : Colors.black),
                                      decoration: const InputDecoration(hintText: "0%", isDense: true, border: OutlineInputBorder()),
                                    ),
                              ),
                          ],
                        ),
                      );
                    }).toList(),
                    const Divider(height: 30),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text("TOTAL FINAL:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: isOscuro ? Colors.white70 : Colors.black)),
                        Text("\$${(nuevoTotal + domVal).toStringAsFixed(0)}", 
                          style: TextStyle(fontWeight: FontWeight.w900, color: isOscuro ? Colors.greenAccent : Colors.green, fontSize: 22)),
                      ],
                    )
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: isOscuro ? Colors.cyanAccent.shade700 : const Color(0xFF0D47A1)),
                onPressed: () {
                  Map<int, double> descuentosFinales = {};
                  for (int i = 0; i < prods.length; i++) {
                    double descBase = (prods[i]['descuento'] ?? 0).toDouble();
                    if (descBase > 0) {
                      descuentosFinales[i] = descBase; 
                    } else {
                      descuentosFinales[i] = esDescuentoGlobal ? pctGlobal : (double.tryParse(descIndCtrls[i]!.text) ?? 0);
                    }
                  }
                  Navigator.pop(ctx);
                  _finalizarProcesamiento(docId, data, domVal, descuentosFinales);
                },
                child: const Text("CONTINUAR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              )
            ],
          );
        }
      ),
    );
  }

  void _abrirWhatsApp(String telefono, Map<String, dynamic> data) async {
    String numero = telefono.replaceAll(RegExp(r'\D'), ''); 
    String clienteNombre = data['cliente']['nombre'] ?? 'cliente';
    List prods = data['productos'] ?? [];
    String total = data['total'].toString();
    StringBuffer sb = StringBuffer();
    sb.writeln("📦 *¡Hola $clienteNombre! Recibí tu pedido de mi catálogo web*\n");
    sb.writeln("*Resumen de tu pedido:*");
    for (var p in prods) {
      double precioOriginal = (p['precio_venta'] as num).toDouble();
      double descuento = (p['descuento'] ?? 0).toDouble();
      double precioFinal = (p['precio_final'] ?? (precioOriginal - (precioOriginal * (descuento / 100)))).toDouble();
      int cant = p['cantidad'] as int;
      sb.writeln("▪️ ${cant}x ${p['nombre']} (\$${(precioFinal * cant).toStringAsFixed(0)})");
    }
    
    sb.writeln("\n*TOTAL:* \$$total");
    sb.writeln("\nTe escribo para confirmar los detalles del envío.");

    String mensajeCodificado = Uri.encodeComponent(sb.toString());
    
    final Uri url = Uri.parse("https://wa.me/$numero?text=$mensajeCodificado");
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  void _finalizarProcesamiento(String docId, Map<String, dynamic> data, double domicilio, Map<int, double> descuentosPorProd) async {
    if (!mounted) return;
    setState(() => _procesando = true); 
    try {
      List<Map<String, dynamic>> carritoAProcesar = [];
      double nuevoTotalCalculado = 0;
      List prods = data['productos'] ?? [];
      for (int i = 0; i < prods.length; i++) {
        var p = prods[i];
        double pVenta = (p['precio_venta'] as num).toDouble();
        double descFinal = descuentosPorProd[i] ?? 0;
        int cant = p['cantidad'] as int;
        double pFinal = pVenta - (pVenta * (descFinal / 100));
        nuevoTotalCalculado += pFinal * cant;
        carritoAProcesar.add({
          'id': p['id'],
          'nombre': p['nombre'],
          'precio_venta': pVenta,
          'cantidad': cant,
          'descuento': descFinal,
          'precio_final': pFinal, 
          'cart_id': p['id'].toString() + (p['o_index']?.toString() ?? ""),
          if (p['es_variante'] == true) 'es_variante': true,
          if (p['g_index'] != null) 'g_index': p['g_index'],
          if (p['o_index'] != null) 'o_index': p['o_index'],
        });
      }
      if (domicilio > 0) {
        nuevoTotalCalculado += domicilio;
        carritoAProcesar.add({
          'id': -1,
          'cart_id': 'domicilio_web',
          'nombre': 'Domicilio (Web)',
          'precio_venta': domicilio,
          'cantidad': 1,
          'es_domicilio': true,
          'descuento': 0.0,
        });
      }
      await FirebaseFirestore.instance.collection('solicitudes').doc(docId).delete();
      if (mounted) setState(() => _procesando = false);
      if (!mounted) return;
      Navigator.pushReplacement(
        context, 
        MaterialPageRoute(
          builder: (_) => PantallaRegistrarPedido(
            carrito: carritoAProcesar,
            totalPedido: nuevoTotalCalculado,
            datosPreCargados: {
              'nombre': data['cliente']['nombre'],
              'negocio': data['cliente']['negocio'],
              'direccion': data['cliente']['direccion'],
              'telefono': data['cliente']['telefono'],
              'ciudad': data['cliente']['ciudad'],
              'departamento': data['cliente']['departamento'],
            },
          )
        )
      );
    } catch (e) {
      debugPrint("Error procesando: $e");
      if (mounted) {
        setState(() => _procesando = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error al procesar: $e"))
        );
      }
    }
  }
}

class _DialogoDescuentoCart extends StatefulWidget {
  final List<Map<String, dynamic>> carritoActual;
  final bool globalInicial;
  final double pctInicial;
  final Function(List<Map<String, dynamic>>, bool, double) onAplicar;
  const _DialogoDescuentoCart({
    required this.carritoActual, 
    required this.globalInicial, 
    required this.pctInicial, 
    required this.onAplicar
  });
  @override
  State<_DialogoDescuentoCart> createState() => _DialogoDescuentoCartState();
}

class _DialogoDescuentoCartState extends State<_DialogoDescuentoCart> {
  late bool _globalActivo;
  final TextEditingController _globalCtrl = TextEditingController();
  final Map<String, TextEditingController> _cantCtrls = {};
  final Map<String, TextEditingController> _pctCtrls = {};
  @override
  void initState() {
    super.initState();
    _globalActivo = widget.globalInicial;
    _globalCtrl.text = widget.pctInicial > 0 ? widget.pctInicial.toStringAsFixed(0) : "";
    for (var item in widget.carritoActual) {
      if (item['es_domicilio'] == true) continue;
      String id = item['cart_id']?.toString() ?? "sin_id";
      _cantCtrls[id] = TextEditingController(text: "${item['cantidad']}");
      double descPrevia = (item['descuento'] ?? 0).toDouble();
      _pctCtrls[id] = TextEditingController(text: descPrevia > 0 ? descPrevia.toStringAsFixed(0) : "");
    }
  }
  @override
  void dispose() {
    _globalCtrl.dispose();
    for (var c in _cantCtrls.values) c.dispose();
    for (var c in _pctCtrls.values) c.dispose();
    super.dispose();
  }
  bool _generaPerdida(Map<String, dynamic> item, double pctDesc) {
    double costo = (item['precio_compra'] ?? 0).toDouble();
    double ventaBase = (item['precio_venta'] ?? 0).toDouble();
    if (ventaBase <= 0) return false;
    double precioFinal = ventaBase - (ventaBase * (pctDesc / 100));
    return (precioFinal < costo);
  }

  @override
  Widget build(BuildContext context) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    bool perdidaGlobal = false;
    if (_globalActivo) {
      double pctG = double.tryParse(_globalCtrl.text) ?? 0;
      perdidaGlobal = widget.carritoActual.any((item) => item['es_domicilio'] != true && _generaPerdida(item, pctG));
    }
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor, 
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30))
      ),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom + 20, left: 20, right: 20, top: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 50, height: 5, decoration: BoxDecoration(color: isOscuro ? Colors.white24 : Colors.grey[600], borderRadius: BorderRadius.circular(10))),
          const SizedBox(height: 20),
          Text("GESTIONAR DESCUENTOS", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : Colors.black)),
          SwitchListTile(
            title: Text("Descuento Global", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : Colors.black)),
            value: _globalActivo,
            activeColor: Colors.orangeAccent,
            onChanged: (v) => setState(() => _globalActivo = v),
          ),
          if (_globalActivo) ...[
            TextField(
              controller: _globalCtrl,
              onChanged: (v) => setState(() {}),
              keyboardType: TextInputType.number,
              style: TextStyle(color: isOscuro ? Colors.white : Colors.black),
              decoration: InputDecoration(
                labelText: "% Descuento Global", 
                labelStyle: TextStyle(color: isOscuro ? Colors.white70 : Colors.black54),
                border: const OutlineInputBorder(), 
                suffixText: "%",
                suffixStyle: TextStyle(color: isOscuro ? Colors.white70 : Colors.black54),
              ),
            ),
            if (perdidaGlobal)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text("⚠️ Este descuento genera pérdidas.", style: TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)),
              ),
          ] else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: widget.carritoActual.where((i) => i['es_domicilio'] != true).map((item) {
                  String id = item['cart_id']?.toString() ?? "sin_id";
                  bool yaTieneDesc = (item['descuento'] ?? 0) > 0;
                  double precioVenta = (item['precio_venta'] as num).toDouble();
                  double pctInput = double.tryParse(_pctCtrls[id]?.text ?? "0") ?? 0;
                  double precioCalculado = precioVenta - (precioVenta * (pctInput / 100));
                  bool perdidaInd = _generaPerdida(item, pctInput);
                  return Card(
                    color: isOscuro 
                      ? (yaTieneDesc ? Colors.white.withOpacity(0.05) : Colors.white.withOpacity(0.08))
                      : (yaTieneDesc ? Colors.grey.shade100 : Colors.white),
                    elevation: isOscuro ? 0 : 2,
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: isOscuro ? Colors.white10 : Colors.transparent)
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(12),
                      title: Text(item['nombre'], 
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : Colors.black87)),
                      subtitle: yaTieneDesc 
                        ? const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text("Ya tiene descuento de inventario.", 
                              style: TextStyle(color: Colors.orangeAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 10),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text("Antes: \$${precioVenta.toStringAsFixed(0)}", 
                                    style: TextStyle(fontSize: 11, color: isOscuro ? Colors.white38 : Colors.grey, decoration: TextDecoration.lineThrough)),
                                  Text("Ahora: \$${precioCalculado.toStringAsFixed(0)}", 
                                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1))),
                                ],
                              ),
                              const Divider(height: 20),
                              Row(children: [
                                Expanded(child: _miniInput(_cantCtrls[id]!, "Cant", isOscuro)),
                                const SizedBox(width: 15),
                                Expanded(
                                  child: _miniInput(
                                    _pctCtrls[id]!, 
                                    "% Desc", 
                                    isOscuro, 
                                    onChanged: (v) => setState((){}) // Esto refresca el precio al escribir
                                  )
                                ),
                              ]),
                              if (perdidaInd)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 14),
                                      const SizedBox(width: 4),
                                      const Text("Genera pérdida", 
                                        style: TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                    ),
                  );
                }).toList(),
              ),
            ),
          const SizedBox(height: 20),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: perdidaGlobal ? Colors.red : (isOscuro ? Colors.cyanAccent.shade700 : const Color(0xFF0D47A1)), 
              minimumSize: const Size(double.infinity, 50), shape: const StadiumBorder()
            ),
            onPressed: () {
              List<Map<String, dynamic>> resIndividuales = [];
              double pctGlobal = double.tryParse(_globalCtrl.text) ?? 0;
              if (!_globalActivo) {
                for (var item in widget.carritoActual) {
                  String id = item['cart_id']?.toString() ?? "sin_id";
                  if (item['es_domicilio'] == true || (item['descuento'] ?? 0) > 0) continue;
                  int c = int.tryParse(_cantCtrls[id]?.text ?? "0") ?? 0;
                  double p = double.tryParse(_pctCtrls[id]?.text ?? "0") ?? 0;
                  if (c > 0 && p > 0) resIndividuales.add({'cart_id': id, 'qty': c, 'desc': p});
                }
              }
              widget.onAplicar(resIndividuales, _globalActivo, pctGlobal);
              Navigator.pop(context);
            }, 
            child: Text(
              perdidaGlobal ? "GUARDAR CON PÉRDIDAS" : "CONFIRMAR", 
              style: TextStyle(color: isOscuro ? Colors.black : Colors.white, fontWeight: FontWeight.bold)
            )
          ),
        ],
      ),
    );
  }

  Widget _miniInput(TextEditingController ctrl, String label, bool isOscuro, {Function(String)? onChanged}) {
    return TextField(
      controller: ctrl,
      onChanged: onChanged,
      keyboardType: TextInputType.number,
      style: TextStyle(fontSize: 14, color: isOscuro ? Colors.white : Colors.black),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(fontSize: 12, color: isOscuro ? Colors.white60 : Colors.black54),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: isOscuro ? Colors.white24 : Colors.black12)),
      ),
    );
  }
}

class _LogoAnimado extends StatefulWidget {
  final ImageProvider? logoProv;
  const _LogoAnimado({this.logoProv});
  @override
  State<_LogoAnimado> createState() => _LogoAnimadoState();
}

class _LogoAnimadoState extends State<_LogoAnimado> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 5))..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const double size = 60;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) => Container(
        width: size + 6,
        height: size + 6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: SweepGradient(
            transform: GradientRotation(_ctrl.value * 2 * pi),
            colors: const [
              Color(0xFF00E5FF),
              Color(0xFFFF9800),
              Color(0xFFE91E63),
              Color(0xFF00E5FF),
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.cyanAccent.withOpacity(0.3 + 0.15 * sin(_ctrl.value * 2 * pi)),
              blurRadius: 20,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Container(
            decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF041E42)),
            child: CircleAvatar(
              radius: size / 2,
              backgroundColor: Colors.white10,
              backgroundImage: widget.logoProv,
              child: widget.logoProv == null
                  ? const Icon(Icons.business, color: Colors.orangeAccent, size: 25)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

class AnuncioNativoWidget extends StatefulWidget {
  const AnuncioNativoWidget({super.key});

  @override
  State<AnuncioNativoWidget> createState() => _AnuncioNativoWidgetState();
}

class _AnuncioNativoWidgetState extends State<AnuncioNativoWidget> {
  BannerAd? _bannerAd;
  bool _isLoaded = false;

  final String _adUnitId = Platform.isAndroid
      ? 'ca-app-pub-2754846263403564/3464101852' // ID real Android
      : 'ca-app-pub-3940256099942544/2934735716'; // Test ID iOS

  @override
  void initState() {
    super.initState();
    _cargarAnuncio();
  }

  void _cargarAnuncio() {
    _bannerAd = BannerAd(
      adUnitId: _adUnitId,
      request: const AdRequest(),
      size: AdSize.largeBanner, // 📐 320x100 - Extremadamente estable, sin decodificación por hardware de video
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (mounted) {
            setState(() {
              _isLoaded = true;
            });
          }
        },
        onAdFailedToLoad: (ad, error) {
          debugPrint('Error cargando banner seguro: ${error.message}');
          ad.dispose();
        },
      ),
    )..load();
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isOscuro = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      decoration: BoxDecoration(
        color: isOscuro ? const Color(0xFF1E2230) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isOscuro ? Colors.white10 : Colors.grey.shade300),
        boxShadow: [
          if (!isOscuro)
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            )
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // 🏷️ ENCABEZADO
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
            color: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "Publicidad Recomendada", 
                  style: TextStyle(
                    fontSize: 10, 
                    fontWeight: FontWeight.bold, 
                    color: isOscuro ? Colors.white54 : Colors.grey.shade600
                  ),
                ),
                Icon(Icons.info_outline, size: 12, color: isOscuro ? Colors.white54 : Colors.grey.shade400)
              ],
            ),
          ),
          
          // 🖥️ CUERPO (Muestra el anuncio de AdMob, o un banner Pro si está cargando)
          Container(
            height: 120,
            alignment: Alignment.center,
            color: isOscuro ? Colors.black26 : Colors.grey.shade50,
            child: _isLoaded && _bannerAd != null
                ? AdWidget(ad: _bannerAd!)
                : InkWell(
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PantallaPremium())),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.stars, color: Colors.amber.shade700, size: 24),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text("¿Respaldar base de datos?", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                              Text("Sincroniza tus ventas y catálogo web al instante.", style: TextStyle(color: isOscuro ? Colors.white54 : Colors.black54, fontSize: 10)),
                            ],
                          ),
                        )
                      ],
                    ),
                  ),
          ),
          
          // 🔘 ENLACE DE CONVERSIÓN PREMIUM
          InkWell(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PantallaPremium())),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: isOscuro ? Colors.white10 : Colors.black12))
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.workspace_premium, size: 16, color: Colors.orange),
                  SizedBox(width: 8),
                  Text(
                    "QUITAR ANUNCIOS (HAZTE PRO)", 
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.orange),
                  )
                ],
              ),
            ),
          )
        ],
      ),
    );
  }
}