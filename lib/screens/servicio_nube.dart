import 'dart:io';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:sqflite/sqflite.dart';
import '../database/db_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_database/firebase_database.dart' hide Query;

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
      bool cambioCategorias = false;
      
      final prefs = await SharedPreferences.getInstance();
      bool esPremium = prefs.getBool('es_premium') ?? false;

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
              
          // 🔥 INTERCEPTOR DE CLOUDINARY PARA SUBIDAS PENDIENTES OFFLINE
          if (esPremium && tabla == 'productos') {
            String foto = datos['foto_path']?.toString() ?? "";
            if (foto.isNotEmpty && !foto.startsWith('http')) {
               String url = await subirImagenACloudinary(foto);
               if (url.isNotEmpty) {
                 datos['foto_path'] = url;
                 await dbLocal.update('productos', {'foto_path': url}, where: 'id = ?', whereArgs: [datos['id']]);
               }
            }
            
            String varStr = datos['variantes']?.toString() ?? "";
            if (varStr.length > 5) {
               bool varCambiada = false;
               List<dynamic> dec = jsonDecode(varStr);
               var grupos = (dec.isNotEmpty && !dec[0].containsKey('grupo')) ? [{'opciones': dec}] : dec;
               for (var g in grupos) {
                 for (var o in g['opciones']) {
                   String vFoto = o['foto_path']?.toString() ?? "";
                   if (vFoto.isNotEmpty && !vFoto.startsWith('http')) {
                      String vUrl = await subirImagenACloudinary(vFoto);
                      if (vUrl.isNotEmpty) {
                        o['foto_path'] = vUrl;
                        varCambiada = true;
                      }
                   }
                 }
               }
               if (varCambiada) {
                 datos['variantes'] = jsonEncode(dec);
                 await dbLocal.update('productos', {'variantes': datos['variantes']}, where: 'id = ?', whereArgs: [datos['id']]);
               }
            }
          }

          datos['ultima_modificacion'] = FieldValue.serverTimestamp();
          datos.remove('eliminado');
          batch.set(ref, datos, SetOptions(merge: true));
        }

        if (tabla == 'productos' || tabla == 'fotos_variantes') {
          cambioProductos = true;
        }
        if (tabla == 'pedidos') cambioPedidos = true;
        if (tabla == 'categorias') cambioCategorias = true; 
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

      if (cambioCategorias) { 
        batch.update(_db.collection('usuarios').doc(_uid!), {
          'ultima_mod_categorias': FieldValue.serverTimestamp(),
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
      
      // 🔥 RECOMPILAMOS EL CATÁLOGO PARA QUE LA WEB SE ACTUALICE CON LAS NUEVAS RUTAS
      if (esPremium && (cambioProductos || cambioCategorias)) {
        await compilarYSubirCatalogoRTDB();
      }

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
        } else if (tabla == 'categorias') { // 🔥 AÑADIDO PARA CATEGORÍAS
          campoMod = 'ultima_mod_categorias';
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

  // 🔥 NUEVO: Forzar descarga completa ignorando fechas (rescata inactivos/perdidos)
  static Future<bool> descargarTablaCompleta(String uid, String tabla) async {
    if (!await tieneInternet()) return false;
    try {
      final dbLocal = await DBHelper.instance.database;
      final snapshot = await _db.collection('usuarios').doc(uid).collection(tabla).get();
      if (snapshot.docs.isEmpty) return false;

      final List<Map<String, dynamic>> columnasSQLite = await dbLocal.rawQuery('PRAGMA table_info($tabla)');
      final Set<String> columnasValidas = columnasSQLite.map((c) => c['name'] as String).toSet();

      int chunkSize = 20; 
      for (int i = 0; i < snapshot.docs.length; i += chunkSize) {
        int fin = (i + chunkSize < snapshot.docs.length) ? i + chunkSize : snapshot.docs.length;
        List<QueryDocumentSnapshot> chunk = snapshot.docs.sublist(i, fin);
        
        final Batch batch = dbLocal.batch();
        for (final doc in chunk) {
          final Map<String, dynamic> raw = Map<String, dynamic>.from(doc.data() as Map<String, dynamic>);
          final Map<String, dynamic> mapLocal = {};
          
          raw.forEach((key, value) {
            if (!columnasValidas.contains(key)) return;
            if (value is Timestamp) {
              mapLocal[key] = value.toDate().toIso8601String();
            } else if (value is Blob) {
              mapLocal[key] = value.bytes;
            } else if (value is List || value is Map) {
              mapLocal[key] = jsonEncode(value); // 🔥 Salvavidas por si en Firestore guardó listas
            } else {
              mapLocal[key] = value;
            }
          });
          batch.insert(tabla, mapLocal, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      }
      return true;
    } catch (e) {
      debugPrint('❌ Error descargarTablaCompleta ($tabla): $e');
      return false;
    }
  }

  // 🔥 NUEVO: Función para rescatar datos que no se subieron al JSON en su momento
  static Future<void> rescatarDatosPerdidosFirestore(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    bool yaRescatado = prefs.getBool('rescate_inactivos_v1_$uid') ?? false;
    if (yaRescatado) return;

    if (!await tieneInternet()) return;

    try {
      debugPrint('🚀 INICIANDO RESCATE DE FIRESTORE (Inactivos perdidos)');
      await descargarTablaCompleta(uid, 'categorias');
      await descargarTablaCompleta(uid, 'productos');
      
      // Recompilar RTDB con el JSON completo (ahora sí subirá los inactivos)
      await compilarYSubirCatalogoRTDB();
      
      await prefs.setBool('rescate_inactivos_v1_$uid', true);
      debugPrint('✅ RESCATE COMPLETADO CON ÉXITO');
    } catch (e) {
      debugPrint('❌ ERROR EN RESCATE: $e');
    }
  }

  static Future<void> descargarTodoDesdeNube() async {
    if (_uid == null) return;
    
    // 1. Descargamos e importamos instantáneamente el catálogo de Realtime
    await _importarCatalogoDesdeRTDB(_uid!);

    // 2. Descargamos en paralelo el resto de tablas privadas
    List<Future<bool>> descargas = [];
    const List<String> tablasPrivadas = [
      'vendedores',
      'clientes',
      'pedidos',
      'detalle_pedidos',
      'reportes_guardados',
      'ajustes_capital',
    ];
    
    for (final t in tablasPrivadas) {
      descargas.add(descargarSoloModificados(_uid!, t, 'ultima_modificacion'));
    }
    await Future.wait(descargas);
  }

  static Future<void> _importarCatalogoDesdeRTDB(String uid) async {
    try {
      if (!await tieneInternet()) return;
      final ref = FirebaseDatabase.instance.ref("catalogos_web/$uid");
      final snap = await ref.get();
      if (!snap.exists) return;

      final dbLocal = await DBHelper.instance.database;
      Map<String, dynamic> datos = {};
      final rawValue = snap.value;
      if (rawValue is String) {
        datos = jsonDecode(rawValue);
      } else if (rawValue is Map) {
        datos = Map<String, dynamic>.from(rawValue);
      }

      final prefs = await SharedPreferences.getInstance();

      // 1. Restaurar perfil comercial en SharedPreferences (muy rápido)
      if (datos['negocio'] != null) {
        final neg = Map<String, dynamic>.from(datos['negocio']);
        if (neg['nombre_negocio'] != null) await prefs.setString('nombre_negocio', neg['nombre_negocio']);
        if (neg['logo_base64'] != null) await prefs.setString('logo_path', neg['logo_base64']);
        if (neg['whatsapp_admin'] != null) await prefs.setString('whatsapp_admin', neg['whatsapp_admin']);
      }

      // 🔥 UN SOLO BATCH EVITA EL ANR (0 bloqueos de base de datos)
      final Batch batch = dbLocal.batch();

      // 2. Encolar Categorías Activas
      if (datos['categorias'] != null) {
        final cats = List<dynamic>.from(datos['categorias']);
        for (var c in cats) {
          if (c != null) {
            batch.insert('categorias', Map<String, dynamic>.from(c), conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      }

      // 2b. Encolar Categorías Inactivas
      if (datos['categorias_inactivas'] != null) {
        final catsInactivas = List<dynamic>.from(datos['categorias_inactivas']);
        for (var c in catsInactivas) {
          if (c != null) {
            batch.insert('categorias', Map<String, dynamic>.from(c), conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      }

      // 3. Encolar Productos Activos
      if (datos['productos'] != null) {
        final prods = List<dynamic>.from(datos['productos']);
        for (var p in prods) {
          if (p != null) {
            final Map<String, dynamic> map = Map<String, dynamic>.from(p);
            if (map['variantes'] != null && map['variantes'] is! String) {
              map['variantes'] = jsonEncode(map['variantes']);
            }
            batch.insert('productos', map, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      }

      // 3b. Encolar Productos Inactivos (Recuperados de forma segura)
      if (datos['productos_inactivos'] != null) {
        final prodsInactivos = List<dynamic>.from(datos['productos_inactivos']);
        for (var p in prodsInactivos) {
          if (p != null) {
            final Map<String, dynamic> map = Map<String, dynamic>.from(p);
            if (map['variantes'] != null && map['variantes'] is! String) {
              map['variantes'] = jsonEncode(map['variantes']);
            }
            batch.insert('productos', map, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      }

      // 4. Encolar fotos de variantes antiguas
      if (datos['fotosVariantesCache'] != null) {
        final fotosCache = Map<String, String>.from(datos['fotosVariantesCache']);
        for (var entry in fotosCache.entries) {
          List<String> partes = entry.key.split('_');
          if (partes.length == 3) {
            batch.insert('fotos_variantes', {
              'producto_id': int.tryParse(partes[0]) ?? 0,
              'grupo_index': int.tryParse(partes[1]) ?? 0,
              'opcion_index': int.tryParse(partes[2]) ?? 0,
              'foto_base64': entry.value.toString(),
              'ultima_modificacion': DateTime.now().toIso8601String(),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      }

      // Guardamos todo el lote de una sola vez
      await batch.commit(noResult: true);
      
      debugPrint("✅ Catálogo completo importado desde Realtime (0 bloqueos).");
    } catch (e) {
      debugPrint("Error importando desde RTDB con Batch: $e");
    }
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
    'categorias', 
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
      if (data.containsKey('nombre_negocio')) {
        await prefs.setString('nombre_negocio', data['nombre_negocio']);
      }
      if (data.containsKey('logo_base64')) {
        await prefs.setString('logo_path', data['logo_base64']);
      }

      if (data.containsKey('whatsapp_admin')) {
        String wa = data['whatsapp_admin'].toString();
        await prefs.setString('whatsapp_admin', wa);
        
        String indicativo = "";
        String numeroLocal = wa;

        if (wa.startsWith('1') && wa.length == 11) {
          indicativo = '1';
          numeroLocal = wa.substring(1);
        } else if (wa.length >= 12) {
          indicativo = wa.substring(0, wa.length - 10);
          numeroLocal = wa.substring(wa.length - 10);
        } else if (wa.length == 11) {
          indicativo = wa.substring(0, 2);
          numeroLocal = wa.substring(2);
        }

        // Guardamos los datos desglosados listos para los campos del perfil
        await prefs.setString('whatsapp_admin_indicativo', indicativo);
        await prefs.setString('whatsapp_admin_numero', numeroLocal);
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

  static Future<String> subirImagenACloudinary(String imageSource) async {
    if (imageSource.startsWith('http')) return imageSource; // Ya es Cloudinary

    File? imageFile;
    bool isTemp = false;

    // 🔥 Si es un texto base64, lo guardamos en un archivo temporal para enviarlo
    if (imageSource.length > 500) {
      final tempDir = Directory.systemTemp;
      final bytes = base64Decode(imageSource);
      imageFile = File('${tempDir.path}/temp_up_${DateTime.now().millisecondsSinceEpoch}.png');
      await imageFile.writeAsBytes(bytes);
      isTemp = true;
    } else {
      imageFile = File(imageSource);
    }

    if (!imageFile.existsSync()) return "";

    const String cloudName = 'fdvjsavu';
    const String uploadPreset = 'boxi_fotos';
    final url = Uri.parse('https://api.cloudinary.com/v1_1/$cloudName/image/upload');
    
    try {
      final request = http.MultipartRequest('POST', url)
        ..fields['upload_preset'] = uploadPreset
        ..files.add(await http.MultipartFile.fromPath('file', imageFile.path));

      final response = await request.send();
      final responseData = await response.stream.bytesToString();
      final data = jsonDecode(responseData);

      if (isTemp && imageFile.existsSync()) await imageFile.delete(); // Limpiar

      if (response.statusCode == 200) {
        return data['secure_url']; 
      }
      return "";
    } catch (e) {
      return "";
    }
  }

  static bool _migrandoACloudinary = false;

  static Future<void> migrarTodoACloudinary() async {
    final user = _auth.currentUser;
    if (user == null) return;
    final uid = user.uid;

    final db = await DBHelper.instance.database;
    final prefs = await SharedPreferences.getInstance();

    if (_migrandoACloudinary) {
      debugPrint("⏳ Ya hay una migración a Cloudinary activa. Bloqueando intento duplicado.");
      return;
    }

    bool yaMigrado = prefs.getBool('migracion_cloudinary_completada_$uid') ?? false;
    if (yaMigrado) return;

    _migrandoACloudinary = true; 

    try {
      debugPrint("🚀 Iniciando migración de imágenes locales/Base64 a Cloudinary...");

      final prods = await db.query('productos');

      // 1. Migrar Fotos Principales de Productos
      for (var p in prods) {
        String foto = p['foto_path']?.toString() ?? "";
        if (foto.isEmpty || foto.startsWith('http')) continue;

        String nuevaUrl = "";
        File? tempFile;

        try {
          if (foto.length > 500) {
            tempFile = await _base64ATempFile(foto, "prod_${p['id']}");
            nuevaUrl = await subirImagenACloudinary(tempFile.path);
          } else if (File(foto).existsSync()) {
            nuevaUrl = await subirImagenACloudinary(foto);
          }

          if (nuevaUrl.isNotEmpty) {
            await db.update('productos', {'foto_path': nuevaUrl}, where: 'id = ?', whereArgs: [p['id']]);
            Map<String, dynamic> pActualizado = Map.from(p)..['foto_path'] = nuevaUrl;
            guardarProductoNube(pActualizado);
          }
        } catch (e) {
          debugPrint("Error migrando foto de producto ${p['id']}: $e");
        } finally {
          if (tempFile != null && tempFile.existsSync()) {
            await tempFile.delete();
          }
        }
      }

      // 2. Migrar Fotos de Variantes (Directo desde el JSON)
      final prodsActualizados = await db.query('productos');
      for (var p in prodsActualizados) {
        String variantesJson = p['variantes']?.toString() ?? "";
        if (variantesJson.length > 5) {
          bool varCambiada = false;
          List<dynamic> dec = jsonDecode(variantesJson);
          
          var grupos = (dec.isNotEmpty && !dec[0].containsKey('grupo')) ? [{'opciones': dec}] : dec;
          
          for (var g in grupos) {
            for (var o in g['opciones']) {
              String foto = o['foto_path']?.toString() ?? "";
              if (foto.isEmpty || foto.startsWith('http')) continue;

              String nuevaUrl = "";
              File? tempFile;
              try {
                if (foto.length > 500) {
                  tempFile = await _base64ATempFile(foto, "var_${p['id']}");
                  nuevaUrl = await subirImagenACloudinary(tempFile.path);
                } else if (File(foto).existsSync()) {
                  nuevaUrl = await subirImagenACloudinary(foto);
                }

                if (nuevaUrl.isNotEmpty) {
                  o['foto_path'] = nuevaUrl;
                  varCambiada = true;
                }
              } catch (e) {
                debugPrint("Error migrando foto de variante: $e");
              } finally {
                if (tempFile != null && tempFile.existsSync()) await tempFile.delete();
              }
            }
          }

          if (varCambiada) {
            String nuevoJson = jsonEncode(dec);
            await db.update('productos', {'variantes': nuevoJson}, where: 'id = ?', whereArgs: [p['id']]);
            Map<String, dynamic> pActualizado = Map.from(p)..['variantes'] = nuevoJson;
            guardarProductoNube(pActualizado);
          }
        }
      }

      // 3. Subir el super JSON unificado y limpio a RTDB
      await compilarYSubirCatalogoRTDB();

      // 4. Guardamos la bandera
      await prefs.setBool('migracion_cloudinary_completada_$uid', true);
      debugPrint("✅ Migración global a Cloudinary finalizada con éxito.");

    } catch (e) {
      debugPrint("❌ Error crítico en la migración a Cloudinary: $e");
    } finally {
      _migrandoACloudinary = false; 
    }
  }

  static Future<File> _base64ATempFile(String b64, String prefix) async {
    final tempDir = Directory.systemTemp;
    final bytes = base64Decode(b64);
    final file = File('${tempDir.path}/${prefix}_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(bytes);
    return file;
  }

  static Future<void> compilarYSubirCatalogoRTDB() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final db = await DBHelper.instance.database;
      final prefs = await SharedPreferences.getInstance();
      
      bool esPremium = prefs.getBool('es_premium') ?? false;
      bool hayInternet = await tieneInternet();

      // 1. Saneamos el LOGO
      String logo = prefs.getString('logo_path') ?? "";
      if (logo.isNotEmpty && !logo.startsWith('http')) {
        if (esPremium && hayInternet) {
          String urlLogo = await subirImagenACloudinary(logo);
          if (urlLogo.isNotEmpty) {
            logo = urlLogo;
            await prefs.setString('logo_path', logo);
            await actualizarPerfilNegocioNube(
              prefs.getString('nombre_negocio') ?? "MI NEGOCIO", 
              logo
            );
          } else if (logo.length > 5000) {
            logo = ""; 
          }
        } else {
          if (logo.length > 5000) logo = ""; 
        }
      }

      final negocioData = {
        'nombre_negocio': prefs.getString('nombre_negocio') ?? "MI NEGOCIO",
        'logo_base64': logo, 
        'email': user.email ?? "",
        'whatsapp_admin': prefs.getString('whatsapp_admin') ?? ""
      };

      // 2. Obtener Categorías Activas e Inactivas
      final catSnap = await db.query('categorias', orderBy: 'orden ASC');
      List<Map<String, dynamic>> categorias = [];
      List<Map<String, dynamic>> categoriasInactivas = [];
      for (var row in catSnap) {
        if (row['activo'] == null || row['activo'] == 1 || row['activo'] == '1') {
          categorias.add(Map<String, dynamic>.from(row));
        } else {
          categoriasInactivas.add(Map<String, dynamic>.from(row));
        }
      }

      // 3. Obtener Productos Activos
      final prodSnap = await db.query('productos', where: 'activo = 1', orderBy: 'orden ASC, id DESC');
      List<Map<String, dynamic>> productos = [];
      Set<String> catsDesdeProductos = {};
      Map<String, String> fotosVariantesCache = {}; 

      for (var row in prodSnap) {
        var map = Map<String, dynamic>.from(row);
        String foto = map['foto_path']?.toString() ?? "";
        
        if (map['categoria'] != null && map['categoria'].toString().isNotEmpty) {
          catsDesdeProductos.add(map['categoria'].toString());
        }

        if (foto.isNotEmpty && !foto.startsWith('http')) {
           if (esPremium && hayInternet) {
             String urlFoto = await subirImagenACloudinary(foto);
             if (urlFoto.isNotEmpty) {
               map['foto_path'] = urlFoto;
               await db.update('productos', {'foto_path': urlFoto}, where: 'id = ?', whereArgs: [map['id']]);
               await FirebaseFirestore.instance.collection('usuarios').doc(user.uid).collection('productos').doc(map['id'].toString()).set({'foto_path': urlFoto}, SetOptions(merge: true));
             } else {
               map['foto_path'] = ""; 
             }
           } else {
             map['foto_path'] = "";
           }
        }

        if (map['variantes'] != null && map['variantes'].toString().length > 5) {
          List<dynamic> dec = jsonDecode(map['variantes']);
          var grupos = (dec.isNotEmpty && !dec[0].containsKey('grupo')) ? [{'opciones': dec}] : dec;
          bool varActualizada = false;
          
          for (int gIdx = 0; gIdx < grupos.length; gIdx++) {
            for (int oIdx = 0; oIdx < grupos[gIdx]['opciones'].length; oIdx++) {
              String varFoto = grupos[gIdx]['opciones'][oIdx]['foto_path']?.toString() ?? "";
              
              if (varFoto.isNotEmpty && !varFoto.startsWith('http')) {
                if (esPremium && hayInternet) {
                  String urlVar = await subirImagenACloudinary(varFoto);
                  if (urlVar.isNotEmpty) {
                    grupos[gIdx]['opciones'][oIdx]['foto_path'] = urlVar;
                    fotosVariantesCache["${map['id']}_${gIdx}_${oIdx}"] = urlVar;
                    varActualizada = true;
                  } else {
                    grupos[gIdx]['opciones'][oIdx]['foto_path'] = "";
                  }
                } else {
                  grupos[gIdx]['opciones'][oIdx]['foto_path'] = "";
                }
              } else if (varFoto.startsWith('http')) {
                 fotosVariantesCache["${map['id']}_${gIdx}_${oIdx}"] = varFoto;
              }
            }
          }
          
          if (varActualizada) {
             String nuevoJson = jsonEncode(dec);
             await db.update('productos', {'variantes': nuevoJson}, where: 'id = ?', whereArgs: [map['id']]);
             await FirebaseFirestore.instance.collection('usuarios').doc(user.uid).collection('productos').doc(map['id'].toString()).set({'variantes': nuevoJson}, SetOptions(merge: true));
          }
          map['variantes'] = dec;
        }

        productos.add(map);
      }

      // 4. Obtener Productos Inactivos (Subiendo fotos pendientes a Cloudinary de forma segura)
      final prodInactivosSnap = await db.query('productos', where: 'activo = 0', orderBy: 'orden ASC, id DESC');
      List<Map<String, dynamic>> productosInactivos = [];

      for (var row in prodInactivosSnap) {
        var map = Map<String, dynamic>.from(row);
        String foto = map['foto_path']?.toString() ?? "";

        // Si la foto es local/base64, la subimos a Cloudinary para que otros celulares la puedan ver/descargar
        if (foto.isNotEmpty && !foto.startsWith('http')) {
           if (esPremium && hayInternet) {
             String urlFoto = await subirImagenACloudinary(foto);
             if (urlFoto.isNotEmpty) {
               map['foto_path'] = urlFoto;
               await db.update('productos', {'foto_path': urlFoto}, where: 'id = ?', whereArgs: [map['id']]);
               await FirebaseFirestore.instance.collection('usuarios').doc(user.uid).collection('productos').doc(map['id'].toString()).set({'foto_path': urlFoto}, SetOptions(merge: true));
             } else {
               map['foto_path'] = ""; 
             }
           } else {
             map['foto_path'] = "";
           }
        }

        // Variantes de productos inactivos
        if (map['variantes'] != null && map['variantes'].toString().length > 5) {
          List<dynamic> dec = jsonDecode(map['variantes']);
          var grupos = (dec.isNotEmpty && !dec[0].containsKey('grupo')) ? [{'opciones': dec}] : dec;
          bool varActualizada = false;
          
          for (int gIdx = 0; gIdx < grupos.length; gIdx++) {
            for (int oIdx = 0; oIdx < grupos[gIdx]['opciones'].length; oIdx++) {
              String varFoto = grupos[gIdx]['opciones'][oIdx]['foto_path']?.toString() ?? "";
              
              if (varFoto.isNotEmpty && !varFoto.startsWith('http')) {
                if (esPremium && hayInternet) {
                  String urlVar = await subirImagenACloudinary(varFoto);
                  if (urlVar.isNotEmpty) {
                    grupos[gIdx]['opciones'][oIdx]['foto_path'] = urlVar;
                    fotosVariantesCache["${map['id']}_${gIdx}_${oIdx}"] = urlVar;
                    varActualizada = true;
                  } else {
                    grupos[gIdx]['opciones'][oIdx]['foto_path'] = "";
                  }
                } else {
                  grupos[gIdx]['opciones'][oIdx]['foto_path'] = "";
                }
              } else if (varFoto.startsWith('http')) {
                 fotosVariantesCache["${map['id']}_${gIdx}_${oIdx}"] = varFoto;
              }
            }
          }
          
          if (varActualizada) {
             String nuevoJson = jsonEncode(dec);
             await db.update('productos', {'variantes': nuevoJson}, where: 'id = ?', whereArgs: [map['id']]);
             await FirebaseFirestore.instance.collection('usuarios').doc(user.uid).collection('productos').doc(map['id'].toString()).set({'variantes': nuevoJson}, SetOptions(merge: true));
          }
          map['variantes'] = dec;
        }

        productosInactivos.add(map);
      }

      if (categorias.isEmpty && catsDesdeProductos.isNotEmpty) {
        int i = 0;
        for (String c in catsDesdeProductos) {
          categorias.add({'id': i, 'nombre': c, 'activo': 1, 'orden': i});
          i++;
        }
      }

      // Armar y subir JSON
      Map<String, dynamic> superJson = {
        'negocio': negocioData,
        'categorias': categorias,
        'categorias_inactivas': categoriasInactivas, // 🔥 Ocultas para clientes
        'productos': productos,
        'productos_inactivos': productosInactivos, // 🔥 Ocultas para clientes
        'fotosVariantesCache': fotosVariantesCache,
        'ultima_actualizacion': DateTime.now().toIso8601String()
      };

      DatabaseReference ref = FirebaseDatabase.instance.ref("catalogos_web/${user.uid}");
      await ref.set(jsonEncode(superJson));
      
      debugPrint("✅ Catálogo compilado exitosamente.");
    } catch (e) {
      debugPrint("❌ Error subiendo catálogo a RTDB: $e");
    }
  }

  static Future<void> migrarVariantesAlJSONyCarpetas() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 🔥 CONTROL DE EJECUCIÓN ÚNICA: Corregida clave a v6
    if (prefs.getBool('migracion_definitiva_completa_v6') ?? false) {
      return; 
    }

    debugPrint("🚀 ==================================================");
    debugPrint("🚀 INICIANDO MIGRACIÓN Y RESCATE DE FOTOS DE VARIANTES...");
    debugPrint("🚀 ==================================================");

    final db = await DBHelper.instance.database;
    bool esPremium = prefs.getBool('es_premium') ?? false;
    final user = _auth.currentUser;

    // --- 1. RESCATE DE FOTOS DESDE FIRESTORE ---
    if (esPremium && user != null && await tieneInternet()) {
      try {
        final fotosSnap = await _db
            .collection('usuarios')
            .doc(user.uid)
            .collection('fotos_variantes')
            .get()
            .timeout(const Duration(seconds: 10));

        if (fotosSnap.docs.isNotEmpty) {
          debugPrint("☁️ Rescatando ${fotosSnap.docs.length} URLs de Cloudinary desde Firestore...");
          Map<String, List<Map<String, dynamic>>> fotosPorProd = {};
          
          for (var doc in fotosSnap.docs) {
            var f = doc.data();
            String pid = f['producto_id'].toString();
            fotosPorProd.putIfAbsent(pid, () => []).add(f);
          }

          final Batch batchLocal = db.batch();
          bool huboCambiosEnNube = false;

          for (String pid in fotosPorProd.keys) {
            final pRes = await db.query('productos', where: 'id = ?', whereArgs: [pid]);
            if (pRes.isEmpty) continue;

            var p = Map<String, dynamic>.from(pRes.first);
            String varStr = p['variantes']?.toString() ?? "";
            
            if (varStr.length > 5) {
              List<dynamic> dec = jsonDecode(varStr);
              bool cambiado = false;
              
              for (var f in fotosPorProd[pid]!) {
                int gIdx = f['grupo_index'] as int;
                int oIdx = f['opcion_index'] as int;
                String fotoUrl = f['foto_base64']?.toString() ?? "";
                
                if (fotoUrl.isNotEmpty) {
                  if (dec.isNotEmpty && !dec[0].containsKey('grupo')) {
                     if (oIdx < dec.length) { dec[oIdx]['foto_path'] = fotoUrl; cambiado = true; }
                  } else {
                     if (gIdx < dec.length && oIdx < dec[gIdx]['opciones'].length) {
                       dec[gIdx]['opciones'][oIdx]['foto_path'] = fotoUrl; cambiado = true;
                     }
                  }
                }
              }
              
              if (cambiado) {
                String nuevoJson = jsonEncode(dec);
                batchLocal.update('productos', {'variantes': nuevoJson}, where: 'id = ?', whereArgs: [pid]);
                huboCambiosEnNube = true;

                await _db.collection('usuarios').doc(user.uid).collection('productos').doc(pid).update({
                  'variantes': nuevoJson,
                  'ultima_modificacion': FieldValue.serverTimestamp()
                });
              }
            }
          }
          
          if (huboCambiosEnNube) {
            await batchLocal.commit(noResult: true);
          }

          final batchDelete = _db.batch();
          for (var doc in fotosSnap.docs) {
            batchDelete.delete(doc.reference);
          }
          await batchDelete.commit();
        }
      } catch (e) {
        debugPrint("❌ Error rescatando fotos: $e");
      }
    }

    // --- 2. MOVER CARPETAS A LA GALERÍA PÚBLICA (OMITIENDO LA DESCARGA CONGELA-APP) ---
    try {
      // 🔥 Leemos la ruta unificada dinámica (pública o interna)
      String pathBoxi = prefs.getString('local_boxi_path') ?? "/storage/emulated/0/Pictures/Boxi";
      Directory baseDir = Directory(pathBoxi);
      if (!await baseDir.exists()) await baseDir.create(recursive: true);
      
      final varDir = Directory('${baseDir.path}/Variantes');
      if (!await varDir.exists()) await varDir.create(recursive: true);

      final prods = await db.query('productos');
      int fotosMovidas = 0;
      
      final Batch batchActualizaciones = db.batch();
      bool huboActualizacionesLocales = false;

      for (var p in prods) {
        String foto = p['foto_path']?.toString() ?? "";
        String variantesJson = p['variantes']?.toString() ?? "";
        bool actualizado = false;
        
        if (foto.isNotEmpty && !foto.startsWith('http') && foto.length < 500 && !foto.contains(baseDir.path)) {
          File oldFile = File(foto);
          if (await oldFile.exists()) {
            File newFile = await oldFile.copy('${baseDir.path}/${foto.split('/').last}');
            foto = newFile.path;
            actualizado = true;
            fotosMovidas++;
          }
        }

        if (variantesJson.length > 5) {
          List<dynamic> dec = jsonDecode(variantesJson);
          bool varCambiada = false;
          
          for (var g in (dec.isNotEmpty && !dec[0].containsKey('grupo') ? [{'opciones': dec}] : dec)) {
             for (var o in g['opciones']) {
               String vFoto = o['foto_path']?.toString() ?? "";
               if (vFoto.isNotEmpty && !vFoto.startsWith('http') && vFoto.length < 500 && !vFoto.contains(varDir.path)) {
                  File oldFile = File(vFoto);
                  if (await oldFile.exists()) {
                    File newFile = await oldFile.copy('${varDir.path}/${vFoto.split('/').last}');
                    o['foto_path'] = newFile.path;
                    varCambiada = true;
                    fotosMovidas++;
                  }
               }
             }
          }
          if (varCambiada) {
            variantesJson = jsonEncode(dec);
            actualizado = true;
          }
        }

        if (actualizado) {
          batchActualizaciones.update('productos', {'foto_path': foto, 'variantes': variantesJson}, where: 'id = ?', whereArgs: [p['id']]);
          huboActualizacionesLocales = true;
        }
      }
      
      if (huboActualizacionesLocales) {
        await batchActualizaciones.commit(noResult: true);
      }
      
      await prefs.setBool('migracion_definitiva_completa_v6', true);
      debugPrint("✅ Saneamiento físico local completado ($fotosMovidas fotos movidas, 0 descargas bloqueantes).");
    } catch (e) {
      debugPrint("❌ Error en respaldo físico: $e");
    }
  }

 // 🔥 NUEVO: Cola en memoria para evitar descargas paralelas idénticas (Evita la clonación)
  static final Set<String> _descargasActivas = {};

  // 🔥 NUEVO: Validador instantáneo de rutas fijas (Sin listSync pesados)
  static Future<String?> obtenerRutaLegibleSegura(String urlOPath) async {
    if (urlOPath.isEmpty) return null;
    if (!urlOPath.startsWith('http')) {
      try {
        final f = File(urlOPath);
        if (await f.exists()) {
          final access = await f.open(mode: FileMode.read);
          await access.close();
          return urlOPath;
        }
      } catch (_) {}
      return null;
    }

    String name = urlOPath.split('/').last;
    String ext = name.contains('.') ? name.split('.').last : 'jpg';
    String id = name.split('.').first;

    final prefs = await SharedPreferences.getInstance();
    String pathBoxi = prefs.getString('local_boxi_path') ?? "/storage/emulated/0/Pictures/Boxi";

    // Generamos candidatos fijos exactos (O(1) en microsegundos, sin congelar la UI)
    final candidatos = [
      File('$pathBoxi/$name'),
      File('$pathBoxi/${id}_safe.$ext'),
      File('$pathBoxi/Variantes/$name'),
      File('$pathBoxi/Variantes/${id}_safe.$ext'),
    ];

    for (var f in candidatos) {
      try {
        if (await f.exists()) {
          final access = await f.open(mode: FileMode.read);
          await access.close();
          return f.path; // Retorna el primer archivo legible
        }
      } catch (_) {}
    }
    return null;
  }

  static Future<void> descargarFotoIndividualEnSegundoPlano(String url, String localPath) async {
    if (!url.startsWith('http')) return;
    
    // Evitamos duplicidad de descargas simultáneas en paralelo
    if (_descargasActivas.contains(url)) return;
    _descargasActivas.add(url);

    try {
      String name = url.split('/').last;
      String ext = name.contains('.') ? name.split('.').last : 'jpg';
      String id = name.split('.').first;

      // 1. Si ya existe físicamente en el celular, cancelamos
      String? rutaLegible = await obtenerRutaLegibleSegura(url);
      if (rutaLegible != null) return;

      // 2. Descargamos de internet
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        File f = File('$localPath/$name');
        try {
          await f.writeAsBytes(res.bodyBytes);
          debugPrint("✅ Imagen guardada de forma normal: ${f.path}");
        } catch (e) {
          // Si Android bloquea la escritura (Error 13), guardamos con nombre fijos en la misma carpeta
          File fallback = File('$localPath/${id}_safe.$ext');
          await fallback.writeAsBytes(res.bodyBytes);
          debugPrint("🛡️ Imagen guardada en fallback estático seguro: ${fallback.path}");
        }
      }
    } catch (_) {} finally {
      _descargasActivas.remove(url); // Liberamos de la cola
    }
  }
  
  static Future<void> guardarProductoNube(Map<String, dynamic> p) async =>
      _escribir(
          tabla: 'productos', docId: p['id'].toString(), datos: p);

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

  static Future<void> guardarCategoriaNube(Map<String, dynamic> cat) async =>
      _escribir(tabla: 'categorias', docId: cat['id'].toString(), datos: cat);

  static Future<void> eliminarCategoriaNube(int id) async =>
      _eliminar(tabla: 'categorias', docId: id.toString());

  static Stream<QuerySnapshot>? escucharCategoriasEnTiempoReal() =>
      _uid == null
          ? null
          : _db
              .collection('usuarios')
              .doc(_uid)
              .collection('categorias')
              .snapshots();

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