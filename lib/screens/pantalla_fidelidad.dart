import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/services.dart';
import '../database/db_helper.dart';
import 'pantalla_premium.dart';
import 'servicio_fidelidad.dart';
import 'servicio_anuncios.dart';
import 'dart:convert';
import 'package:firebase_database/firebase_database.dart';
import 'servicio_nube.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/foundation.dart'; 

class PantallaFidelidad extends StatefulWidget {
  final String? tokenParaReclamarDirecto;
  const PantallaFidelidad({super.key, this.tokenParaReclamarDirecto});

  @override
  State<PantallaFidelidad> createState() => _PantallaFidelidadState();
}

class _PantallaFidelidadState extends State<PantallaFidelidad> {
  bool _esPremium = false;
  List<Map<String, dynamic>> _misTarjetasComoVendedor = [];
  List<Map<String, dynamic>> _misTarjetasComoCliente = [];
  String _nombreNegocio = "MI NEGOCIO";
  String _logoPath = "";
  bool _cargandoDatos = true;
  String _busquedaMisTarjetas = ""; // 👈 Filtro buscador
  bool _mostrarTodasMisTarjetas = false; // 👈 Control "Ver más"
  bool _procesandoPunto = false; // 👈 Bloqueo anti-doble toque
  String _localBoxiPathGlobal = "/storage/emulated/0/Pictures/Boxi";

  @override
  void initState() {
    super.initState();
    _cargarDatosBD();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.tokenParaReclamarDirecto != null && widget.tokenParaReclamarDirecto!.isNotEmpty) {
        _ejecutarReclamoDirecto(widget.tokenParaReclamarDirecto!);
      }
    });
  }

  Future<void> _cargarDatosBD() async {
    final prefs = await SharedPreferences.getInstance();
    final db = await DBHelper.instance.database;
    final user = FirebaseAuth.instance.currentUser;
    await db.rawDelete('''
      DELETE FROM puntos_clientes 
      WHERE tarjeta_id NOT IN (SELECT id FROM tarjetas_fidelidad)
    ''');
    if (user != null) {
      try {
        final tarjetasValidas = await db.query('tarjetas_fidelidad', columns: ['id']);
        Set<String> idsValidosStr = tarjetasValidas.map((t) => t['id'].toString()).toSet();
        
        String? jsonCache = prefs.getString('cache_tarjetas_acumuladas_${user.uid}');
        if (jsonCache != null && jsonCache.isNotEmpty) {
          List<dynamic> listCache = jsonDecode(jsonCache);
          listCache.removeWhere((item) {
            String vUid = item['vendorUid']?.toString() ?? '';
            String tId = item['tarjetaId']?.toString() ?? '';
            return vUid == user.uid && !idsValidosStr.contains(tId);
          });
          await prefs.setString('cache_tarjetas_acumuladas_${user.uid}', jsonEncode(listCache));
        }
      } catch (_) {}
    }
    String nombreNeg = prefs.getString('nombre_negocio') ?? "MI NEGOCIO";
    String logoP = prefs.getString('logo_path') ?? "";
    _localBoxiPathGlobal = prefs.getString('local_boxi_path') ?? "/storage/emulated/0/Pictures/Boxi";
    final tarjetasRes = await db.query('tarjetas_fidelidad', orderBy: 'id DESC');
    final puntosLocal = await db.query('puntos_clientes');
    final clientesLocal = await db.query('clientes');

    Map<int, String> mapaClientesNombre = {};
    for (var c in clientesLocal) {
      mapaClientesNombre[c['id'] as int] = (c['nombre_completo'] ?? '').toString();
    }

    Map<int, Map<String, dynamic>> mapaTarjetasVendedor = {};
    for (var t in tarjetasRes) {
      mapaTarjetasVendedor[t['id'] as int] = Map<String, dynamic>.from(t);
    }

    Map<String, Map<String, dynamic>> acumuladasMapLocal = {};
    for (var p in puntosLocal) {
      int pts = (p['puntos_actuales'] as num).toInt();
      int tId = (p['tarjeta_id'] as num).toInt();
      int cId = (p['cliente_id'] as num).toInt();

      if (pts > 0 && mapaTarjetasVendedor.containsKey(tId)) {
        var tInfo = mapaTarjetasVendedor[tId]!;
        String cNom = mapaClientesNombre[cId] ?? 'Cliente';
        String keyUnicaLocal = "${user?.uid ?? ''}_${tId}_$cId"; 
        int compTotalesLocal = (p['completadas_totales'] as num?)?.toInt() ?? 0;
        int ptsPrevios = acumuladasMapLocal.containsKey(keyUnicaLocal) ? (acumuladasMapLocal[keyUnicaLocal]!['puntosActuales'] as int) : -1;
        int compPrevias = acumuladasMapLocal.containsKey(keyUnicaLocal) ? (acumuladasMapLocal[keyUnicaLocal]!['completadasTotales'] as int) : -1;
        int metaT = ((tInfo['meta_compras'] ?? 10) as num).toInt();

        bool esMasNuevoLocal = !acumuladasMapLocal.containsKey(keyUnicaLocal);
        if (!esMasNuevoLocal) {
          if (compTotalesLocal != compPrevias) {
            esMasNuevoLocal = compTotalesLocal > compPrevias;
          } else if (ptsPrevios >= metaT && pts < metaT) {
            esMasNuevoLocal = true; // Reinicio de tarjeta completada
          } else {
            esMasNuevoLocal = pts > ptsPrevios;
          }
        }

        // Solo mostrar en "MIS PREMIOS ACUMULADOS" si la tarjeta es tuya personal ("Yo" o vinculada a tu propia cuenta)
        bool esMiTarjetaPersonal = cNom.toLowerCase() == 'yo' || 
            cNom.toLowerCase().contains('yo (') || 
            (p['client_uid'] != null && p['client_uid'] == user?.uid);

        if (esMasNuevoLocal && esMiTarjetaPersonal) {
          String fotoPremio = (tInfo['foto_path'] != null && tInfo['foto_path'].toString().isNotEmpty)
              ? tInfo['foto_path'].toString()
              : '';

          acumuladasMapLocal[keyUnicaLocal] = {
            'docId': "${user?.uid ?? 'local'}_${tId}_$cId",
            'vendorUid': user?.uid ?? '',
            'tarjetaId': tId.toString(),
            'clienteLocalId': cId.toString(),
            'clienteNombre': cNom,
            'nombreNegocio': "$nombreNeg ($cNom)",
            'logoPath': logoP, // 👈 CORREGIDO: Guarda el logo real de tu negocio
            'fotoPath': fotoPremio, // 👈 Guarda la foto del producto/premio
            'tarjetaTitulo': tInfo['titulo'] ?? 'Tarjeta',
            'metaCompras': ((tInfo['meta_compras'] ?? 10) as num).toInt(),
            'premioDesc': tInfo['premio_descripcion'] ?? tInfo['titulo'] ?? '',
            'montoMinimo': ((tInfo['monto_minimo'] ?? 0) as num).toDouble(),
            'puntosActuales': pts,
            'completadasTotales': (p['completadas_totales'] as num?)?.toInt() ?? 0,
          };
        }
      }
    }
    List<Map<String, dynamic>> acumuladasLocales = acumuladasMapLocal.values.toList();

    List<Map<String, dynamic>> acumuladasCache = List.from(acumuladasLocales);
    if (user != null) {
      String? jsonCache = prefs.getString('cache_tarjetas_acumuladas_${user.uid}');
      if (jsonCache != null && jsonCache.isNotEmpty) {
        try {
          var list = List<Map<String, dynamic>>.from(jsonDecode(jsonCache));
          for (var item in list) {
            String cLoc = item['clienteLocalId']?.toString() ?? '';
            String key = (user.uid == item['vendorUid'] && cLoc.isNotEmpty)
                ? "${item['vendorUid']}_${item['tarjetaId']}_$cLoc"
                : "${item['vendorUid']}_${item['tarjetaId']}";
            if (!acumuladasCache.any((x) {
              String xLoc = x['clienteLocalId']?.toString() ?? '';
              String xKey = (user.uid == x['vendorUid'] && xLoc.isNotEmpty)
                  ? "${x['vendorUid']}_${x['tarjetaId']}_$xLoc"
                  : "${x['vendorUid']}_${x['tarjetaId']}";
              return xKey == key;
            })) {
              acumuladasCache.add(item);
            }
          }
        } catch (_) {}
      }
    }

    if (mounted) {
      setState(() {
        _esPremium = prefs.getBool('es_premium') ?? false;
        _nombreNegocio = nombreNeg;
        _logoPath = logoP;
        _misTarjetasComoVendedor = List<Map<String, dynamic>>.from(tarjetasRes);
        _misTarjetasComoCliente = acumuladasCache;
        _cargandoDatos = false;
      });
    }

    // ⚡ 2. VENDEDOR: SINCRONIZAR SUS TARJETAS CREADAS Y CLIENTES CON PUNTOS OFFLINE
    if (user != null && await ServicioNube.tieneInternet()) {
      try {
        final creadasSnap = await FirebaseFirestore.instance
            .collection('usuarios')
            .doc(user.uid)
            .collection('mis_tarjetas_creadas')
            .get()
            .timeout(const Duration(seconds: 4));

        final puntosLocal = await db.query('puntos_clientes');
        Map<String, int> mapaPtsLocal = {};
        for (var p in puntosLocal) {
          mapaPtsLocal["${p['cliente_id']}_${p['tarjeta_id']}"] = (p['puntos_actuales'] as num).toInt();
        }

        for (var doc in creadasSnap.docs) {
          var cData = doc.data();
          int tId = int.tryParse(doc.id) ?? int.tryParse(cData['tarjetaId']?.toString() ?? '0') ?? 0;

          if (tId > 0) {
            String fotoNubeBD = cData['fotoPath']?.toString() ?? cData['foto_path']?.toString() ?? '';

            await db.insert('tarjetas_fidelidad', {
              'id': tId,
              'titulo': cData['titulo'] ?? 'Tarjeta',
              'meta_compras': ((cData['metaCompras'] ?? 10) as num).toInt(),
              'premio_descripcion': cData['premioDesc'] ?? cData['titulo'] ?? '',
              'monto_minimo': ((cData['montoMinimo'] ?? 0) as num).toDouble(),
              'foto_path': fotoNubeBD,
              'activa': ((cData['activa'] ?? 1) as num).toInt(),
              'ultima_modificacion': DateTime.now().toIso8601String(),
            }, conflictAlgorithm: ConflictAlgorithm.replace);

            // 🔥 REVISAR CLIENTES DE ESTA TARJETA Y SUBIR PUNTOS PENDIENTES AL CLIENTE Y AL VENDEDOR
            final clientSnap = await FirebaseFirestore.instance
                .collection('usuarios')
                .doc(user.uid)
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
              String key = "${cLocId}_$tId";

              int ptsLoc = mapaPtsLocal[key] ?? 0;

              if (ptsLoc > ptsCloud) {
                // A. Si local es mayor, actualizar en la nube
                await FirebaseFirestore.instance
                    .collection('usuarios')
                    .doc(user.uid)
                    .collection('mis_tarjetas_creadas')
                    .doc(tId.toString())
                    .collection('clientes')
                    .doc(cDoc.id)
                    .set({'puntosActuales': ptsLoc, 'ultimaModificacion': FieldValue.serverTimestamp()}, SetOptions(merge: true));

                String targetUidCliente = clientUid.isNotEmpty ? clientUid : user.uid;
                String docTargetCliente = (targetUidCliente == user.uid && cLocId.isNotEmpty)
                    ? "${user.uid}_${tId}_$cLocId"
                    : "${user.uid}_$tId";
                await FirebaseFirestore.instance
                    .collection('usuarios')
                    .doc(targetUidCliente)
                    .collection('tarjetas_acumuladas')
                    .doc(docTargetCliente)
                    .set({'puntosActuales': ptsLoc, 'ultimaModificacion': FieldValue.serverTimestamp()}, SetOptions(merge: true));
              } else if (ptsCloud > ptsLoc) {
                // B. Si la nube es mayor, actualizar en la base local SQLite
                int cIdInt = int.tryParse(cLocId) ?? 0;
                if (cIdInt > 0) {
                  await db.delete('puntos_clientes', where: 'cliente_id = ? AND tarjeta_id = ?', whereArgs: [cIdInt, tId]);
                  await db.insert('puntos_clientes', {
                    'cliente_id': cIdInt,
                    'tarjeta_id': tId,
                    'puntos_actuales': ptsCloud,
                    'completadas_totales': compCloud,
                    if (clientUid.isNotEmpty) 'client_uid': clientUid,
                    'ultima_modificacion': DateTime.now().toIso8601String(),
                  });
                }
              }
            }
          }
        }

        final tarjetasActualizadas = await db.query('tarjetas_fidelidad', orderBy: 'id DESC');
        if (mounted) {
          setState(() {
            _misTarjetasComoVendedor = List<Map<String, dynamic>>.from(tarjetasActualizadas);
          });
        }
      } catch (e) {
        debugPrint("Error sincronizando tarjetas de vendedor: $e");
      }
    }

    // ⚡ 3. CLIENTE: CARGAR TARJETAS ACUMULADAS DESDE FIRESTORE
    if (user != null) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('usuarios')
            .doc(user.uid)
            .collection('tarjetas_acumuladas')
            .get()
            .timeout(const Duration(seconds: 4));

        Map<String, Map<String, dynamic>> tarjetasSinClones = {};

        Map<String, Map<String, String>> vendorInfoCache = {};

        for (var d in snap.docs) {
          var data = d.data();
          data['docId'] = d.id;

          String vUid = data['vendorUid']?.toString() ?? '';
          String tId = data['tarjetaId']?.toString() ?? '';
          String cLocId = data['clienteLocalId']?.toString() ?? '';

          // 🔑 Clave única: si es la cuenta del cliente real, la clave es ÚNICA por vendedor y tarjeta
          String claveUnica = (user.uid == vUid && cLocId.isNotEmpty)
              ? "${vUid}_${tId}_$cLocId"
              : "${vUid}_$tId";

          // ⚡ Obtener nombre y logo real del negocio desde el perfil del vendedor si no vienen completos
          if (vUid.isNotEmpty) {
            String currentNom = data['nombreNegocio']?.toString() ?? '';
            String currentLogo = data['logoPath']?.toString() ?? '';

            if (currentNom.isEmpty || currentNom == "MI NEGOCIO" || currentNom == "Nuestro Negocio" || currentLogo.isEmpty) {
              if (!vendorInfoCache.containsKey(vUid)) {
                try {
                  var vDoc = await FirebaseFirestore.instance.collection('usuarios').doc(vUid).get();
                  if (vDoc.exists && vDoc.data() != null) {
                    var vData = vDoc.data()!;
                    vendorInfoCache[vUid] = {
                      'nombre': (vData['nombre_negocio'] ?? vData['nombreNegocio'] ?? vData['nombre'] ?? '').toString(),
                      'logo': (vData['logo_path'] ?? vData['logoPath'] ?? vData['logo_url'] ?? '').toString(),
                    };
                  }
                } catch (_) {}
              }

              if (vendorInfoCache.containsKey(vUid)) {
                String fetchedNom = vendorInfoCache[vUid]!['nombre'] ?? '';
                String fetchedLogo = vendorInfoCache[vUid]!['logo'] ?? '';
                if ((currentNom.isEmpty || currentNom == "MI NEGOCIO" || currentNom == "Nuestro Negocio") && fetchedNom.isNotEmpty) {
                  data['nombreNegocio'] = fetchedNom;
                }
                if (currentLogo.isEmpty && fetchedLogo.isNotEmpty) {
                  data['logoPath'] = fetchedLogo;
                }
              }
            }
          }

          // ⚡ SI ERES EL VENDEDOR ADMINISTRANDO A UN CLIENTE, MANTENER "Negocio (NombreCliente)"
          if (user.uid == vUid && cLocId.isNotEmpty) {
            String cNom = (data['clienteNombre'] ?? '').toString();
            if (cNom.isNotEmpty && cNom.toLowerCase() != 'yo' && !cNom.toLowerCase().contains('yo (')) {
              String baseNom = (data['nombreNegocio'] ?? nombreNeg).toString();
              if (baseNom.contains(' (')) {
                baseNom = baseNom.split(' (').first;
              }
              data['nombreNegocio'] = "$baseNom ($cNom)";
            }
          }
          int ptsActuales = ((data['puntosActuales'] ?? 0) as num).toInt();

          if (!tarjetasSinClones.containsKey(claveUnica)) {
            tarjetasSinClones[claveUnica] = data;
          } else {
            var existente = tarjetasSinClones[claveUnica]!;
            int ptsExistentes = ((existente['puntosActuales'] ?? 0) as num).toInt();
            int meta = ((data['metaCompras'] ?? 10) as num).toInt();
            int compN = ((data['completadasTotales'] ?? 0) as num).toInt();
            int compE = ((existente['completadasTotales'] ?? 0) as num).toInt();

            // 🔥 Detectar el reinicio de ciclo (de 5/5 a 1/5) o mayor cantidad de vueltas completadas
            bool esMasNueva = false;
            if (compN != compE) {
              esMasNueva = compN > compE;
            } else if (ptsExistentes >= meta && ptsActuales < meta) {
              esMasNueva = true; // Tarjeta reiniciada a 1/5
            } else {
              esMasNueva = ptsActuales >= ptsExistentes;
            }

            if (esMasNueva) {
              tarjetasSinClones[claveUnica] = data;
            } else {
              if (data['nombreNegocio'] != null && data['nombreNegocio'].toString().isNotEmpty && data['nombreNegocio'] != "MI NEGOCIO") {
                existente['nombreNegocio'] = data['nombreNegocio'];
              }
            }
          }
        }

        // 🔥 Combinar con las tarjetas locales preservando SIEMPRE el nombre de tienda y logo real de la nube
        for (var localCard in acumuladasLocales) {
          String vUid = localCard['vendorUid']?.toString() ?? '';
          String tId = localCard['tarjetaId']?.toString() ?? '';
          String cLocId = localCard['clienteLocalId']?.toString() ?? '';
          String claveUnica = (user.uid == vUid && cLocId.isNotEmpty)
              ? "${vUid}_${tId}_$cLocId"
              : "${vUid}_$tId";

          // Preservar nombre del cliente si es tarjeta administrada por el vendedor
          if (user.uid == vUid && cLocId.isNotEmpty) {
            String cNom = (localCard['clienteNombre'] ?? '').toString();
            if (cNom.isNotEmpty && cNom.toLowerCase() != 'yo' && !cNom.toLowerCase().contains('yo (')) {
              String baseNom = (localCard['nombreNegocio'] ?? nombreNeg).toString();
              if (baseNom.contains(' (')) {
                baseNom = baseNom.split(' (').first;
              }
              localCard['nombreNegocio'] = "$baseNom ($cNom)";
            }
          }

          if (!tarjetasSinClones.containsKey(claveUnica)) {
            tarjetasSinClones[claveUnica] = localCard;
          } else {
            var existente = tarjetasSinClones[claveUnica]!;
            int ptsExistentes = ((existente['puntosActuales'] ?? 0) as num).toInt();
            int ptsLocalCard = ((localCard['puntosActuales'] ?? 0) as num).toInt();

            String nombreReal = (existente['nombreNegocio'] != null && existente['nombreNegocio'].toString().isNotEmpty && existente['nombreNegocio'] != "MI NEGOCIO")
                ? existente['nombreNegocio']
                : localCard['nombreNegocio'];
            String logoReal = (existente['logoPath'] != null && existente['logoPath'].toString().isNotEmpty)
                ? existente['logoPath']
                : localCard['logoPath'];

            int meta = ((localCard['metaCompras'] ?? 10) as num).toInt();
            int compLocal = ((localCard['completadasTotales'] ?? 0) as num).toInt();
            int compExistente = ((existente['completadasTotales'] ?? 0) as num).toInt();

            bool localEsMasNueva = false;
            if (compLocal != compExistente) {
              localEsMasNueva = compLocal > compExistente;
            } else if (ptsExistentes >= meta && ptsLocalCard < meta) {
              localEsMasNueva = true; // Tarjeta reiniciada a 1/5
            } else {
              localEsMasNueva = ptsLocalCard > ptsExistentes;
            }

            if (localEsMasNueva) {
              localCard['nombreNegocio'] = nombreReal;
              localCard['logoPath'] = logoReal;
              tarjetasSinClones[claveUnica] = localCard;
            } else {
              existente['nombreNegocio'] = nombreReal;
              existente['logoPath'] = logoReal;
            }
          }
        }

        List<Map<String, dynamic>> misTarjetasClienteNube = tarjetasSinClones.values.map((item) {
          Map<String, dynamic> copia = Map<String, dynamic>.from(item);
          if (copia['ultimaModificacion'] is Timestamp) {
            copia['ultimaModificacion'] = (copia['ultimaModificacion'] as Timestamp).toDate().toIso8601String();
          }
          return copia;
        }).toList();

        try {
          await prefs.setString('cache_tarjetas_acumuladas_${user.uid}', jsonEncode(misTarjetasClienteNube));
        } catch (e) {
          debugPrint("Error guardando cache JSON: $e");
        }

        if (!mounted) return;
        setState(() {
          _misTarjetasComoCliente = misTarjetasClienteNube;
        });
      } catch (e) {
        debugPrint("Error leyendo tarjetas acumuladas: $e");
      }
    }

    // 🧹 4. VERIFICACIÓN EN SEGUNDO PLANO VÍA RTDB
    if (user != null && _esPremium && await ServicioNube.tieneInternet()) {
      try {
        final ref = FirebaseDatabase.instance.ref("datos_privados/${user.uid}/tarjetas_fidelidad");
        final snap = await ref.get().timeout(const Duration(seconds: 4));

        if (snap.exists) {
          final raw = snap.value;
          List<int> idsRTDB = [];
          if (raw is List) {
            for (var item in raw) {
              if (item != null && item['id'] != null) idsRTDB.add((item['id'] as num).toInt());
            }
          }

          final tarjetasLocales = await db.query('tarjetas_fidelidad', columns: ['id']);
          bool huboBorrados = false;

          for (var t in tarjetasLocales) {
            int localId = t['id'] as int;
            if (!idsRTDB.contains(localId) && idsRTDB.isNotEmpty) {
              await db.delete('tarjetas_fidelidad', where: 'id = ?', whereArgs: [localId]);
              huboBorrados = true;
            }
          }

          if (huboBorrados) {
            final tarjetasLimpias = await db.query('tarjetas_fidelidad', orderBy: 'id DESC');
            if (mounted) {
              setState(() {
                _misTarjetasComoVendedor = List<Map<String, dynamic>>.from(tarjetasLimpias);
              });
            }
          }
        }
      } catch (e) {
        debugPrint("Error comprobando borrados en RTDB: $e");
      }
    }
  }

  void _ejecutarReclamoDirecto(String token) {
    ServicioFidelidad.reclamarPuntoToken(
      token: token,
      context: context,
      onSuccess: (negocioData, puntoNuevo) {
        _cargarDatosBD();
        _mostrarAnimacionEstampadoX(negocioData, puntoNuevo);
      },
    );
  }

  Widget _construirLogoNegocio(String logoPath) {
    if (logoPath.trim().isEmpty) {
      return const Center(
        child: Icon(Icons.card_giftcard_rounded, color: Color(0xFF0D47A1), size: 26),
      );
    }

    // 🔥 BUSCAR RECURSO LOCAL SI ES UNA URL DE CLOUDINARY U HTTP
    if (logoPath.startsWith('http')) {
      String name = logoPath.split('/').last.split('?').first;
      if (!name.contains('.')) name += '.jpg';

      File fPub = File('$_localBoxiPathGlobal/$name');
      File fVar = File('$_localBoxiPathGlobal/Variantes/$name');

      if (fVar.existsSync() && fVar.lengthSync() > 0) {
        return Image.file(fVar, fit: BoxFit.cover, gaplessPlayback: true);
      } else if (fPub.existsSync() && fPub.lengthSync() > 0) {
        return Image.file(fPub, fit: BoxFit.cover, gaplessPlayback: true);
      }

      return Image.network(
        logoPath,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const Center(
          child: Icon(Icons.card_giftcard_rounded, color: Color(0xFF0D47A1), size: 26),
        ),
      );
    }

    // Archivo local directo
    try {
      File file = File(logoPath);
      if (file.existsSync() && file.lengthSync() > 0) {
        return Image.file(
          file,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const Center(
            child: Icon(Icons.card_giftcard_rounded, color: Color(0xFF0D47A1), size: 26),
          ),
        );
      }
    } catch (_) {}

    return const Center(
      child: Icon(Icons.card_giftcard_rounded, color: Color(0xFF0D47A1), size: 26),
    );
  }

  // 🔥 MÉTODO OPTIMIZADO: UTILIZA BATCH ATÓMICO EN FIRESTORE PARA EVITAR MÚLTIPLES MODIFICACIONES
  Future<void> _ajustarPuntosClientesPorNuevaMeta({
    required int tarjetaId,
    required int metaAntigua,
    required int nuevaMeta,
    required String tituloTarjeta,
    required String premioDesc,
  }) async {
    if (metaAntigua == nuevaMeta) return;

    final db = await DBHelper.instance.database;
    final user = FirebaseAuth.instance.currentUser;
    final prefs = await SharedPreferences.getInstance();
    String vendorUid = user?.uid ?? '';
    String nomNegocio = _nombreNegocio;
    bool hayInternet = user != null && await ServicioNube.tieneInternet();

    Set<String> clientesNotificados = {};
    Set<String> vendedoresNotificados = {};

    final puntosClientesDB = await db.query(
      'puntos_clientes',
      where: 'tarjeta_id = ?',
      whereArgs: [tarjetaId],
    );

    // 1. DEDUPLICAR CLIENTES LOCALES (Procesar cada cliente una sola vez)
    Map<int, Map<String, dynamic>> clientesUnicosMap = {};
    for (var p in puntosClientesDB) {
      int cId = (p['cliente_id'] as num).toInt();
      if (!clientesUnicosMap.containsKey(cId)) {
        clientesUnicosMap[cId] = Map<String, dynamic>.from(p);
      }
    }

    // 2. CREAR BATCH DE FIRESTORE (Agrupa todas las escrituras en un solo paquete)
    WriteBatch? batchNube = hayInternet ? FirebaseFirestore.instance.batch() : null;

    for (var p in clientesUnicosMap.values) {
      int cId = (p['cliente_id'] as num).toInt();
      int ptsActuales = (p['puntos_actuales'] as num).toInt();
      int compTotales = (p['completadas_totales'] as num?)?.toInt() ?? 0;
      String clientUid = p['client_uid']?.toString() ?? '';

      int nuevosPts = ptsActuales > nuevaMeta ? nuevaMeta : ptsActuales;
      bool acabaDeCompletar = (ptsActuales < metaAntigua) && (nuevosPts >= nuevaMeta);

      if (acabaDeCompletar) {
        compTotales++;
      }

      // A. Actualizar en SQLite local
      await db.update(
        'puntos_clientes',
        {
          'puntos_actuales': nuevosPts,
          'completadas_totales': compTotales,
          'ultima_modificacion': DateTime.now().toIso8601String(),
        },
        where: 'cliente_id = ? AND tarjeta_id = ?',
        whereArgs: [cId, tarjetaId],
      );

      final clienteDoc = await db.query('clientes', where: 'id = ?', whereArgs: [cId]);
      String clienteNombre = clienteDoc.isNotEmpty ? (clienteDoc.first['nombre_completo'] ?? 'Cliente').toString() : 'Cliente';
      String clienteTel = clienteDoc.isNotEmpty ? (clienteDoc.first['telefono'] ?? '').toString() : '';

      if (vendorUid.isNotEmpty) {
        String docTargetCliente = "${vendorUid}_${tarjetaId}_$cId";
        String targetUidCliente = clientUid.isNotEmpty ? clientUid : vendorUid;

        Map<String, dynamic> datosVendedor = {
          'clientUid': clientUid,
          'clienteLocalId': cId.toString(),
          'clienteNombre': clienteNombre,
          'clienteTelefono': clienteTel,
          'completadasTotales': compTotales,
          'puntosActuales': nuevosPts,
        };

        Map<String, dynamic> datosCliente = {
          'clienteLocalId': cId.toString(),
          'clienteNombre': clienteNombre,
          'completadasTotales': compTotales,
          'logoPath': _logoPath,
          'metaCompras': nuevaMeta,
          'nombreNegocio': nomNegocio,
          'premioDesc': premioDesc,
          'puntosActuales': nuevosPts,
          'tarjetaId': tarjetaId.toString(),
          'tarjetaTitulo': tituloTarjeta,
          'vendorUid': vendorUid,
        };

        String rutaVendedor = "ruta_custom:usuarios/$vendorUid/mis_tarjetas_creadas/$tarjetaId/clientes";
        String rutaCliente = "ruta_custom:usuarios/$targetUidCliente/tarjetas_acumuladas";

        if (hayInternet && batchNube != null) {
          // B. ENCOLAR EN EL BATCH ATÓMICO
          DocumentReference docRefVendedor = FirebaseFirestore.instance
              .collection('usuarios')
              .doc(vendorUid)
              .collection('mis_tarjetas_creadas')
              .doc(tarjetaId.toString())
              .collection('clientes')
              .doc(cId.toString());

          batchNube.set(docRefVendedor, {
            ...datosVendedor,
            'ultimaModificacion': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

          DocumentReference docRefCliente = FirebaseFirestore.instance
              .collection('usuarios')
              .doc(targetUidCliente)
              .collection('tarjetas_acumuladas')
              .doc(docTargetCliente);

          batchNube.set(docRefCliente, {
            ...datosCliente,
            'ultimaModificacion': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

          // Notificaciones
          if (acabaDeCompletar) {
            if (!clientesNotificados.contains(targetUidCliente)) {
              clientesNotificados.add(targetUidCliente);
              ServicioFidelidad.notificarClientePuntoOtorgado(
                clientUid: targetUidCliente,
                nombreNegocio: nomNegocio,
                puntosActuales: nuevosPts,
                meta: nuevaMeta,
                premioDesc: premioDesc,
              );
            }

            if (targetUidCliente != vendorUid && !vendedoresNotificados.contains(vendorUid)) {
              vendedoresNotificados.add(vendorUid);
              ServicioFidelidad.notificarVendedorPuntoReclamado(
                vendorUid: vendorUid,
                nombreCliente: clienteNombre,
                nombreNegocio: nomNegocio,
                metaAlcanzada: true,
                premioDesc: premioDesc,
              );
            }
          }
        } else {
          // Guardar en cola de operaciones pendientes offline
          await db.insert('operaciones_pendientes', {
            'tabla': rutaVendedor,
            'operacion': 'set',
            'doc_id': cId.toString(),
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

      // C. Actualizar Caché SharedPreferences
      try {
        if (vendorUid.isNotEmpty) {
          String? jsonCache = prefs.getString('cache_tarjetas_acumuladas_$vendorUid');
          if (jsonCache != null && jsonCache.isNotEmpty) {
            List<dynamic> listCache = jsonDecode(jsonCache);
            for (var item in listCache) {
              if (item['tarjetaId']?.toString() == tarjetaId.toString() &&
                  item['clienteLocalId']?.toString() == cId.toString()) {
                item['puntosActuales'] = nuevosPts;
                item['completadasTotales'] = compTotales;
                item['metaCompras'] = nuevaMeta;
              }
            }
            await prefs.setString('cache_tarjetas_acumuladas_$vendorUid', jsonEncode(listCache));
          }
        }
      } catch (_) {}
    }

    // 3. EJECUTAR EL BATCH ATÓMICO EN FIRESTORE (UNA SOLA MODIFICACIÓN EN LUGAR DE MÚLTIPLES)
    if (batchNube != null) {
      try {
        await batchNube.commit();
      } catch (e) {
        debugPrint("Error ejecutando batch en Firestore: $e");
      }
    }
  }

  void _mostrarAnimacionEstampadoX(Map<String, dynamic> tarjeta, int puntoNuevo) {
    int meta = ((tarjeta['metaCompras'] ?? 10) as num).toInt();
    String nomNegocio = tarjeta['nombreNegocio'] ?? 'Negocio';
    String premio = tarjeta['premioDesc'] ?? tarjeta['titulo'] ?? 'Recompensa';
    String logoNegocio = tarjeta['logoPath'] ?? _logoPath;
    String fotoPremio = tarjeta['fotoPath'] ?? tarjeta['foto_path'] ?? '';
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
        child: Container(
          width: 440,
          padding: const EdgeInsets.all(22),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 🏪 LOGO DE NEGOCIO + NOMBRE
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 36,
                      height: 38,
                      decoration: const BoxDecoration(shape: BoxShape.circle),
                      clipBehavior: Clip.antiAlias,
                      child: _construirLogoNegocio(logoNegocio),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        nomNegocio,
                        style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // 🎁 RECUADRO DEL PREMIO CON SU FOTO
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isOscuro ? Colors.cyanAccent.withOpacity(0.08) : Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: isOscuro ? Colors.cyanAccent.withOpacity(0.3) : Colors.blue.shade200),
                  ),
                  child: Row(
                    children: [
                      if (fotoPremio.isNotEmpty) ...[
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: isOscuro ? Colors.white10 : Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: _construirLogoNegocio(fotoPremio),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Builder(
                          builder: (context) {
                            double mMin = ((tarjeta['montoMinimo'] ?? 0) as num).toDouble();
                            String textoMonto = mMin > 0 ? " de \$${mMin.toInt()} o más" : "";
                            return Text(
                              "Por $meta compras$textoMonto obtienes $premio",
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
                              ),
                            );
                          }
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 1.0,
                  ),
                  itemCount: meta,
                  itemBuilder: (context, index) {
                    bool tieneSello = (index + 1) <= puntoNuevo;
                    bool esElNuevoSello = (index + 1) == puntoNuevo;

                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 800),
                      curve: Curves.elasticOut,
                      decoration: BoxDecoration(
                        color: tieneSello ? Colors.green.withOpacity(0.15) : (isOscuro ? Colors.white10 : Colors.grey.shade100),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: tieneSello ? Colors.green : Colors.grey.shade300, width: tieneSello ? 2 : 1),
                      ),
                      child: Center(
                        child: tieneSello
                            ? TweenAnimationBuilder<double>(
                                duration: const Duration(milliseconds: 1200),
                                tween: Tween(begin: 0.0, end: 1.0),
                                curve: Curves.elasticOut,
                                builder: (context, scale, child) {
                                  return Transform.scale(
                                    scale: esElNuevoSello ? (0.4 + scale * 0.8) : 1.0,
                                    child: const Text("❌", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                                  );
                                },
                              )
                            : Text("${index + 1}", style: TextStyle(color: Colors.grey.shade400, fontSize: 11)),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),
                const Text("🎉 ¡Punto reclamado con éxito!", style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0D47A1),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 45),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    if (!_esPremium) ServicioAnuncios.mostrarAnuncioIntersticial(() {});
                  },
                  child: const Text("ACEPTAR", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _mostrarModalIngresarLink() {
    TextEditingController linkCtrl = TextEditingController();
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
        contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
        title: const Row(
          children: [
            Icon(Icons.qr_code_scanner_rounded, color: Colors.blueAccent, size: 26),
            SizedBox(width: 10),
            Text("Reclamar Punto", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                "Elige cómo deseas reclamar tu punto de fidelidad:",
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 14),

              // 📷 BOTÓN 1: ESCANEAR CON CÁMARA EN TIEMPO REAL
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0D47A1),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  elevation: 2,
                ),
                icon: const Icon(Icons.camera_alt_rounded, size: 20),
                label: const Text(
                  "ESCANEAR CÓDIGO QR CON CÁMARA",
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: 0.5),
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  _abrirEscanerCamara();
                },
              ),

              const SizedBox(height: 14),

              Row(
                children: [
                  Expanded(child: Divider(color: isOscuro ? Colors.white24 : Colors.grey.shade300)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text("O PEGA EL CÓDIGO", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey.shade500)),
                  ),
                  Expanded(child: Divider(color: isOscuro ? Colors.white24 : Colors.grey.shade300)),
                ],
              ),

              const SizedBox(height: 12),

              // ✏️ OPCIÓN 2: CAMPO DE TEXTO MANUAL
              TextField(
                controller: linkCtrl,
                style: TextStyle(color: isOscuro ? Colors.white : Colors.black87, fontSize: 13),
                decoration: InputDecoration(
                  hintText: "Pega el enlace o código aquí...",
                  hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  prefixIcon: const Icon(Icons.link_rounded, size: 20),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx), 
            child: const Text("CANCELAR", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold))
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green, 
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              String texto = linkCtrl.text.trim();
              if (texto.isEmpty) return;
              Navigator.pop(ctx);

              String token = texto;
              if (texto.contains("token=")) {
                token = texto.split("token=").last.split("&").first;
              }
              _ejecutarReclamoDirecto(token);
            },
            child: const Text("RECLAMAR", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // 📷 ABRE LA CÁMARA EN TIEMPO REAL CON OPCIÓN DE LEER QR DESDE LA GALERÍA
  void _abrirEscanerCamara() {
    bool detectado = false;
    final MobileScannerController scannerController = MobileScannerController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),
      builder: (ctx) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(25)),
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.8,
          child: Stack(
            children: [
              // 🎥 VISOR DE LA CÁMARA
              MobileScanner(
                controller: scannerController,
                onDetect: (capture) {
                  if (detectado) return;
                  final List<Barcode> barcodes = capture.barcodes;
                  for (final barcode in barcodes) {
                    final String? rawValue = barcode.rawValue;
                    if (rawValue != null && rawValue.isNotEmpty) {
                      detectado = true;
                      Navigator.pop(ctx);

                      String token = rawValue.trim();
                      if (rawValue.contains("token=")) {
                        token = rawValue.split("token=").last.split("&").first;
                      }
                      _ejecutarReclamoDirecto(token);
                      break;
                    }
                  }
                },
              ),

              // 🔝 BOTONES SUPERIORES (LINTERNA Y CERRAR)
              Positioned(
                top: 20,
                right: 20,
                child: Row(
                  children: [
                    // Botón Linterna
                    CircleAvatar(
                      backgroundColor: Colors.black54,
                      child: IconButton(
                        icon: const Icon(Icons.flash_on_rounded, color: Colors.white, size: 20),
                        onPressed: () => scannerController.toggleTorch(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Botón Cerrar (X)
                    CircleAvatar(
                      backgroundColor: Colors.black54,
                      child: IconButton(
                        icon: const Icon(Icons.close_rounded, color: Colors.white, size: 22),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ),
                  ],
                ),
              ),

              // 🖼️ BOTÓN FLOTANTE: CARGAR QR DESDE IMAGEN (GALERÍA)
              Positioned(
                bottom: 85,
                left: 20,
                right: 20,
                child: Center(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white.withOpacity(0.92),
                      foregroundColor: Colors.black87,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                      elevation: 4,
                    ),
                    icon: const Icon(Icons.photo_library_rounded, color: Color(0xFF0D47A1), size: 20),
                    label: const Text(
                      "Cargar QR desde imagen",
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    onPressed: () async {
                      try {
                        final XFile? image = await ImagePicker().pickImage(
                          source: ImageSource.gallery,
                        );

                        if (image != null) {
                          // Analizar la foto seleccionada en busca de códigos QR
                          final BarcodeCapture? capture = await scannerController.analyzeImage(image.path);

                          if (capture != null && capture.barcodes.isNotEmpty) {
                            final String? rawValue = capture.barcodes.first.rawValue;
                            if (rawValue != null && rawValue.isNotEmpty) {
                              detectado = true;
                              if (ctx.mounted) Navigator.pop(ctx);

                              String token = rawValue.trim();
                              if (rawValue.contains("token=")) {
                                token = rawValue.split("token=").last.split("&").first;
                              }
                              _ejecutarReclamoDirecto(token);
                              return;
                            }
                          }

                          // Si la foto no tiene QR
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text("⚠️ No se detectó ningún código QR en la imagen seleccionada."),
                                backgroundColor: Colors.orange,
                              ),
                            );
                          }
                        }
                      } catch (e) {
                        debugPrint("Error leyendo imagen de la galería: $e");
                      }
                    },
                  ),
                ),
              ),

              // ℹ️ LEYENDA INFERIOR
              Positioned(
                bottom: 25,
                left: 20,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.qr_code_scanner_rounded, color: Colors.cyanAccent, size: 20),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          "Apunta la cámara o selecciona una foto de tu galería",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _mostrarModalCrearTarjeta({Map<String, dynamic>? tarjetaAEditar}) {
    if (!_esPremium) {
      _mostrarAlertaPremium();
      return;
    }

    final metaCtrl = TextEditingController(text: tarjetaAEditar != null ? tarjetaAEditar['meta_compras'].toString() : "10");
    final premioCtrl = TextEditingController(text: tarjetaAEditar != null ? (tarjetaAEditar['premio_descripcion'] ?? tarjetaAEditar['titulo']) : "");
    final montoCtrl = TextEditingController(text: tarjetaAEditar != null && tarjetaAEditar['monto_minimo'] != null && (tarjetaAEditar['monto_minimo'] as num) > 0 ? (tarjetaAEditar['monto_minimo'] as num).toInt().toString() : "");
    String fotoTarjetaPath = tarjetaAEditar != null ? (tarjetaAEditar['foto_path']?.toString() ?? tarjetaAEditar['fotoPath']?.toString() ?? '') : '';

    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setModalState) {
          String premioText = premioCtrl.text.trim().isEmpty ? "tu premio" : premioCtrl.text.trim();
          int metaVal = int.tryParse(metaCtrl.text.trim()) ?? 10;
          double montoVal = double.tryParse(montoCtrl.text.trim()) ?? 0;
          String previewMonto = montoVal > 0 ? " de \$${montoVal.toInt()} o más" : "";

          bool esPersonalizado = !['5', '8', '10', '12', '15'].contains(metaCtrl.text.trim());

          return Dialog(
            backgroundColor: Theme.of(context).cardColor,
            insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 🎨 CABECERA AZUL
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Color(0xFF0D47A1), Color(0xFF1976D2)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), shape: BoxShape.circle),
                            child: const Icon(Icons.card_giftcard_rounded, color: Colors.white, size: 26),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  tarjetaAEditar == null ? "Nueva Tarjeta Fidelidad" : "Editar Tarjeta Fidelidad",
                                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: Colors.white),
                                ),
                                const SizedBox(height: 2),
                                const Text("Premia la lealtad de tus clientes", style: TextStyle(color: Colors.white70, fontSize: 11)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 🖼️ SELECCIÓN DE IMAGEN DE REFERENCIA / PREMIO
                          Center(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(20),
                              onTap: () {
                                showModalBottomSheet(
                                  context: context,
                                  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                                  builder: (c) => SafeArea(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        ListTile(
                                          leading: const Icon(Icons.inventory_2_rounded, color: Color(0xFF0D47A1)),
                                          title: const Text("Elegir de Producto Existente del Inventario"),
                                          onTap: () {
                                            Navigator.pop(c);
                                            _mostrarDialogoSeleccionarProductoParaTarjeta((p) {
                                              setModalState(() {
                                                premioCtrl.text = p['nombre'].toString();
                                                fotoTarjetaPath = p['foto_path']?.toString() ?? '';
                                              });
                                            });
                                          },
                                        ),
                                        ListTile(
                                          leading: const Icon(Icons.photo_library, color: Colors.orange),
                                          title: const Text("Elegir de Galería"),
                                          onTap: () async {
                                            Navigator.pop(c);
                                            final XFile? image = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 800, imageQuality: 80);
                                            if (image != null) setModalState(() => fotoTarjetaPath = image.path);
                                          },
                                        ),
                                        ListTile(
                                          leading: const Icon(Icons.camera_alt, color: Colors.green),
                                          title: const Text("Tomar Foto"),
                                          onTap: () async {
                                            Navigator.pop(c);
                                            final XFile? image = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 800, imageQuality: 80);
                                            if (image != null) setModalState(() => fotoTarjetaPath = image.path);
                                          },
                                        ),
                                        if (fotoTarjetaPath.isNotEmpty)
                                          ListTile(
                                            leading: const Icon(Icons.delete_forever, color: Colors.red),
                                            title: const Text("Eliminar Imagen", style: TextStyle(color: Colors.red)),
                                            onTap: () {
                                              setModalState(() => fotoTarjetaPath = '');
                                              Navigator.pop(c);
                                            },
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                              child: Container(
                                width: 90,
                                height: 90,
                                decoration: BoxDecoration(
                                  color: isOscuro ? Colors.white10 : Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: isOscuro ? Colors.cyanAccent.withOpacity(0.4) : const Color(0xFF0D47A1), width: 1.5),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: fotoTarjetaPath.isEmpty
                                    ? Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.add_a_photo_rounded, size: 28, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)),
                                          const SizedBox(height: 4),
                                          Text("Foto Premio", style: TextStyle(fontSize: 10, color: isOscuro ? Colors.white70 : Colors.black54, fontWeight: FontWeight.bold)),
                                        ],
                                      )
                                    : Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          _construirLogoNegocio(fotoTarjetaPath),
                                          Positioned(
                                            right: 4, bottom: 4,
                                            child: Container(
                                              padding: const EdgeInsets.all(4),
                                              decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                                              child: const Icon(Icons.edit, size: 12, color: Colors.white),
                                            ),
                                          )
                                        ],
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),

                          // 1. RECOMPENSA
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text("RECOMPENSA O PREMIO", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1), letterSpacing: 0.5)),
                              InkWell(
                                onTap: () {
                                  _mostrarDialogoSeleccionarProductoParaTarjeta((p) {
                                    setModalState(() {
                                      premioCtrl.text = p['nombre'].toString();
                                      fotoTarjetaPath = p['foto_path']?.toString() ?? '';
                                    });
                                  });
                                },
                                child: Text("🛍️ Elegir de inventario", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1))),
                              )
                            ],
                          ),
                          const SizedBox(height: 6),
                          TextField(
                            controller: premioCtrl,
                            onChanged: (v) => setModalState(() {}),
                            style: TextStyle(color: isOscuro ? Colors.white : Colors.black87, fontWeight: FontWeight.bold, fontSize: 14),
                            decoration: InputDecoration(
                              hintText: "Ej: Audífonos Bluetooth",
                              hintStyle: TextStyle(color: Colors.grey.shade400, fontWeight: FontWeight.normal),
                              prefixIcon: Icon(Icons.card_giftcard, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)),
                              filled: true,
                              fillColor: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade100,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1), width: 2)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                            ),
                          ),

                          const SizedBox(height: 16),

                          // 2. META DE COMPRAS
                          Text("META DE COMPRAS (SELLOS)", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1), letterSpacing: 0.5)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: metaCtrl,
                            keyboardType: TextInputType.number,
                            onChanged: (v) => setModalState(() {}),
                            style: TextStyle(color: isOscuro ? Colors.white : Colors.black87, fontWeight: FontWeight.bold, fontSize: 14),
                            decoration: InputDecoration(
                              hintText: "Escribe la cantidad de sellos...",
                              hintStyle: TextStyle(color: Colors.grey.shade400, fontWeight: FontWeight.normal),
                              prefixIcon: Icon(Icons.pin_outlined, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)),
                              filled: true,
                              fillColor: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade100,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1), width: 2)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                            ),
                          ),
                          const SizedBox(height: 8),

                          // CHIPS RÁPIDOS + BOTÓN PERSONALIZADO
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              ...[5, 8, 10, 12, 15].map((s) {
                                bool isSel = metaCtrl.text.trim() == s.toString();
                                return ChoiceChip(
                                  label: Text("$s sellos", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isSel ? Colors.white : (isOscuro ? Colors.white70 : Colors.black87))),
                                  selected: isSel,
                                  selectedColor: const Color(0xFF0D47A1),
                                  backgroundColor: isOscuro ? Colors.white10 : Colors.grey.shade200,
                                  onSelected: (_) {
                                    setModalState(() {
                                      metaCtrl.text = s.toString();
                                    });
                                  },
                                );
                              }),
                              ChoiceChip(
                                label: Text("✏️ Personalizado", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: esPersonalizado ? Colors.white : (isOscuro ? Colors.white70 : Colors.black87))),
                                selected: esPersonalizado,
                                selectedColor: Colors.orange.shade800,
                                backgroundColor: isOscuro ? Colors.white10 : Colors.grey.shade200,
                                onSelected: (_) {
                                  setModalState(() {
                                    if (!esPersonalizado) metaCtrl.text = "";
                                  });
                                },
                              ),
                            ],
                          ),

                          const SizedBox(height: 16),

                          // 3. MONTO MÍNIMO POR COMPRA (Texto plano corto)
                          Text("MONTO MÍNIMO POR COMPRA (OPCIONAL)", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1), letterSpacing: 0.5)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: montoCtrl,
                            keyboardType: TextInputType.number,
                            onChanged: (v) => setModalState(() {}),
                            style: TextStyle(color: isOscuro ? Colors.white : Colors.black87, fontWeight: FontWeight.bold, fontSize: 14),
                            decoration: InputDecoration(
                              hintText: "Ej: 20000",
                              hintStyle: TextStyle(color: Colors.grey.shade400, fontWeight: FontWeight.normal),
                              prefixText: "\$ ",
                              prefixStyle: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: isOscuro ? Colors.white : Colors.black87),
                              prefixIcon: Icon(Icons.monetization_on_outlined, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)),
                              filled: true,
                              fillColor: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade100,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1), width: 2)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                            ),
                          ),

                          const SizedBox(height: 18),

                          // VISTA PREVIA EN TIEMPO REAL
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isOscuro ? Colors.cyanAccent.withOpacity(0.1) : Colors.blue.shade50,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: isOscuro ? Colors.cyanAccent.withOpacity(0.3) : Colors.blue.shade200),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.remove_red_eye_rounded, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1), size: 20),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text("Vista previa para el cliente:", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
                                      const SizedBox(height: 2),
                                      Text(
                                        "\"Por $metaVal compras$previewMonto obtienes $premioText\"",
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w900,
                                          color: isOscuro ? Colors.white : const Color(0xFF0D47A1),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 20),

                          // BOTONES DE ACCIÓN
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                    side: BorderSide(color: isOscuro ? Colors.white24 : Colors.grey.shade400),
                                  ),
                                  onPressed: () => Navigator.pop(ctx),
                                  child: Text("CANCELAR", style: TextStyle(color: isOscuro ? Colors.white70 : Colors.grey.shade700, fontWeight: FontWeight.bold)),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                flex: 2,
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: isOscuro ? Colors.cyanAccent.shade700 : const Color(0xFF0D47A1),
                                    foregroundColor: isOscuro ? Colors.black : Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                    elevation: 3,
                                  ),
                                  icon: const Icon(Icons.check_circle_rounded, size: 18),
                                  label: const Text("GUARDAR TARJETA", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 0.5)),
                                  onPressed: () async {
                                    String premio = premioCtrl.text.trim();
                                    int meta = int.tryParse(metaCtrl.text.trim()) ?? 0;
                                    double montoMin = double.tryParse(montoCtrl.text.trim()) ?? 0.0;

                                    if (premio.isEmpty || meta <= 0) {
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("⚠️ Ingresa la recompensa y una meta válida.")));
                                      return;
                                    }

                                    Navigator.pop(ctx);

                                    // ⚡ 1. ACTUALIZAR BASE DE DATOS LOCAL
                                    final db = await DBHelper.instance.database;
                                    Map<String, dynamic> tarjetaMap = {
                                      'titulo': premio,
                                      'meta_compras': meta,
                                      'premio_descripcion': premio,
                                      'monto_minimo': montoMin,
                                      'foto_path': fotoTarjetaPath,
                                      'activa': tarjetaAEditar != null ? tarjetaAEditar['activa'] : 1,
                                      'ultima_modificacion': DateTime.now().toIso8601String(),
                                    };

                                    int idTarjetaInsertada;
                                    int metaAntigua = tarjetaAEditar != null ? ((tarjetaAEditar['meta_compras'] ?? 10) as num).toInt() : meta;

                                    if (tarjetaAEditar == null) {
                                      idTarjetaInsertada = await db.insert('tarjetas_fidelidad', tarjetaMap);
                                      await db.delete('puntos_clientes', where: 'tarjeta_id = ?', whereArgs: [idTarjetaInsertada]);
                                    } else {
                                      idTarjetaInsertada = tarjetaAEditar['id'];
                                      await db.update('tarjetas_fidelidad', tarjetaMap, where: 'id = ?', whereArgs: [idTarjetaInsertada]);
                                    }

                                    // ⚡ 2. ACTUALIZAR DOCUMENTO DE VENDEDOR EN LA NUBE PARA QUE NO SOBRESCRIBA LA META
                                    final user = FirebaseAuth.instance.currentUser;
                                    if (user != null && await ServicioNube.tieneInternet()) {
                                      try {
                                        await FirebaseFirestore.instance
                                            .collection('usuarios')
                                            .doc(user.uid)
                                            .collection('mis_tarjetas_creadas')
                                            .doc(idTarjetaInsertada.toString())
                                            .set({
                                          'tarjetaId': idTarjetaInsertada.toString(),
                                          'titulo': premio,
                                          'metaCompras': meta,
                                          'premioDesc': premio,
                                          'montoMinimo': montoMin,
                                          'fotoPath': fotoTarjetaPath,
                                          'logoPath': _logoPath,
                                          'activa': tarjetaAEditar != null ? tarjetaAEditar['activa'] : 1,
                                          'ultimaModificacion': FieldValue.serverTimestamp(),
                                        }, SetOptions(merge: true));
                                      } catch (e) {
                                        debugPrint("Error actualizando tarjeta vendedor en nube: $e");
                                      }
                                    }

                                    // ⚡ 3. ACTUALIZAR PANTALLA LOCAL DE INMEDIATO (AMBAS SECCIONES MOSTRARÁN LA NUEVA META)
                                    _cargarDatosBD();

                                    // ⚡ 4. TAREAS DE PROPAGACIÓN MASIVA A CLIENTES Y FOTO EN SEGUNDO PLANO
                                    Future.microtask(() async {
                                      if (tarjetaAEditar != null && metaAntigua != meta) {
                                        await _ajustarPuntosClientesPorNuevaMeta(
                                          tarjetaId: idTarjetaInsertada,
                                          metaAntigua: metaAntigua,
                                          nuevaMeta: meta,
                                          tituloTarjeta: premio,
                                          premioDesc: premio,
                                        );
                                      }

                                      String fotoNubeUrl = fotoTarjetaPath;
                                      if (_esPremium && fotoTarjetaPath.isNotEmpty && !fotoTarjetaPath.startsWith('http')) {
                                        String urlSubida = await ServicioNube.subirImagenACloudinary(fotoTarjetaPath);
                                        if (urlSubida.isNotEmpty) {
                                          fotoNubeUrl = urlSubida;
                                          await db.update('tarjetas_fidelidad', {'foto_path': fotoNubeUrl}, where: 'id = ?', whereArgs: [idTarjetaInsertada]);
                                        }
                                      }

                                      if (user != null && await ServicioNube.tieneInternet()) {
                                        try {
                                          final clientesSnap = await FirebaseFirestore.instance
                                              .collection('usuarios')
                                              .doc(user.uid)
                                              .collection('mis_tarjetas_creadas')
                                              .doc(idTarjetaInsertada.toString())
                                              .collection('clientes')
                                              .get();

                                          WriteBatch batchPropagacion = FirebaseFirestore.instance.batch();

                                          for (var cDoc in clientesSnap.docs) {
                                            var cData = cDoc.data();
                                            String cUid = cData['clientUid']?.toString() ?? cDoc.id;
                                            String cLocId = cData['clienteLocalId']?.toString() ?? cDoc.id;
                                            String targetUid = cUid.isNotEmpty ? cUid : user.uid;
                                            String docTarget = (targetUid == user.uid && cLocId.isNotEmpty)
                                                ? "${user.uid}_${idTarjetaInsertada}_$cLocId"
                                                : "${user.uid}_$idTarjetaInsertada";

                                            DocumentReference docRefCliente = FirebaseFirestore.instance
                                                .collection('usuarios')
                                                .doc(targetUid)
                                                .collection('tarjetas_acumuladas')
                                                .doc(docTarget);

                                            batchPropagacion.set(docRefCliente, {
                                              'tarjetaTitulo': premio,
                                              'premioDesc': premio,
                                              'metaCompras': meta,
                                              'montoMinimo': montoMin,
                                              'logoPath': _logoPath,
                                              'fotoPath': fotoNubeUrl,
                                              'ultimaModificacion': FieldValue.serverTimestamp(),
                                            }, SetOptions(merge: true));
                                          }

                                          await batchPropagacion.commit();
                                        } catch (e) {
                                          debugPrint("Error propagando cambios a clientes: $e");
                                        }
                                        await ServicioNube.respaldarDatosPrivadosRTDB();
                                      }
                                    });
                                  },
                                ),
                              ),
                            ],
                          )
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
      ),
    );
  }

  Future<void> _mostrarListadoClientesParaPuntos(Map<String, dynamic> tarjetaData) async {
    final db = await DBHelper.instance.database;
    final user = FirebaseAuth.instance.currentUser;
    String tarjetaIdStr = tarjetaData['id'].toString();

    // 1. Obtener clientes de Firestore
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docsCloud = [];
    bool cloudDisponible = false;

    if (user != null && await ServicioNube.tieneInternet()) {
      try {
        final cloudSnap = await FirebaseFirestore.instance
            .collection('usuarios')
            .doc(user.uid)
            .collection('mis_tarjetas_creadas')
            .doc(tarjetaIdStr)
            .collection('clientes')
            .get();
        docsCloud = cloudSnap.docs;
        cloudDisponible = true;
      } catch (e) {
        debugPrint("Error leyendo clientes cloud: $e");
      }
    }

    Map<String, int> puntosCloudPorLocalId = {};
    for (var doc in docsCloud) {
      final data = doc.data();
      String locId = data['clienteLocalId']?.toString() ?? doc.id;
      int ptsCloud = ((data['puntosActuales'] ?? 0) as num).toInt();
      if (locId.isNotEmpty) {
        puntosCloudPorLocalId[locId] = ptsCloud;
      }
    }

    if (cloudDisponible) {
      final puntosLocalEnBD = await db.query('puntos_clientes', where: 'tarjeta_id = ?', whereArgs: [tarjetaData['id']]);
      Batch batchLimpieza = db.batch();
      bool huboLimpieza = false;

      for (var p in puntosLocalEnBD) {
        String cLocalId = p['cliente_id'].toString();
        if (!puntosCloudPorLocalId.containsKey(cLocalId)) {
          batchLimpieza.delete('puntos_clientes', where: 'cliente_id = ? AND tarjeta_id = ?', whereArgs: [p['cliente_id'], tarjetaData['id']]);
          huboLimpieza = true;
        }
      }

      if (huboLimpieza) {
        await batchLimpieza.commit(noResult: true);
      }
    }

    final clientesDB = await db.query('clientes');
    final puntosLocal = await db.query('puntos_clientes', where: 'tarjeta_id = ?', whereArgs: [tarjetaData['id']]);

    // IDs de clientes activos en la base de datos
    Set<int> idsClientesActivos = clientesDB.map((c) => c['id'] as int).toSet();

    Map<int, int> mapaPuntosLocal = {};
    for (var p in puntosLocal) {
      int cId = p['cliente_id'] as int;
      if (idsClientesActivos.contains(cId)) {
        mapaPuntosLocal[cId] = p['puntos_actuales'] as int;
      }
    }

    Map<String, Map<String, dynamic>> clientesUnificados = {};

    for (var c in clientesDB) {
      String idKey = c['id'].toString();
      String nom = (c['nombre_completo'] ?? '').toString().trim();
      int pts = mapaPuntosLocal[c['id'] as int] ?? 0;

      if (nom.isNotEmpty) {
        clientesUnificados[idKey] = {
          'id': c['id'],
          'clienteLocalId': c['id'].toString(),
          'nombre_completo': nom,
          'telefono': c['telefono'] ?? '',
          'puntos': pts,
        };
      }
    }

    // Unir con Firestore sin alterar el nombre limpio del cliente
    for (var doc in docsCloud) {
      final data = doc.data();
      String cUid = doc.id;
      String locId = data['clienteLocalId']?.toString() ?? cUid;
      String email = data['clienteEmail'] ?? '';
      int ptsCloud = ((data['puntosActuales'] ?? 0) as num).toInt();

      if (locId.isNotEmpty && clientesUnificados.containsKey(locId)) {
        var local = clientesUnificados[locId]!;
        local['puntos'] = ptsCloud;
        local['clientUid'] = cUid;
        if (email.isNotEmpty) {
          local['email'] = email; // 👈 Mantiene el nombre limpio "Yo" sin pegarle el correo
        }
      } else {
        clientesUnificados[locId] = {
          'id': locId,
          'clientUid': cUid,
          'nombre_completo': data['clienteNombre'] != null && data['clienteNombre'].toString().isNotEmpty 
              ? data['clienteNombre'] 
              : (email.isNotEmpty ? email : 'Cliente App'),
          'telefono': data['clienteTelefono'] ?? '',
          'puntos': ptsCloud,
          'email': email,
        };
      }
    }

    List<Map<String, dynamic>> todosClientes = clientesUnificados.values.toList();
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    if (!mounted) return;

    String queryModal = "";

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          List<Map<String, dynamic>> filtradosModal = todosClientes.where((c) {
            String nom = c['nombre_completo'].toString().toLowerCase();
            return nom.contains(queryModal.toLowerCase());
          }).toList();

          List<Map<String, dynamic>> activos = filtradosModal.where((c) => (c['puntos'] as int) > 0).toList();
          List<Map<String, dynamic>> inactivos = filtradosModal.where((c) => (c['puntos'] as int) == 0).toList();

          activos.sort((a, b) => (b['puntos'] as int).compareTo(a['puntos'] as int));
          inactivos.sort((a, b) => (a['nombre_completo'] as String).compareTo(b['nombre_completo'] as String));

          return DefaultTabController(
            length: 2,
            child: Container(
              height: MediaQuery.of(ctx).size.height * 0.82,
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(25)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 12),
                  Text("Clientes para: ${tarjetaData['titulo']}", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1))),
                  const SizedBox(height: 10),
                  
                  // 🔥 BUSCADOR INTERNO DE CLIENTES
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: TextField(
                      onChanged: (v) => setModalState(() => queryModal = v),
                      decoration: InputDecoration(
                        hintText: "Buscar cliente por nombre o correo...",
                        prefixIcon: const Icon(Icons.search, size: 20),
                        isDense: true,
                        contentPadding: const EdgeInsets.all(10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),

                  TabBar(
                    labelColor: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
                    unselectedLabelColor: Colors.grey,
                    indicatorColor: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
                    tabs: [
                      Tab(text: "Activos (${activos.length})"),
                      Tab(text: "Inactivos (${inactivos.length})"),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildListaClientesSelect(
                          activos, 
                          tarjetaData,
                          onDeleteClient: (c) {
                            setModalState(() {
                              todosClientes.removeWhere((item) => item['id'].toString() == c['id'].toString());
                            });
                          },
                        ),
                        _buildListaClientesSelect(
                          inactivos, 
                          tarjetaData,
                          onDeleteClient: (c) {
                            setModalState(() {
                              todosClientes.removeWhere((item) => item['id'].toString() == c['id'].toString());
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }
      ),
    );
  }

  Widget _buildListaClientesSelect(
    List<Map<String, dynamic>> lista, 
    Map<String, dynamic> tarjetaData, {
    void Function(Map<String, dynamic> cliente)? onDeleteClient,
  }) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    if (lista.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20.0),
          child: Text("No hay clientes en esta sección.", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(15),
      itemCount: lista.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        var c = lista[i];
        String nombreMostrar = c['nombre_completo'] ?? 'Cliente';
        String email = c['email']?.toString() ?? '';
        int pts = (c['puntos'] as num?)?.toInt() ?? 0;
        int meta = ((tarjetaData['meta_compras'] ?? 10) as num).toInt();

        return Card(
          elevation: 0,
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _mostrarModalVerTarjetaCliente(c, tarjetaData),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: isOscuro ? Colors.cyanAccent.withOpacity(0.15) : Colors.blue.shade100,
                    child: Icon(Icons.person_rounded, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1), size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          nombreMostrar, 
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: isOscuro ? Colors.white : Colors.black87)
                        ),
                        const SizedBox(height: 2),
                        Text(
                          email.isNotEmpty ? "✉️ $email" : "Sin correo vinculado",
                          style: TextStyle(fontSize: 10, color: email.isNotEmpty ? Colors.grey.shade600 : Colors.grey.shade400),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          "Puntos: $pts / $meta  •  👉 Toca aquí para ver",
                          style: TextStyle(fontSize: 11, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1), fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 20),
                        tooltip: "Eliminar Tarjeta del Cliente",
                        onPressed: () async {
                          bool confirm = await showDialog(
                            context: context,
                            builder: (dialogCtx) => AlertDialog(
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                              title: const Text("¿Eliminar Tarjeta del Cliente?", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent, fontSize: 16)),
                              content: Text("¿Estás seguro de que deseas eliminar la tarjeta de \"$nombreMostrar\"? También se borrará de la aplicación del cliente."),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(dialogCtx, false), child: const Text("CANCELAR")),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                                  onPressed: () => Navigator.pop(dialogCtx, true),
                                  child: const Text("ELIMINAR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ),
                          ) ?? false;

                          if (!confirm) return;

                          // ⚡ 1. Borrado instantáneo local en la lista del modal (0 ms)
                          onDeleteClient?.call(c);

                          // ⚡ 2. Proceso en segundo plano sin congelar la interfaz ni cerrar la ventana
                          final user = FirebaseAuth.instance.currentUser;
                          if (user != null) {
                            ServicioFidelidad.eliminarTarjetaAcumuladaCliente(
                              vendorUid: user.uid,
                              tarjetaId: tarjetaData['id'].toString(),
                              clienteLocalId: c['id']?.toString(),
                              clientUid: c['clientUid']?.toString(),
                            ).then((_) {
                              if (mounted) _cargarDatosBD();
                            });
                          }
                        },
                      ),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white, elevation: 0, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                        icon: const Icon(Icons.add_circle, size: 14),
                        label: const Text("Dar Punto", style: TextStyle(fontSize: 11)),
                        onPressed: _procesandoPunto ? null : () async {
                          setState(() => _procesandoPunto = true);

                          try {
                            showDialog(
                              context: ctx,
                              barrierDismissible: false,
                              builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.green)),
                            );

                            bool hayInternetReal = false;
                            try {
                              final response = await http
                                  .get(Uri.parse('https://clients3.google.com/generate_204'))
                                  .timeout(const Duration(milliseconds: 1000));
                              hayInternetReal = (response.statusCode == 204 || response.statusCode == 200);
                            } catch (_) {
                              hayInternetReal = false;
                            }

                            if (ctx.mounted) Navigator.pop(ctx);

                            if (!hayInternetReal) {
                              if (ctx.mounted) {
                                showDialog(
                                  context: ctx,
                                  builder: (dialogCtx) => AlertDialog(
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                    title: const Row(
                                      children: [
                                        Icon(Icons.wifi_off_rounded, color: Colors.redAccent, size: 28),
                                        SizedBox(width: 10),
                                        Text("Sin Conexión", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                      ],
                                    ),
                                    content: const Text("Necesitas conexión a internet para generar y otorgar puntos de fidelidad."),
                                    actions: [
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0D47A1), foregroundColor: Colors.white),
                                        onPressed: () => Navigator.pop(dialogCtx),
                                        child: const Text("ENTENDIDO", style: TextStyle(fontWeight: FontWeight.bold)),
                                      ),
                                    ],
                                  ),
                                );
                              }
                              return;
                            }
final user = FirebaseAuth.instance.currentUser;
                            String fotoPremioEnviar = (tarjetaData['foto_path'] ?? tarjetaData['fotoPath'] ?? '').toString();
                            if (!fotoPremioEnviar.startsWith('http')) {
                              fotoPremioEnviar = _logoPath;
                            }

                            String token = await ServicioFidelidad.crearTokenUnicoNube(
                              vendorUid: user?.uid ?? 'anon',
                              tarjetaId: tarjetaData['id'].toString(),
                              clienteLocalId: c['id'],
                              clienteNombre: c['nombre_completo'],
                              nombreNegocio: _nombreNegocio,
                              logoPath: _logoPath,
                              fotoPath: fotoPremioEnviar,
                              tarjetaTitulo: tarjetaData['titulo'] ?? 'Tarjeta Fidelidad',
                              metaCompras: tarjetaData['meta_compras'],
                              premioDesc: tarjetaData['premio_descripcion'] ?? '',
                              montoMinimo: (tarjetaData['monto_minimo'] as num?)?.toDouble(),
                              clienteTelefono: c['telefono']?.toString() ?? '',
                            );

                            if (mounted) {
                              _generarQrOLinkUnico(
                                tokenUnico: token,
                                nombreCliente: c['nombre_completo'] ?? 'Cliente',
                                telefono: c['telefono']?.toString() ?? '',
                                tarjetaTitulo: tarjetaData['titulo'] ?? 'Tarjeta Fidelidad',
                                premioDesc: tarjetaData['premio_descripcion'] ?? '',
                                metaCompras: ((tarjetaData['meta_compras'] ?? 10) as num).toInt(),
                                montoMinimo: (tarjetaData['monto_minimo'] as num?)?.toDouble() ?? 0.0,
                              );
                            }
                          } finally {
                            if (mounted) setState(() => _procesandoPunto = false);
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _mostrarModalVerTarjetaCliente(Map<String, dynamic> cliente, Map<String, dynamic> tarjetaData) {
    int meta = ((tarjetaData['meta_compras'] ?? 10) as num).toInt();
    int pts = ((cliente['puntos'] ?? 0) as num).toInt();
    String nombreCliente = cliente['nombre_completo'] ?? 'Cliente';
    String email = cliente['email']?.toString() ?? '';
    String premio = tarjetaData['premio_descripcion'] ?? tarjetaData['titulo'] ?? 'Recompensa';
    bool metaAlcanzada = pts >= meta;
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
        child: Container(
          width: 440,
          padding: const EdgeInsets.all(22),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Tarjeta de $nombreCliente", textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                if (email.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text("✉️ $email", style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
                const SizedBox(height: 12),
                Builder(
                  builder: (context) {
                    double mMin = ((tarjetaData['monto_minimo'] ?? 0) as num).toDouble();
                    String textoMonto = mMin > 0 ? " de \$${mMin.toInt()} o más" : "";
                    return Text("Por $meta compras$textoMonto obtienes $premio", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)), textAlign: TextAlign.center);
                  }
                ),
                const SizedBox(height: 18),

                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 1.0,
                  ),
                  itemCount: meta,
                  itemBuilder: (context, index) {
                    bool tieneSello = (index + 1) <= pts;

                    return Container(
                      decoration: BoxDecoration(
                        color: tieneSello ? Colors.green.withOpacity(0.15) : (isOscuro ? Colors.white10 : Colors.grey.shade100),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: tieneSello ? Colors.green : Colors.grey.shade300, width: tieneSello ? 2 : 1),
                      ),
                      child: Center(
                        child: tieneSello
                            ? const Text("❌", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))
                            : Text("${index + 1}", style: TextStyle(color: Colors.grey.shade400, fontSize: 11)),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 18),
                Text(
                  metaAlcanzada ? "🎉 ¡Tarjeta Completada!" : "$pts de $meta sellos acumulados",
                  style: TextStyle(color: metaAlcanzada ? Colors.green : (isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)), fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0D47A1),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 42),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("CERRAR", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ❓ MODAL DE PREGUNTAS FRECUENTES Y GUÍA DE FIDELIZACIÓN
  void _mostrarModalAyudaFidelidad() {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    final List<Map<String, String>> preguntas = [
      {
        'q': '🤔 ¿Qué es una Tarjeta de Regalo y para qué sirve?',
        'a': 'Es un sistema digital de recompensas para premiarte o a tus clientes recurrentes. Cada vez que realices o que tus clientes realicen una compra o alcancen la meta establecida, recibirán sellos (puntos) hasta completar la tarjeta y ganar un premio.'
      },
      {
        'q': '📱 ¿Cómo enviar o dar puntos a clientes con iPhone o PC?',
        'a': '¡Es muy sencillo! Tus clientes con iPhone o PC no necesitan instalar ninguna aplicación:\n\n1. Envíales su enlace por WhatsApp (se genera automáticamente al completar un pedido o al presionar "Dar Punto").\n\n2. Reclamo Web Instantáneo: Al abrir el enlace en Safari o Chrome, verán el logo de tu negocio y la foto del premio, y podrán presionar "RECLAMAR MI PUNTO".\n\n3. Tarjeta Guardada: Podrán copiar y guardar el enlace de su tarjeta para revisar sus sellos acumulados cuando quieran desde el navegador de su teléfono.'
      },
      {
        'q': '💳 ¿Cómo crear una nueva Tarjeta de Regalo?',
        'a': '\n\n1.SI ERES PREMIUM Toca el botón "+ Nueva" en la sección de Fidelización. Ingresa el premio a otorgar (ej: Audífonos Gratis), define la cantidad de sellos requeridos (ej: 5 compras) y opcionalmente un monto mínimo por compra. \n\n2. Si no eres PREMIUM debes adquirir la membresia PREMIUM'
      },
      {
        'q': '⚡ ¿Cómo funcionan los Puntos Automáticos?',
        'a': 'Cuando marcas un pedido como "Completado" o "Pagado" desde la pantalla Gestión de Pedidos, si el pedido cumple con el monto mínimo configurado, el sistema le suma automáticamente el punto al cliente (incluso sin internet).'
      },
      {
        'q': '🖐️ ¿Cómo funcionan los Puntos Manuales?',
        'a': 'Toca la tarjeta deseada en la sección "FIDELIZACIÓN (MI NEGOCIO)". Selecciona al cliente y presiona "Dar Punto". Se generará un código QR y un enlace único que el cliente puede escanear para reclamar su sello.'
      },
      {
        'q': '🎁 ¿Cómo funciona el primer punto / Invitación por WhatsApp?',
        'a': 'Si completas una venta a un cliente que aún no tiene su tarjeta vinculada, la app te mostrará una opción para enviarle una invitación directa a su WhatsApp con su primer punto listo para reclamar.'
      },
      {
        'q': '🏆 ¿Cómo reclama el cliente su premio?',
        'a': 'Cuando el cliente llega a la meta (ej: 5/5 sellos), en su app aparecerá el botón verde "RECLAMAR RECOMPENSA", el cual enviará un mensaje directo a tu WhatsApp configurado para entregarle el premio.'
      },
      {
        'q': '😞 ¿Si mi cliente no tiene celular?',
        'a': 'Para tus clientes que no tienen celular puedes: \n\n1. Cuando les completes un pedido y te salga la invitación a reclamar puntos, copiar el link tu mismo y pegalo en el boton de "Ingresar QR", así tu manejaras la tarjeta del cliente desde tu cuenta. \n\n2. Tocas en Dar un punto manualmente, copias el link y pégalo en el boton de "Ingresar QR", así tu manejaras la tarjeta del cliente desde tu cuenta.'
      },
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        height: MediaQuery.of(ctx).size.height * 0.8,
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(25)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.help_outline_rounded, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1), size: 22),
                const SizedBox(width: 8),
                Text(
                  "Preguntas Frecuentes y Guía",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: preguntas.length,
                itemBuilder: (context, i) {
                  var p = preguntas[i];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    color: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade50,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                      side: BorderSide(color: isOscuro ? Colors.white10 : Colors.grey.shade200),
                    ),
                    child: Theme(
                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        title: Text(
                          p['q']!,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: isOscuro ? Colors.white : Colors.black87,
                          ),
                        ),
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            child: Text(
                              p['a']!,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                color: isOscuro ? Colors.white70 : Colors.grey.shade800,
                              ),
                            ),
                          )
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // GENERADOR DE QR / LINK Y ENVÍO POR WHATSAPP
  void _generarQrOLinkUnico({
    required String tokenUnico,
    required String nombreCliente,
    String telefono = '',
    String tarjetaTitulo = 'Tarjeta Fidelidad',
    String premioDesc = '',
    int metaCompras = 10,
    double montoMinimo = 0.0,
  }) {
    String enlaceUnico = "https://boxi-catalogo.web.app/reclamar?token=$tokenUnico";

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text("Punto para $nombreCliente", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Muestra este código QR al cliente o envíale el enlace de uso único por WhatsApp para que lo reclame:", style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 15),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15)),
              child: SizedBox(
                width: 170, height: 170,
                child: QrImageView(data: enlaceUnico, version: QrVersions.auto, gapless: false),
              ),
            ),
            const SizedBox(height: 18),

            // 🟢 BOTÓN ENVIAR POR WHATSAPP
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF25D366),
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 44),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 2,
              ),
              icon: const Icon(Icons.send_rounded, size: 18),
              label: const Text("Enviar por WhatsApp", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              onPressed: () async {
                String textoMonto = "";
                if (montoMinimo > 0) {
                  String mFormateado = montoMinimo == montoMinimo.roundToDouble() 
                      ? montoMinimo.toInt().toString() 
                      : montoMinimo.toStringAsFixed(0);
                  textoMonto = " de *\$$mFormateado* o más";
                }

                String premioTxt = premioDesc.isNotEmpty ? premioDesc : tarjetaTitulo;
                String mensaje = "¡Hola *$nombreCliente*! 🎁 *$_nombreNegocio* te obsequió *1 punto* para tu tarjeta de regalo *$tarjetaTitulo*.\n\nPor *$metaCompras* compras$textoMonto obtienes *$premioTxt*.\n\n*Al completar 5 puntos llevas el premio, reclama tu punto ingresando a este enlace:*\n$enlaceUnico";
                String numClean = telefono.replaceAll(RegExp(r'\D'), '');

                if (numClean.length == 10) numClean = "57$numClean";
                String textEncoded = Uri.encodeComponent(mensaje);

                // Usamos el esquema nativo whatsapp:// para forzar a Android/iOS a preguntar qué app usar (WhatsApp o Business)
                Uri uriApp = numClean.length >= 10
                    ? Uri.parse("whatsapp://send?phone=$numClean&text=$textEncoded")
                    : Uri.parse("whatsapp://send?text=$textEncoded");

                Uri uriWeb = numClean.length >= 10
                    ? Uri.parse("https://wa.me/$numClean?text=$textEncoded")
                    : Uri.parse("https://api.whatsapp.com/send?text=$textEncoded");

                try {
                  if (await canLaunchUrl(uriApp)) {
                    await launchUrl(uriApp, mode: LaunchMode.externalApplication);
                  } else if (await canLaunchUrl(uriWeb)) {
                    await launchUrl(uriWeb, mode: LaunchMode.externalApplication);
                  } else {
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text("No se pudo abrir WhatsApp en este dispositivo."))
                      );
                    }
                  }
                } catch (e) {
                  if (await canLaunchUrl(uriWeb)) {
                    await launchUrl(uriWeb, mode: LaunchMode.externalApplication);
                  }
                }
              },
            ),

            const SizedBox(height: 10),

            // 🔥 BOTÓN PARA COPIAR ENLACE ÚNICO
            Builder(
              builder: (context) {
                final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
                return OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
                    backgroundColor: isOscuro ? Colors.cyanAccent.withOpacity(0.08) : Colors.blue.shade50,
                    minimumSize: const Size(double.infinity, 42),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    side: BorderSide(color: isOscuro ? Colors.cyanAccent.withOpacity(0.6) : const Color(0xFF0D47A1)),
                  ),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text("Copiar Enlace Único", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: enlaceUnico));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Enlace copiado al portapapeles 📋"), duration: Duration(seconds: 2))
                    );
                  },
                );
              }
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx), 
            child: const Text("CERRAR", style: TextStyle(fontWeight: FontWeight.bold))
          )
        ],
      ),
    );
  }

  // 🔥 RECLAMAR RECOMPENSA VÍA WHATSAPP
  Future<void> _reclamarRecompensaWhatsApp(Map<String, dynamic> tarjeta) async {
    String vendorUid = tarjeta['vendorUid'] ?? '';
    String nomNegocio = tarjeta['nombreNegocio'] ?? 'Negocio';
    String premio = tarjeta['premioDesc'] ?? tarjeta['titulo'] ?? 'Recompensa';
    int meta = ((tarjeta['metaCompras'] ?? 10) as num).toInt();

    final user = FirebaseAuth.instance.currentUser;
    String emailCliente = user?.email ?? 'Cliente registrado';

    String telefonoVendedor = "";

    // 1. Consultar el número de WhatsApp del vendedor en Firestore
    if (vendorUid.isNotEmpty) {
      try {
        final vendorDoc = await FirebaseFirestore.instance.collection('usuarios').doc(vendorUid).get();
        if (vendorDoc.exists) {
          telefonoVendedor = vendorDoc.data()?['whatsapp_admin'] ?? vendorDoc.data()?['telefono'] ?? '';
        }
      } catch (e) {
        debugPrint("Error buscando teléfono del vendedor: $e");
      }
    }

    if (telefonoVendedor.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("⚠️ El negocio aún no ha configurado un número de WhatsApp."))
        );
      }
      return;
    }

    String numClean = telefonoVendedor.replaceAll(RegExp(r'\D'), '');
    String mensaje = "¡Hola *$nomNegocio*! 👋 Completé los *$meta puntos* de mi tarjeta de regalo para el premio: *$premio* 🎁.\n\nMi cuenta en la app es: *$emailCliente*\n\n¿Cómo puedo reclamar mi recompensa? ¡Muchas gracias! 🙌";

    if (numClean.length == 10) numClean = "57$numClean";
    String textEncoded = Uri.encodeComponent(mensaje);

    Uri uriApp = Uri.parse("whatsapp://send?phone=$numClean&text=$textEncoded");
    Uri uriWeb = Uri.parse("https://wa.me/$numClean?text=$textEncoded");

    try {
      if (await canLaunchUrl(uriApp)) {
        await launchUrl(uriApp, mode: LaunchMode.externalApplication);
      } else if (await canLaunchUrl(uriWeb)) {
        await launchUrl(uriWeb, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("No se pudo abrir WhatsApp en este dispositivo."))
          );
        }
      }
    } catch (e) {
      if (await canLaunchUrl(uriWeb)) {
        await launchUrl(uriWeb, mode: LaunchMode.externalApplication);
      }
    }
  }

  void _mostrarAlertaPremium() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1B2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Colors.orangeAccent, width: 1)),
        title: const Row(children: [Icon(Icons.stars, color: Colors.orangeAccent), SizedBox(width: 10), Text("Función Exclusiva PRO", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold))]),
        content: const Text("Hazte Premium para acceder al sistema de tarjetas de fidelidad y premiar a tus clientes con puntos y códigos QR.", style: TextStyle(color: Colors.white70, fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR", style: TextStyle(color: Colors.white38))),
          ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.orangeAccent), onPressed: () { Navigator.pop(ctx); Navigator.push(context, MaterialPageRoute(builder: (_) => const PantallaPremium())); }, child: const Text("ACCEDER A PRO", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold))),
        ],
      ),
    );
  }

  void _mostrarDialogoSeleccionarProductoParaTarjeta(Function(Map<String, dynamic>) onSeleccionado) async {
    final db = await DBHelper.instance.database;
    final prods = await db.query('productos', where: 'activo = 1', orderBy: 'nombre ASC');
    if (!mounted) return;

    String busqueda = "";
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStDialog) {
          final filtrados = prods.where((p) => p['nombre'].toString().toLowerCase().contains(busqueda.toLowerCase())).toList();

          return AlertDialog(
            backgroundColor: Theme.of(context).cardColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
            title: const Text("Seleccionar Producto del Inventario", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.of(context).size.height * 0.45,
              child: Column(
                children: [
                  TextField(
                    onChanged: (v) => setStDialog(() => busqueda = v),
                    style: TextStyle(fontSize: 13, color: isOscuro ? Colors.white : Colors.black),
                    decoration: InputDecoration(
                      hintText: "Buscar producto...",
                      prefixIcon: const Icon(Icons.search, size: 20),
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: filtrados.isEmpty
                        ? const Center(child: Text("No se encontraron productos", style: TextStyle(color: Colors.grey, fontSize: 12)))
                        : ListView.separated(
                            itemCount: filtrados.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (context, i) {
                              final p = filtrados[i];
                              String fotoP = p['foto_path']?.toString() ?? "";
                              return ListTile(
                                dense: true,
                                leading: Container(
                                  width: 40, height: 40,
                                  decoration: BoxDecoration(color: isOscuro ? Colors.white10 : Colors.grey.shade200, borderRadius: BorderRadius.circular(8)),
                                  clipBehavior: Clip.antiAlias,
                                  child: _construirLogoNegocio(fotoP),
                                ),
                                title: Text(p['nombre'].toString(), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: isOscuro ? Colors.white : Colors.black87)),
                                subtitle: Text("\$${(p['precio_venta'] as num).toStringAsFixed(0)}", style: const TextStyle(fontSize: 11, color: Colors.green, fontWeight: FontWeight.bold)),
                                onTap: () {
                                  Navigator.pop(ctx);
                                  onSeleccionado(p);
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold))),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    if (_cargandoDatos) {
      return Scaffold(
        backgroundColor: isOscuro ? const Color(0xFF0A0A0F) : const Color(0xFFF2F4F7),
        appBar: AppBar(title: const Text('Premios Fidelidad'), backgroundColor: isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: isOscuro ? const Color(0xFF0A0A0F) : const Color(0xFFF2F4F7),
      appBar: AppBar(
        title: const Text('Premios Fidelidad', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
        backgroundColor: isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline_rounded, color: Colors.white, size: 22),
            tooltip: "Preguntas Frecuentes y Guía",
            onPressed: _mostrarModalAyudaFidelidad,
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // ==========================================
            // SECCIÓN 1: MIS PREMIOS ACUMULADOS (CLIENTE)
            // ==========================================
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.card_giftcard_rounded, size: 18, color: Color(0xFF0D47A1)),
                    const SizedBox(width: 6),
                    Text(
                      "MIS PREMIOS ACUMULADOS",
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: isOscuro ? Colors.white70 : Colors.blueGrey.shade800, letterSpacing: 0.5),
                    ),
                  ],
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isOscuro ? Colors.cyanAccent.withOpacity(0.15) : const Color(0xFF0D47A1).withOpacity(0.1),
                    foregroundColor: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _mostrarModalIngresarLink,
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 14),
                  label: const Text("Ingresar QR", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // BUSCADOR MODERNO DE MIS TARJETAS
            if (_misTarjetasComoCliente.isNotEmpty) ...[
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    if (!isOscuro)
                      BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 4))
                  ],
                  border: Border.all(color: isOscuro ? Colors.white10 : Colors.grey.shade200),
                ),
                child: TextField(
                  onChanged: (v) => setState(() => _busquedaMisTarjetas = v),
                  style: TextStyle(fontSize: 13, color: isOscuro ? Colors.white : Colors.black87),
                  decoration: InputDecoration(
                    hintText: "Buscar por negocio o premio...",
                    hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                    prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF0D47A1), size: 20),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],

            if (_misTarjetasComoCliente.isEmpty)
              Container(
                width: double.infinity, padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor, 
                  borderRadius: BorderRadius.circular(22), 
                  border: Border.all(color: isOscuro ? Colors.white10 : Colors.black12)
                ),
                child: Column(
                  children: [
                    Icon(Icons.style_outlined, size: 44, color: Colors.grey.shade400),
                    const SizedBox(height: 10),
                    const Text("No tienes tarjetas acumuladas", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 4),
                    const Text("Escanea el QR de tus negocios favoritos para acumular puntos.", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 11)),
                  ],
                ),
              )
            else ...[
              Builder(
                builder: (context) {
                  var tarjetasFiltradas = _misTarjetasComoCliente.where((item) {
                    String nom = (item['nombreNegocio'] ?? '').toString().toLowerCase();
                    String premio = (item['premioDesc'] ?? '').toString().toLowerCase();
                    return nom.contains(_busquedaMisTarjetas.toLowerCase()) || premio.contains(_busquedaMisTarjetas.toLowerCase());
                  }).toList();

                  var tarjetasAMostrar = _mostrarTodasMisTarjetas 
                      ? tarjetasFiltradas 
                      : tarjetasFiltradas.take(3).toList();

                  if (tarjetasFiltradas.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(15.0),
                      child: Center(child: Text("No se encontraron coincidencias.", style: TextStyle(color: Colors.grey, fontSize: 12))),
                    );
                  }

                  return Column(
                    children: [
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: tarjetasAMostrar.length,
                        itemBuilder: (ctx, i) {
                          var item = tarjetasAMostrar[i];
                          String logoNegocio = item['logoPath'] ?? _logoPath;
                          String fotoPremio = item['fotoPath'] ?? item['foto_path'] ?? '';
                          String nomNegocio = item['nombreNegocio'] ?? 'Negocio';
                          String premio = item['premioDesc'] ?? 'Premio Especial';
                          int pts = ((item['puntosActuales'] ?? 0) as num).toInt();
                          int meta = ((item['metaCompras'] ?? 10) as num).toInt();
                          bool metaAlcanzada = pts >= meta;
                          double porcentaje = (pts / meta).clamp(0.0, 1.0);

                          return Card(
                            color: Theme.of(context).cardColor,
                            margin: const EdgeInsets.only(bottom: 12),
                            elevation: isOscuro ? 0 : 2,
                            shadowColor: Colors.black12,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                              side: BorderSide(
                                color: metaAlcanzada 
                                    ? const Color(0xFF25D366) 
                                    : (isOscuro ? Colors.white10 : Colors.grey.shade200),
                                width: metaAlcanzada ? 2 : 1,
                              ),
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(18),
                              onTap: () => _mostrarAnimacionEstampadoX(item, pts),
                              child: Padding(
                                padding: const EdgeInsets.all(12.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // 1. FILA SUPERIOR: LOGO, NOMBRE DEL NEGOCIO, SELLOS Y TRES PUNTOS
                                    Row(
                                      children: [
                                        Container(
                                          width: 38,
                                          height: 38,
                                          decoration: BoxDecoration(
                                            color: isOscuro ? Colors.white10 : Colors.grey.shade200,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: metaAlcanzada 
                                                  ? const Color(0xFF25D366) 
                                                  : (isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)),
                                              width: 1.5,
                                            ),
                                          ),
                                          clipBehavior: Clip.antiAlias,
                                          child: _construirLogoNegocio(logoNegocio),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                nomNegocio,
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w900,
                                                  fontSize: 14,
                                                  color: isOscuro ? Colors.white : Colors.black87,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              Text(
                                                metaAlcanzada ? "¡COMPLETADO! 🎉" : "$pts de $meta sellos acumulados",
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                  color: metaAlcanzada 
                                                      ? const Color(0xFF25D366) 
                                                      : (isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        PopupMenuButton<String>(
                                          icon: const Icon(Icons.more_vert, size: 20, color: Colors.grey),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          onSelected: (val) async {
                                            if (val == 'delete') {
                                              bool confirm = await showDialog(
                                                context: context,
                                                builder: (ctx) => AlertDialog(
                                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                                  title: const Text("¿Eliminar Tarjeta?", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent, fontSize: 16)),
                                                  content: Text("¿Estás seguro de que deseas eliminar la tarjeta de \"$nomNegocio\"?"),
                                                  actions: [
                                                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("CANCELAR")),
                                                    ElevatedButton(
                                                      style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                                                      onPressed: () => Navigator.pop(ctx, true),
                                                      child: const Text("ELIMINAR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                                    ),
                                                  ],
                                                ),
                                              ) ?? false;

                                              if (!confirm) return;

                                              setState(() {
                                                _misTarjetasComoCliente.removeWhere((x) => 
                                                  (x['docId'] != null && x['docId'] == item['docId']) ||
                                                  (x['vendorUid'] == item['vendorUid'] && x['tarjetaId'] == item['tarjetaId'])
                                                );
                                              });

                                              ServicioFidelidad.eliminarTarjetaAcumuladaCliente(
                                                vendorUid: item['vendorUid'] ?? '',
                                                tarjetaId: item['tarjetaId'] ?? 'general',
                                                docId: item['docId'],
                                                clienteLocalId: item['clienteLocalId']?.toString(),
                                              ).then((_) {
                                                if (mounted) _cargarDatosBD();
                                              });
                                            }
                                          },
                                          itemBuilder: (ctx) => [
                                            const PopupMenuItem(
                                              value: 'delete',
                                              child: Row(children: [Icon(Icons.delete_outline, size: 16, color: Colors.red), SizedBox(width: 8), Text("Eliminar Tarjeta", style: TextStyle(color: Colors.red, fontSize: 13))]),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),

                                    const SizedBox(height: 10),

                                    // 2. CAJA DE RECOMPENSA CON FOTO Y CONDICIÓN
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: isOscuro ? Colors.cyanAccent.withOpacity(0.08) : Colors.blue.shade50.withOpacity(0.7),
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(color: isOscuro ? Colors.cyanAccent.withOpacity(0.2) : Colors.blue.shade100),
                                      ),
                                      child: Row(
                                        children: [
                                          if (fotoPremio.isNotEmpty) ...[
                                            Container(
                                              width: 44,
                                              height: 44,
                                              decoration: BoxDecoration(
                                                color: isOscuro ? Colors.white10 : Colors.grey.shade200,
                                                borderRadius: BorderRadius.circular(10),
                                              ),
                                              clipBehavior: Clip.antiAlias,
                                              child: _construirLogoNegocio(fotoPremio),
                                            ),
                                            const SizedBox(width: 10),
                                          ],
                                          Expanded(
                                            child: Builder(
                                              builder: (context) {
                                                double mMin = ((item['montoMinimo'] ?? 0) as num).toDouble();
                                                String textoMonto = mMin > 0 ? " de \$${mMin.toInt()} o más" : "";
                                                return Text(
                                                  "Por $meta compras$textoMonto obtienes $premio",
                                                  style: TextStyle(
                                                    fontSize: 11.5,
                                                    fontWeight: FontWeight.bold,
                                                    color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
                                                    height: 1.25,
                                                  ),
                                                );
                                              }
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),

                                    const SizedBox(height: 10),

                                    // 3. BARRA DE PROGRESO Y PORCENTAJE ABAJO
                                    Column(
                                      children: [
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: LinearProgressIndicator(
                                            value: porcentaje,
                                            minHeight: 6,
                                            backgroundColor: isOscuro ? Colors.white10 : Colors.grey.shade200,
                                            valueColor: AlwaysStoppedAnimation<Color>(
                                              metaAlcanzada ? const Color(0xFF25D366) : (isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              "Progreso de Sellos",
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color: isOscuro ? Colors.white38 : Colors.grey.shade500,
                                              ),
                                            ),
                                            Text(
                                              "${(porcentaje * 100).toInt()}%",
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w900,
                                                color: metaAlcanzada ? const Color(0xFF25D366) : (isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),

                                    if (metaAlcanzada) ...[
                                      const SizedBox(height: 10),
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFF25D366),
                                          foregroundColor: Colors.white,
                                          minimumSize: const Size(double.infinity, 38),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                          elevation: 2,
                                        ),
                                        onPressed: () => _reclamarRecompensaWhatsApp(item),
                                        icon: const Icon(Icons.card_giftcard_rounded, size: 18),
                                        label: const Text(
                                          "🎁 ¡RECLAMAR RECOMPENSA!", 
                                          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 0.5)
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),

                      if (tarjetasFiltradas.length > 3)
                        TextButton.icon(
                          onPressed: () {
                            setState(() {
                              _mostrarTodasMisTarjetas = !_mostrarTodasMisTarjetas;
                            });
                          },
                          icon: Icon(_mostrarTodasMisTarjetas ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down),
                          label: Text(
                            _mostrarTodasMisTarjetas 
                                ? "Ver menos" 
                                : "Ver más (${tarjetasFiltradas.length - 3} restantes)",
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                          ),
                        ),
                    ],
                  );
                }
              ),
            ],

            const SizedBox(height: 28),

            // ==========================================
            // SECCIÓN 2: SISTEMA DE FIDELIZACIÓN (MI NEGOCIO)
            // ==========================================
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      const Icon(Icons.storefront_rounded, size: 18, color: Color(0xFF0D47A1)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          "FIDELIZACIÓN (MI NEGOCIO)",
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: isOscuro ? Colors.white70 : Colors.blueGrey.shade800, letterSpacing: 0.5),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0D47A1),
                    foregroundColor: Colors.white,
                    elevation: 2,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () => _mostrarModalCrearTarjeta(),
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text("Nueva", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (_misTarjetasComoVendedor.isEmpty)
              Container(
                width: double.infinity, padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor, 
                  borderRadius: BorderRadius.circular(22), 
                  border: Border.all(color: isOscuro ? Colors.white10 : Colors.black12)
                ),
                child: Column(
                  children: [
                    Icon(Icons.card_giftcard_outlined, size: 44, color: Colors.grey.shade400),
                    const SizedBox(height: 10),
                    const Text("No has creado tarjetas para tus clientes", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 15),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0D47A1), foregroundColor: Colors.white),
                      onPressed: () => _mostrarModalCrearTarjeta(),
                      child: const Text("Crear Primera Tarjeta"),
                    ),
                  ],
                ),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _misTarjetasComoVendedor.length,
                itemBuilder: (ctx, i) {
                  var t = _misTarjetasComoVendedor[i];
                  bool esActiva = t['activa'] == 1;

                  return Card(
                    color: Theme.of(context).cardColor,
                    margin: const EdgeInsets.only(bottom: 14),
                    elevation: isOscuro ? 0 : 3,
                    shadowColor: Colors.black12,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                      side: BorderSide(
                        color: esActiva
                            ? (isOscuro ? Colors.cyanAccent.withOpacity(0.3) : const Color(0xFF0D47A1).withOpacity(0.2))
                            : (isOscuro ? Colors.white10 : Colors.grey.shade300),
                        width: 1.5,
                      ),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(22),
                      onTap: () {
                        if (!esActiva) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Esta tarjeta está inactiva.")));
                          return;
                        }
                        _mostrarListadoClientesParaPuntos(t);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                // FOTO DE REFERENCIA DEL PREMIO
                                Container(
                                  width: 52,
                                  height: 52,
                                  decoration: BoxDecoration(
                                    color: isOscuro ? Colors.white10 : Colors.grey.shade200,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: esActiva 
                                          ? (isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1))
                                          : Colors.grey,
                                      width: 1.5,
                                    ),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: _construirLogoNegocio(
                                    (t['foto_path'] != null && t['foto_path'].toString().isNotEmpty)
                                        ? t['foto_path'].toString()
                                        : ((t['fotoPath'] != null && t['fotoPath'].toString().isNotEmpty)
                                            ? t['fotoPath'].toString()
                                            : '')
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        t['titulo'] ?? 'Tarjeta',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 16,
                                          color: isOscuro ? Colors.white : Colors.black87,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Builder(
                                        builder: (context) {
                                          double mMin = ((t['monto_minimo'] ?? 0) as num).toDouble();
                                          String textoMonto = mMin > 0 ? " de \$${mMin.toInt()} o más" : "";
                                          return Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                "Por ${t['meta_compras']} compras$textoMonto obtienes ${t['premio_descripcion'] ?? t['titulo']}",
                                                style: TextStyle(
                                                  fontSize: 12, 
                                                  fontWeight: FontWeight.bold, 
                                                  color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
                                                  height: 1.25,
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              Text(
                                                "👉 Toca aquí para dar puntos manualmente",
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w800,
                                                  color: isOscuro ? Colors.orangeAccent : Colors.orange.shade900,
                                                ),
                                              ),
                                            ],
                                          );
                                        }
                                      ),
                                    ],
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  icon: const Icon(Icons.more_vert, size: 20, color: Colors.grey),
                                  onSelected: (val) async {
                                    final db = await DBHelper.instance.database;
                                    final user = FirebaseAuth.instance.currentUser;
                                    String tarjetaIdStr = t['id'].toString();
                                    String tituloTarj = t['titulo'] ?? 'Tarjeta';

                                    if (val == 'edit') {
                                      _mostrarModalCrearTarjeta(tarjetaAEditar: t);
                                    } else if (val == 'toggle') {
                                      bool confirm = await showDialog(
                                        context: context,
                                        builder: (ctx) => AlertDialog(
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                          title: Text(esActiva ? "¿Inhabilitar Tarjeta?" : "¿Activar Tarjeta?", style: const TextStyle(fontWeight: FontWeight.bold)),
                                          content: Text(esActiva 
                                              ? "¿Deseas inhabilitar \"$tituloTarj\"? No se otorgarán puntos a clientes mientras esté inactiva."
                                              : "¿Deseas activar la tarjeta \"$tituloTarj\"?"),
                                          actions: [
                                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("CANCELAR")),
                                            ElevatedButton(
                                              style: ElevatedButton.styleFrom(backgroundColor: esActiva ? Colors.orange : Colors.green),
                                              onPressed: () => Navigator.pop(ctx, true),
                                              child: Text(esActiva ? "INHABILITAR" : "ACTIVAR", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                            ),
                                          ],
                                        ),
                                      ) ?? false;

                                      if (!confirm) return;

                                      int nuevoEstado = esActiva ? 0 : 1;
                                      await db.update('tarjetas_fidelidad', {'activa': nuevoEstado}, where: 'id = ?', whereArgs: [t['id']]);

                                      if (user != null) {
                                        if (await ServicioNube.tieneInternet()) {
                                          await FirebaseFirestore.instance
                                              .collection('usuarios')
                                              .doc(user.uid)
                                              .collection('mis_tarjetas_creadas')
                                              .doc(tarjetaIdStr)
                                              .set({'activa': nuevoEstado}, SetOptions(merge: true));
                                        } else {
                                          await db.insert('operaciones_pendientes', {
                                            'tabla': 'mis_tarjetas_creadas',
                                            'operacion': 'set',
                                            'doc_id': tarjetaIdStr,
                                            'datos_json': jsonEncode({'activa': nuevoEstado}),
                                            'fecha_creacion': DateTime.now().toIso8601String(),
                                          }, conflictAlgorithm: ConflictAlgorithm.replace);
                                        }
                                        await ServicioNube.respaldarDatosPrivadosRTDB();
                                      }
                                      _cargarDatosBD();
                                    } else if (val == 'delete') {
                                      bool confirm = await showDialog(
                                        context: context,
                                        builder: (ctx) => AlertDialog(
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                          title: const Text("¿Eliminar Tarjeta?", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent)),
                                          content: Text("¿Estás seguro de que deseas eliminar la tarjeta \"$tituloTarj\"? Esta acción la borrará para ti y tus clientes."),
                                          actions: [
                                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("CANCELAR")),
                                            ElevatedButton(
                                              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                                              onPressed: () => Navigator.pop(ctx, true),
                                              child: const Text("ELIMINAR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                            ),
                                          ],
                                        ),
                                      ) ?? false;

                                      if (!confirm) return;

                                      await db.delete('tarjetas_fidelidad', where: 'id = ?', whereArgs: [t['id']]);
                                      await db.delete('puntos_clientes', where: 'tarjeta_id = ?', whereArgs: [t['id']]);
                                      if (user != null) {
                                        if (await ServicioNube.tieneInternet()) {
                                          await FirebaseFirestore.instance
                                              .collection('usuarios')
                                              .doc(user.uid)
                                              .collection('mis_tarjetas_creadas')
                                              .doc(tarjetaIdStr)
                                              .delete();
                                        } else {
                                          await db.insert('operaciones_pendientes', {
                                            'tabla': 'mis_tarjetas_creadas',
                                            'operacion': 'delete',
                                            'doc_id': tarjetaIdStr,
                                            'datos_json': null,
                                            'fecha_creacion': DateTime.now().toIso8601String(),
                                          }, conflictAlgorithm: ConflictAlgorithm.replace);
                                        }
                                        await ServicioNube.respaldarDatosPrivadosRTDB();
                                      }
                                      _cargarDatosBD();
                                    }
                                  },
                                  itemBuilder: (ctx) => [
                                    const PopupMenuItem(value: 'edit', child: Row(children: [Icon(Icons.edit, size: 16, color: Colors.orange), SizedBox(width: 8), Text("Editar")])),
                                    PopupMenuItem(value: 'toggle', child: Row(children: [Icon(esActiva ? Icons.visibility_off : Icons.visibility, size: 16, color: Colors.blue), SizedBox(width: 8), Text(esActiva ? "Inactivar" : "Activar")])),
                                    const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline, size: 16, color: Colors.red), SizedBox(width: 8), Text("Eliminar", style: TextStyle(color: Colors.red))])),
                                  ],
                                ),
                              ],
                            ),

                            const SizedBox(height: 12),
                            Divider(height: 1, color: isOscuro ? Colors.white10 : Colors.grey.shade200),
                            const SizedBox(height: 10),

                            // INDICADOR INFERIOR DE ESTADO Y ACCIÓN
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: (esActiva ? Colors.green : Colors.grey).withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: (esActiva ? Colors.green : Colors.grey).withOpacity(0.3)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 6, height: 6,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: esActiva ? Colors.green : Colors.grey,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        esActiva ? "Activa" : "Inactiva",
                                        style: TextStyle(
                                          color: esActiva ? Colors.green.shade800 : Colors.grey,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 10,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                Row(
                                  children: [
                                    Text(
                                      "Ver Clientes",
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: isOscuro ? Colors.white60 : Colors.grey.shade700,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(Icons.arrow_forward_ios_rounded, size: 10, color: isOscuro ? Colors.white60 : Colors.grey.shade700),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),

            // BANNER PUBLICIDAD NO PREMIUM
            if (!_esPremium) ...[
              const SizedBox(height: 20),
              const AnuncioNativoWidget(key: ValueKey('admob_fidelidad_ad')),
            ],
          ],
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
      ? 'ca-app-pub-2754846263403564/3464101852' 
      : 'ca-app-pub-3940256099942544/2934735716';

  @override
  void initState() {
    super.initState();
    _cargarAnuncio();
  }

  void _cargarAnuncio() {
    _bannerAd = BannerAd(
      adUnitId: _adUnitId,
      request: const AdRequest(),
      size: AdSize.largeBanner, 
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (mounted) setState(() => _isLoaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          debugPrint('Error cargando banner: ${error.message}');
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
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
      decoration: BoxDecoration(
        color: isOscuro ? const Color(0xFF1E2230) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isOscuro ? Colors.white10 : Colors.grey.shade300),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
            color: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("Publicidad Recomendada", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white54 : Colors.grey.shade600)),
                Icon(Icons.info_outline, size: 12, color: isOscuro ? Colors.white54 : Colors.grey.shade400)
              ],
            ),
          ),
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
                        const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("¿Respaldar base de datos?", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            Text("Sincroniza tus productos en tiempo real.", style: TextStyle(color: Colors.grey, fontSize: 10)),
                          ],
                        )
                      ],
                    ),
                  ),
          ),
          InkWell(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PantallaPremium())),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: isOscuro ? Colors.white10 : Colors.black12))),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.workspace_premium, size: 16, color: Colors.orange),
                  SizedBox(width: 8),
                  Text("QUITAR PUBLICIDAD (HAZTE PRO)", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.orange)),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }
}

// ============================================================
// PANTALLA WEB DE RECLAMO Y VISTA PERMANENTE PARA IPHONE / PC
// ============================================================
class PantallaReclamarPuntoWeb extends StatefulWidget {
  final String token;
  final String? cardId;
  const PantallaReclamarPuntoWeb({super.key, required this.token, this.cardId});

  @override
  State<PantallaReclamarPuntoWeb> createState() => _PantallaReclamarPuntoWebState();
}

class _PantallaReclamarPuntoWebState extends State<PantallaReclamarPuntoWeb> {
  bool _cargando = true;
  String _error = "";
  Map<String, dynamic>? _cardData;
  int _puntosTotales = 0;
  int _meta = 10;
  String _linkPermanente = "";

  @override
  void initState() {
    super.initState();
    _procesarEntradaWebUltraRapida();
  }

  Future<void> _procesarEntradaWebUltraRapida() async {
    try {
      final String uriStr = Uri.base.toString();
      String? cardParam = widget.cardId ?? Uri.base.queryParameters['card'];
      String? tokenParam = widget.token.isNotEmpty ? widget.token : Uri.base.queryParameters['token'];

      if (cardParam == null && uriStr.contains('card=')) {
        cardParam = uriStr.split('card=').last.split('&').first;
      }
      if (tokenParam == null && uriStr.contains('token=')) {
        tokenParam = uriStr.split('token=').last.split('&').first;
      }

      // 1️⃣ CONSULTA DIRECTA DE TARJETA PERMANENTE (`card=...`)
      if (cardParam != null && cardParam.isNotEmpty) {
        try {
          List<String> partes = cardParam.split('_');
          if (partes.length >= 2) {
            String vUid = partes[0];
            String tId = partes[1];
            String cDocId = partes.sublist(2).join('_');

            // Obtener datos reales del negocio (Nombre y Logo) desde el perfil del vendedor
            String realNomNegocio = "";
            String realLogoNegocio = "";
            try {
              var vDoc = await FirebaseFirestore.instance.collection('usuarios').doc(vUid).get();
              if (vDoc.exists && vDoc.data() != null) {
                var vData = vDoc.data()!;
                realNomNegocio = (vData['nombre_negocio'] ?? vData['nombreNegocio'] ?? vData['nombre'] ?? '').toString();
                realLogoNegocio = (vData['logo_path'] ?? vData['logoPath'] ?? vData['logo_url'] ?? '').toString();
              }
            } catch (_) {}

            var acumSnap = await FirebaseFirestore.instance
                .collection('usuarios')
                .doc(vUid)
                .collection('tarjetas_acumuladas')
                .doc(cardParam)
                .get()
                .timeout(const Duration(seconds: 3));

            var cData = acumSnap.exists ? acumSnap.data() : null;

            if (cData == null) {
              var clientSnap = await FirebaseFirestore.instance
                  .collection('usuarios')
                  .doc(vUid)
                  .collection('mis_tarjetas_creadas')
                  .doc(tId)
                  .collection('clientes')
                  .doc(cDocId)
                  .get()
                  .timeout(const Duration(seconds: 2));

              var tMetaSnap = await FirebaseFirestore.instance
                  .collection('usuarios')
                  .doc(vUid)
                  .collection('mis_tarjetas_creadas')
                  .doc(tId)
                  .get()
                  .timeout(const Duration(seconds: 2));

              if (clientSnap.exists || tMetaSnap.exists) {
                var clData = clientSnap.data() ?? {};
                var tMeta = tMetaSnap.data() ?? {};
                cData = {
                  'vendorUid': vUid,
                  'tarjetaId': tId,
                  'nombreNegocio': realNomNegocio.isNotEmpty ? realNomNegocio : (tMeta['nombreNegocio'] ?? 'Negocio'),
                  'logoPath': realLogoNegocio.isNotEmpty ? realLogoNegocio : (tMeta['logoPath'] ?? ''),
                  'fotoPath': tMeta['fotoPath'] ?? tMeta['foto_path'] ?? '',
                  'premioDesc': tMeta['premioDesc'] ?? tMeta['titulo'] ?? 'Premio',
                  'metaCompras': ((tMeta['metaCompras'] ?? 10) as num).toInt(),
                  'montoMinimo': ((tMeta['montoMinimo'] ?? 0) as num).toDouble(),
                  'puntosActuales': ((clData['puntosActuales'] ?? 0) as num).toInt(),
                };
              }
            } else {
              if (realNomNegocio.isNotEmpty) cData['nombreNegocio'] = realNomNegocio;
              if (realLogoNegocio.isNotEmpty) cData['logoPath'] = realLogoNegocio;
            }

            if (cData != null) {
              setState(() {
                _cardData = cData;
                _meta = ((cData!['metaCompras'] ?? 10) as num).toInt();
                _puntosTotales = ((cData['puntosActuales'] ?? 0) as num).toInt();
                _linkPermanente = "https://boxi-catalogo.web.app/reclamar?card=$cardParam";
                _cargando = false;
              });
              return;
            }
          }
        } catch (e) {
          debugPrint("Error leyendo card: $e");
        }

        setState(() {
          _error = "Tarjeta no encontrada o enlace vencido.";
          _cargando = false;
        });
        return;
      }
      // 2️⃣ RECLAMO ATÓMICO ULTRA RÁPIDO CON TOKEN (`token=...`) < 1 SEGUNDO
      if (tokenParam != null && tokenParam.isNotEmpty) {
        String tokenLimpio = tokenParam.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');
        final tokenSnap = await FirebaseFirestore.instance.collection('tokens_fidelidad').doc(tokenLimpio).get();

        if (!tokenSnap.exists || tokenSnap.data() == null) {
          setState(() {
            _error = "El código o enlace no existe o ya fue reclamado.";
            _cargando = false;
          });
          return;
        }

        final tData = tokenSnap.data()!;

        // Validar expiración de 24 horas
        if (tData.containsKey('expireAt') && tData['expireAt'] != null) {
          Timestamp expireAt = tData['expireAt'];
          if (expireAt.toDate().isBefore(DateTime.now())) {
            await tokenSnap.reference.delete().catchError((_) {});
            setState(() {
              _error = "Este enlace ha caducado (duración máxima 24 horas).";
              _cargando = false;
            });
            return;
          }
        }

        String vendorUid = tData['vendorUid'] ?? '';
        String tarjetaId = tData['tarjetaId'] ?? 'general';
        String clienteLocalId = tData['clienteLocalId']?.toString() ?? '';
        String clienteNombre = tData['clienteNombre']?.toString() ?? 'Cliente Web';

        String clientDocId = clienteLocalId.isNotEmpty ? clienteLocalId : "1";
        String cardKey = "${vendorUid}_${tarjetaId}_$clientDocId";

        // ⚡ Leer la meta más reciente y datos actualizados directamente desde la tarjeta del vendedor
        int meta = ((tData['metaCompras'] ?? 10) as num).toInt();
        String premioDesc = tData['premioDesc'] ?? tData['tarjetaTitulo'] ?? 'Premio';
        double montoMin = ((tData['montoMinimo'] ?? 0) as num).toDouble();
        String logoPath = tData['logoPath'] ?? '';
        String fotoPath = tData['fotoPath'] ?? tData['foto_path'] ?? '';
        String nombreNegocio = tData['nombreNegocio'] ?? 'Negocio';

        try {
          var tMasterDoc = await FirebaseFirestore.instance
              .collection('usuarios')
              .doc(vendorUid)
              .collection('mis_tarjetas_creadas')
              .doc(tarjetaId)
              .get();
          if (tMasterDoc.exists && tMasterDoc.data() != null) {
            Map<String, dynamic> mData = tMasterDoc.data() as Map<String, dynamic>;
            meta = ((mData['metaCompras'] ?? meta) as num).toInt();
            premioDesc = (mData['premioDesc'] ?? mData['titulo'] ?? premioDesc).toString();
            montoMin = ((mData['montoMinimo'] ?? montoMin) as num).toDouble();
            if ((mData['fotoPath'] ?? '').toString().isNotEmpty) fotoPath = mData['fotoPath'].toString();
            if ((mData['logoPath'] ?? '').toString().isNotEmpty) logoPath = mData['logoPath'].toString();
          }
        } catch (_) {}

        // ⚡ Leer los puntos acumulados reales del cliente desde sus datos guardados
        DocumentReference clientRef = FirebaseFirestore.instance
            .collection('usuarios')
            .doc(vendorUid)
            .collection('mis_tarjetas_creadas')
            .doc(tarjetaId)
            .collection('clientes')
            .doc(clientDocId);

        var clientSnap = await clientRef.get();
        int ptsAntiguos = 0;
        int completadas = 0;

        if (clientSnap.exists && clientSnap.data() != null) {
          Map<String, dynamic> clData = clientSnap.data() as Map<String, dynamic>;
          ptsAntiguos = ((clData['puntosActuales'] ?? 0) as num).toInt();
          completadas = ((clData['completadasTotales'] ?? 0) as num).toInt();
        }

        int ptsActuales = ptsAntiguos + 1;
        if (ptsAntiguos >= meta) {
          ptsActuales = 1;
        } else if (ptsActuales >= meta) {
          completadas++;
        }

        Map<String, dynamic> datosTarjetaCompleta = {
          'vendorUid': vendorUid,
          'tarjetaId': tarjetaId,
          'clienteLocalId': clientDocId,
          'clienteNombre': clienteNombre,
          'nombreNegocio': nombreNegocio,
          'logoPath': logoPath,
          'fotoPath': fotoPath,
          'tarjetaTitulo': premioDesc,
          'premioDesc': premioDesc,
          'metaCompras': meta,
          'montoMinimo': montoMin,
          'puntosActuales': ptsActuales,
          'completadasTotales': completadas,
          'ultimaModificacion': FieldValue.serverTimestamp(),
        };

        // 🚀 PROCESAMIENTO ATÓMICO EN UN SOLO LOTE (0 LAG)
        WriteBatch batch = FirebaseFirestore.instance.batch();

        batch.set(clientRef, {
          'clienteLocalId': clientDocId,
          'clienteNombre': clienteNombre,
          'clienteTelefono': tData['clienteTelefono'] ?? '',
          'puntosActuales': ptsActuales,
          'completadasTotales': completadas,
          'ultimaModificacion': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        // Destruir token usado
        batch.delete(tokenSnap.reference);

        await batch.commit();

        // Notificar al vendedor por FCM
        ServicioFidelidad.notificarVendedorPuntoReclamado(
          vendorUid: vendorUid,
          nombreCliente: clienteNombre,
          nombreNegocio: nombreNegocio,
          metaAlcanzada: ptsActuales >= meta,
          premioDesc: premioDesc,
        );

        setState(() {
          _cardData = datosTarjetaCompleta;
          _meta = meta;
          _puntosTotales = ptsActuales;
          _linkPermanente = "${Uri.base.origin}/reclamar?card=$cardKey";
          _cargando = false;
        });
        return;
      }

      setState(() {
        _error = "Enlace no válido.";
        _cargando = false;
      });
    } catch (e) {
      setState(() {
        _error = "Error cargando la tarjeta: $e";
        _cargando = false;
      });
    }
  }

  // 🟢 RECLAMAR RECOMPENSA VÍA WHATSAPP
  Future<void> _reclamarRecompensaWhatsAppWeb() async {
    if (_cardData == null) return;

    String vendorUid = _cardData!['vendorUid'] ?? '';
    String nomNegocio = _cardData!['nombreNegocio'] ?? 'Negocio';
    String premio = _cardData!['premioDesc'] ?? 'Recompensa';
    int meta = _meta;

    String telefonoVendedor = "";

    if (vendorUid.isNotEmpty) {
      try {
        final vDoc = await FirebaseFirestore.instance.collection('usuarios').doc(vendorUid).get();
        if (vDoc.exists && vDoc.data() != null) {
          telefonoVendedor = vDoc.data()?['whatsapp_admin'] ?? vDoc.data()?['telefono'] ?? '';
        }
      } catch (_) {}
    }

    if (telefonoVendedor.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("⚠️ El negocio aún no ha configurado un número de WhatsApp."), backgroundColor: Colors.orange)
      );
      return;
    }

    String numClean = telefonoVendedor.replaceAll(RegExp(r'\D'), '');
    if (numClean.length == 10) numClean = "57$numClean";

    String mensaje = "¡Hola *$nomNegocio*! 👋 Completé los *$meta puntos* de mi tarjeta de regalo para el premio: *$premio* 🎁.\n\n¿Cómo puedo reclamar mi recompensa? ¡Muchas gracias! 🙌";
    String textEncoded = Uri.encodeComponent(mensaje);

    Uri uriApp = Uri.parse("whatsapp://send?phone=$numClean&text=$textEncoded");
    Uri uriWeb = Uri.parse("https://wa.me/$numClean?text=$textEncoded");

    try {
      if (await canLaunchUrl(uriApp)) {
        await launchUrl(uriApp, mode: LaunchMode.externalApplication);
      } else if (await canLaunchUrl(uriWeb)) {
        await launchUrl(uriWeb, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(Uri.parse("https://api.whatsapp.com/send?phone=$numClean&text=$textEncoded"), mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      await launchUrl(uriWeb, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    String logoUrl = _cardData?['logoPath'] ?? '';
    String fotoPremioUrl = _cardData?['fotoPath'] ?? _cardData?['foto_path'] ?? '';
    String nomNegocio = _cardData?['nombreNegocio'] ?? 'Negocio';
    String premio = _cardData?['premioDesc'] ?? 'Recompensa';
    double mMin = ((_cardData?['montoMinimo'] ?? 0) as num).toDouble();
    String textoMonto = mMin > 0 ? " de \$${mMin.toInt()} o más" : "";
    bool metaAlcanzada = _puntosTotales >= _meta;
    double porcentaje = _meta > 0 ? (_puntosTotales / _meta).clamp(0.0, 1.0) : 0.0;

    return Scaffold(
      backgroundColor: const Color(0xFF0A1628),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Card(
                color: const Color(0xFF132238),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                  side: const BorderSide(color: Colors.white12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: _cargando
                      ? const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: Colors.cyanAccent),
                            SizedBox(height: 15),
                            Text("Sumando tu punto...", style: TextStyle(color: Colors.white70, fontSize: 13)),
                          ],
                        )
                      : _error.isNotEmpty
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 60),
                                const SizedBox(height: 15),
                                const Text("Enlace No Disponible", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                                const SizedBox(height: 10),
                                Text(_error, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60, fontSize: 12)),
                              ],
                            )
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 🏪 1. LOGO Y NOMBRE DEL NEGOCIO
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    CircleAvatar(
                                      radius: 22,
                                      backgroundColor: Colors.white10,
                                      child: ClipOval(
                                        child: Image.network(
                                          logoUrl,
                                          width: 44, height: 44, fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) => const Icon(Icons.storefront_rounded, color: Colors.cyanAccent, size: 24),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Flexible(
                                      child: Text(
                                        nomNegocio,
                                        style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Colors.white),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),

                                // 🎁 2. CAJA DE RECOMPENSA CON FOTO DEL PREMIO
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.cyanAccent.withOpacity(0.08),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
                                  ),
                                  child: Row(
                                    children: [
                                      if (fotoPremioUrl.isNotEmpty && fotoPremioUrl.startsWith('http')) ...[
                                        Container(
                                          width: 52,
                                          height: 52,
                                          decoration: BoxDecoration(
                                            color: Colors.white10,
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          clipBehavior: Clip.antiAlias,
                                          child: Image.network(
                                            fotoPremioUrl,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) => const Icon(Icons.card_giftcard, color: Colors.cyanAccent, size: 28),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                      ],
                                      Expanded(
                                        child: Text(
                                          "Por $_meta compras$textoMonto obtienes $premio",
                                          style: const TextStyle(color: Colors.cyanAccent, fontSize: 12, fontWeight: FontWeight.bold, height: 1.25),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 20),

                                // 🏆 3. ESTAMPAS Y PROGRESO
                                Text(
                                  metaAlcanzada ? "🎉 ¡TARJETA COMPLETADA!" : "🎉 ¡Punto Reclamado con Éxito!",
                                  style: TextStyle(color: metaAlcanzada ? Colors.greenAccent : Colors.cyanAccent, fontWeight: FontWeight.w900, fontSize: 15),
                                ),
                                const SizedBox(height: 15),

                                GridView.builder(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 5,
                                    crossAxisSpacing: 8,
                                    mainAxisSpacing: 8,
                                  ),
                                  itemCount: _meta,
                                  itemBuilder: (ctx, idx) {
                                    bool tieneSello = (idx + 1) <= _puntosTotales;
                                    return Container(
                                      decoration: BoxDecoration(
                                        color: tieneSello ? Colors.green.withOpacity(0.2) : Colors.white10,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: tieneSello ? Colors.greenAccent : Colors.white24),
                                      ),
                                      child: Center(
                                        child: tieneSello
                                            ? const Text("❌", style: TextStyle(fontSize: 20))
                                            : Text("${idx + 1}", style: const TextStyle(color: Colors.white38, fontSize: 11)),
                                      ),
                                    );
                                  },
                                ),

                                const SizedBox(height: 15),

                                // BARRA DE PROGRESO Y PORCENTAJE
                                Column(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: LinearProgressIndicator(
                                        value: porcentaje,
                                        minHeight: 6,
                                        backgroundColor: Colors.white10,
                                        valueColor: AlwaysStoppedAnimation<Color>(
                                          metaAlcanzada ? Colors.greenAccent : Colors.cyanAccent,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        const Text("Progreso de Sellos", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white38)),
                                        Text("${(porcentaje * 100).toInt()}%", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: metaAlcanzada ? Colors.greenAccent : Colors.cyanAccent)),
                                      ],
                                    ),
                                  ],
                                ),

                                const SizedBox(height: 15),

                                // 🟢 4. BOTÓN VERDE RECLAMAR RECOMPENSA (APARECE AL LLEGAR A LA META 5/5)
                                if (metaAlcanzada) ...[
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF25D366),
                                      foregroundColor: Colors.white,
                                      minimumSize: const Size(double.infinity, 50),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                      elevation: 3,
                                    ),
                                    icon: const Icon(Icons.card_giftcard_rounded, size: 22),
                                    label: const Text(
                                      "🎁 ¡RECLAMAR RECOMPENSA VÍA WHATSAPP!", 
                                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 0.5)
                                    ),
                                    onPressed: _reclamarRecompensaWhatsAppWeb,
                                  ),
                                  const SizedBox(height: 15),
                                ],

                                // 📋 5. BOTÓN COPIAR ENLACE PERMANENTE (NUNCA MÁS COPIA TOKEN=)
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.05),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: Colors.white10),
                                  ),
                                  child: Column(
                                    children: [
                                      const Text(
                                        "📌 Guarda este enlace en tus notas para ver tus sellos cuando quieras:",
                                        textAlign: TextAlign.center,
                                        style: TextStyle(color: Colors.white70, fontSize: 11),
                                      ),
                                      const SizedBox(height: 8),
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.cyanAccent,
                                          foregroundColor: Colors.black,
                                          minimumSize: const Size(double.infinity, 40),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        ),
                                        icon: const Icon(Icons.copy_rounded, size: 16),
                                        label: const Text("📋 COPIAR MI ENLACE DE TARJETA", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11)),
                                        onPressed: () {
                                          String vUid = _cardData?['vendorUid'] ?? '';
                                          String tId = _cardData?['tarjetaId'] ?? 'general';
                                          String cId = _cardData?['clienteLocalId']?.toString() ?? '1';
                                          
                                          // Construye la URL de la tarjeta permanente directamente sin depender de token
                                          String linkPermanenteReal = "https://boxi-catalogo.web.app/reclamar?card=${vUid}_${tId}_$cId";
                                          if (_linkPermanente.isNotEmpty && _linkPermanente.contains("card=")) {
                                            linkPermanenteReal = _linkPermanente;
                                          }

                                          Clipboard.setData(ClipboardData(text: linkPermanenteReal));
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text("Enlace permanente de la tarjeta copiado 📋"), backgroundColor: Colors.green),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}