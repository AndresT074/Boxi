import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../database/db_helper.dart';
import 'servicio_anuncios.dart';
import 'servicio_nube.dart';

class ServicioRespaldo {
  static const String dbNombre = 'boxi_pro_database.db';

  // Auxiliar para verificar si una tabla existe en el archivo de respaldo (Evita crashes entre versiones)
  static Future<bool> _tablaExiste(Database db, String nombreTabla) async {
    var res = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [nombreTabla],
    );
    return res.isNotEmpty;
  }

  static Future<void> exportarBaseDeDatos(BuildContext context) async {
    try {
      String databasesPath = await getDatabasesPath();
      String rutaDBOriginal = join(databasesPath, dbNombre);

      // Cerramos para asegurar que no haya escrituras pendientes
      await DBHelper.instance.close();

      File archivoDB = File(rutaDBOriginal);
      if (!await archivoDB.exists()) throw "No hay datos para respaldar.";

      Uint8List bytes = await archivoDB.readAsBytes();

      String? rutaDestino = await FilePicker.platform.saveFile(
        dialogTitle: 'Guardar respaldo',
        fileName:
            'Respaldo_Boxi_${DateTime.now().day}_${DateTime.now().month}.db',
        bytes: bytes,
      );

      // Reabrimos la DB
      await DBHelper.instance.database;

      if (rutaDestino != null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("✅ Respaldo exportado con éxito"),
              backgroundColor: Colors.green,
            ),
          );
          ServicioAnuncios.mostrarAnuncioIntersticial(() {});
        }
      }
    } catch (e) {
      await DBHelper.instance.database;
      if (context.mounted) _mostrarError(context, "Error al exportar: $e");
    }
  }

  static Future<void> importarBaseDeDatos(
    BuildContext context,
    VoidCallback onComplete,
  ) async {
    try {
      // 1. Asegurar que la base de datos actual esté en la versión correcta
      Database dbActual = await DBHelper.instance.database;

      // 2. Seleccionar archivo
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        dialogTitle: 'Selecciona el respaldo para fusionar',
      );

      if (result == null || result.files.single.path == null) return;
      File archivoRespaldo = File(result.files.single.path!);

      // 3. Validar que sea un SQLite válido
      final firstBytes = await archivoRespaldo.openRead(0, 16).first;
      if (!String.fromCharCodes(firstBytes).contains("SQLite format 3")) {
        throw "El archivo no es una base de datos válida de Boxi.";
      }

      bool? confirmar = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Row(
            children: [
              Icon(
                Icons.download_for_offline_rounded,
                color: Color(0xFF0D47A1),
                size: 28,
              ),
              SizedBox(width: 8),
              Text(
                "Fusionar Datos",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: const Text(
            "Se restaurarán proveedores, categorías, productos, clientes y pedidos vinculándolos a tu inventario actual. Los registros duplicados se ignorarán.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text(
                "CANCELAR",
                style: TextStyle(
                  color: Colors.grey,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0D47A1),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                "FUSIONAR",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );

      if (confirmar != true) return;

      // 4. Abrir DB de Respaldo en modo lectura
      Database dbRespaldo = await openDatabase(
        archivoRespaldo.path,
        readOnly: true,
      );

      // Mapas de traducción: ID_ARCHIVO_RESPALDO -> ID_NUEVO_EN_ESTE_DISPOSITIVO
      Map<int, int> provMap = {};
      Map<int, int> vMap = {};
      Map<int, int> cMap = {};
      Map<int, int> pMap = {};
      Map<int, int> pedMap = {};

      int contadorNuevos = 0;
      String ahora = DateTime.now().toIso8601String();

      // ==========================================
      // 1. PROVEEDORES
      // ==========================================
      if (await _tablaExiste(dbRespaldo, 'proveedores') &&
          await _tablaExiste(dbActual, 'proveedores')) {
        List<Map<String, dynamic>> provRes = await dbRespaldo.query(
          'proveedores',
        );
        for (var prov in provRes) {
          String nomProv = (prov['nombre'] ?? '').toString().trim();
          var existe = await dbActual.query(
            'proveedores',
            where: 'LOWER(nombre) = ?',
            whereArgs: [nomProv.toLowerCase()],
          );
          if (existe.isEmpty) {
            Map<String, dynamic> provNueva = Map.from(prov)..remove('id');
            provNueva['ultima_modificacion'] = ahora;
            int newId = await dbActual.insert('proveedores', provNueva);
            if (prov['id'] != null) provMap[prov['id']] = newId;
            contadorNuevos++;
          } else {
            if (prov['id'] != null)
              provMap[prov['id']] = existe.first['id'] as int;
          }
        }
      }

      // ==========================================
      // 2. CATEGORÍAS
      // ==========================================
      if (await _tablaExiste(dbRespaldo, 'categorias') &&
          await _tablaExiste(dbActual, 'categorias')) {
        List<Map<String, dynamic>> catRes = await dbRespaldo.query(
          'categorias',
        );
        for (var cat in catRes) {
          String nomCat = (cat['nombre'] ?? '').toString().trim();
          var existe = await dbActual.query(
            'categorias',
            where: 'LOWER(nombre) = ?',
            whereArgs: [nomCat.toLowerCase()],
          );
          if (existe.isEmpty) {
            Map<String, dynamic> catNueva = Map.from(cat)..remove('id');
            catNueva['ultima_modificacion'] = ahora;
            await dbActual.insert('categorias', catNueva);
            contadorNuevos++;
          }
        }
      }

      // ==========================================
      // 3. VENDEDORES
      // ==========================================
      if (await _tablaExiste(dbRespaldo, 'vendedores')) {
        List<Map<String, dynamic>> vRes = await dbRespaldo.query('vendedores');
        for (var v in vRes) {
          String nomV = (v['nombre'] ?? '').toString().trim();
          var existe = await dbActual.query(
            'vendedores',
            where: 'LOWER(nombre) = ?',
            whereArgs: [nomV.toLowerCase()],
          );
          if (existe.isEmpty) {
            Map<String, dynamic> vNueva = Map.from(v)..remove('id');
            vNueva['ultima_modificacion'] = ahora;
            int newId = await dbActual.insert('vendedores', vNueva);
            if (v['id'] != null) vMap[v['id']] = newId;
            contadorNuevos++;
          } else {
            if (v['id'] != null) vMap[v['id']] = existe.first['id'] as int;
          }
        }
      }

      // ==========================================
      // 4. CLIENTES (Comprobación segura de duplicados)
      // ==========================================
      if (await _tablaExiste(dbRespaldo, 'clientes')) {
        List<Map<String, dynamic>> cRes = await dbRespaldo.query('clientes');
        for (var c in cRes) {
          String nomC = (c['nombre_completo'] ?? '').toString().trim();
          String telC = (c['telefono'] ?? '').toString().replaceAll(
            RegExp(r'\D'),
            '',
          );

          List<Map<String, dynamic>> existe = [];
          if (telC.isNotEmpty) {
            existe = await dbActual.query(
              'clientes',
              where: 'telefono LIKE ?',
              whereArgs: ['%$telC%'],
            );
          }
          if (existe.isEmpty) {
            existe = await dbActual.query(
              'clientes',
              where: 'LOWER(nombre_completo) = ?',
              whereArgs: [nomC.toLowerCase()],
            );
          }

          if (existe.isEmpty) {
            Map<String, dynamic> cNueva = Map.from(c)..remove('id');
            cNueva['ultima_modificacion'] = ahora;
            int newId = await dbActual.insert('clientes', cNueva);
            if (c['id'] != null) cMap[c['id']] = newId;
            contadorNuevos++;
          } else {
            if (c['id'] != null) cMap[c['id']] = existe.first['id'] as int;
          }
        }
      }

      // ==========================================
      // 5. PRODUCTOS Y VARIANTES (Con mapeo de proveedor)
      // ==========================================
      if (await _tablaExiste(dbRespaldo, 'productos')) {
        List<Map<String, dynamic>> pRes = await dbRespaldo.query('productos');
        for (var p in pRes) {
          String nomP = (p['nombre'] ?? '').toString().trim();
          var existe = await dbActual.query(
            'productos',
            where: 'LOWER(nombre) = ?',
            whereArgs: [nomP.toLowerCase()],
          );

          int? newProvId;
          if (p['proveedor_id'] != null) {
            newProvId = provMap[p['proveedor_id']];
          }

          if (existe.isEmpty) {
            Map<String, dynamic> pNueva = Map.from(p)..remove('id');
            if (newProvId != null) pNueva['proveedor_id'] = newProvId;
            pNueva['ultima_modificacion'] = ahora;
            int newId = await dbActual.insert('productos', pNueva);
            if (p['id'] != null) pMap[p['id']] = newId;
            contadorNuevos++;
          } else {
            int existingId = existe.first['id'] as int;
            if (p['id'] != null) pMap[p['id']] = existingId;

            // Si el producto existe y tiene proveedor asignado en el respaldo
            if (newProvId != null && existe.first['proveedor_id'] == null) {
              await dbActual.update(
                'productos',
                {'proveedor_id': newProvId},
                where: 'id = ?',
                whereArgs: [existingId],
              );
            }

            // Restauración de variantes
            String varActual = existe.first['variantes']?.toString() ?? "";
            String varRespaldo = p['variantes']?.toString() ?? "";

            if (varRespaldo.length > 5 && varActual != varRespaldo) {
              await dbActual.update(
                'productos',
                {'variantes': varRespaldo, 'ultima_modificacion': ahora},
                where: 'id = ?',
                whereArgs: [existingId],
              );
              contadorNuevos++;
            }
          }
        }
      }

      // ==========================================
      // 6. PEDIDOS
      // ==========================================
      if (await _tablaExiste(dbRespaldo, 'pedidos')) {
        List<Map<String, dynamic>> pedRes = await dbRespaldo.query('pedidos');
        for (var ped in pedRes) {
          int? newClienteId = cMap[ped['cliente_id']];
          if (newClienteId == null) continue;

          var existe = await dbActual.query(
            'pedidos',
            where: 'cliente_id = ? AND fecha_hora = ?',
            whereArgs: [newClienteId, ped['fecha_hora']],
          );

          if (existe.isEmpty) {
            Map<String, dynamic> pedNueva = Map.from(ped)..remove('id');
            pedNueva['cliente_id'] = newClienteId;
            pedNueva['vendedor_id'] =
                vMap[ped['vendedor_id']] ?? ped['vendedor_id'] ?? 1;
            pedNueva['ultima_modificacion'] = ahora;
            int newPedId = await dbActual.insert('pedidos', pedNueva);
            if (ped['id'] != null) pedMap[ped['id']] = newPedId;
            contadorNuevos++;
          } else {
            if (ped['id'] != null)
              pedMap[ped['id']] = existe.first['id'] as int;
          }
        }
      }

      // ==========================================
      // 7. DETALLE DE PEDIDOS
      // ==========================================
      if (await _tablaExiste(dbRespaldo, 'detalle_pedidos')) {
        List<Map<String, dynamic>> detRes = await dbRespaldo.query(
          'detalle_pedidos',
        );
        for (var d in detRes) {
          int? idPedidoActual = pedMap[d['pedido_id']];
          int? idProductoActual = pMap[d['producto_id']];

          if (idPedidoActual != null && idProductoActual != null) {
            var existe = await dbActual.query(
              'detalle_pedidos',
              where: 'pedido_id = ? AND producto_id = ? AND cantidad = ?',
              whereArgs: [idPedidoActual, idProductoActual, d['cantidad']],
            );

            if (existe.isEmpty) {
              Map<String, dynamic> dNueva = Map.from(d)..remove('id');
              dNueva['pedido_id'] = idPedidoActual;
              dNueva['producto_id'] = idProductoActual;
              dNueva['ultima_modificacion'] = ahora;
              await dbActual.insert('detalle_pedidos', dNueva);
            }
          }
        }
      }

      // ==========================================
      // 8. FOTOS DE VARIANTES
      // ==========================================
      if (await _tablaExiste(dbRespaldo, 'fotos_variantes')) {
        List<Map<String, dynamic>> fvRes = await dbRespaldo.query(
          'fotos_variantes',
        );
        for (var fv in fvRes) {
          int? idProductoActual = pMap[fv['producto_id']];
          if (idProductoActual != null) {
            var existe = await dbActual.query(
              'fotos_variantes',
              where: 'producto_id = ? AND grupo_index = ? AND opcion_index = ?',
              whereArgs: [
                idProductoActual,
                fv['grupo_index'],
                fv['opcion_index'],
              ],
            );
            if (existe.isEmpty) {
              Map<String, dynamic> fvNueva = Map.from(fv)..remove('id');
              fvNueva['producto_id'] = idProductoActual;
              fvNueva['ultima_modificacion'] = ahora;
              await dbActual.insert('fotos_variantes', fvNueva);
            }
          }
        }
      }

      // ==========================================
      // 9. AJUSTES DE CAPITAL (Con mapeo de proveedor y producto)
      // ==========================================
      if (await _tablaExiste(dbRespaldo, 'ajustes_capital')) {
        List<Map<String, dynamic>> ajRes = await dbRespaldo.query(
          'ajustes_capital',
        );
        for (var aj in ajRes) {
          var existe = await dbActual.query(
            'ajustes_capital',
            where: 'fecha = ? AND monto = ?',
            whereArgs: [aj['fecha'], aj['monto']],
          );
          if (existe.isEmpty) {
            Map<String, dynamic> ajNueva = Map.from(aj)..remove('id');
            if (aj['proveedor_id'] != null &&
                provMap.containsKey(aj['proveedor_id'])) {
              ajNueva['proveedor_id'] = provMap[aj['proveedor_id']];
            }
            if (aj['producto_id'] != null &&
                pMap.containsKey(aj['producto_id'])) {
              ajNueva['producto_id'] = pMap[aj['producto_id']];
            }
            ajNueva['ultima_modificacion'] = ahora;
            await dbActual.insert('ajustes_capital', ajNueva);
          }
        }
      }

      // ==========================================
      // 10. REPORTES GUARDADOS
      // ==========================================
      if (await _tablaExiste(dbRespaldo, 'reportes_guardados') &&
          await _tablaExiste(dbActual, 'reportes_guardados')) {
        List<Map<String, dynamic>> repRes = await dbRespaldo.query(
          'reportes_guardados',
        );
        for (var rep in repRes) {
          var existe = await dbActual.query(
            'reportes_guardados',
            where: 'fecha = ? AND titulo = ?',
            whereArgs: [rep['fecha'], rep['titulo']],
          );
          if (existe.isEmpty) {
            Map<String, dynamic> repNueva = Map.from(rep)..remove('id');
            repNueva['ultima_modificacion'] = ahora;
            await dbActual.insert('reportes_guardados', repNueva);
          }
        }
      }

      await dbRespaldo.close();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('migracion_definitiva_completa_v6', false);

      try {
        await ServicioNube.migrarVariantesAlJSONyCarpetas();
      } catch (e) {
        debugPrint("⚠️ Error en migración de variantes: $e");
      }

      onComplete(); // Refresca la UI de la aplicación inmediatamente

      if (prefs.getBool('es_premium') ?? false) {
        try {
          await ServicioNube.respaldarDatosPrivadosRTDB();
        } catch (e) {
          debugPrint("⚠️ Error respaldando datos privados: $e");
        }

        try {
          await ServicioNube.compilarYSubirCatalogoRTDB();
        } catch (e) {
          debugPrint("⚠️ Error respaldando catálogo web: $e");
        }

        try {
          await ServicioNube.migrarTodoACloudinary();
        } catch (e) {
          debugPrint("⚠️ Error migrando fotos a Cloudinary: $e");
        }
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "✅ Fusión exitosa. Se añadieron $contadorNuevos registros.",
            ),
            backgroundColor: Colors.green,
          ),
        );
        ServicioAnuncios.mostrarAnuncioIntersticial(() {});
      }
    } catch (e) {
      if (context.mounted) _mostrarError(context, "Error en fusión: $e");
    }
  }

  static void _mostrarError(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("❌ $msg"), backgroundColor: Colors.red),
    );
  }
}
