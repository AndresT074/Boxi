import 'dart:io';
import 'dart:typed_data';
import 'package:Boxi/database/db_helper.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'servicio_anuncios.dart'; 
import 'servicio_nube.dart';

class ServicioRespaldo {
  static const String dbNombre = 'boxi_pro_database.db'; 

  // Auxiliar para verificar si una tabla existe en el archivo de respaldo (Evita crashes de versiones)
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
        fileName: 'Respaldo_Boxi_${DateTime.now().day}_${DateTime.now().month}.db',
        bytes: bytes, 
      );

      // Reabrimos la DB
      await DBHelper.instance.database;

      if (rutaDestino != null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ Respaldo exportado con éxito")));
          ServicioAnuncios.mostrarAnuncioIntersticial(() {});
        }
      }
    } catch (e) {
      await DBHelper.instance.database;
      if (context.mounted) _mostrarError(context, "Error al exportar: $e");
    }
  }

  static Future<void> importarBaseDeDatos(BuildContext context, VoidCallback onComplete) async {
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
      
      // 3. Validar que sea un SQLite
      final firstBytes = await archivoRespaldo.openRead(0, 16).first;
      if (!String.fromCharCodes(firstBytes).contains("SQLite format 3")) {
        throw "El archivo no es una base de datos válida.";
      }

      bool? confirmar = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("📥 Fusionar Datos"),
          content: const Text("Se restaurarán categorías, productos, clientes y pedidos vinculándolos a tu inventario actual. Los duplicados se ignorarán."),
          actions:[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("CANCELAR")),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("FUSIONAR")),
          ],
        ),
      );

      if (confirmar != true) return;

      // 4. Abrir DB de Respaldo en modo lectura
      Database dbRespaldo = await openDatabase(archivoRespaldo.path, readOnly: true);

      // Mapas de traducción: ID_ARCHIVO_RESPALDO -> ID_NUEVO_EN_ESTE_CELULAR
      Map<int, int> vMap = {}; 
      Map<int, int> cMap = {}; 
      Map<int, int> pMap = {}; 
      Map<int, int> pedMap = {}; 

      int contadorNuevos = 0;
      String ahora = DateTime.now().toIso8601String();

      // --- PROCESO DE FUSIÓN CON COMPROBACIONES DE SEGURIDAD ---

      // CATEGORÍAS (🔥 AÑADIDO)
      if (await _tablaExiste(dbRespaldo, 'categorias')) {
        List<Map<String, dynamic>> catRes = await dbRespaldo.query('categorias');
        for (var cat in catRes) {
          var existe = await dbActual.query('categorias', where: 'nombre = ?', whereArgs: [cat['nombre']]);
          if (existe.isEmpty) {
            Map<String, dynamic> catNueva = Map.from(cat)..remove('id');
            catNueva['ultima_modificacion'] = ahora; 
            await dbActual.insert('categorias', catNueva);
            contadorNuevos++;
          }
        }
      }

      // VENDEDORES
      if (await _tablaExiste(dbRespaldo, 'vendedores')) {
        List<Map<String, dynamic>> vRes = await dbRespaldo.query('vendedores');
        for (var v in vRes) {
          var existe = await dbActual.query('vendedores', where: 'nombre = ?', whereArgs: [v['nombre']]);
          if (existe.isEmpty) {
            Map<String, dynamic> vNueva = Map.from(v)..remove('id');
            vNueva['ultima_modificacion'] = ahora; 
            int newId = await dbActual.insert('vendedores', vNueva);
            vMap[v['id']] = newId;
            contadorNuevos++;
          } else {
            vMap[v['id']] = existe.first['id'] as int;
          }
        }
      }

      // CLIENTES
      if (await _tablaExiste(dbRespaldo, 'clientes')) {
        List<Map<String, dynamic>> cRes = await dbRespaldo.query('clientes');
        for (var c in cRes) {
          var existe = await dbActual.query('clientes', 
              where: 'nombre_completo = ? AND nombre_negocio = ?', 
              whereArgs: [c['nombre_completo'], c['nombre_negocio']]);
          if (existe.isEmpty) {
            Map<String, dynamic> cNueva = Map.from(c)..remove('id');
            cNueva['ultima_modificacion'] = ahora; 
            int newId = await dbActual.insert('clientes', cNueva);
            cMap[c['id']] = newId;
            contadorNuevos++;
          } else {
            cMap[c['id']] = existe.first['id'] as int;
          }
        }
      }

      // PRODUCTOS Y VARIANTES
      if (await _tablaExiste(dbRespaldo, 'productos')) {
        List<Map<String, dynamic>> pRes = await dbRespaldo.query('productos');
        for (var p in pRes) {
          var existe = await dbActual.query('productos', where: 'nombre = ?', whereArgs: [p['nombre']]);
          if (existe.isEmpty) {
            Map<String, dynamic> pNueva = Map.from(p)..remove('id');
            pNueva['ultima_modificacion'] = ahora; 
            int newId = await dbActual.insert('productos', pNueva);
            pMap[p['id']] = newId;
            contadorNuevos++;
          } else {
            int existingId = existe.first['id'] as int;
            pMap[p['id']] = existingId;

            // 🔥 RECUPERACIÓN DE VARIANTES: Si el producto existe pero la copia tiene variantes eliminadas o diferentes, las restaura.
            String varActual = existe.first['variantes']?.toString() ?? "";
            String varRespaldo = p['variantes']?.toString() ?? "";

            if (varRespaldo.length > 5 && varActual != varRespaldo) {
              await dbActual.update(
                'productos', 
                {
                  'variantes': varRespaldo,
                  'ultima_modificacion': ahora,
                }, 
                where: 'id = ?', 
                whereArgs: [existingId]
              );
              contadorNuevos++;
            }
          }
        }
      }
      // PEDIDOS
      if (await _tablaExiste(dbRespaldo, 'pedidos')) {
        List<Map<String, dynamic>> pedRes = await dbRespaldo.query('pedidos');
        for (var ped in pedRes) {
          int? newClienteId = cMap[ped['cliente_id']];
          if (newClienteId == null) continue;
          var existe = await dbActual.query('pedidos', 
              where: 'cliente_id = ? AND fecha_hora = ?', 
              whereArgs: [newClienteId, ped['fecha_hora']]);
          if (existe.isEmpty) {
            Map<String, dynamic> pedNueva = Map.from(ped)..remove('id');
            pedNueva['cliente_id'] = newClienteId;
            pedNueva['vendedor_id'] = vMap[ped['vendedor_id']] ?? ped['vendedor_id'];
            pedNueva['ultima_modificacion'] = ahora; 
            int newPedId = await dbActual.insert('pedidos', pedNueva);
            pedMap[ped['id']] = newPedId;
            contadorNuevos++;
          }
        }
      }
      if (await _tablaExiste(dbRespaldo, 'detalle_pedidos')) {
        List<Map<String, dynamic>> detRes = await dbRespaldo.query('detalle_pedidos');
        for (var d in detRes) {
          int? idPedidoActual = pedMap[d['pedido_id']];
          int? idProductoActual = pMap[d['producto_id']];

          if (idPedidoActual != null && idProductoActual != null) {
            Map<String, dynamic> dNueva = Map.from(d)..remove('id');
            dNueva['pedido_id'] = idPedidoActual;
            dNueva['producto_id'] = idProductoActual;
            dNueva['ultima_modificacion'] = ahora; 
            await dbActual.insert('detalle_pedidos', dNueva);
          }
        }
      }

      if (await _tablaExiste(dbRespaldo, 'fotos_variantes')) {
        List<Map<String, dynamic>> fvRes = await dbRespaldo.query('fotos_variantes');
        for (var fv in fvRes) {
          int? idProductoActual = pMap[fv['producto_id']];
          if (idProductoActual != null) {
            var existe = await dbActual.query('fotos_variantes', 
                where: 'producto_id = ? AND grupo_index = ? AND opcion_index = ?', 
                whereArgs: [idProductoActual, fv['grupo_index'], fv['opcion_index']]);
            if (existe.isEmpty) {
              Map<String, dynamic> fvNueva = Map.from(fv);
              fvNueva['producto_id'] = idProductoActual; 
              fvNueva['ultima_modificacion'] = ahora;
              await dbActual.insert('fotos_variantes', fvNueva);
            }
          }
        }
      }

      // AJUSTES CAPITAL
      if (await _tablaExiste(dbRespaldo, 'ajustes_capital')) {
        List<Map<String, dynamic>> ajRes = await dbRespaldo.query('ajustes_capital');
        for (var aj in ajRes) {
          var existe = await dbActual.query('ajustes_capital', where: 'fecha = ? AND monto = ?', whereArgs: [aj['fecha'], aj['monto']]);
          if (existe.isEmpty) {
            Map<String, dynamic> ajNueva = Map.from(aj)..remove('id');
            ajNueva['ultima_modificacion'] = ahora;
            await dbActual.insert('ajustes_capital', ajNueva);
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

      onComplete(); // Refresca la UI de la pantalla principal inmediatamente

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
          SnackBar(content: Text("✅ Fusión exitosa. Se añadieron $contadorNuevos registros."), backgroundColor: Colors.green),
        );
        ServicioAnuncios.mostrarAnuncioIntersticial(() {});
      }

    } catch (e) {
      if (context.mounted) _mostrarError(context, "Error en fusión: $e");
    }
  }

  static void _mostrarError(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("❌ $msg"), backgroundColor: Colors.red));
  }
}