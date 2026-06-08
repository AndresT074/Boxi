import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:sqflite/sqflite.dart';
import '../database/db_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

class ServicioNube {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  static DateTime? _ultimaVerifInternet;
  static bool _cacheInternet = false;

  static String? get _uid => _auth.currentUser?.uid;

  // ─────────────────────────────────────────────────────────────
  //  INTERNET — resultado cacheado 10 segundos
  // ─────────────────────────────────────────────────────────────
  static Future<bool> tieneInternet() async {
    if (_ultimaVerifInternet != null &&
        DateTime.now().difference(_ultimaVerifInternet!).inSeconds < 10) {
      return _cacheInternet;
    }
    try {
      final r = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 3));
      _cacheInternet = r.isNotEmpty && r[0].rawAddress.isNotEmpty;
    } catch (_) {
      _cacheInternet = false;
    }
    _ultimaVerifInternet = DateTime.now();
    return _cacheInternet;
  }

  // ─────────────────────────────────────────────────────────────
  //  Marcar timestamp de modificación en doc raíz
  // ─────────────────────────────────────────────────────────────
  static Future<void> _marcarModificacion(String campo) async {
    if (_uid == null) return;
    try {
      await _db.collection('usuarios').doc(_uid).set(
        {campo: FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );
    } catch (e) {
      debugPrint('Error marcando modificación ($campo): $e');
    }
  }

  // ─────────────────────────────────────────────────────────────
  //  COLA OFFLINE
  // ─────────────────────────────────────────────────────────────
  static Future<void> _encolarOperacion({
    required String tabla,
    required String operacion,
    required String docId,
    Map<String, dynamic>? datos,
  }) async {
    try {
      final dbLocal = await DBHelper.instance.database;
      // Reemplazamos cualquier operación pendiente anterior para este doc
      await dbLocal.delete(
        'operaciones_pendientes',
        where: 'tabla = ? AND doc_id = ?',
        whereArgs: [tabla, docId],
      );
      await dbLocal.insert('operaciones_pendientes', {
        'tabla': tabla,
        'operacion': operacion,
        'doc_id': docId,
        'datos_json': datos != null ? jsonEncode(datos) : null,
        'fecha_creacion': DateTime.now().toIso8601String(),
      });
      debugPrint('📦 Encolado offline: $operacion $tabla/$docId');
    } catch (e) {
      debugPrint('Error encolando operación: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────
  //  PROCESADOR DE COLA OFFLINE
  // ─────────────────────────────────────────────────────────────
  static Future<void> procesarColaOffline() async {
    if (_uid == null) return;
    if (!await tieneInternet()) return;

    try {
      final dbLocal = await DBHelper.instance.database;
      final pendientes = await dbLocal.query(
        'operaciones_pendientes',
        orderBy: 'fecha_creacion ASC',
      );
      if (pendientes.isEmpty) return;

      debugPrint('🔄 Procesando ${pendientes.length} operaciones pendientes...');

      final WriteBatch batch = _db.batch();
      final List<int> idsAEliminar = [];
      bool cambioProductos = false;
      bool cambioPedidos = false;

      for (final op in pendientes) {
        final String tabla = op['tabla'] as String;
        final String docId = op['doc_id'] as String;
        final ref = _db
            .collection('usuarios')
            .doc(_uid)
            .collection(tabla)
            .doc(docId);

        if (op['operacion'] == 'delete') {
          batch.delete(ref);
        } else {
          final String jsonString = op['datos_json'] as String;
          final Map<String, dynamic> datos =
              Map<String, dynamic>.from(jsonDecode(jsonString));
          datos['ultima_modificacion'] = FieldValue.serverTimestamp();
          datos.remove('eliminado');
          batch.set(ref, datos, SetOptions(merge: true));
        }

        if (tabla == 'productos' || tabla == 'fotos_variantes') {
          cambioProductos = true;
        }
        if (tabla == 'pedidos') cambioPedidos = true;
        idsAEliminar.add(op['id'] as int);
      }

      if (cambioProductos) {
        batch.update(_db.collection('usuarios').doc(_uid!), {
          'ultima_mod_productos': FieldValue.serverTimestamp(),
        });
      }
      if (cambioPedidos) {
        batch.update(_db.collection('usuarios').doc(_uid!), {
          'ultima_mod_pedidos': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();

      for (final id in idsAEliminar) {
        await dbLocal.delete(
          'operaciones_pendientes',
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      debugPrint('✅ Cola procesada y Firebase sincronizado.');
    } catch (e) {
      debugPrint('Error en procesarColaOffline: $e');
    }
  }

  static Future<void> _escribir({
    required String tabla,
    required String docId,
    required Map<String, dynamic> datos,
  }) async {
    if (_uid == null) return;

    final Map<String, dynamic> datosLimpios = Map.from(datos)
      ..remove('archivado')
      ..remove('ultima_modificacion')
      ..remove('eliminado');

    if (await tieneInternet()) {
      try {
        final WriteBatch batch = _db.batch();

        batch.set(
          _db
              .collection('usuarios')
              .doc(_uid)
              .collection(tabla)
              .doc(docId),
          {
            ...datosLimpios,
            'ultima_modificacion': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );

        String campoMod = '';
        if (tabla == 'productos' || tabla == 'fotos_variantes') {
          campoMod = 'ultima_mod_productos';
        } else if (tabla == 'pedidos' || tabla == 'detalle_pedidos') {
          campoMod = 'ultima_mod_pedidos';
        } else if (tabla == 'ajustes_capital') {
          campoMod = 'ultima_mod_ajustes';
        }

        if (campoMod.isNotEmpty) {
          batch.update(_db.collection('usuarios').doc(_uid!), {
            campoMod: FieldValue.serverTimestamp(),
          });
        }
        await batch.commit();

        final dbLocal = await DBHelper.instance.database;
        await dbLocal.delete(
          'operaciones_pendientes',
          where: 'tabla = ? AND doc_id = ?',
          whereArgs: [tabla, docId],
        );
      } catch (e) {
        debugPrint('Error escribiendo en Firebase ($tabla/$docId): $e — encolando...');
        await _encolarOperacion(
          tabla: tabla,
          operacion: 'set',
          docId: docId,
          datos: datosLimpios,
        );
      }
    } else {
      await _encolarOperacion(
        tabla: tabla,
        operacion: 'set',
        docId: docId,
        datos: datosLimpios,
      );
    }
  }
  
  static Future<void> _eliminar({
    required String tabla,
    required String docId,
  }) async {
    if (_uid == null) return;

    if (await tieneInternet()) {
      try {
        final WriteBatch batch = _db.batch();

        batch.delete(
          _db
              .collection('usuarios')
              .doc(_uid)
              .collection(tabla)
              .doc(docId),
        );

        String campo = (tabla == 'productos' || tabla == 'fotos_variantes')
            ? 'ultima_mod_productos'
            : 'ultima_mod_pedidos';
        batch.update(_db.collection('usuarios').doc(_uid!), {
          campo: FieldValue.serverTimestamp(),
        });

        await batch.commit();

        final dbLocal = await DBHelper.instance.database;
        await dbLocal.delete(
          'operaciones_pendientes',
          where: 'tabla = ? AND doc_id = ?',
          whereArgs: [tabla, docId],
        );
      } catch (e) {
        debugPrint('Error eliminando de Firebase ($tabla/$docId): $e — encolando...');
        await _encolarOperacion(
          tabla: tabla,
          operacion: 'delete',
          docId: docId,
        );
      }
    } else {
      await _encolarOperacion(
        tabla: tabla,
        operacion: 'delete',
        docId: docId,
      );
    }
  }

  static Future<void> eliminarProductoNube(int id) async =>
      _eliminar(tabla: 'productos', docId: id.toString());

  static Future<void> eliminarFotoVarianteNube(
      int productoId, int gIdx, int oIdx) async {
    String docId = '${productoId}_${gIdx}_${oIdx}';
    await _eliminar(tabla: 'fotos_variantes', docId: docId);
  }

  // ─────────────────────────────────────────────────────────────
  //  DESCARGA CON CHUNKING PARA EVITAR COLAPSO DE SQLITE
  // ─────────────────────────────────────────────────────────────
  static Future<bool> descargarSoloModificados(
    String uid, String tabla, String campoFecha) async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('es_premium') ?? false)) return false;
    if (!await tieneInternet()) return false;

    try {
      final dbLocal = await DBHelper.instance.database;

      final res = await dbLocal
          .rawQuery('SELECT MAX($campoFecha) as ultima FROM $tabla');
      final String? ultimaFechaLocal = res.first['ultima']?.toString();
      debugPrint('🔍 $tabla → ultima fecha local: "$ultimaFechaLocal"');

      Query query = _db.collection('usuarios').doc(uid).collection(tabla);

      if (ultimaFechaLocal != null && ultimaFechaLocal.isNotEmpty) {
        final DateTime? dt = DateTime.tryParse(ultimaFechaLocal);
        if (dt != null) {
          query = query.where(
            'ultima_modificacion',
            isGreaterThan: Timestamp.fromDate(dt.toUtc()),
          );
        }
      }

      final snapshot = await query.get();
      debugPrint('🔍 $tabla → docs en Firestore: ${snapshot.docs.length}');
      if (snapshot.docs.isEmpty) return false;

      final List<Map<String, dynamic>> columnasSQLite =
          await dbLocal.rawQuery('PRAGMA table_info($tabla)');
      final Set<String> columnasValidas =
          columnasSQLite.map((c) => c['name'] as String).toSet();
      debugPrint('🔍 $tabla → columnas SQLite: $columnasValidas');

      // 🔥 SALVAVIDAS ANTI-COLAPSO DE MEMORIA EN SQLITE (CHUNKING)
      int chunkSize = 10; // Guardar de 10 en 10
      for (int i = 0; i < snapshot.docs.length; i += chunkSize) {
        int fin = (i + chunkSize < snapshot.docs.length) ? i + chunkSize : snapshot.docs.length;
        List<QueryDocumentSnapshot> chunk = snapshot.docs.sublist(i, fin);

        final Batch batch = dbLocal.batch();
        for (final doc in chunk) {
          final Map<String, dynamic> raw =
              Map<String, dynamic>.from(doc.data() as Map<String, dynamic>);

          final Map<String, dynamic> mapLocal = {};
          raw.forEach((key, value) {
            if (!columnasValidas.contains(key)) return;

            if (value is Timestamp) {
              mapLocal[key] = value.toDate().toIso8601String();
            } else if (value is List && value.isNotEmpty && value[0] is int) {
              mapLocal[key] = Uint8List.fromList(List<int>.from(value));
            } else if (value is Blob) {
              mapLocal[key] = value.bytes;
            } else if (value is List || value is Map) {
              // Ignorar
            } else {
              mapLocal[key] = value;
            }
          });
          if (tabla == 'pedidos') {
            mapLocal['fecha_hora'] ??= '2000-01-01 00:00:00';
            mapLocal['cliente_id'] ??= 0;
            mapLocal['vendedor_id'] ??= 0;
            mapLocal['total_venta'] ??= 0.0;
            mapLocal['ganancia_total'] ??= 0.0;
            mapLocal['estado'] ??= 'Desconocido';
          }
          batch.insert(tabla, mapLocal,
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        // Guardamos y liberamos memoria
        await batch.commit(noResult: true);
      }
      
      debugPrint('✅ Descargados ${snapshot.docs.length} docs de $tabla');
      return true;
    } catch (e, stack) {
      debugPrint('❌ Error descargarSoloModificados ($tabla): $e');
      debugPrint('$stack');
      return false;
    }
  }

  static Future<void> sincronizarBorradosFisicos(
      String uid, String tabla) async {
    if (!await tieneInternet()) return;
    try {
      final dbLocal = await DBHelper.instance.database;

      final snapshot = await _db
          .collection('usuarios')
          .doc(uid)
          .collection(tabla)
          .get();
      final List<int> idsNube = snapshot.docs
          .map((doc) => int.tryParse(doc.id) ?? -1)
          .toList();

      final registrosLocales = await dbLocal.query(tabla, columns: ['id']);
      final List<int> idsLocales =
          registrosLocales.map((row) => row['id'] as int).toList();

      final Batch batch = dbLocal.batch();
      bool huboBorrados = false;

      for (int idLocal in idsLocales) {
        if (!idsNube.contains(idLocal) && idLocal != -1) {
          batch.delete(tabla, where: 'id = ?', whereArgs: [idLocal]);
          if (tabla == 'productos') {
            batch.delete('fotos_variantes',
                where: 'producto_id = ?', whereArgs: [idLocal]);
          }
          huboBorrados = true;
        }
      }

      if (huboBorrados) await batch.commit(noResult: true);
    } catch (e) {
      debugPrint('Error sincronizarBorradosFisicos ($tabla): $e');
    }
  }

  static Future<bool> sincronizarBorradoYOrden(
      String uid, String tabla) async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('es_premium') ?? false)) return false;
    if (!await tieneInternet()) return false;

    try {
      final dbLocal = await DBHelper.instance.database;

      final snapshot = await _db
          .collection('usuarios')
          .doc(uid)
          .collection(tabla)
          .get();

      final registrosLocales =
          await dbLocal.query(tabla, columns: ['id']);
      List<int> idsNube = snapshot.docs
          .map((doc) => int.tryParse(doc.id) ?? -1)
          .toList();
      List<int> idsLocales =
          registrosLocales.map((row) => row['id'] as int).toList();

      final Batch batch = dbLocal.batch();

      for (int idLocal in idsLocales) {
        if (!idsNube.contains(idLocal)) {
          batch.delete(tabla, where: 'id = ?', whereArgs: [idLocal]);
        }
      }

      for (final doc in snapshot.docs) {
        final map = doc.data();
        if (map.containsKey('orden') && map.containsKey('id')) {
          batch.update(tabla, {'orden': map['orden']},
              where: 'id = ?', whereArgs: [map['id']]);
        }
      }

      await batch.commit(noResult: true);
      await descargarSoloModificados(uid, tabla, 'ultima_modificacion');
      return true;
    } catch (e) {
      debugPrint('Error sincronizarBorradoYOrden ($tabla): $e');
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────
  //  SUBIDA INICIAL COMPLETA (PARALELA)
  // ─────────────────────────────────────────────────────────────
  static Future<void> descargarTodoDesdeNube() async {
    if (_uid == null) return;
    
    // 🔥 Descarga en paralelo todas las tablas para ahorrar tiempo
    List<Future<bool>> descargas = [];
    for (final t in _todasLasTablas) {
      descargas.add(descargarSoloModificados(_uid!, t, 'ultima_modificacion'));
    }
    await Future.wait(descargas);
  }

  static Future<void> sincronizarBaseDatosHaciaNube() async {
    if (_uid == null || !await tieneInternet()) return;
    final dbLocal = await DBHelper.instance.database;

    for (final tabla in _todasLasTablas) {
      final registros = await dbLocal.query(tabla);
      if (registros.isEmpty) continue;

      // 🔥 Límite de 400 operaciones por lote para no fallar en Firebase
      WriteBatch batch = _db.batch();
      int count = 0;

      for (final row in registros) {
        final Map<String, dynamic> data = Map.from(row)..remove('archivado');
        data['ultima_modificacion'] = FieldValue.serverTimestamp();
        batch.set(
          _db
              .collection('usuarios')
              .doc(_uid)
              .collection(tabla)
              .doc(row['id'].toString()),
          data,
          SetOptions(merge: true),
        );
        
        count++;
        if (count == 400) {
          await batch.commit();
          batch = _db.batch();
          count = 0;
        }
      }
      if (count > 0) {
        await batch.commit();
      }
    }

    await _marcarModificacion('ultima_mod_productos');
    await _marcarModificacion('ultima_mod_pedidos');
  }

  static const List<String> _todasLasTablas = [
    'vendedores',
    'clientes',
    'productos',
    'pedidos',
    'detalle_pedidos',
    'reportes_guardados',
    'ajustes_capital',
    'fotos_variantes',
  ];

  static Future<void> descargarPerfilNube(String uid) async {
    if (!await tieneInternet()) return;
    try {
      final doc = await _db.collection('usuarios').doc(uid).get();
      if (!doc.exists) return;
      final data = doc.data()!;
      final prefs = await SharedPreferences.getInstance();
      if (data.containsKey('nombre_negocio')) {
        await prefs.setString('nombre_negocio', data['nombre_negocio']);
      }
      if (data.containsKey('logo_base64')) {
        await prefs.setString('logo_path', data['logo_base64']);
      }
    } catch (e) {
      debugPrint('Error cargando perfil: $e');
    }
  }

  static Future<void> actualizarPerfilNegocioNube(
      String nombre, String logo) async {
    if (_uid == null) return;
    try {
      if (!await tieneInternet()) return;
      await _db.collection('usuarios').doc(_uid).set({
        'nombre_negocio': nombre,
        'logo_base64': logo,
        'ultima_modificacion': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  static Future<void> guardarProductoNube(Map<String, dynamic> p) async =>
      _escribir(
          tabla: 'productos', docId: p['id'].toString(), datos: p);

  static Future<void> guardarFotoVarianteNube(
      Map<String, dynamic> f) async {
    if (_uid == null) return;
    String docId =
        '${f['producto_id']}_${f['grupo_index']}_${f['opcion_index']}';
    await _escribir(tabla: 'fotos_variantes', docId: docId, datos: f);
  }

  static Future<void> guardarClienteNube(Map<String, dynamic> c) async =>
      _escribir(
          tabla: 'clientes', docId: c['id'].toString(), datos: c);

  static Future<void> eliminarClienteNube(int id) async =>
      _eliminar(tabla: 'clientes', docId: id.toString());

  static Future<void> guardarVendedorNube(Map<String, dynamic> v) async =>
      _escribir(
          tabla: 'vendedores', docId: v['id'].toString(), datos: v);

  static Future<void> eliminarVendedorNube(int id) async =>
      _eliminar(tabla: 'vendedores', docId: id.toString());

  static Future<void> actualizarTotalesPedidoNube(
      int id, double total, double ganancia,
      {double domicilio = 0}) async {
    await _escribir(
      tabla: 'pedidos',
      docId: id.toString(),
      datos: {
        'id': id,
        'total_venta': total,
        'ganancia_total': ganancia,
        'valor_domicilio': domicilio,
      },
    );
  }

  static Future<void> actualizarEstadoPedidoNube(
      int id, String est) async {
    await _escribir(
      tabla: 'pedidos',
      docId: id.toString(),
      datos: {'id': id, 'estado': est},
    );
  }

  static Future<void> guardarUnicoDetalleNube(
          Map<String, dynamic> d) async =>
      _escribir(
          tabla: 'detalle_pedidos',
          docId: d['id'].toString(),
          datos: d);

  static Future<void> eliminarDetallePedidoNube(int id) async =>
      _eliminar(tabla: 'detalle_pedidos', docId: id.toString());

  static Future<void> guardarVentaCompletaBatch({
    required Map<String, dynamic> cliente,
    required Map<String, dynamic> pedido,
    required List<Map<String, dynamic>> detalles,
    required List<Map<String, dynamic>> productos,
    required Map<String, dynamic> vendedor,
  }) async {
    if (_uid == null) return;

    if (!await tieneInternet()) {
      await _encolarOperacion(
        tabla: 'clientes',
        operacion: 'set',
        docId: cliente['id'].toString(),
        datos: Map.from(cliente)..remove('archivado'),
      );
      await _encolarOperacion(
        tabla: 'pedidos',
        operacion: 'set',
        docId: pedido['id'].toString(),
        datos: Map.from(pedido)..remove('archivado'),
      );
      for (final d in detalles) {
        await _encolarOperacion(
          tabla: 'detalle_pedidos',
          operacion: 'set',
          docId: d['id'].toString(),
          datos: Map.from(d),
        );
      }
      for (final p in productos) {
        await _encolarOperacion(
          tabla: 'productos',
          operacion: 'set',
          docId: p['id'].toString(),
          datos: Map.from(p)..remove('archivado'),
        );
      }
      return;
    }

    try {
      final viejos = await _db
          .collection('usuarios')
          .doc(_uid)
          .collection('detalle_pedidos')
          .where('pedido_id', isEqualTo: pedido['id'])
          .get();

      final WriteBatch batch = _db.batch();
      for (final doc in viejos.docs) batch.delete(doc.reference);

      void addToBatch(
          String tabla, Map<String, dynamic> data, String docId) {
        final limpio = Map<String, dynamic>.from(data)
          ..remove('archivado');
        limpio['ultima_modificacion'] = FieldValue.serverTimestamp();
        batch.set(
          _db
              .collection('usuarios')
              .doc(_uid)
              .collection(tabla)
              .doc(docId),
          limpio,
          SetOptions(merge: true),
        );
      }

      addToBatch('clientes', cliente, cliente['id'].toString());
      addToBatch('pedidos', pedido, pedido['id'].toString());
      for (final d in detalles) {
        addToBatch('detalle_pedidos', d, d['id'].toString());
      }
      for (final p in productos) {
        addToBatch('productos', p, p['id'].toString());
      }
      DocumentReference userRef = _db.collection('usuarios').doc(_uid);
      batch.update(userRef, {
        'ultima_mod_productos': FieldValue.serverTimestamp(),
        'ultima_mod_pedidos': FieldValue.serverTimestamp(),
      });
      await batch.commit();

      await _marcarModificacion('ultima_mod_productos');
      await _marcarModificacion('ultima_mod_pedidos');
    } catch (e) {
      debugPrint('Error Batch Venta: $e — encolando...');
      // Reintentamos encolando cada pieza por separado
      await _encolarOperacion(
        tabla: 'clientes',
        operacion: 'set',
        docId: cliente['id'].toString(),
        datos: Map.from(cliente)..remove('archivado'),
      );
      await _encolarOperacion(
        tabla: 'pedidos',
        operacion: 'set',
        docId: pedido['id'].toString(),
        datos: Map.from(pedido)..remove('archivado'),
      );
      for (final d in detalles) {
        await _encolarOperacion(
          tabla: 'detalle_pedidos',
          operacion: 'set',
          docId: d['id'].toString(),
          datos: Map.from(d),
        );
      }
      for (final p in productos) {
        await _encolarOperacion(
          tabla: 'productos',
          operacion: 'set',
          docId: p['id'].toString(),
          datos: Map.from(p)..remove('archivado'),
        );
      }
    }
  }

  static Future<void> guardarReporteNube(Map<String, dynamic> r) async =>
      _escribir(
          tabla: 'reportes_guardados',
          docId: r['id'].toString(),
          datos: r);

  static Future<void> guardarAjusteCapitalNube(
          Map<String, dynamic> a) async =>
      _escribir(
          tabla: 'ajustes_capital',
          docId: a['id'].toString(),
          datos: a);

  static Future<void> descargarDetallesDePedido(int pedidoId) async {
    if (_uid == null || !await tieneInternet()) return;
    try {
      final snapshot = await _db
          .collection('usuarios')
          .doc(_uid)
          .collection('detalle_pedidos')
          .where('pedido_id', isEqualTo: pedidoId)
          .get();
      if (snapshot.docs.isEmpty) return;

      final dbLocal = await DBHelper.instance.database;
      await dbLocal.transaction((txn) async {
        await txn.delete('detalle_pedidos',
            where: 'pedido_id = ?', whereArgs: [pedidoId]);
        for (final doc in snapshot.docs) {
          final Map<String, dynamic> data = Map.from(doc.data());
          data.remove('archivado');
          await txn.insert('detalle_pedidos', data,
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      });
    } catch (e) {
      debugPrint('Error descargando detalles: $e');
    }
  }

  static Future<void> limpiarFantasmasNubeYLocal(String uid) async {
    if (!await tieneInternet()) return;
    try {
      final dbLocal = await DBHelper.instance.database;
      
      // 1. Buscamos los fantasmas en el celular
      final fantasmas = await dbLocal.rawQuery('''
        SELECT id FROM detalle_pedidos 
        WHERE pedido_id NOT IN (SELECT id FROM pedidos)
      ''');

      if (fantasmas.isEmpty) return;

      // 2. Los borramos de FIRESTORE permanentemente
      final batch = _db.batch();
      for (var row in fantasmas) {
        String docId = row['id'].toString();
        batch.delete(_db.collection('usuarios').doc(uid).collection('detalle_pedidos').doc(docId));
      }
      await batch.commit();

      // 3. Los borramos localmente
      int borrados = await dbLocal.rawDelete('''
        DELETE FROM detalle_pedidos 
        WHERE pedido_id NOT IN (SELECT id FROM pedidos)
      ''');
      debugPrint("🧹 Fantasmas eliminados de Firebase y Local: $borrados");
    } catch (e) {
      debugPrint("Error limpiando fantasmas en la nube: $e");
    }
  }

  // ─────────────────────────────────────────────────────────────
  //  STREAMS (para quien los necesite)
  // ─────────────────────────────────────────────────────────────
  static Stream<QuerySnapshot>? escucharProductosEnTiempoReal() =>
      _uid == null
          ? null
          : _db
              .collection('usuarios')
              .doc(_uid)
              .collection('productos')
              .snapshots();

  static Stream<QuerySnapshot>? escucharClientesEnTiempoReal() =>
      _uid == null
          ? null
          : _db
              .collection('usuarios')
              .doc(_uid)
              .collection('clientes')
              .snapshots();

  static Stream<QuerySnapshot>? escucharVendedoresEnTiempoReal() =>
      _uid == null
          ? null
          : _db
              .collection('usuarios')
              .doc(_uid)
              .collection('vendedores')
              .snapshots();

  static Stream<QuerySnapshot>? escucharPedidosEnTiempoReal() =>
      _uid == null
          ? null
          : _db
              .collection('usuarios')
              .doc(_uid)
              .collection('pedidos')
              .snapshots();

  static Stream<QuerySnapshot>? escucharReportesEnTiempoReal() =>
      _uid == null
          ? null
          : _db
              .collection('usuarios')
              .doc(_uid)
              .collection('reportes_guardados')
              .snapshots();

  static Stream<QuerySnapshot>? escucharAjustesCapitalEnTiempoReal() =>
      _uid == null
          ? null
          : _db
              .collection('usuarios')
              .doc(_uid)
              .collection('ajustes_capital')
              .snapshots();
}