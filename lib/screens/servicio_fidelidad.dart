import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:sqflite/sqflite.dart';
import '../database/db_helper.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'servicio_nube.dart';

class ServicioFidelidad {
  static final _db = FirebaseFirestore.instance;

  // 🔥 1. VENDEDOR: Crear Token con caducidad de 24 Horas
  static Future<String> crearTokenUnicoNube({
    required String vendorUid,
    required String tarjetaId,
    required String nombreNegocio,
    required String logoPath,
    required String tarjetaTitulo,
    required int metaCompras,
    required String premioDesc,
    required String clienteTelefono,
    dynamic clienteLocalId,
    String? clientUid,
    String? clienteNombre,
    double? montoMinimo, // 👈 Monto opcional
  }) async {
    String vendorHash = vendorUid.length > 4 ? vendorUid.substring(0, 4) : vendorUid;
    String token = "boxi_fidelidad_${DateTime.now().millisecondsSinceEpoch}_$vendorHash".trim();
    final DateTime fechaExpiracion = DateTime.now().add(const Duration(hours: 24));

    await _db.collection('tokens_fidelidad').doc(token).set({
      'token': token,
      'vendorUid': vendorUid,
      'tarjetaId': tarjetaId.toString(),
      'clienteLocalId': clienteLocalId?.toString() ?? '',
      'clientUid': clientUid ?? '',
      'nombreNegocio': nombreNegocio,
      'logoPath': logoPath,
      'tarjetaTitulo': tarjetaTitulo,
      'metaCompras': metaCompras,
      'premioDesc': premioDesc,
      'montoMinimo': montoMinimo ?? 0.0, // 👈 Se guarda en el token
      'clienteTelefono': clienteTelefono,
      'clienteNombre': clienteNombre ?? '',
      'usado': false,
      'fechaCreacion': FieldValue.serverTimestamp(),
      'expireAt': Timestamp.fromDate(fechaExpiracion),
    });

    return token;
  }

  // 🔥 2. CLIENTE: Reclamar el punto con destrucción garantizada si es inválido
  static Future<void> reclamarPuntoToken({
    required String token,
    required BuildContext context,
    required Function(Map<String, dynamic> tarjetaCliente, int puntoNuevo) onSuccess,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    
    // 🧹 1. Limpieza preventiva inmediata del celular para no dejar rastro
    await prefs.remove('pending_fidelidad_token');

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (context.mounted) {
        _mostrarAlerta(context, "INICIA SESIÓN", "Debes iniciar sesión para guardar tus puntos.", esError: true);
      }
      return;
    }

    String tokenLimpio = token.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');

    if (tokenLimpio.isEmpty) {
      if (context.mounted) {
        _mostrarAlerta(context, "TOKEN INVÁLIDO", "El enlace o código no tiene un formato válido.", esError: true);
      }
      return;
    }

    final docRef = _db.collection('tokens_fidelidad').doc(tokenLimpio);

    try {
      final snap = await docRef.get();

      // 🛑 SI EL TOKEN NO EXISTE EN FIRESTORE (Ya fue usado o nunca existió)
      if (!snap.exists) {
        await prefs.remove('pending_fidelidad_token'); // Borrado local
        if (context.mounted) {
          _mostrarAlerta(context, "TOKEN INVÁLIDO", "El enlace o código QR no existe o ya fue utilizado.", esError: true);
        }
        return;
      }

      final data = snap.data() as Map<String, dynamic>;

      // ⏰ 1. SI ESTÁ EXPIRADO (Más de 24 HORAS) -> BORRAR DE FIRESTORE Y CELULAR
      if (data.containsKey('expireAt') && data['expireAt'] != null) {
        Timestamp expireAt = data['expireAt'];
        if (expireAt.toDate().isBefore(DateTime.now())) {
          await docRef.delete(); // 🔥 DESTRUIR DE FIRESTORE
          await prefs.remove('pending_fidelidad_token');
          if (context.mounted) {
            _mostrarAlerta(context, "ENLACE EXPIRADO", "Este código QR o enlace ha caducado (duración máxima 24 horas).", esError: true);
          }
          return;
        }
      }

      // 🛑 2. SI YA FUE MARCADO COMO USADO -> BORRAR DE FIRESTORE Y CELULAR
      if (data['usado'] == true) {
        await docRef.delete(); // 🔥 DESTRUIR DE FIRESTORE
        await prefs.remove('pending_fidelidad_token');
        if (context.mounted) {
          _mostrarAlerta(context, "PUNTO YA USADO", "Este punto de fidelidad ya fue reclamado anteriormente.", esError: true);
        }
        return;
      }

      String vendorUid = data['vendorUid'] ?? '';
      String tarjetaId = data['tarjetaId'] ?? 'general';

      // 🛑 3. SI VIENE CORRUPTO O SIN ID DE VENDEDOR -> BORRAR DE FIRESTORE Y CELULAR
      if (vendorUid.isEmpty) {
        await docRef.delete(); // 🔥 DESTRUIR DE FIRESTORE
        await prefs.remove('pending_fidelidad_token');
        if (context.mounted) {
          _mostrarAlerta(context, "TOKEN INVÁLIDO", "El código no contiene la información del negocio.", esError: true);
        }
        return;
      }

      int meta = ((data['metaCompras'] ?? 10) as num).toInt();

      String clienteLocalId = data['clienteLocalId']?.toString() ?? '';
      String clienteNombre = data['clienteNombre']?.toString() ?? '';

      // 🔥 UNIFICACIÓN DE ID: Usa la combinación exacta Vendor + Tarjeta + Cliente Local
      String docIdTarget = (user.uid == vendorUid && clienteLocalId.isNotEmpty)
          ? "${vendorUid}_${tarjetaId}_$clienteLocalId"
          : "${vendorUid}_$tarjetaId";

      String nomNegocioMostrar = data['nombreNegocio'] ?? 'Negocio';
      if (user.uid == vendorUid && clienteNombre.isNotEmpty) {
        nomNegocioMostrar = "${data['nombreNegocio']} ($clienteNombre)";
      }

      DocumentReference miTarjetaRef = _db
          .collection('usuarios')
          .doc(user.uid)
          .collection('tarjetas_acumuladas')
          .doc(docIdTarget);

      final tarjetaSnap = await miTarjetaRef.get();
      int puntosActuales = 1;
      int completadas = 0;

      if (tarjetaSnap.exists) {
        var tData = tarjetaSnap.data() as Map<String, dynamic>;
        int ptsAntiguos = ((tData['puntosActuales'] ?? 0) as num).toInt();
        completadas = ((tData['completadasTotales'] ?? 0) as num).toInt();

        if (ptsAntiguos >= meta) {
          puntosActuales = 1;
        } else {
          puntosActuales = ptsAntiguos + 1;
          if (puntosActuales >= meta) {
            completadas++;
          }
        }
      }

      Map<String, dynamic> datosTarjetaCliente = {
        'vendorUid': vendorUid,
        'tarjetaId': tarjetaId,
        'clienteLocalId': clienteLocalId,
        'clienteNombre': clienteNombre,
        'nombreNegocio': nomNegocioMostrar,
        'logoPath': data['logoPath'] ?? '',
        'tarjetaTitulo': data['tarjetaTitulo'] ?? 'Tarjeta Fidelidad',
        'metaCompras': meta,
        'premioDesc': data['premioDesc'] ?? '',
        'montoMinimo': (data['montoMinimo'] ?? 0.0) as num,
        'puntosActuales': puntosActuales,
        'completadasTotales': completadas,
        'ultimaModificacion': FieldValue.serverTimestamp(),
      };

      await miTarjetaRef.set(datosTarjetaCliente, SetOptions(merge: true));

      // Vincular en la cuenta del vendedor en Firestore
      String clientDocId = user.uid;
      if (user.uid == vendorUid && clienteLocalId.isNotEmpty) {
        clientDocId = clienteLocalId;
      }

      await _db
          .collection('usuarios')
          .doc(vendorUid)
          .collection('mis_tarjetas_creadas')
          .doc(tarjetaId)
          .collection('clientes')
          .doc(clientDocId)
          .set({
        'clientUid': user.uid,
        'clienteLocalId': data['clienteLocalId'] ?? '',
        'clienteEmail': user.email ?? '',
        'clienteNombre': clienteNombre.isNotEmpty ? clienteNombre : (user.email ?? 'Cliente'),
        'clienteTelefono': data['clienteTelefono'] ?? '',
        'puntosActuales': puntosActuales,
        'completadasTotales': completadas,
        'ultimaModificacion': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      String clienteLocalIdStr = data['clienteLocalId']?.toString() ?? '';
      if (clienteLocalIdStr.isNotEmpty) {
        try {
          final dbLocal = await DBHelper.instance.database;
          try { await dbLocal.execute("ALTER TABLE puntos_clientes ADD COLUMN client_uid TEXT;"); } catch (_) {}
          int cId = int.tryParse(clienteLocalIdStr) ?? 0;
          int tId = int.tryParse(tarjetaId) ?? 0;
          if (cId > 0 && tId > 0) {
            await dbLocal.insert('puntos_clientes', {
              'cliente_id': cId,
              'tarjeta_id': tId,
              'puntos_actuales': puntosActuales,
              'completadas_totales': completadas,
              'client_uid': user.uid,
              'ultima_modificacion': DateTime.now().toIso8601String(),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        } catch (e) {
          debugPrint("Error actualizando SQLite local en autovinculacion: $e");
        }
      }

      // 🔥 4. RECLAMO EXITOSO -> DESTRUIR TOKEN DE FIRESTORE Y CELULAR
      await docRef.delete();
      await prefs.remove('pending_fidelidad_token');

      // Notificar al vendedor por FCM
      notificarVendedorPuntoReclamado(
        vendorUid: vendorUid,
        nombreCliente: user.email ?? 'Un cliente',
        nombreNegocio: data['nombreNegocio'] ?? 'Tu negocio',
        metaAlcanzada: puntosActuales >= meta,
        premioDesc: data['premioDesc'],
      );

      // ⚡ ACTUALIZAR MEMORIA CACHÉ LOCAL DEL CLIENTE INMEDIATAMENTE (0 ms de espera)
      try {
        String? jsonCache = prefs.getString('cache_tarjetas_acumuladas_${user.uid}');
        List<dynamic> listCache = (jsonCache != null && jsonCache.isNotEmpty) ? jsonDecode(jsonCache) : [];

        bool encontrado = false;
        String claveBuscada = (user.uid == vendorUid && clienteLocalId.isNotEmpty)
            ? "${vendorUid}_${tarjetaId}_$clienteLocalId"
            : "${vendorUid}_$tarjetaId";

        for (var item in listCache) {
          String cLoc = item['clienteLocalId']?.toString() ?? '';
          String keyItem = (user.uid == item['vendorUid'] && cLoc.isNotEmpty)
              ? "${item['vendorUid']}_${item['tarjetaId']}_$cLoc"
              : "${item['vendorUid']}_${item['tarjetaId']}";

          if (keyItem == claveBuscada) {
            item['puntosActuales'] = puntosActuales;
            item['completadasTotales'] = completadas;
            item['nombreNegocio'] = nomNegocioMostrar;
            encontrado = true;
            break;
          }
        }

        Map<String, dynamic> datosTarjetaParaCache = Map<String, dynamic>.from(datosTarjetaCliente);
        datosTarjetaParaCache['ultimaModificacion'] = DateTime.now().toIso8601String();

        if (!encontrado) {
          listCache.add(datosTarjetaParaCache);
        }

        await prefs.setString('cache_tarjetas_acumuladas_${user.uid}', jsonEncode(listCache));
      } catch (e) {
        debugPrint("Error guardando caché local de cliente: $e");
      }

      // 🔔 Notificar también al cliente que reclamó el punto
      notificarClientePuntoOtorgado(
        clientUid: user.uid,
        nombreNegocio: data['nombreNegocio'] ?? 'Tu negocio',
        puntosActuales: puntosActuales,
        meta: meta,
        premioDesc: data['premioDesc'],
      );

      onSuccess(datosTarjetaCliente, puntosActuales);

    } catch (e) {
      try { await docRef.delete(); } catch (_) {}
      await prefs.remove('pending_fidelidad_token');

      if (context.mounted) {
        _mostrarAlerta(context, "ERROR", "No se pudo reclamar el punto: $e", esError: true);
      }
    }
  }

  static Future<void> notificarVendedorPuntoReclamado({
    required String vendorUid,
    required String nombreCliente,
    required String nombreNegocio,
    bool metaAlcanzada = false,
    String? premioDesc,
  }) async {
    String titulo = metaAlcanzada 
        ? '🏆 ¡CLIENTE COMPLETÓ TARJETA!' 
        : '🎁 ¡Punto de Fidelidad entregado!';

    String premioTxt = premioDesc != null && premioDesc.isNotEmpty ? premioDesc : "el premio";

    String cuerpo = metaAlcanzada 
        ? '¡$nombreCliente ha completado todos sus sellos en $nombreNegocio para ganar $premioTxt!' 
        : '$nombreCliente ha recibido un punto en $nombreNegocio.';

    try {
      await http.post(
        Uri.parse('https://boxi-api.vercel.app/api/notificar-fidelidad'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'targetUid': vendorUid,
          'titulo': titulo,
          'cuerpo': cuerpo,
          'tipo': 'fidelidad_vendedor',
        }),
      );
    } catch (e) {
      debugPrint("Error enviando notificación al vendedor: $e");
    }
  }

  static Future<void> notificarClientePuntoOtorgado({
    required String clientUid,
    required String nombreNegocio,
    required int puntosActuales,
    required int meta,
    String? premioDesc,
  }) async {
    bool metaAlcanzada = puntosActuales >= meta;

    String titulo = metaAlcanzada 
        ? '🏆 ¡TARJETA COMPLETADA! ¡GANASTE!' 
        : '🎉 ¡Punto de Fidelidad Recibido!';

    String premioTxt = premioDesc != null && premioDesc.isNotEmpty ? premioDesc : "tu premio";

    String cuerpo = metaAlcanzada 
        ? '¡Felicidades! Completaste tus $meta sellos en $nombreNegocio. Toca para reclamar $premioTxt 🎁' 
        : '¡$nombreNegocio te ha sumado un punto! Tienes $puntosActuales de $meta puntos.';

    try {
      await http.post(
        Uri.parse('https://boxi-api.vercel.app/api/notificar-fidelidad'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'targetUid': clientUid,
          'titulo': titulo,
          'cuerpo': cuerpo,
          'tipo': 'punto_fidelidad',
        }),
      );
    } catch (e) {
      debugPrint("Error enviando notificación al cliente: $e");
    }
  }

  static void _mostrarAlerta(BuildContext context, String titulo, String msg, {bool esError = false}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(titulo, style: TextStyle(color: esError ? Colors.redAccent : Colors.green, fontWeight: FontWeight.bold)),
        content: Text(msg),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: esError ? Colors.redAccent : Colors.green),
            onPressed: () => Navigator.pop(ctx),
            child: const Text("ENTENDIDO", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // 🔥 Carga completa de tarjetas y puntos al iniciar sesión
  static Future<void> sincronizarTarjetasCompleto(String uid) async {
    if (!await ServicioNube.tieneInternet()) return;
    try {
      final db = await DBHelper.instance.database;
      try { await db.execute("ALTER TABLE puntos_clientes ADD COLUMN client_uid TEXT;"); } catch (_) {}

      final prefs = await SharedPreferences.getInstance();
      String nomNegocio = prefs.getString('nombre_negocio') ?? "Mi Negocio";

      // 1. Sincronizar Tarjetas Creadas como Vendedor
      final creadasSnap = await FirebaseFirestore.instance
          .collection('usuarios')
          .doc(uid)
          .collection('mis_tarjetas_creadas')
          .get()
          .timeout(const Duration(seconds: 5));

      for (var doc in creadasSnap.docs) {
        var cData = doc.data();
        int tId = int.tryParse(doc.id) ?? int.tryParse(cData['tarjetaId']?.toString() ?? '0') ?? 0;

        if (tId > 0) {
          await db.insert('tarjetas_fidelidad', {
            'id': tId,
            'titulo': cData['titulo'] ?? 'Tarjeta',
            'meta_compras': ((cData['metaCompras'] ?? 10) as num).toInt(),
            'premio_descripcion': cData['premioDesc'] ?? cData['titulo'] ?? '',
            'monto_minimo': ((cData['montoMinimo'] ?? 0) as num).toDouble(),
            'activa': ((cData['activa'] ?? 1) as num).toInt(),
            'ultima_modificacion': DateTime.now().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);

          final clientSnap = await FirebaseFirestore.instance
              .collection('usuarios')
              .doc(uid)
              .collection('mis_tarjetas_creadas')
              .doc(tId.toString())
              .collection('clientes')
              .get();

          for (var cDoc in clientSnap.docs) {
            var clientData = cDoc.data();
            String cLocId = clientData['clienteLocalId']?.toString() ?? cDoc.id;
            String clientUid = clientData['clientUid']?.toString() ?? cDoc.id;
            int ptsCloud = ((clientData['puntosActuales'] ?? 0) as num).toInt();
            int compCloud = ((clientData['completadasTotales'] ?? 0) as num).toInt();
            String cNombre = clientData['clienteNombre']?.toString() ?? 'Cliente';

            int cIdInt = int.tryParse(cLocId) ?? 0;
            if (cIdInt > 0) {
              await db.insert('puntos_clientes', {
                'cliente_id': cIdInt,
                'tarjeta_id': tId,
                'puntos_actuales': ptsCloud,
                'completadas_totales': compCloud,
                if (clientUid.isNotEmpty) 'client_uid': clientUid,
                'ultima_modificacion': DateTime.now().toIso8601String(),
              }, conflictAlgorithm: ConflictAlgorithm.replace);

              // 🔥 Asegurar tarjeta acumulada en Firestore
              String targetUid = clientUid.isNotEmpty ? clientUid : uid;
              String docTarget = (targetUid == uid && cLocId.isNotEmpty)
                  ? "${uid}_${tId}_$cLocId"
                  : "${uid}_$tId";

              String nombreNegocioFinal = (targetUid == uid && cNombre.isNotEmpty && cNombre != 'Cliente')
                  ? "$nomNegocio ($cNombre)"
                  : nomNegocio;

              await FirebaseFirestore.instance
                  .collection('usuarios')
                  .doc(targetUid)
                  .collection('tarjetas_acumuladas')
                  .doc(docTarget)
                  .set({
                'vendorUid': uid,
                'tarjetaId': tId.toString(),
                'clienteLocalId': cLocId,
                'clienteNombre': cNombre,
                'nombreNegocio': nombreNegocioFinal,
                'tarjetaTitulo': cData['titulo'] ?? 'Tarjeta',
                'metaCompras': ((cData['metaCompras'] ?? 10) as num).toInt(),
                'premioDesc': cData['premioDesc'] ?? cData['titulo'] ?? '',
                'montoMinimo': ((cData['montoMinimo'] ?? 0) as num).toDouble(),
                'puntosActuales': ptsCloud,
                'completadasTotales': compCloud,
                'ultimaModificacion': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));
            }
          }
        }
      }

      // 2. Sincronizar y guardar en caché "Mis Premios Acumulados" como Cliente
      final acumuladasSnap = await FirebaseFirestore.instance
          .collection('usuarios')
          .doc(uid)
          .collection('tarjetas_acumuladas')
          .get()
          .timeout(const Duration(seconds: 5));

      Map<String, Map<String, dynamic>> tarjetasSinClones = {};
      for (var d in acumuladasSnap.docs) {
        var data = d.data();
        data['docId'] = d.id;
        String vUid = data['vendorUid']?.toString() ?? '';
        String tId = data['tarjetaId']?.toString() ?? '';
        String cLocId = data['clienteLocalId']?.toString() ?? '';
        String claveUnica = (uid == vUid && cLocId.isNotEmpty)
            ? "${vUid}_${tId}_$cLocId"
            : "${vUid}_$tId";
        int ptsActuales = ((data['puntosActuales'] ?? 0) as num).toInt();

        if (!tarjetasSinClones.containsKey(claveUnica)) {
          tarjetasSinClones[claveUnica] = data;
        } else {
          var existente = tarjetasSinClones[claveUnica]!;
          int ptsExistentes = ((existente['puntosActuales'] ?? 0) as num).toInt();
          int meta = ((data['metaCompras'] ?? 10) as num).toInt();
          int compN = ((data['completadasTotales'] ?? 0) as num).toInt();
          int compE = ((existente['completadasTotales'] ?? 0) as num).toInt();

          bool esMasNueva = false;
          if (compN != compE) {
            esMasNueva = compN > compE;
          } else if (ptsExistentes >= meta && ptsActuales < meta) {
            esMasNueva = true; // Tarjeta reiniciada a 1/5
          } else {
            esMasNueva = ptsActuales > ptsExistentes;
          }

          if (esMasNueva) {
            tarjetasSinClones[claveUnica] = data;
          }
        }
      }

      List<Map<String, dynamic>> listaSaneada = tarjetasSinClones.values.map((item) {
        Map<String, dynamic> copia = Map<String, dynamic>.from(item);
        if (copia['ultimaModificacion'] is Timestamp) {
          copia['ultimaModificacion'] = (copia['ultimaModificacion'] as Timestamp).toDate().toIso8601String();
        }
        return copia;
      }).toList();

      await prefs.setString('cache_tarjetas_acumuladas_$uid', jsonEncode(listaSaneada));

    } catch (e) {
      debugPrint("Error cargando tarjetas al iniciar sesión: $e");
    }
  }

  // 🔥 Borrado definitivo de tarjetas en la nube, SQLite y memoria caché
  static Future<void> eliminarTarjetaAcumuladaCliente({
    required String vendorUid,
    required String tarjetaId,
    String? docId,
    String? clienteLocalId,
    String? clientUid,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final dbLocal = await DBHelper.instance.database;
      final prefs = await SharedPreferences.getInstance();

      var clientesColl = FirebaseFirestore.instance
          .collection('usuarios')
          .doc(vendorUid)
          .collection('mis_tarjetas_creadas')
          .doc(tarjetaId)
          .collection('clientes');

      String realClientUid = clientUid ?? '';

      // 🔍 1. Escanear y eliminar de la subcolección 'clientes' del vendedor en Firestore
      try {
        final snap = await clientesColl.get();
        for (var doc in snap.docs) {
          var data = doc.data();
          String docLocId = data['clienteLocalId']?.toString() ?? '';
          String docClientUid = data['clientUid']?.toString() ?? '';

          bool coincide = false;
          if (doc.id == clientUid || doc.id == clienteLocalId) coincide = true;
          if (clientUid != null && clientUid.isNotEmpty && docClientUid == clientUid) coincide = true;
          if (clienteLocalId != null && clienteLocalId.isNotEmpty && docLocId == clienteLocalId) coincide = true;

          if (coincide) {
            if (docClientUid.isNotEmpty) realClientUid = docClientUid;
            await doc.reference.delete().catchError((_) {});
          }
        }
      } catch (e) {
        debugPrint("Error escaneando subcolección clientes del vendedor: $e");
      }

      // 🧹 2. Borrar de la base de datos local SQLite (puntos_clientes)
      try {
        int tId = int.tryParse(tarjetaId) ?? 0;
        if (tId > 0) {
          if (clienteLocalId != null && clienteLocalId.isNotEmpty) {
            int cId = int.tryParse(clienteLocalId) ?? 0;
            if (cId > 0) {
              await dbLocal.delete('puntos_clientes', where: 'cliente_id = ? AND tarjeta_id = ?', whereArgs: [cId, tId]);
            }
          } else {
            await dbLocal.delete('puntos_clientes', where: 'tarjeta_id = ?', whereArgs: [tId]);
          }
        }
      } catch (e) {
        debugPrint("Error limpiando SQLite local: $e");
      }

      // 🧹 3. Borrar de 'tarjetas_acumuladas' en Firestore para todos los UIDs involucrados
      Set<String> uidsAELiminar = {vendorUid, user.uid};
      if (realClientUid.isNotEmpty) uidsAELiminar.add(realClientUid);

      for (String uId in uidsAELiminar) {
        var acumuladasColl = FirebaseFirestore.instance
            .collection('usuarios')
            .doc(uId)
            .collection('tarjetas_acumuladas');

        await acumuladasColl.doc("${vendorUid}_$tarjetaId").delete().catchError((_) {});
        if (clienteLocalId != null && clienteLocalId.isNotEmpty) {
          await acumuladasColl.doc("${vendorUid}_${tarjetaId}_$clienteLocalId").delete().catchError((_) {});
        }
        if (docId != null && docId.isNotEmpty) {
          await acumuladasColl.doc(docId).delete().catchError((_) {});
        }
      }

      // 🧹 4. Borrar de la Memoria Caché de SharedPreferences para que no vuelva a reaparecer
      try {
        String? jsonCache = prefs.getString('cache_tarjetas_acumuladas_${user.uid}');
        if (jsonCache != null && jsonCache.isNotEmpty) {
          List<dynamic> listCache = jsonDecode(jsonCache);
          listCache.removeWhere((item) {
            String tId = item['tarjetaId']?.toString() ?? '';
            String vUid = item['vendorUid']?.toString() ?? '';
            String cLoc = item['clienteLocalId']?.toString() ?? '';
            String itemDocId = item['docId']?.toString() ?? '';

            bool esMismaTarjeta = (vUid == vendorUid && tId == tarjetaId);
            bool esMismoDoc = (docId != null && docId.isNotEmpty && itemDocId == docId);
            bool esMismoCliente = (clienteLocalId != null && clienteLocalId.isNotEmpty && cLoc == clienteLocalId && tId == tarjetaId);

            return esMismaTarjeta || esMismoDoc || esMismoCliente;
          });
          await prefs.setString('cache_tarjetas_acumuladas_${user.uid}', jsonEncode(listCache));
        }
      } catch (e) {
        debugPrint("Error limpiando caché SharedPreferences: $e");
      }

    } catch (e) {
      debugPrint("Error eliminando tarjeta acumulada: $e");
    }
  }
}