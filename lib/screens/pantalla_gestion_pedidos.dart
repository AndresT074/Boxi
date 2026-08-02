import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../database/db_helper.dart';
import 'servicio_pdf.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'servicio_nube.dart';
import 'servicio_anuncios.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'pantalla_premium.dart';
import 'package:sqflite/sqflite.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'servicio_fidelidad.dart';
import 'package:url_launcher/url_launcher.dart';

final Map<String, Uint8List> _imageCache = {};
String _localBoxiPathGlobal = "/storage/emulated/0/Pictures/Boxi"; // 🔥 Añadido para gestionar la ruta offline

Widget _construirMiniatura(String? pathOrBase64, bool isOscuro) {
  if (pathOrBase64 == null || pathOrBase64.trim().isEmpty || pathOrBase64 == 'null') {
    return Container(
      width: 45, height: 45,
      decoration: BoxDecoration(
        color: isOscuro ? Colors.white10 : Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(Icons.image_not_supported,
          size: 20, color: isOscuro ? Colors.white38 : Colors.black26),
    );
  }

  // 🔥 1. SI ES UNA URL DE CLOUDINARY
  if (pathOrBase64.startsWith('http')) {
    String name = pathOrBase64.split('/').last;
    if (!name.contains('.')) name += '.jpg';
    
    File fPub = File('$_localBoxiPathGlobal/$name');
    File fVar = File('$_localBoxiPathGlobal/Variantes/$name');
    
    bool fPubLegible = false;
    try { if (fPub.existsSync()) { fPub.readAsBytesSync(); fPubLegible = true; } } catch(_) {}
    
    bool fVarLegible = false;
    try { if (fVar.existsSync()) { fVar.readAsBytesSync(); fVarLegible = true; } } catch(_) {}

    if (fVarLegible) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(fVar, width: 45, height: 45, fit: BoxFit.cover, gaplessPlayback: true),
      );
    } else if (fPubLegible) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(fPub, width: 45, height: 45, fit: BoxFit.cover, gaplessPlayback: true),
      );
    }
    
    // Si no está offline, cargar de internet
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        pathOrBase64, width: 45, height: 45, fit: BoxFit.cover, gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => Container(
          width: 45, height: 45,
          decoration: BoxDecoration(color: isOscuro ? Colors.white10 : Colors.grey.shade200, borderRadius: BorderRadius.circular(8)),
          child: Icon(Icons.broken_image, size: 20, color: isOscuro ? Colors.white38 : Colors.black26),
        ),
      ),
    );
  }

  // 🔥 2. SI ES UN TEXTO BASE64 LARGO (Retrocompatibilidad)
  if (pathOrBase64.length > 500) {
    try {
      String cleanBase64 = pathOrBase64;
      if (cleanBase64.contains(',')) cleanBase64 = cleanBase64.split(',').last;
      cleanBase64 = cleanBase64.replaceAll(RegExp(r'\s+'), '');

      Uint8List bytes;
      if (_imageCache.containsKey(cleanBase64)) {
        bytes = _imageCache[cleanBase64]!;
      } else {
        bytes = base64Decode(cleanBase64);
        if (_imageCache.length > 200) _imageCache.clear();
        _imageCache[cleanBase64] = bytes;
      }

      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(bytes, width: 45, height: 45, fit: BoxFit.cover, gaplessPlayback: true),
      );
    } catch (_) {}
  }

  // 🔥 3. SI ES UNA RUTA DE ARCHIVO LOCAL DIRECTA
  try {
    File file = File(pathOrBase64);
    if (file.existsSync()) {
      file.readAsBytesSync();
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(file, width: 45, height: 45, fit: BoxFit.cover, gaplessPlayback: true),
      );
    }
  } catch (_) {}

  return Container(
    width: 45, height: 45,
    decoration: BoxDecoration(
      color: isOscuro ? Colors.white10 : Colors.grey.shade200,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Icon(Icons.broken_image, size: 20, color: isOscuro ? Colors.white38 : Colors.black26),
  );
}

class PantallaGestionPedidos extends StatefulWidget {
  const PantallaGestionPedidos({super.key});
  @override
  State<PantallaGestionPedidos> createState() => _PantallaGestionPedidosState();
}

class _PantallaGestionPedidosState extends State<PantallaGestionPedidos>
    with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> _pedidos = [];
  Map<int, bool> _pedidosBloqueados = {};
  bool _esPremium = false;
  String _estadoActual = 'Pendiente';
  final Map<int, bool> _logoToggle = {};
  final Map<int, List<Map<String, dynamic>>> _detallesCache = {};
  bool _refrescando = false;
  late AnimationController _refreshAnim;

  void _invalidarCache(int pedidoId) => _detallesCache.remove(pedidoId);

  // Colores y estilos por estado
  static const Map<String, Color> _coloresEstado = {
    'Pendiente': Color(0xFFFF8C00),
    'Entregado sin Pago': Color(0xFF2196F3),
    'Completado': Color(0xFF00C853),
    'Cancelado': Color(0xFFE53935),
  };

  static const Map<String, IconData> _iconosEstado = {
    'Pendiente': Icons.hourglass_empty_rounded,
    'Entregado sin Pago': Icons.local_shipping_rounded,
    'Completado': Icons.check_circle_rounded,
    'Cancelado': Icons.cancel_rounded,
  };

  @override
  void initState() {
    super.initState();
    _refreshAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _inicializarPantalla();
  }

  @override
  void dispose() {
    _refreshAnim.dispose();
    super.dispose();
  }

  Future<void> _inicializarPantalla() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _esPremium = prefs.getBool('es_premium') ?? false;
        // 🔥 Carga la ruta resuelta al entrar a la pantalla
        _localBoxiPathGlobal = prefs.getString('local_boxi_path') ?? "/storage/emulated/0/Pictures/Boxi";
      });
    }
    await _cargar();
  }

  Future<void> _cargar() async {
    final db = await DBHelper.instance.database;
    await db.delete('pedidos', where: "fecha_hora = '2000-01-01 00:00:00' AND total_venta = 0");

    // 🔥 1. AUTO-SANEAMIENTO: Rellena los nombres vacíos buscando en la tabla clientes local
    int filasModificadas = await db.rawUpdate('''
      UPDATE pedidos 
      SET cliente_nombre_snapshot = (SELECT nombre_completo FROM clientes WHERE clientes.id = pedidos.cliente_id) 
      WHERE cliente_nombre_snapshot IS NULL OR cliente_nombre_snapshot = ""
    ''');

    // 🔥 2. SINCRONIZACIÓN SILENCIOSA: Si reparamos pedidos y el usuario es Premium, encolamos el respaldo para Firebase
    if (filasModificadas > 0 && _esPremium) {
      try {
        final reparados = await db.query('pedidos', columns: ['id', 'cliente_nombre_snapshot'], where: 'cliente_nombre_snapshot IS NOT NULL AND cliente_nombre_snapshot != ""');
        final String fecha = DateTime.now().toIso8601String();
        
        for (var p in reparados) {
          String? nombreSnap = p['cliente_nombre_snapshot']?.toString();
          if (nombreSnap != null && nombreSnap.isNotEmpty) {
            await db.insert('operaciones_pendientes', {
              'tabla': 'pedidos',
              'operacion': 'set',
              'doc_id': p['id'].toString(),
              'datos_json': jsonEncode({
                'id': p['id'], 
                'cliente_nombre_snapshot': nombreSnap
              }),
              'fecha_creacion': fecha
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
        // Dispara el procesador de cola offline de forma silenciosa
        ServicioNube.procesarColaOffline();
      } catch (e) {
        debugPrint("Error sincronizando auto-saneamiento: $e");
      }
    }

    final peds = await db.rawQuery('''
      SELECT pedidos.*,
            clientes.nombre_completo as cliente_nombre,
            clientes.nombre_negocio as negocio_nombre,
            clientes.direccion as cliente_direccion,
            clientes.ciudad as cliente_ciudad,
            clientes.telefono as cliente_telefono,
            vendedores.nombre as vendedor_nombre,
            vendedores.telefono as vendedor_telefono
      FROM pedidos
      LEFT JOIN clientes ON pedidos.cliente_id = clientes.id
      LEFT JOIN vendedores ON pedidos.vendedor_id = vendedores.id
      ORDER BY pedidos.id DESC
    ''');

    Map<int, bool> bloqueos = {};
    for (var p in peds) {
      int id = p['id'] as int;
      if (p['estado'] != 'Pendiente') {
        bloqueos[id] = false;
        continue;
      }
      if (!_detallesCache.containsKey(id)) {
        _detallesCache[id] = await _obtenerDetalles(id);
      }
      bloqueos[id] = _detallesCache[id]!.any((d) => d['sin_stock'] == 1);
    }

    if (mounted) {
      setState(() {
        _pedidos = peds;
        _pedidosBloqueados = bloqueos;
      });
    }
  }

  Future<void> _refrescarDesdeNube() async {
    if (_refrescando || !_esPremium) return;
    setState(() => _refrescando = true);
    _refreshAnim.repeat();

    try {
      final prefs = await SharedPreferences.getInstance();
      final uid = prefs.getString('user_uid');
      if (uid == null || !await ServicioNube.tieneInternet()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Sin conexión a internet'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.all(12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
        }
        return;
      }

      // 🔥 Sincroniza desde Realtime Database (0 Lecturas Firestore)
      await ServicioNube.descargarDatosPrivadosRTDB();
      await ServicioNube.importarCatalogoDesdeRTDB(uid);
      _detallesCache.clear();
      await _cargar();

      if (mounted) {
        final count = _pedidos.length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(children: [
              const Icon(Icons.cloud_done_rounded, color: Colors.white, size: 18),
              const SizedBox(width: 10),
              Text('$count pedidos sincronizados exitosamente',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
            backgroundColor: const Color(0xFF00C853),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error en _refrescarDesdeNube: $e');
    } finally {
      _refreshAnim.stop();
      _refreshAnim.reset();
      if (mounted) setState(() => _refrescando = false);
    }
  }

  Map<String, List<Map<String, dynamic>>> _agruparPorFecha(
    List<Map<String, dynamic>> pedidos) {
    final Map<String, List<Map<String, dynamic>>> grupos = {};
    for (var p in pedidos) {
      String fechaEfectiva = "";
      if (p['estado'] == 'Completado' &&
          p['fecha_pago'] != null &&
          p['fecha_pago'].toString().trim().isNotEmpty &&
          p['fecha_pago'].toString() != "null") {
        fechaEfectiva = p['fecha_pago'].toString();
      } else {
        fechaEfectiva = p['fecha_hora']?.toString() ?? p['fecha']?.toString() ?? '';
      }

      String fechaKey = fechaEfectiva.length >= 10 ? fechaEfectiva.substring(0, 10) : 'Sin fecha';
      grupos.putIfAbsent(fechaKey, () => []).add(p);
    }
    return grupos;
  }

  String _formatearFechaGrupo(String fechaKey) {
    if (fechaKey == 'Sin fecha') return fechaKey;
    try {
      final dt = DateTime.parse(fechaKey);
      final hoy = DateTime.now();
      final ayer = hoy.subtract(const Duration(days: 1));
      if (dt.year == hoy.year && dt.month == hoy.month && dt.day == hoy.day) return 'HOY';
      if (dt.year == ayer.year && dt.month == ayer.month && dt.day == ayer.day) return 'AYER';
      const meses = ['', 'ENE', 'FEB', 'MAR', 'ABR', 'MAY', 'JUN', 'JUL', 'AGO', 'SEP', 'OCT', 'NOV', 'DIC'];
      return '${dt.day} ${meses[dt.month]} ${dt.year}';
    } catch (_) {
      return fechaKey;
    }
  }

  Future<List<Map<String, dynamic>>> _obtenerDetalles(int pedId) async {
    final db = await DBHelper.instance.database;

    // 🔥 1. OBTENEMOS EL TOTAL REAL COBRADO PARA DETECTAR DESCUENTOS GLOBALES
    final pedRes = await db.query('pedidos', columns: ['total_venta', 'valor_domicilio'], where: 'id = ?', whereArgs: [pedId]);
    double totalCobrado = 0.0;
    double domi = 0.0;
    if (pedRes.isNotEmpty) {
      totalCobrado = (pedRes.first['total_venta'] as num?)?.toDouble() ?? 0.0;
      domi = (pedRes.first['valor_domicilio'] as num?)?.toDouble() ?? 0.0;
    }
    double totalRealProductos = totalCobrado - domi;

    final resultado = await db.rawQuery('''
      SELECT d.*,
            IFNULL(d.nombre_snapshot, IFNULL(p.nombre, "Producto")) as nombre_prod,
            p.variantes as prod_variantes,
            p.nombre as prod_nombre_base,
            p.stock as stock_actual_general
      FROM detalle_pedidos d
      LEFT JOIN productos p ON d.producto_id = p.id
      WHERE d.pedido_id = ?
    ''', [pedId]);

    List<Map<String, dynamic>> detallesEditables =
        resultado.map((e) => Map<String, dynamic>.from(e)).toList();

    // 🔥 2. CALCULAMOS SI HAY DINERO FALTANTE (DESCUENTO GLOBAL OCULTO)
    double subtotalSinDescuento = 0.0;
    for (var d in detallesEditables) {
      double pU = (d['precio_unitario'] as num?)?.toDouble() ?? 0.0;
      int c = (d['cantidad'] as int?) ?? 1;
      subtotalSinDescuento += (pU * c);
    }
    bool algunItemTieneDescuento = detallesEditables.any((d) => ((d['descuento'] as num?)?.toDouble() ?? 0.0) > 0);

    double descGlobalFaltante = 0.0;
    if (!algunItemTieneDescuento && subtotalSinDescuento > 0 && totalRealProductos > 0 && (subtotalSinDescuento - totalRealProductos) > 1.0) {
      double rawDesc = ((subtotalSinDescuento - totalRealProductos) / subtotalSinDescuento) * 100;
      descGlobalFaltante = double.parse(rawDesc.toStringAsFixed(2));
    }

    for (var d in detallesEditables) {
      d['sin_stock'] = 0;

      // 🔥 3. APLICAMOS EL DESCUENTO DETECTADO PARA REPARAR LA VISTA Y EL PDF
      double pUnitario = (d['precio_unitario'] as num?)?.toDouble() ?? 0.0;
      int cant = (d['cantidad'] as int?) ?? 1;
      double descGuardado = (d['descuento'] as num?)?.toDouble() ?? 0.0;

      // Si el ítem no tiene descuento registrado, le asignamos el global que detectamos
      if (descGuardado <= 0 && descGlobalFaltante > 0) {
        d['descuento'] = descGlobalFaltante;
        d['subtotal'] = (pUnitario - (pUnitario * (descGlobalFaltante / 100))) * cant;
      } else if (descGuardado > 0) {
        d['subtotal'] = (pUnitario - (pUnitario * (descGuardado / 100))) * cant;
      }

      String varStr = d['prod_variantes']?.toString() ?? "";
      String nombreSnapshot = d['nombre_snapshot']?.toString() ?? "";

      if (varStr.length > 5 && nombreSnapshot.contains(" - ")) {
        try {
          List<dynamic> grupos = jsonDecode(varStr);
          bool encontroVariante = false;
          for (var g in grupos) {
            if (!g.containsKey('grupo')) continue;
            for (var o in g['opciones']) {
              String nombreVar1 = "${d['prod_nombre_base']} - ${g['grupo']}: ${o['nombre']}";
              String nombreVar2 = "${d['prod_nombre_base']} - ${o['nombre']}";
              
              if (nombreSnapshot == nombreVar1 || nombreSnapshot == nombreVar2) {
                encontroVariante = true;
                if ((o['stock'] as int) < 0) d['sin_stock'] = 1;
                break;
              }
            }
            if (encontroVariante) break;
          }
        } catch (e) {
          debugPrint("Error validando variante: $e");
        }
      } else {
        int stockBase = (d['stock_actual_general'] ?? 0) as int;
        if (stockBase < 0) d['sin_stock'] = 1;
      }

      // Pre-carga de fotos
      d['foto_data'] = await _obtenerFotoDetalleEstatico(db, d['producto_id'] as int, d['nombre_prod']?.toString() ?? '');
    }
    return detallesEditables;
  }

  Future<void> _mostrarPantallaExito(String nuevoEstado) async {
    if (!mounted) return;
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    
    Color color;
    IconData icono;
    String titulo;

    if (nuevoEstado == 'Entregado sin Pago') {
      color = Colors.blue;
      icono = Icons.local_shipping_rounded;
      titulo = "¡Pedido Entregado!";
    } else if (nuevoEstado == 'Completado') {
      color = const Color(0xFF00C853);
      icono = Icons.check_circle_rounded;
      titulo = "¡Pago Completado!";
    } else { // Cancelado
      color = Colors.redAccent;
      icono = Icons.delete_forever_rounded;
      titulo = "Pedido Cancelado";
    }

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        // Temporizador seguro que solo cierra SU PROPIO modal
        Future.delayed(const Duration(milliseconds: 1300), () {
          if (ctx.mounted && Navigator.canPop(ctx)) {
            Navigator.of(ctx).pop();
          }
        });

        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: TweenAnimationBuilder(
            duration: const Duration(milliseconds: 400),
            curve: Curves.elasticOut,
            tween: Tween<double>(begin: 0.5, end: 1.0),
            builder: (context, double scale, child) {
              return Transform.scale(
                scale: scale,
                child: Container(
                  padding: const EdgeInsets.all(30),
                  decoration: BoxDecoration(
                    color: isOscuro ? const Color(0xFF141420) : Colors.white,
                    borderRadius: BorderRadius.circular(25),
                    boxShadow: [
                      BoxShadow(
                        color: color.withOpacity(0.3), 
                        blurRadius: 25, 
                        spreadRadius: 2
                      )
                    ]
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: color.withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(icono, color: color, size: 60),
                      ),
                      const SizedBox(height: 20),
                      Text(titulo, 
                        textAlign: TextAlign.center, 
                        style: TextStyle(
                          fontSize: 22, 
                          fontWeight: FontWeight.w900,
                          color: isOscuro ? Colors.white : Colors.black87
                      )),
                      const SizedBox(height: 8),
                      Text("El estado se actualizó correctamente", 
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13, 
                          color: isOscuro ? Colors.white54 : Colors.black54
                      )),
                    ],
                  ),
                ),
              );
            }
          ),
        );
      }
    );
  }

  // Consulta de SQLite rápida y estática para las imágenes
  Future<String?> _obtenerFotoDetalleEstatico(dynamic db, int productoId, String nombreSnapshot) async {
    try {
      if (nombreSnapshot.contains(" - ")) {
        String nombreOpcion = nombreSnapshot;
        if (nombreSnapshot.contains(': ')) {
          nombreOpcion = nombreSnapshot.split(': ').last.trim();
        } else {
          nombreOpcion = nombreSnapshot.split(' - ').last.trim();
        }

        final fotos = await db.query(
          'fotos_variantes',
          columns: ['foto_base64'],
          where: 'producto_id = ? AND (variante_nombre = ? OR variante_nombre LIKE ?)',
          whereArgs: [productoId, nombreOpcion, '%$nombreOpcion%'],
          limit: 1,
        );

        if (fotos.isNotEmpty) {
          return fotos.first['foto_base64'] as String?;
        }
      }

      final prod = await db.query(
        'productos',
        columns: ['foto_path'],
        where: 'id = ?',
        whereArgs: [productoId],
        limit: 1,
      );

      if (prod.isNotEmpty) {
        return prod.first['foto_path'] as String?;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _modificarStockBD(
      int productoId, int cantidadADescontar, String? nombreSnapshot) async {
    final db = await DBHelper.instance.database;
    var pRes = await db.query('productos', where: 'id = ?', whereArgs: [productoId]);
    if (pRes.isEmpty) return;

    var p = pRes.first;
    int nuevoStockGeneral = (p['stock'] as int) - cantidadADescontar;
    String variantesStr = p['variantes']?.toString() ?? "";

    if (variantesStr.length > 5 && nombreSnapshot != null) {
      try {
        List<dynamic> grupos = jsonDecode(variantesStr);
        bool encontrado = false;
        for (var g in grupos) {
          if (!g.containsKey('grupo')) continue;
          for (var o in g['opciones']) {
            String nombreVar = "${p['nombre']} - ${g['grupo']}: ${o['nombre']}";
            String nombreAntigua = "${p['nombre']} - ${o['nombre']}";
            if (nombreVar == nombreSnapshot || nombreAntigua == nombreSnapshot) {
              o['stock'] = (o['stock'] as int) - cantidadADescontar;
              encontrado = true;
              break;
            }
          }
          if (encontrado) break;
        }
        int totalPositivos = 0;
        for (var g in grupos) {
          for (var o in g['opciones']) {
            int s = o['stock'] as int;
            if (s > 0) totalPositivos += s;
          }
        }
        nuevoStockGeneral = totalPositivos;
        variantesStr = jsonEncode(grupos);
      } catch (_) {}
    }

    await db.update(
        'productos',
        {
          'stock': nuevoStockGeneral,
          'variantes': variantesStr,
          'ultima_modificacion': DateTime.now().toIso8601String()
        },
        where: 'id = ?',
        whereArgs: [productoId]);

    if (_esPremium) {
      final pAct = await db.query('productos', where: 'id = ?', whereArgs: [productoId]);
      if (pAct.isNotEmpty) ServicioNube.guardarProductoNube(Map<String, dynamic>.from(pAct.first));
    }
  }

  void _confirmarCambioEstado(int pedidoId, String nuevoEstado) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    String titulo = "";
    String mensaje = "";
    IconData icono = Icons.info;
    Color color = Colors.blue;

    if (nuevoEstado == 'Entregado sin Pago') {
      titulo = "Entregado sin Pago";
      mensaje = "¿Confirmas entrega pendiente de pago?";
      icono = Icons.local_shipping_rounded;
      color = Colors.orange;
    } else if (nuevoEstado == 'Completado') {
      titulo = "Pedido Completado";
      mensaje = "¿Confirmas entrega y pago exitoso?";
      icono = Icons.check_circle_rounded;
      color = Colors.green;
    } else if (nuevoEstado == 'Cancelado') {
      titulo = "Cancelar Pedido";
      mensaje = "¿Seguro? El stock será devuelto.";
      icono = Icons.cancel_rounded;
      color = Colors.red;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          Icon(icono, color: color, size: 28),
          const SizedBox(width: 10),
          Expanded(
              child: Text(titulo,
                  style: TextStyle(
                      color: color, fontWeight: FontWeight.bold, fontSize: 18))),
        ]),
        content:
            Text(mensaje, style: TextStyle(color: isOscuro ? Colors.white70 : Colors.black87)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("VOLVER")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: color),
            onPressed: () {
              Navigator.pop(ctx);
              _cambiarEstado(pedidoId, nuevoEstado);
            },
            child: const Text("ACEPTAR", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _cambiarEstado(int pedidoId, String nuevoEstado) async {
    final db = await DBHelper.instance.database;
    _invalidarCache(pedidoId);

    Future<void> ejecutar() async {
      String? fechaPagoVal;
      
      if (nuevoEstado == 'Completado') {
        final DateTime ahora = DateTime.now();
        final String periodo = ahora.hour >= 12 ? 'PM' : 'AM';
        final int hora12 = ahora.hour > 12 ? ahora.hour - 12 : (ahora.hour == 0 ? 12 : ahora.hour);
        fechaPagoVal = "${ahora.year}-${ahora.month.toString().padLeft(2, '0')}-${ahora.day.toString().padLeft(2, '0')} $hora12:${ahora.minute.toString().padLeft(2, '0')} $periodo";
      }

      // 1. Actualizar Base de Datos
      await db.update(
          'pedidos',
          {
            'estado': nuevoEstado, 
            'ultima_modificacion': DateTime.now().toIso8601String(),
            if (fechaPagoVal != null) 'fecha_pago': fechaPagoVal,
          },
          where: 'id = ?',
          whereArgs: [pedidoId]);

      // 2. Refrescar listado en pantalla
      await _cargar();

      // 3. Mostrar pantalla de éxito y ESPERAR a que termine de cerrarse
      await _mostrarPantallaExito(nuevoEstado);

      // 4. LUEGO de que la pantalla de éxito se cierra, otorgar punto y abrir la invitación de WhatsApp
      if (nuevoEstado == 'Completado') {
        final pedDoc = await db.query('pedidos', columns: ['cliente_id', 'total_venta', 'cliente_nombre_snapshot'], where: 'id = ?', whereArgs: [pedidoId]);
        if (pedDoc.isNotEmpty) {
          int clienteIdPedido = (pedDoc.first['cliente_id'] as num?)?.toInt() ?? 0;
          double totalVenta = (pedDoc.first['total_venta'] as num?)?.toDouble() ?? 0.0;
          String nombreSnap = pedDoc.first['cliente_nombre_snapshot']?.toString() ?? 'Cliente';

          await _otorgarPuntoFidelidadAutomatico(clienteIdPedido, totalVenta, nombreSnap);
        }
      }

      if (nuevoEstado == 'Cancelado') {
        final detalles = await db.query('detalle_pedidos', where: 'pedido_id = ?', whereArgs: [pedidoId]);
        for (var item in detalles) {
          if (item['producto_id'] != null) {
            await _modificarStockBD(item['producto_id'] as int, -(item['cantidad'] as int), item['nombre_snapshot']?.toString());
          }
        }
      }

      if (_esPremium) {
        try {
          await ServicioNube.actualizarEstadoPedidoNube(pedidoId, nuevoEstado, fechaPago: fechaPagoVal);
        } catch (e) {
          debugPrint("Error al sincronizar estado offline: $e");
        }
      }
    }

    if (!_esPremium) {
      ServicioAnuncios.mostrarAnuncioIntersticial(() => ejecutar());
    } else {
      ejecutar();
    }
  }

  Future<void> _otorgarPuntoFidelidadAutomatico(int clienteId, double totalVentaPedido, String clienteNombreSnap) async {
    try {
      final db = await DBHelper.instance.database;
      final prefs = await SharedPreferences.getInstance();
      final user = FirebaseAuth.instance.currentUser;

      // Asegurar columna client_uid en puntos_clientes
      try {
        final cols = await db.rawQuery("PRAGMA table_info(puntos_clientes);");
        if (!cols.any((c) => c['name'] == 'client_uid')) {
          await db.execute("ALTER TABLE puntos_clientes ADD COLUMN client_uid TEXT;");
        }
      } catch (_) {}

      // 1. Obtener tarjetas activas del vendedor
      final tarjetas = await db.query('tarjetas_fidelidad', where: 'activa = 1');
      if (tarjetas.isEmpty) return;

      String nombreLimpio = clienteNombreSnap.trim();

      // Auto-recuperar o crear cliente local si el ID viene en 0
      if (clienteId <= 0 && nombreLimpio.isNotEmpty) {
        final cMatch = await db.query('clientes', columns: ['id'], where: 'LOWER(TRIM(nombre_completo)) = ?', whereArgs: [nombreLimpio.toLowerCase()]);
        if (cMatch.isNotEmpty) {
          clienteId = cMatch.first['id'] as int;
        } else {
          clienteId = await db.insert('clientes', {'nombre_completo': nombreLimpio});
        }
      }

      final clienteRes = await db.query('clientes', where: 'id = ?', whereArgs: [clienteId]);
      String tel = clienteRes.isNotEmpty ? (clienteRes.first['telefono']?.toString() ?? "") : "";
      String telLimpio = tel.replaceAll(RegExp(r'\D'), ''); // 🔥 Limpio para cruce
      String emailCliente = clienteRes.isNotEmpty ? (clienteRes.first['email']?.toString() ?? "") : "";

      String nomNegocio = prefs.getString('nombre_negocio') ?? 'Nuestro Negocio';
      String logoPath = prefs.getString('logo_path') ?? '';
      bool hayInternet = user != null && await ServicioNube.tieneInternet();
      String vendorUid = user?.uid ?? '';

      for (var tarjeta in tarjetas) {
        int tarjetaId = tarjeta['id'] as int;
        String tarjetaIdStr = tarjetaId.toString();
        String tituloTarjeta = tarjeta['titulo'].toString();
        String premioDesc = tarjeta['premio_descripcion']?.toString() ?? "Premio especial";
        int meta = tarjeta['meta_compras'] as int;
        double montoMinimo = (tarjeta['monto_minimo'] as num?)?.toDouble() ?? 0.0;

        // Validar monto mínimo por compra
        if (montoMinimo > 0 && totalVentaPedido < montoMinimo) {
          continue;
        }

        // 1️⃣ CONSULTAR EN SQLITE LOCAL PRIMERO POR ID O POR NOMBRE
        var pLocalRes = await db.query(
          'puntos_clientes', 
          where: 'cliente_id = ? AND tarjeta_id = ?', 
          whereArgs: [clienteId, tarjetaId],
          orderBy: 'id DESC',
          limit: 1,
        );

        // Si no se encuentra por cliente_id, buscar si existe guardado bajo el mismo nombre
        if (pLocalRes.isEmpty && nombreLimpio.isNotEmpty) {
          final similarClients = await db.rawQuery(
            "SELECT p.* FROM puntos_clientes p JOIN clientes c ON p.cliente_id = c.id WHERE LOWER(TRIM(c.nombre_completo)) = ? AND p.tarjeta_id = ? ORDER BY p.id DESC LIMIT 1",
            [nombreLimpio.toLowerCase(), tarjetaId]
          );
          if (similarClients.isNotEmpty) {
            pLocalRes = similarClients;
            clienteId = similarClients.first['cliente_id'] as int;
          }
        }

        bool existeEnLocal = pLocalRes.isNotEmpty;

        String? realClientUid;
        if (existeEnLocal && pLocalRes.first['client_uid'] != null && pLocalRes.first['client_uid'].toString().isNotEmpty) {
          realClientUid = pLocalRes.first['client_uid']?.toString();
        }

        int ptsAntiguos = 0;
        int newComp = 0;

        if (existeEnLocal) {
          ptsAntiguos = ((pLocalRes.first['puntos_actuales'] ?? 0) as num).toInt();
          newComp = ((pLocalRes.first['completadasTotales'] ?? pLocalRes.first['completadas_totales'] ?? 0) as num).toInt();
        }

        bool esMismoUsuarioVendedor = (realClientUid == vendorUid);
        String targetDocId = (esMismoUsuarioVendedor || realClientUid == null || realClientUid.isEmpty)
            ? (clienteId > 0 ? clienteId.toString() : 'general')
            : realClientUid;

        int ptsCloud = 0;
        int compCloud = 0;
        String? docAEliminarDuplicado;

        // 2️⃣ SI HAY INTERNET, CONSULTAR FIRESTORE
        if (hayInternet) {
          try {
            final clientSnap = await FirebaseFirestore.instance
                .collection('usuarios')
                .doc(user.uid)
                .collection('mis_tarjetas_creadas')
                .doc(tarjetaIdStr)
                .collection('clientes')
                .get()
                .timeout(const Duration(seconds: 6)); // 🔥 MEJORA: Aumentado a 6s para evitar timeout

            for (var doc in clientSnap.docs) {
              var cData = doc.data();
              String locId = cData['clienteLocalId']?.toString() ?? '';
              String cNombre = cData['clienteNombre']?.toString() ?? '';
              String cEmail = cData['clienteEmail']?.toString() ?? '';
              String cUid = cData['clientUid']?.toString() ?? '';
              String cTel = (cData['clienteTelefono']?.toString() ?? '').replaceAll(RegExp(r'\D'), ''); // 🔥 Limpio para cruce

              bool coincideLocalId = (locId.isNotEmpty && locId == clienteId.toString()) || doc.id == clienteId.toString();
              bool coincideNombre = nombreLimpio.isNotEmpty && cNombre.isNotEmpty && cNombre.toLowerCase() == nombreLimpio.toLowerCase();
              bool coincideEmail = nombreLimpio.isNotEmpty && cEmail.isNotEmpty && cEmail.toLowerCase() == nombreLimpio.toLowerCase();
              bool coincideTel = telLimpio.isNotEmpty && cTel.isNotEmpty && (cTel.endsWith(telLimpio) || telLimpio.endsWith(cTel)); // 🔥 MEJORA: Cruce por teléfono
              bool coincideUid = (realClientUid != null && realClientUid.isNotEmpty && (cUid == realClientUid || doc.id == realClientUid));

              if (coincideUid || coincideLocalId || coincideNombre || coincideEmail || coincideTel) {
                bool esClienteExternoReal = cUid.isNotEmpty && cUid != user.uid;

                if (esClienteExternoReal && doc.id == clienteId.toString()) {
                  docAEliminarDuplicado = doc.id;
                }

                String idElegido = esClienteExternoReal ? cUid : (clienteId > 0 ? clienteId.toString() : doc.id);
                if (esClienteExternoReal) realClientUid = cUid;
                targetDocId = idElegido;

                int ptsD = ((cData['puntosActuales'] ?? 0) as num).toInt();
                int compD = ((cData['completadasTotales'] ?? 0) as num).toInt();

                if (ptsD > ptsCloud || (ptsD == ptsCloud && compD > compCloud)) {
                  ptsCloud = ptsD;
                  compCloud = compD;
                }

                if (cData['clienteEmail'] != null && cData['clienteEmail'].toString().isNotEmpty && emailCliente.isEmpty) {
                  emailCliente = cData['clienteEmail'].toString();
                }

                if (cUid.isNotEmpty) break;
              }
            }

            if (docAEliminarDuplicado != null && docAEliminarDuplicado != targetDocId) {
              FirebaseFirestore.instance
                  .collection('usuarios')
                  .doc(user.uid)
                  .collection('mis_tarjetas_creadas')
                  .doc(tarjetaIdStr)
                  .collection('clientes')
                  .doc(docAEliminarDuplicado)
                  .delete()
                  .catchError((_) {});
            }
          } catch (e) {
            debugPrint("Error consultando cliente en Firestore: $e");
          }
        }

        if (ptsCloud > ptsAntiguos) {
          ptsAntiguos = ptsCloud;
        }
        if (compCloud > newComp) {
          newComp = compCloud;
        }

        // 🛑 SI EL CLIENTE NO TIENE TARJETA AÚN Y NO ESTÁ VINCULADO
        bool esClienteSinTarjeta = (!existeEnLocal && ptsAntiguos == 0 && (realClientUid == null || realClientUid.isEmpty));

        if (esClienteSinTarjeta) {
          String tokenInv = "boxi_fidelidad_${DateTime.now().millisecondsSinceEpoch}_local".trim();
          try {
            tokenInv = await ServicioFidelidad.crearTokenUnicoNube(
              vendorUid: vendorUid,
              tarjetaId: tarjetaIdStr,
              clienteLocalId: clienteId,
              clienteNombre: nombreLimpio,
              nombreNegocio: nomNegocio,
              logoPath: logoPath,
              tarjetaTitulo: tituloTarjeta,
              metaCompras: meta,
              premioDesc: premioDesc,
              montoMinimo: montoMinimo,
              clienteTelefono: tel,
            ).timeout(const Duration(seconds: 2));
          } catch (e) {
            debugPrint("Modo offline: se genera enlace local para invitación WhatsApp: $e");
          }

          if (mounted) {
            _mostrarModalInvitacionWhatsApp(
              nombreLimpio,
              tel,
              premioDesc,
              tokenInv,
              meta,
              tituloTarjeta,
              montoMinimo: montoMinimo,
            );
          }
          continue; 
        }

        int newPts;
        if (ptsAntiguos < meta) {
          newPts = ptsAntiguos + 1;
          if (newPts == meta) {
            newComp++;
          }
        } else {
          newPts = 1;
        }

        // 3️⃣ GUARDAR EN SQLITE LOCAL SIEMPRE (MODO OFFLINE Y ONLINE)
        if (clienteId > 0) {
          await db.delete('puntos_clientes', where: 'cliente_id = ? AND tarjeta_id = ?', whereArgs: [clienteId, tarjetaId]);
          await db.insert('puntos_clientes', {
            'cliente_id': clienteId,
            'tarjeta_id': tarjetaId,
            'puntos_actuales': newPts,
            'completadas_totales': newComp,
            if (realClientUid != null && realClientUid.isNotEmpty) 'client_uid': realClientUid,
            'ultima_modificacion': DateTime.now().toIso8601String(),
          });

          // Actualizar caché local de Mis Premios Acumulados para refresco inmediato offline
          try {
            String keyUser = vendorUid.isNotEmpty ? vendorUid : (user?.uid ?? '');
            if (keyUser.isNotEmpty) {
              String? jsonCache = prefs.getString('cache_tarjetas_acumuladas_$keyUser');
              List<dynamic> listCache = (jsonCache != null && jsonCache.isNotEmpty) ? jsonDecode(jsonCache) : [];
              
              bool encontrado = false;
              for (var item in listCache) {
                if (item['tarjetaId']?.toString() == tarjetaIdStr &&
                    (item['clienteLocalId']?.toString() == clienteId.toString() || item['vendorUid'] == vendorUid)) {
                  item['puntosActuales'] = newPts;
                  item['completadasTotales'] = newComp;
                  encontrado = true;
                }
              }

              if (!encontrado) {
                listCache.add({
                  'docId': "${keyUser}_${tarjetaIdStr}_$clienteId",
                  'vendorUid': keyUser,
                  'tarjetaId': tarjetaIdStr,
                  'clienteLocalId': clienteId.toString(),
                  'clienteNombre': nombreLimpio,
                  'nombreNegocio': nomNegocio,
                  'logoPath': logoPath,
                  'tarjetaTitulo': tituloTarjeta,
                  'metaCompras': meta,
                  'premioDesc': premioDesc,
                  'montoMinimo': montoMinimo,
                  'puntosActuales': newPts,
                  'completadasTotales': newComp,
                });
              }
              await prefs.setString('cache_tarjetas_acumuladas_$keyUser', jsonEncode(listCache));
            }
          } catch (e) {
            debugPrint("Error actualizando caché local: $e");
          }
        }

        // 4️⃣ ESTRUCTURAR DATOS DE RESPALDO
        Map<String, dynamic> datosVendedor = {
          'clientUid': realClientUid ?? '',
          if (emailCliente.isNotEmpty) 'clienteEmail': emailCliente,
          'clienteLocalId': clienteId > 0 ? clienteId.toString() : '',
          'clienteNombre': nombreLimpio,
          'clienteTelefono': tel,
          'completadasTotales': newComp,
          'puntosActuales': newPts,
        };

        String targetUidCliente = (realClientUid != null && realClientUid.isNotEmpty) ? realClientUid : vendorUid;

        String nombreNegocioParaCliente = (targetUidCliente == vendorUid && nombreLimpio.isNotEmpty && nombreLimpio != 'Cliente')
            ? "$nomNegocio ($nombreLimpio)"
            : nomNegocio;

        Map<String, dynamic> datosCliente = {
          'clienteLocalId': clienteId > 0 ? clienteId.toString() : '',
          'clienteNombre': nombreLimpio,
          'completadasTotales': newComp,
          'logoPath': logoPath,
          'metaCompras': meta,
          'montoMinimo': montoMinimo,
          'nombreNegocio': nombreNegocioParaCliente,
          'premioDesc': premioDesc,
          'puntosActuales': newPts,
          'tarjetaId': tarjetaIdStr,
          'tarjetaTitulo': tituloTarjeta,
          'vendorUid': vendorUid,
        };

        // 5️⃣ ENCOLAR EN FIRESTORE O GUARDAR EN PENDIENTES OFFLINE
        if (vendorUid.isNotEmpty && targetDocId.isNotEmpty) {
          String rutaVendedor = "ruta_custom:usuarios/$vendorUid/mis_tarjetas_creadas/$tarjetaIdStr/clientes";
          String targetUidCliente = (realClientUid != null && realClientUid.isNotEmpty) ? realClientUid : vendorUid;
          String rutaCliente = "ruta_custom:usuarios/$targetUidCliente/tarjetas_acumuladas";
          String docTargetCliente = (targetUidCliente == vendorUid && clienteId > 0)
              ? "${vendorUid}_${tarjetaIdStr}_$clienteId"
              : "${vendorUid}_$tarjetaIdStr";

          if (hayInternet) {
            try {
              await FirebaseFirestore.instance
                  .collection('usuarios')
                  .doc(vendorUid)
                  .collection('mis_tarjetas_creadas')
                  .doc(tarjetaIdStr)
                  .collection('clientes')
                  .doc(targetDocId)
                  .set({
                ...datosVendedor,
                'ultimaModificacion': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));

              await FirebaseFirestore.instance
                  .collection('usuarios')
                  .doc(targetUidCliente)
                  .collection('tarjetas_acumuladas')
                  .doc(docTargetCliente)
                  .set({
                ...datosCliente,
                'ultimaModificacion': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));

              bool metaAlcanzada = newPts >= meta;
              ServicioFidelidad.notificarClientePuntoOtorgado(
                clientUid: targetUidCliente,
                nombreNegocio: nomNegocio,
                puntosActuales: newPts,
                meta: meta,
                premioDesc: premioDesc,
              );

              // 🔥 Evitar enviar la notificación de vendedor si el cliente es la misma cuenta (pruebas "Yo")
              if (vendorUid != targetUidCliente) {
                ServicioFidelidad.notificarVendedorPuntoReclamado(
                  vendorUid: vendorUid,
                  nombreCliente: clienteNombreSnap,
                  nombreNegocio: nomNegocio,
                  metaAlcanzada: metaAlcanzada,
                  premioDesc: premioDesc,
                );
              }
            } catch (e) {
              await db.insert('operaciones_pendientes', {
                'tabla': rutaVendedor,
                'operacion': 'set',
                'doc_id': targetDocId,
                'datos_json': jsonEncode(datosVendedor),
                'fecha_creacion': DateTime.now().toIso8601String(),
              }, conflictAlgorithm: ConflictAlgorithm.replace);

              await db.insert('operaciones_pendientes', {
                'tabla': rutaCliente,
                'operacion': 'set',
                'doc_id': docTargetCliente,
                'datos_json': jsonEncode(datosCliente),
                'fecha_creacion': DateTime.now().toIso8601String(),
              }, conflictAlgorithm: ConflictAlgorithm.replace);
            }
          } else {
            // 🚫 MODO OFFLINE
            await db.insert('operaciones_pendientes', {
              'tabla': rutaVendedor,
              'operacion': 'set',
              'doc_id': targetDocId,
              'datos_json': jsonEncode(datosVendedor),
              'fecha_creacion': DateTime.now().toIso8601String(),
            }, conflictAlgorithm: ConflictAlgorithm.replace);

            await db.insert('operaciones_pendientes', {
              'tabla': rutaCliente,
              'operacion': 'set',
              'doc_id': docTargetCliente,
              'datos_json': jsonEncode(datosCliente),
              'fecha_creacion': DateTime.now().toIso8601String(),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }

        // 🔥 MENSAJE VERDE GARANTIZADO DE RETROALIMENTACIÓN
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("🎉 Punto sumado a $nombreLimpio en $tituloTarjeta ($newPts/$meta)"),
              backgroundColor: Colors.green.shade800,
              duration: const Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint("Error general en _otorgarPuntoFidelidadAutomatico: $e");
    }
  }

  void _mostrarModalInvitacionWhatsApp(String clienteNombre, String telefono, String premioDesc, String token, int meta, String tituloTarjeta, {double montoMinimo = 0.0}) {
    String numLimpio = telefono.replaceAll(RegExp(r'\D'), '');
    String ind = "57";
    String telSolo = numLimpio;

    if (numLimpio.length > 10) {
      ind = numLimpio.substring(0, numLimpio.length - 10);
      telSolo = numLimpio.substring(numLimpio.length - 10);
    }

    TextEditingController indCtrl = TextEditingController(text: ind == "57" ? "" : ind);
    TextEditingController numCtrl = TextEditingController(text: telSolo);
    String enlaceUnico = "https://boxi-catalogo.web.app/reclamar?token=$token";

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.card_giftcard_rounded, color: Colors.green, size: 26),
            const SizedBox(width: 8),
            Expanded(child: Text("¡Invita a $clienteNombre!", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Invita a $clienteNombre a acumular sus compras para la tarjeta \"$tituloTarjeta\".", style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 15),
            const Text("Número de WhatsApp del cliente:", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 65,
                  child: TextField(
                    controller: indCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(prefixText: "+", hintText: "57", border: OutlineInputBorder(), isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: numCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 15),
            // 🔥 BOTÓN PARA COPIAR ENLACE ÚNICO
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 42),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text("Copiar Enlace Único", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: enlaceUnico));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Enlace copiado al portapapeles 📋"), duration: Duration(seconds: 2))
                );
              },
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("DESPUÉS")),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF25D366), foregroundColor: Colors.white),
            icon: const Icon(Icons.send_rounded, size: 16),
            label: const Text("ENVIAR WHATSAPP"),
            onPressed: () async {
              Navigator.pop(ctx);
              final prefs = await SharedPreferences.getInstance();
              String nomNegocio = prefs.getString('nombre_negocio') ?? "Nuestro Negocio";
              String indClean = indCtrl.text.trim().replaceAll(RegExp(r'\D'), '');
              if (indClean.isEmpty) indClean = "57";
              String telClean = numCtrl.text.trim().replaceAll(RegExp(r'\D'), '');
              String fullNum = "$indClean$telClean";

              String textoMonto = "";
              if (montoMinimo > 0) {
                String mFormateado = montoMinimo == montoMinimo.roundToDouble() 
                    ? montoMinimo.toInt().toString() 
                    : montoMinimo.toStringAsFixed(0);
                textoMonto = " de *\$$mFormateado* o más";
              }

              String premioTxt = premioDesc.isNotEmpty ? premioDesc : tituloTarjeta;
              String mensaje = "¡Hola *$clienteNombre*! 🎁 *$nomNegocio* te obsequió *1 punto* para tu tarjeta de regalo *$tituloTarjeta*.\n\nPor *$meta* compras$textoMonto obtienes *$premioTxt*.\n\n*Al completar $meta puntos llevas el premio, descarga la app BOXI para empezar a acumular puntos:*\n$enlaceUnico";
              String urlWa = "https://wa.me/$fullNum?text=${Uri.encodeComponent(mensaje)}";
              if (await canLaunchUrl(Uri.parse(urlWa))) {
                await launchUrl(Uri.parse(urlWa), mode: LaunchMode.externalApplication);
              }
            },
          ),
        ],
      ),
    );
  }

  Future<void> _actualizarCantidadDetalle(
      Map<String, dynamic> item,
      int pedidoId,
      int incremento,
      StateSetter setSt,
      Function(List<Map<String, dynamic>>) callback) async {
    _invalidarCache(pedidoId);
    int nuevaCantidad = (item['cantidad'] as int) + incremento;
    if (nuevaCantidad < 1) return;

    // 🔥 1. Actualización visual ultrarrápida (sin recargar desde BD)
    try {
      setSt(() {
        item['cantidad'] = nuevaCantidad;
        item['subtotal'] = nuevaCantidad * (item['precio_unitario'] as num).toDouble();
      });
    } catch (_) {}

    // 🔥 2. Tarea asíncrona silenciosa para guardar en Base de Datos y Nube
    Future.microtask(() async {
      final db = await DBHelper.instance.database;
      double nuevoSubtotal = nuevaCantidad * (item['precio_unitario'] as num).toDouble();
      int detId = item['id'] as int;

      await db.update(
          'detalle_pedidos',
          {
            'cantidad': nuevaCantidad,
            'subtotal': nuevoSubtotal,
            'ultima_modificacion': DateTime.now().toIso8601String()
          },
          where: 'id = ?',
          whereArgs: [detId]);

      if (item['producto_id'] != null) {
        await _modificarStockBD(
            item['producto_id'] as int, incremento, item['nombre_snapshot']?.toString());
      }

      if (_esPremium) {
        var d = await db.query('detalle_pedidos', where: 'id = ?', whereArgs: [detId]);
        if (d.isNotEmpty) ServicioNube.guardarUnicoDetalleNube(d.first);
      }

      await _recalcularTotal(pedidoId);
      _cargar(); // Solo actualiza la pantalla principal atrás
    });
  }

  Future<Map<String, dynamic>?> _cambiarVariante(Map<String, dynamic> item, int pedId) async {
    String varStr = item['prod_variantes']?.toString() ?? "";
    if (varStr.length < 5) return null;

    List<dynamic> grupos;
    try {
      grupos = jsonDecode(varStr);
    } catch (_) {
      return null;
    }

    final db = await DBHelper.instance.database;
    final fotosVariantes = await db.query(
      'fotos_variantes',
      where: 'producto_id = ?',
      whereArgs: [item['producto_id']],
    );

    if (!mounted) return null;

    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          title: const Text("Reemplazar Variante", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: grupos.asMap().entries.expand((gEntry) {
                int gIndex = gEntry.key;
                var g = gEntry.value;

                return (g['opciones'] as List).asMap().entries.map((oEntry) {
                  int oIndex = oEntry.key;
                  var o = oEntry.value;

                  if (o['activo'] == false) return const SizedBox.shrink();
                  String nombreNueva =
                      "${item['prod_nombre_base']} - ${g['grupo']}: ${o['nombre']}";
                  bool isCurrent = nombreNueva == item['nombre_prod'];

                  var fotoMatch = fotosVariantes.where((f) => 
                    f['grupo_index'] == gIndex && f['opcion_index'] == oIndex
                  );
                  String? fotoBase64 = fotoMatch.isNotEmpty ? fotoMatch.first['foto_base64'] as String? : null;

                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: _construirMiniatura(fotoBase64, isOscuro),
                    title: Text(o['nombre'],
                        style: TextStyle(
                            color: isOscuro ? Colors.white : Colors.black87,
                            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal)),
                    subtitle: Text("Stock: ${o['stock']}",
                        style: TextStyle(
                            color: isOscuro ? Colors.white54 : Colors.black54)),
                    trailing: isCurrent
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : const Icon(Icons.swap_horiz, color: Colors.orange),
                    onTap: isCurrent
                        ? null
                        : () {
                            // 🔥 Guardamos todos los datos planos antes de cerrar
                            final result = {
                              'nombreNueva': nombreNueva,
                              'fotoBase64': fotoBase64,
                              'nombreViejo': item['nombre_snapshot']?.toString() ?? "",
                              'cantidad': item['cantidad'] as int,
                              'productoId': item['producto_id'] as int,
                              'detalleId': item['id'] as int
                            };
                            Navigator.pop(ctx, result);
                          },
                  );
                }).toList();
              }).toList().cast<Widget>(),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("CANCELAR", style: TextStyle(color: Colors.grey)))
          ],
        );
      },
    );
  }

  // Guardado asíncrono silencioso en segundo plano sin interrumpir la interfaz
  void _procesarCambioVarianteEnSegundoPlano(
      int detalleId, int prodId, int cantidadVendida, String nombreViejo, String nombreNueva, int pedId) async {
    
    // Modificaciones locales rápidas de SQLite (Ahora usan los strings correctos)
    await _modificarStockBD(prodId, -cantidadVendida, nombreViejo);
    await _modificarStockBD(prodId, cantidadVendida, nombreNueva);

    final db = await DBHelper.instance.database;
    await db.update(
        'detalle_pedidos',
        {
          'nombre_snapshot': nombreNueva,
          'ultima_modificacion': DateTime.now().toIso8601String()
        },
        where: 'id = ?',
        whereArgs: [detalleId]);

    if (_esPremium) {
      // Subida de fondo sin 'await' para evitar bloqueos
      db.query('detalle_pedidos', where: 'id = ?', whereArgs: [detalleId]).then((d) {
        if (d.isNotEmpty) ServicioNube.guardarUnicoDetalleNube(d.first);
      });
    }

    _invalidarCache(pedId);
  }
  
  Future<void> _actualizarDescuentoDetalle(
      Map<String, dynamic> item,
      int pedidoId,
      double nuevoDesc,
      StateSetter setSt,
      Function(List<Map<String, dynamic>>) callback) async {
    final db = await DBHelper.instance.database;
    double precioBase = (item['precio_unitario'] as num).toDouble();
    int cant = item['cantidad'] as int;
    double nuevoSubtotal = (precioBase - (precioBase * (nuevoDesc / 100))) * cant;

    await db.update(
        'detalle_pedidos',
        {
          'descuento': nuevoDesc,
          'subtotal': nuevoSubtotal,
          'ultima_modificacion': DateTime.now().toIso8601String()
        },
        where: 'id = ?',
        whereArgs: [item['id']]);

    if (_esPremium) {
      var d = await db.query('detalle_pedidos', where: 'id = ?', whereArgs: [item['id']]);
      if (d.isNotEmpty) ServicioNube.guardarUnicoDetalleNube(d.first);
    }

    await _recalcularTotal(pedidoId);
    _actualizarVistaEditor(pedidoId, setSt, callback);
  }

  void _abrirEditorPedido(Map<String, dynamic> pedido) async {
    final int pedId = pedido['id'] as int;
    List<Map<String, dynamic>> detalles = await _obtenerDetalles(pedId);
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    String formatearInicial(dynamic val) {
      if (val == null) return "";
      double d = (val as num).toDouble();
      if (d <= 0) return "";
      return (d == d.roundToDouble()) ? d.toInt().toString() : d.toStringAsFixed(2);
    }

    TextEditingController domiCtrl =
        TextEditingController(text: formatearInicial(pedido['valor_domicilio'] ?? 0));
    final Map<int, TextEditingController> descCtrls = {};
    for (var item in detalles) {
      descCtrls[item['id'] as int] = TextEditingController(text: formatearInicial(item['descuento'] ?? 0));
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSt) {
          double subtotalProds =
              detalles.fold(0, (sum, i) => sum + (i['subtotal'] as num).toDouble());
          double domiActual = double.tryParse(domiCtrl.text) ?? 0;

          return GestureDetector(
            onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
            child: AlertDialog(
              backgroundColor: Theme.of(context).cardColor,
            insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("Editar Pedido",
                    style: TextStyle(
                        color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
                        fontWeight: FontWeight.bold,
                        fontSize: 20)),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                        icon: const Icon(Icons.add_circle, color: Colors.green, size: 30),
                        tooltip: "Añadir producto",
                        onPressed: () =>
                            _buscarYAgregar(pedId, setSt, (newList) => detalles = newList)),
                    IconButton(
                        icon: Icon(Icons.close,
                            color: isOscuro ? Colors.white54 : Colors.grey, size: 26),
                        tooltip: "Cerrar",
                        onPressed: () => Navigator.pop(ctx)), // 🔥 BOTÓN X PARA SALIR
                  ],
                ),
              ],
            ),
            content: SizedBox(
              width: MediaQuery.of(context).size.width * 0.9,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: domiCtrl,
                      keyboardType: TextInputType.number,
                      style: TextStyle(color: isOscuro ? Colors.white : Colors.black),
                      decoration: InputDecoration(
                        labelText: "Costo de Domicilio",
                        hintText: "0",
                        labelStyle:
                            TextStyle(color: isOscuro ? Colors.white60 : Colors.black54),
                        prefixIcon: const Icon(Icons.motorcycle, color: Colors.blue),
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (v) => setSt(() {}),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        icon: const Icon(Icons.percent, size: 16, color: Colors.orange),
                        label: const Text("Aplicar % a todo",
                            style: TextStyle(
                                color: Colors.orange, fontWeight: FontWeight.bold)),
                        onPressed: () => _promptDescuentoGlobal(
                            pedId, detalles, setSt, (newList) => detalles = newList),
                      ),
                    ),
                    const Divider(height: 30),
                    ...detalles.map((item) {
                      final int idDetalle = item['id'] as int;
                      if (!descCtrls.containsKey(idDetalle)) {
                        descCtrls[idDetalle] = TextEditingController(
                            text: formatearInicial(item['descuento'] ?? 0));
                      }
                      final descCtrl = descCtrls[idDetalle]!;
                      bool tieneVariantes = item['prod_variantes'] != null &&
                          item['prod_variantes'].toString().length > 5;
                      double pUnitario = (item['precio_unitario'] as num).toDouble();
                      double dPct = (item['descuento'] ?? 0).toDouble();
                      int cant = (item['cantidad'] as int);
                      double subtotalItem = (pUnitario - (pUnitario * (dPct / 100))) * cant;

                      return Card(
                        margin: const EdgeInsets.only(bottom: 15),
                        color: isOscuro
                            ? Colors.white.withOpacity(0.05)
                            : Colors.grey.shade50,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15),
                            side: BorderSide(
                                color: isOscuro ? Colors.white10 : Colors.black12)),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 🔥 AQUÍ SE ARREGLA EL PARPADEO. Se usa foto_data directo.
                              Row(
                                children: [
                                  _construirMiniatura(item['foto_data']?.toString(), isOscuro),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(item['nombre_prod'],
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                            color: isOscuro ? Colors.white : Colors.black87)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Container(
                                    decoration: BoxDecoration(
                                        color: isOscuro ? Colors.white10 : Colors.white,
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                            color: isOscuro
                                                ? Colors.white10
                                                : Colors.black12)),
                                    child: Row(
                                      children: [
                                        IconButton(
                                            icon: const Icon(Icons.remove,
                                                size: 18, color: Colors.red),
                                            onPressed: () => _actualizarCantidadDetalle(
                                                item, pedId, -1, setSt, (l) => detalles = l)),
                                        Text("${item['cantidad']}",
                                            style: const TextStyle(
                                                fontWeight: FontWeight.bold, fontSize: 15)),
                                        IconButton(
                                            icon: const Icon(Icons.add,
                                                size: 18, color: Colors.green),
                                            onPressed: () => _actualizarCantidadDetalle(
                                                item, pedId, 1, setSt, (l) => detalles = l)),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextField(
                                      controller: descCtrl,
                                      keyboardType: TextInputType.number,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: isOscuro ? Colors.white : Colors.black),
                                      decoration: InputDecoration(
                                        hintText: "0",
                                        labelText: "% Desc",
                                        isDense: true,
                                        contentPadding:
                                            const EdgeInsets.symmetric(vertical: 10),
                                        border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(8)),
                                      ),
                                      onChanged: (v) {
                                        setSt(() {
                                          double parsed = double.tryParse(v) ?? 0;
                                          item['descuento'] = double.parse(parsed.toStringAsFixed(2));
                                          double pU = (item['precio_unitario'] as num).toDouble();
                                          double dP = (item['descuento'] as num).toDouble();
                                          item['subtotal'] = (pU - (pU * (dP / 100))) * (item['cantidad'] as int);
                                        });
                                      },
                                      onEditingComplete: () {
                                        double val =
                                            double.tryParse(descCtrl.text) ?? 0;
                                        _actualizarDescuentoDetalle(
                                            item, pedId, val, setSt, (l) => detalles = l);
                                        FocusScope.of(context).unfocus();
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (tieneVariantes)
                                        IconButton(
                                          icon: const Icon(Icons.swap_horiz,
                                              color: Colors.orange, size: 24),
                                          onPressed: () async {
                                            // 🔥 Esperamos el mapa de datos limpios
                                            final result = await _cambiarVariante(item, pedId);
                                            if (result != null && mounted) {
                                              setSt(() {
                                                // Refleja en pantalla instantáneamente sin parpadeo
                                                item['nombre_prod'] = result['nombreNueva'];
                                                item['nombre_snapshot'] = result['nombreNueva'];
                                                item['foto_data'] = result['fotoBase64']; 
                                              });
                                              // Ejecuta la BD en fondo con la info exacta, sin referenciar
                                              _procesarCambioVarianteEnSegundoPlano(
                                                  result['detalleId'], 
                                                  result['productoId'], 
                                                  result['cantidad'], 
                                                  result['nombreViejo'], 
                                                  result['nombreNueva'], 
                                                  pedId);
                                            }
                                          },
                                        ),
                                      IconButton(
                                          icon: const Icon(Icons.delete_outline,
                                              color: Colors.redAccent, size: 24),
                                          onPressed: () async {
                                            if (item['producto_id'] != null) {
                                              await _modificarStockBD(
                                                  item['producto_id'] as int,
                                                  -(item['cantidad'] as int),
                                                  item['nombre_snapshot']?.toString());
                                            }
                                            final db = await DBHelper.instance.database;
                                            await db.delete('detalle_pedidos',
                                                where: 'id = ?', whereArgs: [item['id']]);
                                            if (_esPremium)
                                              ServicioNube.eliminarDetallePedidoNube(
                                                  item['id']);
                                            _recalcularTotal(pedId);
                                            descCtrls.remove(item['id']); 
                                            _actualizarVistaEditor(pedId, setSt, (newList) {
                                              detalles = newList;
                                            });
                                          })
                                    ],
                                  )
                                ],
                              ),
                              const SizedBox(height: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                    color: isOscuro
                                        ? Colors.black26
                                        : Colors.black.withOpacity(0.02),
                                    borderRadius: BorderRadius.circular(8)),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text("Subtotal ítem:",
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: isOscuro
                                                ? Colors.white38
                                                : Colors.black54)),
                                    Text("\$${subtotalItem.toStringAsFixed(0)}",
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                            color: isOscuro
                                                ? Colors.greenAccent
                                                : Colors.green.shade700)),
                                  ],
                                ),
                              )
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ],
                ),
              ),
            ),
            actions: [
              Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                    color: isOscuro
                        ? Colors.white.withOpacity(0.05)
                        : Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(15)),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("TOTAL FINAL:",
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14)),
                        Text("\$${(subtotalProds + domiActual).toStringAsFixed(0)}",
                            style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                                color: Colors.green)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0D47A1),
                          minimumSize: const Size(double.infinity, 50),
                          shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15))),
                      onPressed: () async { 
                        for (var item in detalles) {
                          int idDetalle = item['id'] as int;
                          if (!descCtrls.containsKey(idDetalle)) {
                            descCtrls[idDetalle] = TextEditingController(
                                text: formatearInicial(item['descuento'] ?? 0));
                          }
                          double descActual =
                              double.tryParse(descCtrls[idDetalle]!.text) ?? 0;
                          await _actualizarDescuentoDetalle(
                              item, pedId, descActual, setSt, (l) => detalles = l);
                        }
                        double valFinalDomi = double.tryParse(domiCtrl.text) ?? 0;
                        await _actualizarDomicilio(pedId, valFinalDomi); // Esto internamente recalcula e invalida la caché
                        
                        if (mounted) {
                          Navigator.pop(ctx);
                          await _cargar(); // 🔥 Recarga el listado general con la caché limpia
                        }
                      },
                      child: const Text("GUARDAR CAMBIOS",
                          style: TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ],
          ), 
          ); 
        },
      ),
    );
  }

  void _promptDescuentoGlobal(int pedId, List<Map<String, dynamic>> detalles,
      StateSetter setStEditor, Function(List<Map<String, dynamic>>) callback) {
    TextEditingController pctCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => GestureDetector(
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(), // Oculta teclado
        behavior: HitTestBehavior.translucent,
        child: AlertDialog(
          title: const Text("Descuento Global"),
        content: TextField(
          controller: pctCtrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
              labelText: "Porcentaje para todos los productos", suffixText: "%"),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
          ElevatedButton(
            onPressed: () async {
              double pct = double.tryParse(pctCtrl.text) ?? 0;
              Navigator.pop(ctx);
              for (var item in detalles) {
                await _actualizarDescuentoDetalle(
                    item, pedId, pct, setStEditor, callback);
              }
            },
            child: const Text("APLICAR"),
          )
        ],
      ), 
      ), 
    ); 
  }

  Future<void> _buscarYAgregar(int pedId, StateSetter setStEditor,
    Function(List<Map<String, dynamic>>) callback) async {
    final db = await DBHelper.instance.database;
    final yaEnPedido = await db.query('detalle_pedidos',
        columns: ['producto_id', 'nombre_snapshot'],
        where: 'pedido_id = ?',
        whereArgs: [pedId]);
    List<int> idsSimplesOcultos = [];
    List<String> nombresVariantesOcultas = [];
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    for (var item in yaEnPedido) {
      String nombre = item['nombre_snapshot']?.toString() ?? "";
      if (nombre.contains(" - ")) {
        nombresVariantesOcultas.add(nombre);
      } else {
        idsSimplesOcultos.add(item['producto_id'] as int);
      }
    }

    List<Map<String, dynamic>> productosBase = await db.query('productos', where: 'activo = 1');
    List<Map<String, dynamic>> productosPermitidos = [];
    for (var p in productosBase) {
      String varStr = p['variantes']?.toString() ?? "";
      if (varStr.length < 5 && idsSimplesOcultos.contains(p['id'])) continue;
      if (varStr.length > 5) {
        bool tieneOpcionesLibres = false;
        try {
          List<dynamic> grps = jsonDecode(varStr);
          if (grps.isNotEmpty && !grps[0].containsKey('grupo')) {
            grps = [{'grupo': 'Opciones', 'opciones': grps}];
          }
          for (var g in grps) {
            if (!g.containsKey('grupo')) continue;
            for (var o in g['opciones']) {
              if (o['activo'] == false) continue;
              String nombreVar = "${p['nombre']} - ${g['grupo']}: ${o['nombre']}";
              String nombreAntigua = "${p['nombre']} - ${o['nombre']}";
              if (!nombresVariantesOcultas.contains(nombreVar) &&
                  !nombresVariantesOcultas.contains(nombreAntigua)) {
                tieneOpcionesLibres = true;
                break;
              }
            }
            if (tieneOpcionesLibres) break;
          }
        } catch (_) {}
        if (!tieneOpcionesLibres) continue;
      }
      productosPermitidos.add(Map<String, dynamic>.from(p));
    }

    List<Map<String, dynamic>> filtrados = List.from(productosPermitidos);
    TextEditingController searchCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStSearch) => GestureDetector(
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          behavior: HitTestBehavior.translucent,
          child: AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                  child: Text("Añadir al pedido",
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)))),
              IconButton(
                  icon: Icon(Icons.close,
                      color: isOscuro ? Colors.white54 : Colors.grey),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => Navigator.pop(ctx))
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: searchCtrl,
                  style: TextStyle(color: isOscuro ? Colors.white : Colors.black),
                  decoration: InputDecoration(
                  hintText: "Buscar producto...",
                  hintStyle:
                      TextStyle(color: isOscuro ? Colors.white38 : Colors.black54),
                  prefixIcon: Icon(Icons.search,
                      color: isOscuro ? Colors.cyanAccent : Colors.grey),
                  filled: true,
                  fillColor: isOscuro ? Colors.white10 : Colors.grey.shade100,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none)),
                  onChanged: (v) {
                    setStSearch(() {
                      filtrados = productosPermitidos
                      .where((p) => p['nombre']
                          .toString()
                          .toLowerCase()
                          .contains(v.toLowerCase()))
                      .toList();
                    });
                  },
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: filtrados.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text("Todos los productos ya están en este pedido.",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: isOscuro ? Colors.white38 : Colors.grey)))
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: filtrados.length,
                          itemBuilder: (c, i) {
                            var p = filtrados[i];
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(vertical: 4),
                              leading: MiniaturaProductoLocal(key: ValueKey("min_${p['id']}"), id: p['id'] as int, isOscuro: isOscuro), // 🔥 Clave única para evitar reutilizar fotos de otros productos
                              title: Text(p['nombre'].toString(),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: isOscuro ? Colors.white : Colors.black87)),
                              subtitle: Text("Stock: ${p['stock']}",
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: isOscuro ? Colors.white54 : Colors.black54)),
                              trailing: Text("\$${p['precio_venta']}",
                                  style: TextStyle(
                                      color: isOscuro ? Colors.greenAccent : Colors.green,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14)),
                              onTap: () async {
                                String varStr = p['variantes']?.toString() ?? "";
                                List<dynamic> grps = [];
                                if (varStr.length > 5) {
                                  try {
                                    var dec = jsonDecode(varStr);
                                    if (dec.isNotEmpty && !dec[0].containsKey('grupo')) {
                                      grps = [{'grupo': 'Opciones', 'opciones': dec}];
                                    } else {
                                      grps = dec;
                                    }
                                  } catch (_) {}
                                }

                                if (grps.isNotEmpty) {
                                  // 🔥 1. Traemos las fotos ANTES de filtrar y ANTES de cerrar
                                  final fotosVariantes = await db.query(
                                    'fotos_variantes',
                                    where: 'producto_id = ?',
                                    whereArgs: [p['id']],
                                  );

                                  for (int gIdx = 0; gIdx < grps.length; gIdx++) {
                                    var g = grps[gIdx];
                                    if (!g.containsKey('grupo')) continue;
                                    for (int oIdx = 0; oIdx < g['opciones'].length; oIdx++) {
                                      var o = g['opciones'][oIdx];
                                      var fotoMatch = fotosVariantes.where((f) => 
                                        f['grupo_index'] == gIdx && f['opcion_index'] == oIdx
                                      );
                                      if (fotoMatch.isNotEmpty) {
                                        o['foto_path'] = fotoMatch.first['foto_base64'];
                                      }
                                    }
                                  }

                                  // 🔥 2. AHORA SÍ filtramos las que están inactivas/ocultas
                                  for (var g in grps) {
                                    if (!g.containsKey('grupo')) continue;
                                    g['opciones'] = (g['opciones'] as List).where((o) {
                                      if (o['activo'] == false) return false;
                                      String nombreVar = "${p['nombre']} - ${g['grupo']}: ${o['nombre']}";
                                      String nombreAntigua = "${p['nombre']} - ${o['nombre']}";
                                      return !nombresVariantesOcultas.contains(nombreVar) &&
                                             !nombresVariantesOcultas.contains(nombreAntigua);
                                    }).toList();
                                  }

                                  // 🔥 3. Comprobamos estado y CERRAMOS la búsqueda JUSTO antes de abrir el modal
                                  if (!mounted) return;
                                  Navigator.pop(ctx); 

                                  showModalBottomSheet(
                                    context: context,
                                    isScrollControlled: true,
                                    backgroundColor: Colors.transparent,
                                    builder: (_) => _DialogoVariantes(
                                      producto: p,
                                      gruposVariantes: grps,
                                      onAceptar: (cantidades) async {
                                        int pId = p['id'] as int;
                                        double pr = (p['precio_venta'] as num).toDouble();
                                        double descProd = (p['descuento'] ?? 0).toDouble();
                                        double prConDesc = pr - (pr * (descProd / 100));

                                        for (var entry in cantidades.entries) {
                                          if (entry.value > 0) {
                                            List<String> partes =
                                                entry.key.split('_');
                                            int gIndex = int.parse(partes[0]);
                                            int oIndex = int.parse(partes[1]);
                                            var g = grps[gIndex];
                                            var o = g['opciones'][oIndex];
                                            String nombreVar =
                                                "${p['nombre']} - ${g['grupo']}: ${o['nombre']}";
                                            int uniqueId =
                                                DateTime.now().millisecondsSinceEpoch +
                                                    entry.key.hashCode;
                                            await db.insert('detalle_pedidos', {
                                              'id': uniqueId,
                                              'pedido_id': pedId,
                                              'producto_id': pId,
                                              'cantidad': entry.value,
                                              'precio_unitario': pr,
                                              'descuento': descProd, 
                                              'subtotal': prConDesc * entry.value, 
                                              'nombre_snapshot': nombreVar,
                                              'ultima_modificacion':
                                                  DateTime.now().toIso8601String()
                                            });
                                            if (_esPremium) {
                                              ServicioNube.guardarUnicoDetalleNube({
                                                'id': uniqueId,
                                                'pedido_id': pedId,
                                                'producto_id': pId,
                                                'cantidad': entry.value,
                                                'precio_unitario': pr,
                                                'descuento': descProd, 
                                                'subtotal': prConDesc * entry.value, 
                                                'nombre_snapshot': nombreVar
                                              });
                                            }
                                            await _modificarStockBD(
                                                pId, entry.value, nombreVar);
                                          }
                                        }
                                        await _recalcularTotal(pedId); 
                                        _actualizarVistaEditor(
                                            pedId, setStEditor, callback);
                                        _cargar();
                                      },
                                    ),
                                  );
                                } else {
                                  int pId = p['id'] as int;
                                  double pr = (p['precio_venta'] as num).toDouble();
                                  String nombre = p['nombre'].toString();
                                  double descProd = (p['descuento'] ?? 0).toDouble();
                                  double prConDesc = pr - (pr * (descProd / 100));
                                  
                                  int uniqueId = DateTime.now().millisecondsSinceEpoch;
                                  await db.insert('detalle_pedidos', {
                                    'id': uniqueId,
                                    'pedido_id': pedId,
                                    'producto_id': pId,
                                    'cantidad': 1,
                                    'precio_unitario': pr,
                                    'descuento': descProd, 
                                    'subtotal': prConDesc, 
                                    'nombre_snapshot': nombre,
                                    'ultima_modificacion':
                                        DateTime.now().toIso8601String()
                                  });
                                  if (_esPremium) {
                                    ServicioNube.guardarUnicoDetalleNube({
                                      'id': uniqueId,
                                      'pedido_id': pedId,
                                      'producto_id': pId,
                                      'cantidad': 1,
                                      'precio_unitario': pr,
                                      'descuento': descProd, 
                                      'subtotal': prConDesc,
                                      'nombre_snapshot': nombre
                                    });
                                  }
                                  await _modificarStockBD(pId, 1, nombre);
                                  await _recalcularTotal(pedId);
                                  if (mounted) Navigator.pop(ctx);
                                  _actualizarVistaEditor(pedId, setStEditor, callback);
                                  _cargar();
                                }
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ), 
        ), 
      ),
    ); 
  }

  Future<void> _actualizarDomicilio(int pedidoId, double nuevoVal) async {
    final db = await DBHelper.instance.database;
    await db.update(
        'pedidos',
        {
          'valor_domicilio': nuevoVal,
          'ultima_modificacion': DateTime.now().toIso8601String()
        },
        where: 'id = ?',
        whereArgs: [pedidoId]);
    await _recalcularTotal(pedidoId);
    _cargar();
  }

  Future<void> _recalcularTotal(int pedId) async {
  _invalidarCache(pedId); // 🔥 CORRECCIÓN: Limpia la caché para obligar a recargar desde la BD
  final db = await DBHelper.instance.database;
  var pedData = await db.query('pedidos',
      columns: ['valor_domicilio'], where: 'id = ?', whereArgs: [pedId]);
  if (pedData.isEmpty) return;
  double domVal = (pedData.first['valor_domicilio'] ?? 0.0) as double;
  var res = await db.rawQuery('''
    SELECT SUM(subtotal) as total_prods,
           SUM(subtotal - (cantidad * COALESCE((SELECT precio_compra FROM productos WHERE id = producto_id), 0))) as ganancia
    FROM detalle_pedidos WHERE pedido_id = $pedId
  ''');
  double tProds = (res.first['total_prods'] as num?)?.toDouble() ?? 0.0;
  double g = (res.first['ganancia'] as num?)?.toDouble() ?? 0.0;
  double totalFinal = tProds + domVal;
  await db.update(
      'pedidos',
      {
        'total_venta': totalFinal,
        'ganancia_total': g,
        'valor_domicilio': domVal,
        'ultima_modificacion': DateTime.now().toIso8601String()
      },
      where: 'id = ?',
      whereArgs: [pedId]);

  if (_esPremium) {
    ServicioNube.actualizarTotalesPedidoNube(pedId, totalFinal, g, domicilio: domVal);
  }
}

  Future<void> _actualizarVistaEditor(int pedId, StateSetter setSt,
      Function(List<Map<String, dynamic>>) callback) async {
    List<Map<String, dynamic>> res = await _obtenerDetalles(pedId);
    try {
      setSt(() => callback(res));
    } catch (_) {}
    _cargar();
  }

  Widget _buildResumenEstadisticas(bool isOscuro) {
    final estados = ['Pendiente', 'Entregado sin Pago', 'Completado', 'Cancelado'];
    return Container(
      height: 80,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: estados.map((estado) {
          final count = _pedidos.where((p) => p['estado'] == estado).length;
          final color = _coloresEstado[estado]!;
          final icon = _iconosEstado[estado]!;
          final seleccionado = _estadoActual == estado;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _estadoActual = estado),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: seleccionado
                      ? color.withOpacity(isOscuro ? 0.25 : 0.12)
                      : (isOscuro ? Colors.white.withOpacity(0.04) : Colors.white),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: seleccionado ? color: isOscuro ? Colors.white12 : Colors.black.withOpacity(0.08),
                    width: seleccionado ? 1.5 : 1,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, color: color, size: 20),
                    const SizedBox(height: 4),
                    Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: seleccionado
                            ? color
                            : (isOscuro ? Colors.white54 : Colors.black45),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildChipsFiltro(bool isOscuro) {
    final estados = ['Pendiente', 'Entregado sin Pago', 'Completado', 'Cancelado'];
    final etiquetas = ['Pendientes', 'Sin Pago', 'Completados', 'Cancelados'];
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: estados.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final seleccionado = _estadoActual == estados[i];
          final color = _coloresEstado[estados[i]]!;
          return GestureDetector(
            onTap: () => setState(() => _estadoActual = estados[i]),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: seleccionado
                    ? color.withOpacity(isOscuro ? 0.3 : 0.15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: seleccionado ? color : (isOscuro ? Colors.white12 : Colors.black12),
                ),
              ),
              child: Text(
                etiquetas[i],
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: seleccionado ? FontWeight.bold : FontWeight.normal,
                  color: seleccionado
                      ? color
                      : (isOscuro ? Colors.white54 : Colors.black54),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    final colorEstado = _coloresEstado[_estadoActual]!;
    return Scaffold(
      backgroundColor:
          isOscuro ? const Color(0xFF0A0A0F) : const Color(0xFFF2F4F7),
      appBar: AppBar(
        elevation: 0,
        backgroundColor:
            isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Gestión de Pedidos',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 17)),
            Text(
              '${_pedidos.where((p) => p['estado'] == _estadoActual).length} ${_estadoActual.toLowerCase()}',
              style: TextStyle(
                  color: colorEstado.withOpacity(0.9),
                  fontSize: 11,
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          if (_esPremium)
            RotationTransition(
              turns: _refreshAnim,
              child: IconButton(
                icon: Icon(
                  Icons.sync_rounded,
                  color: _refrescando ? colorEstado : Colors.white70,
                  size: 24,
                ),
                tooltip: 'Sincronizar desde la nube',
                onPressed: _refrescando ? null : _refrescarDesdeNube,
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh_rounded, color: Colors.white70, size: 22),
              tooltip: 'Recargar local',
              onPressed: _cargar,
            ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 10),
          _buildResumenEstadisticas(isOscuro),
          const SizedBox(height: 10),
          _buildChipsFiltro(isOscuro),
          const SizedBox(height: 8),
          Expanded(child: _listaPedidosAgrupada(isOscuro)),
        ],
      ),
    );
  }

  Widget _listaPedidosAgrupada(bool isOscuro) {
    final filtrados = _pedidos.where((p) => p['estado'] == _estadoActual).toList();
    if (filtrados.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _iconosEstado[_estadoActual]!,
              size: 64,
              color: isOscuro ? Colors.white12 : Colors.black12,
            ),
            const SizedBox(height: 16),
            Text(
              'Sin pedidos ${_estadoActual.toLowerCase()}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isOscuro ? Colors.white24 : Colors.black26,
              ),
            ),
          ],
        ),
      );
    }

    final grupos = _agruparPorFecha(filtrados);
    final fechasOrdenadas = grupos.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
      itemCount: fechasOrdenadas.length,
      itemBuilder: (context, idx) {
        final fecha = fechasOrdenadas[idx];
        final pedidosGrupo = grupos[fecha]!;
        final totalGrupo = pedidosGrupo.fold<double>(
            0, (sum, p) => sum + (p['total_venta'] as num).toDouble());
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _coloresEstado[_estadoActual]!.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: _coloresEstado[_estadoActual]!.withOpacity(0.3)),
                    ),
                    child: Text(
                      _formatearFechaGrupo(fecha),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: _coloresEstado[_estadoActual],
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Divider(color: isOscuro ? Colors.white10 : Colors.black.withOpacity(0.08))),                  const SizedBox(width: 8),
                  Text(
                    '\$${totalGrupo.toStringAsFixed(0)}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isOscuro ? Colors.white38 : Colors.black38,
                    ),
                  ),
                ],
              ),
            ),
            ...pedidosGrupo.map((p) => _buildTarjetaPedido(p, isOscuro)),
          ],
        );
      },
    );
  }

  Widget _buildTarjetaPedido(Map<String, dynamic> p, bool isOscuro) {
    final estado = p['estado'] as String;
    final colorEst = _coloresEstado[estado]!;
    final bool hayBloqueo = _pedidosBloqueados[p['id'] as int] ?? false;

    String nombreCliente = p['cliente_nombre'] ?? p['cliente_nombre_snapshot'] ?? 'Cliente no registrado';
    String neg = (p['negocio_nombre'] ?? '').toString().trim();
    String ciudad = (p['cliente_ciudad'] ?? '').toString().trim();
    if (ciudad.isEmpty || ciudad == "null") ciudad = '';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isOscuro ? const Color(0xFF141420) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hayBloqueo
              ? Colors.red.withOpacity(0.4)
              : (isOscuro ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.06)),
        ),
        boxShadow: isOscuro
            ? []
            : [
                BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 8,
                    offset: const Offset(0, 2))
              ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          childrenPadding: EdgeInsets.zero,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                      radius: 20,
                      backgroundColor: isOscuro ? const Color(0xFF141420) : Colors.white,
                      child: Icon(
                        _iconosEstado[estado]!, 
                        color: colorEst, 
                        size: 20
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          nombreCliente,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: isOscuro ? Colors.white : Colors.black87,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.visible, 
                        ),
                        if (neg.isNotEmpty && neg != "null" && neg != "N/A") ...[
                          const SizedBox(height: 2),
                          Text(
                            neg,
                            style: TextStyle(
                              fontSize: 11,
                              color: isOscuro ? Colors.white30 : Colors.black45,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.visible, 
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Divider(
                  height: 1, 
                  color: isOscuro ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.06)
                ),
              ),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "TOTAL VENTA", 
                        style: TextStyle(
                          fontSize: 9, 
                          fontWeight: FontWeight.w900, 
                          color: isOscuro ? Colors.white38 : Colors.grey.shade500,
                          letterSpacing: 0.5
                        )
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '\$${(p['total_venta'] as num).toStringAsFixed(0)}',
                        style: TextStyle(
                          color: colorEst,
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                  if (ciudad.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: isOscuro ? Colors.white.withOpacity(0.03) : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: isOscuro ? Colors.white10 : Colors.black12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.location_on_rounded,
                              size: 12,
                              color: isOscuro ? Colors.white30 : Colors.black.withOpacity(0.40)),
                          const SizedBox(width: 4),
                          Text(
                            ciudad,
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: isOscuro ? Colors.white54 : Colors.black54),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
          children: [
            Divider(
                height: 1,
                color: isOscuro ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.06)),
            _buildDetalleItems(
                p['id'] as int, estado, (p['valor_domicilio'] ?? 0).toDouble(), isOscuro),
            if (hayBloqueo && estado == 'Pendiente')
              Container(
                margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Producto agotado — actualiza el inventario para procesar',
                        style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            _buildBotonesAccion(p, estado, hayBloqueo, isOscuro),
          ],
        ),
      ),
    );
  }

  Widget _buildDetalleItems(int id, String estado, double domi, bool isOscuro) {
    if (!_detallesCache.containsKey(id)) {
      return FutureBuilder<List<Map<String, dynamic>>>(
        future: _obtenerDetalles(id),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          _detallesCache[id] = snapshot.data!;
          return _construirListaDetallesWidget(snapshot.data!, id, estado, domi, isOscuro);
        },
      );
    }
    return _construirListaDetallesWidget(_detallesCache[id]!, id, estado, domi, isOscuro);
  }

  Widget _construirListaDetallesWidget(
      List<Map<String, dynamic>> detalles, int id, String estado, double domi, bool isOscuro) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Column(
        children: [
          ...detalles.map((d) {
            bool falta = (estado == 'Pendiente') && (d['sin_stock'] == 1);
            double base = (d['precio_unitario'] as num).toDouble();
            double descPct = (d['descuento'] ?? 0).toDouble();
            double finalP = base - (base * (descPct / 100));

            String formatDesc(double pct) =>
                pct == pct.roundToDouble() ? pct.toStringAsFixed(0) : pct.toStringAsFixed(1);

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  if (falta)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(Icons.warning_rounded, color: Colors.red, size: 13),
                    ),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: TextStyle(
                          fontSize: 12,
                          color: falta
                              ? Colors.red
                              : (isOscuro ? Colors.white70 : Colors.black87),
                        ),
                        children: [
                          TextSpan(text: d['nombre_prod']),
                          if (descPct > 0)
                            TextSpan(
                              text: ' (−${formatDesc(descPct)}%)',
                              style: const TextStyle(
                                  color: Colors.orange,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 10),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Text(
                    '${d['cantidad']} × \$${finalP.toStringAsFixed(0)}',
                    style: TextStyle(
                        fontSize: 12,
                        color: isOscuro ? Colors.white38 : Colors.black45),
                  ),
                ],
              ),
            );
          }),
          if (domi > 0) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.motorcycle_rounded,
                    size: 14,
                    color: isOscuro ? Colors.cyanAccent : Colors.blue),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('Domicilio / Envío',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: isOscuro ? Colors.cyanAccent : Colors.blue)),
                ),
                Text('\$${domi.toStringAsFixed(0)}',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: isOscuro ? Colors.cyanAccent : Colors.blue)),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Divider(color: isOscuro ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.06)),
        ],
      ),
    );
  }

  Widget _buildBotonesAccion(
      Map<String, dynamic> p, String estado, bool bloq, bool isOscuro) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
      child: Column(
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // 🔥 CAMBIADO: Botón PDF ahora llama a compartirFactura() para abrir apps recomendadas (WhatsApp, Gmail, etc.)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: isOscuro ? Colors.white70 : Colors.black54,
                  side: BorderSide(
                      color: isOscuro ? Colors.white12 : Colors.black12),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.share_rounded, size: 16), // Ícono de compartir para ser coherente
                label: const Text('PDF', style: TextStyle(fontSize: 12)),
                onPressed: () async {
                  final d = await _obtenerDetalles(p['id'] as int);
                  final prefs = await SharedPreferences.getInstance();
                  Map<String, dynamic> pedParaPdf = Map.from(p);
                  pedParaPdf['valor_domicilio'] =
                      (p['valor_domicilio'] ?? 0).toDouble();
                  List<Map<String, dynamic>> dPdf = d
                      .map((i) => {...Map<String, dynamic>.from(i), 'nombre': i['nombre_prod']})
                      .toList();
                  
                  // 🔥 CAMBIADO: Llama al nuevo método compartirFactura()
                  await ServicioPdf.compartirFactura(
                    pedido: pedParaPdf,
                    detalles: dPdf,
                    nombreNegocio:
                        prefs.getString('nombre_negocio') ?? "Mi Negocio",
                    logoPath: prefs.getString('logo_path'),
                    mostrarLogo:
                        _esPremium ? (_logoToggle[p['id']] ?? true) : false,
                  );
                },
              ),
              if (estado == 'Pendiente') ...[
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: isOscuro ? Colors.cyanAccent : Colors.indigo,
                    side: BorderSide(
                        color: isOscuro
                            ? Colors.cyanAccent.withOpacity(0.4)
                            : Colors.indigo.withOpacity(0.4)),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.edit_rounded, size: 16),
                  label: const Text('Editar', style: TextStyle(fontSize: 12)),
                  onPressed: () => _abrirEditorPedido(p),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    elevation: 0,
                  ),
                  icon: const Icon(Icons.local_shipping_rounded, size: 16),
                  label:
                      const Text('Entregar', style: TextStyle(fontSize: 12)),
                  onPressed: bloq
                      ? null
                      : () => _confirmarCambioEstado(
                          p['id'] as int, 'Entregado sin Pago'),
                ),
              ],
              if (estado == 'Pendiente' || estado == 'Entregado sin Pago')
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00C853),
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    elevation: 0,
                  ),
                  icon: const Icon(Icons.check_circle_rounded, size: 16),
                  label: const Text('Pagado', style: TextStyle(fontSize: 12)),
                  onPressed: bloq
                      ? null
                      : () =>
                          _confirmarCambioEstado(p['id'] as int, 'Completado'),
                ),
              if (estado != 'Cancelado' && estado != 'Completado')
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  ),
                  onPressed: () =>
                      _confirmarCambioEstado(p['id'] as int, 'Cancelado'),
                  child: const Text('Cancelar',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
            ],
          ),
          if (_esPremium)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('Logo en PDF',
                  style: TextStyle(
                      fontSize: 11,
                      color: isOscuro ? Colors.white38 : Colors.black38)),
              value: _logoToggle[p['id']] ?? true,
              activeColor:
                  isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
              onChanged: (v) => setState(() => _logoToggle[p['id']] = v!),
              controlAffinity: ListTileControlAffinity.leading,
            )
          else
            TextButton.icon(
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const PantallaPremium())),
              icon: const Icon(Icons.workspace_premium,
                  size: 14, color: Colors.orange),
              label: const Text('Premium para logo en PDF',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.orange,
                      fontWeight: FontWeight.bold)),
            ),
        ],
      ),
    );
  }
}

class _DialogoVariantes extends StatefulWidget {
  final Map<String, dynamic> producto;
  final List<dynamic> gruposVariantes;
  final Function(Map<String, int>) onAceptar;
  const _DialogoVariantes(
      {required this.producto,
      required this.gruposVariantes,
      required this.onAceptar});
  @override
  State<_DialogoVariantes> createState() => _DialogoVariantesState();
}

class _DialogoVariantesState extends State<_DialogoVariantes> {
  final Map<String, int> _cantidades = {};
  final Map<String, TextEditingController> _controllers = {};

  @override
  void initState() {
    super.initState();
    for (int g = 0; g < widget.gruposVariantes.length; g++) {
      var opciones = widget.gruposVariantes[g]['opciones'] ?? [];
      for (int o = 0; o < opciones.length; o++) {
        String key = "${g}_$o";
        _cantidades[key] = 0;
        _controllers[key] = TextEditingController(text: "0");
      }
    }
  }

  @override
  void dispose() {
    for (var ctrl in _controllers.values) ctrl.dispose();
    super.dispose();
  }

  void _actualizarCant(String key, int nuevaCant) {
    if (nuevaCant < 0) nuevaCant = 0;
    setState(() {
      _cantidades[key] = nuevaCant;
      _controllers[key]!.text = nuevaCant.toString();
      _controllers[key]!.selection = TextSelection.fromPosition(
          TextPosition(offset: _controllers[key]!.text.length));
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(), // Oculta el teclado
      behavior: HitTestBehavior.translucent,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // La miniatura al lado del nombre
                      _construirMiniatura((widget.producto['imagen'] ?? widget.producto['foto'])?.toString(), isOscuro),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Seleccionar Variantes",
                                style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: isOscuro
                                        ? Colors.cyanAccent
                                        : const Color(0xFF0D47A1))),
                            Text(widget.producto['nombre'],
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: isOscuro ? Colors.white60 : Colors.grey,
                                    fontSize: 13)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: isOscuro ? Colors.white10 : Colors.black12),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 10),
                itemCount: widget.gruposVariantes.length,
                itemBuilder: (context, gIndex) {
                  var grupo = widget.gruposVariantes[gIndex];
                  List<dynamic> opciones = grupo['opciones'] ?? [];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 8),
                        child: Text(grupo['grupo'].toString().toUpperCase(),
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: isOscuro ? Colors.white54 : Colors.blueGrey,
                                fontSize: 12)),
                      ),
                      ...opciones.asMap().entries
                          .where((entry) => entry.value['activo'] != false)
                          .map((entry) {
                        int oIndex = entry.key;
                        var o = entry.value;
                        String key = "${gIndex}_$oIndex";
                        int stock = o['stock'] ?? 0;
                        return ListTile(
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 20),
                          leading: _construirMiniatura(o['foto_path']?.toString(), isOscuro), // 🔥 MOSTRAMOS LA FOTO DE LA VARIANTE
                          title: Text(o['nombre'],
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  color: isOscuro ? Colors.white : Colors.black87)),
                          subtitle: Text("Stock: $stock",
                              style: TextStyle(
                                  fontSize: 11,
                                  color: stock <= 0
                                      ? Colors.redAccent
                                      : Colors.green)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  icon: const Icon(Icons.remove_circle_outline,
                                      color: Colors.red, size: 28),
                                  onPressed: () =>
                                      _actualizarCant(key, _cantidades[key]! - 1)),
                              SizedBox(
                                width: 45,
                                child: TextField(
                                  controller: _controllers[key],
                                  keyboardType: TextInputType.number,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      color: isOscuro ? Colors.white : Colors.black),
                                  decoration: const InputDecoration(
                                      border: InputBorder.none, isDense: true),
                                  onChanged: (val) =>
                                      _cantidades[key] = int.tryParse(val) ?? 0,
                                ),
                              ),
                              IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  icon: const Icon(Icons.add_circle_outline,
                                      color: Colors.green, size: 28),
                                  onPressed: () =>
                                      _actualizarCant(key, _cantidades[key]! + 1)),
                            ],
                          ),
                        );
                      }),
                      Divider(
                          indent: 20,
                          endIndent: 20,
                          color: isOscuro ? Colors.white10 : Colors.black12),
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        side: BorderSide(
                            color: isOscuro ? Colors.white24 : Colors.grey),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: Text("CANCELAR",
                          style: TextStyle(
                              color: isOscuro ? Colors.white54 : Colors.grey,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isOscuro
                            ? Colors.cyanAccent.shade700
                            : const Color(0xFF0D47A1),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () {
                        widget.onAceptar(_cantidades);
                        Navigator.pop(context);
                      },
                      child: Text("AÑADIR",
                          style: TextStyle(
                              color: isOscuro ? Colors.black : Colors.white,
                              fontWeight: FontWeight.bold)),
                    ),
                  )
                ],
              ),
            )
          ],
        ),
      ),
      ), // <-- Cierra el Container original
    ); // <-- NUEVO: Cierra el GestureDetector
  }
}

class MiniaturaProductoLocal extends StatefulWidget {
  final int id;
  final bool isOscuro;

  const MiniaturaProductoLocal({super.key, required this.id, required this.isOscuro});

  @override
  State<MiniaturaProductoLocal> createState() => _MiniaturaProductoLocalState();
}

class _MiniaturaProductoLocalState extends State<MiniaturaProductoLocal> {
  Future<String?>? _fotoFuture;

  @override
  void initState() {
    super.initState();
    _fotoFuture = _cargarFoto();
  }

  @override
  void didUpdateWidget(covariant MiniaturaProductoLocal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      setState(() {
        _fotoFuture = _cargarFoto(); // 🔥 Fuerza a cargar la foto correcta si el ID cambia al buscar
      });
    }
  }

  Future<String?> _cargarFoto() async {
    final db = await DBHelper.instance.database;
    final res = await db.query('productos', columns: ['foto_path'], where: 'id = ?', whereArgs: [widget.id]);
    if (res.isNotEmpty) return res.first['foto_path']?.toString();
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _fotoFuture, // 🔥 Almacenado en memoria, no recarga con cada tecla presionada
      builder: (context, snapshot) {
        if (!snapshot.hasData) return _construirMiniatura(null, widget.isOscuro);
        return _construirMiniatura(snapshot.data, widget.isOscuro);
      },
    );
  }
}