import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart'; 
import '../database/db_helper.dart';
import 'servicio_nube.dart';    
import 'servicio_anuncios.dart'; 
import 'pantalla_premium.dart'; 
import 'dart:async';
import 'dart:ui' as ui;           // Para ui.Codec, ui.FrameInfo, etc.
import 'dart:typed_data';       // Para Uint8List y ByteData

final Map<String, Uint8List> _inventarioImageCache = {};

class PantallaInventario extends StatefulWidget {
  const PantallaInventario({super.key});
  @override
  State<PantallaInventario> createState() => _PantallaInventarioState();
}

class _PantallaInventarioState extends State<PantallaInventario> {
  List<Map<String, dynamic>> _prods =[];
  List<Map<String, dynamic>> _filtrados =[];
  bool _esCuadricula = true;
  bool _esPremium = false; 
  bool _estaCargando = true; 
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _iniciarYMigrar(); 
    _repararFotosPesadas(); // 🔥 Inicia la migración global silenciosa
  }

  Future<void> _iniciarYMigrar() async {
    final prefs = await SharedPreferences.getInstance();
    bool migracionRealizada = prefs.getBool('migracion_variantes_completada') ?? false;
    if (!migracionRealizada) {
      await _migrarVariantesViejasGlobal(); 
      await prefs.setBool('migracion_variantes_completada', true);
    }
    _cargar();
    _activarTiempoReal();
  }

  Future<void> _migrarVariantesViejasGlobal() async {
    final db = await DBHelper.instance.database;
    final prefs = await SharedPreferences.getInstance();
    bool esPremium = prefs.getBool('es_premium') ?? false;
    
    final prods = await db.query('productos');
    
    for (var p in prods) {
      if (p['variantes'] != null && p['variantes'].toString().length > 50) {
        try {
          List<dynamic> dec = jsonDecode(p['variantes'].toString());
          bool huboCambio = false;
          
          // Caso 1: Formato viejo sin grupos
          if (dec.isNotEmpty && !dec[0].containsKey('grupo')) {
            for (int o = 0; o < dec.length; o++) {
              if (dec[o]['foto_path'] != null && dec[o]['foto_path'].toString().length > 50) {
                final fotoMap = {
                  'producto_id': p['id'],
                  'grupo_index': 0,
                  'opcion_index': o,
                  'variante_nombre': dec[o]['nombre'] ?? '', // 🔥 GUARDAMOS EL NOMBRE
                  'foto_base64': dec[o]['foto_path'],
                };
                await db.insert('fotos_variantes', fotoMap);
                if (esPremium) ServicioNube.guardarFotoVarianteNube(fotoMap); // 🔥 SUBIMOS A LA NUBE
                dec[o].remove('foto_path');
                huboCambio = true;
              }
            }
          } 
          // Caso 2: Formato con grupos
          else {
            for (int g = 0; g < dec.length; g++) {
              List opciones = dec[g]['opciones'] ?? [];
              for (int o = 0; o < opciones.length; o++) {
                if (opciones[o]['foto_path'] != null && opciones[o]['foto_path'].toString().length > 50) {
                  final fotoMap = {
                    'producto_id': p['id'],
                    'grupo_index': g,
                    'opcion_index': o,
                    'variante_nombre': opciones[o]['nombre'] ?? '', // 🔥 GUARDAMOS EL NOMBRE
                    'foto_base64': opciones[o]['foto_path'],
                  };
                  await db.insert('fotos_variantes', fotoMap);
                  if (esPremium) ServicioNube.guardarFotoVarianteNube(fotoMap); // 🔥 SUBIMOS A LA NUBE
                  opciones[o].remove('foto_path');
                  huboCambio = true;
                }
              }
            }
          }

          if (huboCambio) {
            String nuevoJson = jsonEncode(dec);
            // Actualizamos local
            await db.update('productos', {'variantes': nuevoJson}, where: 'id = ?', whereArgs: [p['id']]);
            
            // 🔥 ACTUALIZAMOS LA NUBE PARA QUE EL PRODUCTO YA NO TENGA FOTOS EN EL JSON
            if (esPremium) {
              Map<String, dynamic> prodParaNube = Map.from(p);
              prodParaNube['variantes'] = nuevoJson;
              ServicioNube.guardarProductoNube(prodParaNube);
            }
            debugPrint("✅ Producto ${p['nombre']} migrado exitosamente.");
          }
        } catch(e) {
          debugPrint("Error migrando producto ${p['id']}: $e");
        }
      }
    }
  }

  Future<void> _repararFotosPesadas() async {
    final db = await DBHelper.instance.database;
    // Buscamos productos donde la foto sea un String gigante
    final List<Map<String, dynamic>> pesados = await db.rawQuery(
      "SELECT id, nombre, foto_path FROM productos WHERE length(foto_path) > 1000000"
    );

    if (pesados.isEmpty) return;

    for (var p in pesados) {
      debugPrint("Reparando producto pesado: ${p['nombre']}");
      try {
        Uint8List bytes = base64Decode(p['foto_path']);
        ui.Codec codec = await ui.instantiateImageCodec(bytes, targetWidth: 600);
        ui.FrameInfo fi = await codec.getNextFrame();
        final ByteData? data = await fi.image.toByteData(format: ui.ImageByteFormat.png);
        String nuevaFoto = base64Encode(data!.buffer.asUint8List());
        
        await db.update('productos', {'foto_path': nuevaFoto}, where: 'id = ?', whereArgs: [p['id']]);
      } catch (e) {
        // Si la foto está corrupta, mejor la vaciamos para evitar crash
        await db.update('productos', {'foto_path': ''}, where: 'id = ?', whereArgs: [p['id']]);
      }
    }
    _cargar(); // Recargamos la lista ya limpia
  }


  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _activarTiempoReal() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _esPremium = prefs.getBool('es_premium') ?? false);
  }

  Future<void> _cargar() async {
    final db = await DBHelper.instance.database;
    final prefs = await SharedPreferences.getInstance();
    // 🔥 AÑADIDA LA COLUMNA "variantes" AL SELECT
    final data = await db.rawQuery('''
      SELECT id, nombre, precio_compra, precio_venta, descuento, stock, descripcion, orden, activo, ultima_modificacion, variantes 
      FROM productos 
      ORDER BY activo DESC, orden ASC, id DESC
    ''');
    if (!mounted) return;
    setState(() {
      _prods = data;
      _filtrados = data;
      _esPremium = prefs.getBool('es_premium') ?? false;
      _estaCargando = false;
    });
  }

  void _filtrar(String q) {
    setState(() {
      _filtrados = _prods
          .where((p) => p['nombre'].toLowerCase().contains(q.toLowerCase()))
          .toList();
    });
  }

  Future<void> _abrirFormulario({Map<String, dynamic>? p, bool saltarPorAnuncio = false}) async {
    Map<String, dynamic>? productoCompleto;
    
    // 🔥 Si estamos editando un producto, recuperamos sus datos completos (con fotos y variantes)
    if (p != null) {
      final db = await DBHelper.instance.database;
      final res = await db.query('productos', where: 'id = ?', whereArgs: [p['id']]);
      if (res.isNotEmpty) {
        productoCompleto = Map<String, dynamic>.from(res.first);
      }
    }

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => PantallaFormularioProducto(
          producto: productoCompleto, // 🔥 Le pasamos el producto completo
          onGuardar: () {
            _cargar();
            if (saltarPorAnuncio) {
              ServicioAnuncios.mostrarAnuncioIntersticial(() {});
            }
          },
        ),
      ),
    );
  }

  String _formatDesc(double pct) {
    return pct == pct.roundToDouble() 
        ? pct.toStringAsFixed(0) 
        : pct.toStringAsFixed(1);
  }
  
  Widget _construirVistaProductos(int columnas) {
    if (_estaCargando) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF0D47A1)),
      );
    }
    if (_filtrados.isEmpty) return const Center(child: Text('Sin productos'));

    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    double anchoPantalla = MediaQuery.of(context).size.width;
    bool esVertical = MediaQuery.of(context).orientation == Orientation.portrait;

    int columnasCalculadas = columnas == 1 ? 1 : (esVertical ? 2 : 5);

    double factorTexto = 1.0;
    if (anchoPantalla < 360) {
      factorTexto = 0.85;
    } else if (anchoPantalla > 600 && esVertical) {
      factorTexto = 1.2;
    } else if (anchoPantalla > 800 && !esVertical) {
      factorTexto = 1.15;
    }

    double aspect = columnasCalculadas == 1 
        ? (anchoPantalla > 600 ? 5.0 : 2.5) 
        : (0.58 - (factorTexto > 1.0 ? 0.05 : 0.0));

    return GridView.builder(
      padding: const EdgeInsets.only(left: 8, right: 8, top: 8, bottom: 90),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columnasCalculadas,
        childAspectRatio: aspect,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: _filtrados.length,
      itemBuilder: (context, i) {
        final p = _filtrados[i];
        bool estaInactivo = (p['activo'] ?? 1) == 0;

        bool tieneNegativoOCero = false;
        bool tieneVariantes = false; // 🔥 Nuevo verificador
        String variantesData = p['variantes']?.toString() ?? ""; 
        
        // 🔥 LÓGICA BLINDADA Y AISLADA
        if (variantesData.length > 5) {
          try {
            var dec = jsonDecode(variantesData);
            if (dec is List && dec.isNotEmpty) {
              tieneVariantes = true; // Confirmamos que trabaja con variantes
              for (var g in dec) {
                if (g is Map) {
                  // Soporta tanto formato con grupos como formato viejo (lista plana)
                  List opciones = g.containsKey('opciones') && g['opciones'] is List ? g['opciones'] : [g];
                  
                  for (var o in opciones) {
                    if (o is Map) {
                      bool esActivo = o['activo']?.toString() != 'false';
                      if (esActivo) { 
                        int st = int.tryParse(o['stock']?.toString() ?? '0') ?? 0;
                        if (st <= 0) { tieneNegativoOCero = true; break; }
                      }
                    }
                  }
                }
                if (tieneNegativoOCero) break;
              }
            }
          } catch (_) {}
        }

        bool sinStockGlobal = (int.tryParse(p['stock']?.toString() ?? '0') ?? 0) <= 0;
        
        // 🔥 SI TIENE VARIANTES, EL BORDE ROJO DEPENDE DE ELLAS. SI NO, DEL GLOBAL.
        bool mostrarAlerta = tieneVariantes ? tieneNegativoOCero : sinStockGlobal;

        double descuentoPct = (p['descuento'] ?? 0).toDouble();
        double precioCompra = (p['precio_compra'] ?? 0).toDouble();
        double precioBase = (p['precio_venta'] ?? 0).toDouble();
        double precioFinal = descuentoPct > 0 ? precioBase - (precioBase * descuentoPct / 100) : precioBase;

        Widget widgetImagen(bool esLista) {
          return InkWell(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PantallaDetalleProducto(producto: p))),
            child: SizedBox(
              width: esLista ? 115 * factorTexto : double.infinity,
              height: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  estaInactivo 
                    ? ColorFiltered(
                        colorFilter: const ColorFilter.mode(Colors.grey, BlendMode.saturation),
                        // 🔥 KEY AGREGADA PARA EVITAR CAOS DE RECICLAJE
                        child: ImagenInventario(key: ValueKey('img_${p['id']}'), id: p['id']), 
                      )
                    // 🔥 KEY AGREGADA
                    : ImagenInventario(key: ValueKey('img_${p['id']}'), id: p['id']), 
                  if (estaInactivo)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(5)),
                        child: Text('INACTIVO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10 * factorTexto)),
                      ),
                    ),
                  if (descuentoPct > 0)
                    Positioned(
                      top: 5,
                      left: esLista ? 0 : null,
                      right: esLista ? null : 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.only(
                                topRight: Radius.circular(esLista ? 8 : 0),
                                bottomRight: Radius.circular(esLista ? 8 : 0),
                                topLeft: Radius.circular(esLista ? 0 : 8),
                                bottomLeft: Radius.circular(esLista ? 0 : 8))),
                        child:Text('-${_formatDesc(descuentoPct)}%', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                      ),
                    )
                ],
              ),
            ),
          );
        }

        return Card(
          elevation: 3,
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: mostrarAlerta ? const BorderSide(color: Colors.red, width: 2) : BorderSide.none),
          color: estaInactivo
              ? (isOscuro ? Colors.white10 : Colors.grey.shade200)
              : Theme.of(context).cardColor,
          child: Opacity(
            opacity: estaInactivo ? 0.6 : 1.0,
            child: columnasCalculadas == 1
                ? Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            widgetImagen(true),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(p['nombre'],
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: 14 * factorTexto,
                                            fontWeight: FontWeight.bold,
                                            color: isOscuro ? Colors.white : Colors.black)),
                                    const SizedBox(height: 2),
                                    Text('STOCK: ${p['stock']}',
                                        style: TextStyle(
                                            fontSize: 11 * factorTexto,
                                            color: mostrarAlerta ? const Color.fromARGB(255, 236, 173, 168) : (isOscuro ? Colors.white70 : Colors.blueGrey))),
                                    const SizedBox(height: 2),
                                    Text('Costo: \$${precioCompra.toStringAsFixed(2)}',
                                        style: TextStyle(
                                            fontSize: 11 * factorTexto,
                                            color: isOscuro ? Colors.white38 : Colors.blueGrey,
                                            fontWeight: FontWeight.bold)),
                                    if (descuentoPct > 0)
                                      Text('\$$precioBase',
                                          style: TextStyle(fontSize: 10 * factorTexto, color: const Color.fromARGB(255, 249, 174, 168), decoration: TextDecoration.lineThrough)),
                                    const SizedBox(height: 2),
                                    FittedBox(
                                        child: Text('Venta: \$${precioFinal.toStringAsFixed(2)}',
                                            style: TextStyle(
                                                fontSize: 14 * factorTexto,
                                                color: descuentoPct > 0
                                                    ? Colors.greenAccent
                                                    : (isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)),
                                                fontWeight: FontWeight.bold))),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(border: Border(left: BorderSide(color: isOscuro ? Colors.white10 : Colors.grey.shade300))),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                                icon: Icon(Icons.edit_note, color: Colors.blue, size: 28 * factorTexto),
                                onPressed: () => _abrirFormulario(p: p)),
                            const SizedBox(height: 8),
                            IconButton(
                                icon: Icon(Icons.delete_outline, color: Colors.red, size: 28 * factorTexto),
                                onPressed: () => _eliminar(p['id'], p['nombre'])),
                          ],
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: widgetImagen(false),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(p['nombre'],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 13 * factorTexto,
                                    fontWeight: FontWeight.bold,
                                    color: isOscuro ? Colors.white : Colors.black)),
                            const SizedBox(height: 2),
                            Text('Stock: ${p['stock']}',
                                style: TextStyle(
                                    fontSize: 11 * factorTexto,
                                    color: mostrarAlerta ? const Color.fromARGB(255, 248, 174, 169) : (isOscuro ? Colors.white70 : Colors.black54))),
                            Text('Costo: \$${precioCompra.toStringAsFixed(2)}',
                                style: TextStyle(
                                    fontSize: 11 * factorTexto,
                                    color: isOscuro ? Colors.white38 : Colors.blueGrey,
                                    fontWeight: FontWeight.bold)),
                            if (descuentoPct > 0)
                              Text('\$$precioBase',
                                  style: TextStyle(fontSize: 10 * factorTexto, color: const Color.fromARGB(255, 244, 137, 137), decoration: TextDecoration.lineThrough)),
                            FittedBox(
                                child: Text('Venta: \$${precioFinal.toStringAsFixed(2)}',
                                    style: TextStyle(
                                        fontSize: 13 * factorTexto,
                                        color: descuentoPct > 0
                                            ? const Color.fromARGB(255, 19, 190, 107)
                                            : (isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)),
                                        fontWeight: FontWeight.bold))),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                IconButton(
                                    padding: const EdgeInsets.all(4),
                                    constraints: const BoxConstraints(),
                                    icon: Icon(Icons.edit_note, color: Colors.blue, size: 26 * factorTexto),
                                    onPressed: () => _abrirFormulario(p: p)),
                                const SizedBox(width: 16),
                                IconButton(
                                    padding: const EdgeInsets.all(4),
                                    constraints: const BoxConstraints(),
                                    icon: Icon(Icons.delete_outline, color: Colors.red, size: 26 * factorTexto),
                                    onPressed: () => _eliminar(p['id'], p['nombre'])),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  void _eliminar(int id, String nombre) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠️ Confirmar'),
        content: Text('¿Deseas eliminar "$nombre" por completo?'),
        actions:[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCELAR')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              final db = await DBHelper.instance.database;
              
              // 1. Encontrar cuántas variantes tenía para poder borrarlas en la nube
              final fotosDelProd = await db.query('fotos_variantes', where: 'producto_id = ?', whereArgs: [id]);
              
              // 2. Borrar de SQLite
              await db.delete('fotos_variantes', where: 'producto_id = ?', whereArgs: [id]);
              await db.delete('productos', where: 'id = ?', whereArgs: [id]);
              
              // 3. Borrar de Firebase
              if (_esPremium) {
                ServicioNube.eliminarProductoNube(id);
                // Borramos las fotos de Firestore una por una
                for (var f in fotosDelProd) {
                  ServicioNube.eliminarFotoVarianteNube(id, f['grupo_index'] as int, f['opcion_index'] as int);
                }
              }

              _cargar();
              if (mounted) Navigator.pop(ctx);
            },
            child: const Text('ELIMINAR', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    bool superoLimite = !_esPremium && _prods.length >= 50;
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    int totalStock = _filtrados.fold(0, (sum, item) => sum + (item['stock'] as int? ?? 0));

    return Scaffold(
      backgroundColor: isOscuro ? const Color(0xFF0A0A0F) : const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1),
        iconTheme: const IconThemeData(color: Colors.white),
        title: TextField(
          controller: _searchCtrl,
          onChanged: _filtrar,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Buscar producto...',
            hintStyle: TextStyle(color: Colors.white70),
            border: InputBorder.none,
            icon: Icon(Icons.search, color: Colors.white),
          ),
        ),
        actions:[
          IconButton(
            icon: Icon(_esCuadricula ? Icons.format_list_bulleted : Icons.grid_view_rounded, color: Colors.white),
            onPressed: () => setState(() => _esCuadricula = !_esCuadricula),
          )
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: superoLimite ? null : () => _abrirFormulario(),
        backgroundColor: superoLimite ? Colors.grey : const Color(0xFF0D47A1),
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text("Añadir Producto", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: Column(
        children:[
          if (superoLimite)
            Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors:[Colors.orange, Colors.orangeAccent, Colors.white, Colors.orangeAccent, Colors.orange],
                  stops:[0.0, 0.4, 0.5, 0.6, 1.0],
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                ),
              ),
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
              child: Row(
                children:[
                  const Expanded(child: Text("Límite de 50 alcanzado", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))),
                  TextButton(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PantallaPremium())),
                    child: const Text("HAZTE PREMIUM", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, decoration: TextDecoration.underline)),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                    onPressed: () => ServicioAnuncios.mostrarAnuncioIntersticial(() => _abrirFormulario(saltarPorAnuncio: true)),
                    child: const Text("Añade 1+ por Anuncio", style: TextStyle(fontSize: 10, color: Colors.white)),
                  )
                ],
              ),
            ),
          
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isOscuro ? const Color(0xFF1A1A2E) : Colors.white,
              border: Border(bottom: BorderSide(color: isOscuro ? Colors.white10 : Colors.grey.shade300, width: 1))
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children:[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children:[
                    Text("Cant. de productos:", style: TextStyle(fontSize: 12, color: isOscuro ? Colors.white38 : Colors.grey, fontWeight: FontWeight.bold)),
                    Text("${_filtrados.length} distintos", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: isOscuro ? Colors.white : Colors.black)),
                  ],
                ),
                Container(width: 1, height: 30, color: isOscuro ? Colors.white10 : Colors.grey.shade300),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children:[
                    Text("Total en inventario:", style: TextStyle(fontSize: 12, color: isOscuro ? Colors.white38 : Colors.grey, fontWeight: FontWeight.bold)),
                    Text("$totalStock unidades", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1))),
                  ],
                ),
              ],
            ),
          ),
          Expanded(child: _construirVistaProductos(_esCuadricula ? 5 : 1)),
        ],
      ),
    );
  }
}

class PantallaFormularioProducto extends StatefulWidget {
  final Map<String, dynamic>? producto;
  final VoidCallback onGuardar;
  const PantallaFormularioProducto({super.key, this.producto, required this.onGuardar});
  @override
  State<PantallaFormularioProducto> createState() => _PantallaFormularioProductoState();
}

class _PantallaFormularioProductoState extends State<PantallaFormularioProducto> {
  final _nC = TextEditingController(), _pCC = TextEditingController(), _pVC = TextEditingController(), _sC = TextEditingController();
  final _descC = TextEditingController(); 
  final _descPctC = TextEditingController(); 

  String _imgData = ""; 
  bool _esReinversion = false;
  bool _estaGuardando = false; 
  bool _estaActivo = true; 
  final Map<String, TextEditingController> _stockCtrls = {};
  final Map<String, String> _fotosVariantes = {};
  List<Map<String, dynamic>> _gruposVariantes = [];

  @override
  void initState() {
    super.initState();
    if (widget.producto != null) {
      _estaActivo = (widget.producto!['activo'] ?? 1) == 1;
      _nC.text = widget.producto!['nombre'];
      _pCC.text = widget.producto!['precio_compra'].toString();
      _pVC.text = widget.producto!['precio_venta'].toString();
      _sC.text = widget.producto!['stock'].toString();
      _imgData = widget.producto!['foto_path'] ?? '';
      _descC.text = widget.producto!['descripcion'] ?? '';
      double pct = widget.producto!['descuento']?.toDouble() ?? 0.0;
      _descPctC.text = pct > 0 ? pct.toString() : '';

      if (widget.producto!['variantes'] != null && widget.producto!['variantes'].toString().length > 5) {
        try {
          // 1. Decodificamos el JSON
          final decoded = jsonDecode(widget.producto!['variantes']);
          
          // 2. Lo convertimos a una lista de Mapas real para evitar el crash de tipo
          _gruposVariantes = List<Map<String, dynamic>>.from(
            decoded.map((e) => Map<String, dynamic>.from(e))
          );

          // 3. Limpiamos las opciones para que sean mapas reales también
          for (var grupo in _gruposVariantes) {
            if (grupo['opciones'] != null) {
              grupo['opciones'] = List<Map<String, dynamic>>.from(
                grupo['opciones'].map((o) => Map<String, dynamic>.from(o))
              );
            }
          }
        } catch (e) {
          debugPrint("Error al decodificar: $e");
          _gruposVariantes = [];
        }
      }
      _cargarFotosVariantes(); 
    } else {
      _sC.text = "0"; _pCC.text = ""; _pVC.text = ""; _descPctC.text = "";
    }
  }

  @override
  void dispose() {
    for (var c in _stockCtrls.values) c.dispose();
    super.dispose(); 
  }

  Future<void> _cargarFotosVariantes() async {
    if (widget.producto == null) return;
    final db = await DBHelper.instance.database;
    final fotos = await db.query(
      'fotos_variantes',
      where: 'producto_id = ?',
      whereArgs: [widget.producto!['id']],
    );
    for (var f in fotos) {
      String key = "${f['grupo_index']}_${f['opcion_index']}";
      _fotosVariantes[key] = f['foto_base64'] as String;
    }
    if (mounted) setState(() {});
  }

  Future<String> _capturarImagenBase64(ImageSource source) async {
    try {
      await [Permission.camera, Permission.photos].request();
      XFile? x = await ImagePicker().pickImage(source: source);
      
      if (x != null) {
        Uint8List bytes = await x.readAsBytes();
        String base64Result = "";
        int anchoActual = 600; // Empezamos con tus 600px

        // Preparamos el procesador de imagen
        ui.Codec codec = await ui.instantiateImageCodec(bytes, targetWidth: anchoActual);
        ui.FrameInfo fi = await codec.getNextFrame();
        
        // Bucle inteligente: si el texto Base64 se pasa de 1MB, bajamos el tamaño un poco
        // Esto solo pasará con fotos muy pesadas para asegurar que Firestore las acepte.
        do {
          final ByteData? data = await fi.image.toByteData(format: ui.ImageByteFormat.png);
          if (data == null) break;
          bytes = data.buffer.asUint8List();
          base64Result = base64Encode(bytes);
          
          if (base64Result.length > 1000000) {
            anchoActual -= 50; // Bajamos de 50 en 50 hasta que quepa
            codec = await ui.instantiateImageCodec(bytes, targetWidth: anchoActual);
            fi = await codec.getNextFrame();
          }
        } while (base64Result.length > 1000000 && anchoActual > 100);

        debugPrint("FOTO PROCESADA: ${base64Result.length / 1024} KB (Ancho: $anchoActual px)");
        return base64Result;
      }
    } catch (e) {
      debugPrint("Error imagen: $e");
    }
    return "";
  }

  void _recalcularStockGlobal() {
    if (_gruposVariantes.isNotEmpty) {
      int totalPositivos = 0;
      for (var grupo in _gruposVariantes) {
        for (var opc in grupo['opciones']) {
          int s = opc['stock'] as int;
          if (s > 0) totalPositivos += s; 
        }
      }
      _sC.text = totalPositivos.toString();
    }
  }

  Future<void> _guardar() async {
    if (_estaGuardando || _nC.text.isEmpty) return;

    double pCompra = _pCC.text.trim().isEmpty ? 0 : (double.tryParse(_pCC.text) ?? 0);
    double pVenta = _pVC.text.trim().isEmpty ? 0 : (double.tryParse(_pVC.text) ?? 0);
    double descPct = _descPctC.text.trim().isEmpty ? 0 : (double.tryParse(_descPctC.text) ?? 0);
    int nuevoStock = int.tryParse(_sC.text.trim()) ?? 0;

    if (pCompra < 0 || pVenta < 0 || descPct < 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("⚠️ Valores no pueden ser negativos"), backgroundColor: Colors.orange));
      return;
    }
    if (pVenta <= pCompra && pVenta != 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("⚠️ El precio base de venta debe ser mayor al de compra"), backgroundColor: Colors.red));
      return;
    }

    String variantesJson = jsonEncode(_gruposVariantes);

    int pesoTotal = variantesJson.length + _imgData.length;
    if (pesoTotal > 1900000) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('⚠️ Límite de Base de Datos', style: TextStyle(color: Colors.red)),
          content: const Text('La foto principal es demasiado pesada. Por favor usa una imagen más pequeña.'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ENTENDIDO'))],
        ),
      );
      return;
    }

    setState(() => _estaGuardando = true);

    try {
      final db = await DBHelper.instance.database;
      final prefs = await SharedPreferences.getInstance();
      bool esPremium = prefs.getBool('es_premium') ?? false;

      int stockAnterior = widget.producto != null ? (widget.producto!['stock'] as int) : 0;
      int unidadesCompradas = nuevoStock - stockAnterior;

      if (_esReinversion && unidadesCompradas > 0) {
        double dineroGastado = unidadesCompradas * pCompra;
        Map<String, dynamic> ajusteData = {
          'monto': dineroGastado,
          'fecha': DateTime.now().toIso8601String(),
          'descripcion': 'Compra de $unidadesCompradas x ${_nC.text.trim()} (Reinversión)',
        };
        int idAjuste = await db.insert('ajustes_capital', ajusteData);
        if (esPremium) ServicioNube.guardarAjusteCapitalNube({...ajusteData, 'id': idAjuste});
      }

      String pathFinal = _imgData;
      if (pathFinal.isNotEmpty && pathFinal.length < 500 && File(pathFinal).existsSync()) {
        final bytes = await File(pathFinal).readAsBytes();
        if (bytes.length > 950000) {
          setState(() => _estaGuardando = false);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("⚠️ Imagen muy pesada"), backgroundColor: Colors.red));
          return;
        }
        pathFinal = base64Encode(bytes);
      }

      int ordenActual = widget.producto != null ? (widget.producto!['orden'] ?? 0) : 0;

      final map = {
        'nombre': _nC.text.trim(),
        'activo': _estaActivo ? 1 : 0,
        'descripcion': _descC.text.trim(),
        'variantes': variantesJson, 
        'precio_compra': pCompra,
        'precio_venta': pVenta,
        'stock': nuevoStock,
        'foto_path': pathFinal,
        'orden': ordenActual,
        'descuento': descPct,
      };

      int idActual;
      if (widget.producto == null) {
        idActual = DateTime.now().millisecondsSinceEpoch;
        final mapConId = {...map, 'id': idActual}; // Añadimos el ID al mapa
        await db.insert('productos', mapConId);
        if (!esPremium) {
          int prodsCreados = (prefs.getInt('contador_anuncios_creacion') ?? 0) + 1;
          await prefs.setInt('contador_anuncios_creacion', prodsCreados);
          if (prodsCreados % 3 == 0) ServicioAnuncios.mostrarAnuncioIntersticial(() {});
        }
      } else {
        idActual = widget.producto!['id'];
        await db.update('productos', map, where: 'id = ?', whereArgs: [idActual]);
      }

      await db.delete('fotos_variantes', where: 'producto_id = ?', whereArgs: [idActual]);

      for (var entry in _fotosVariantes.entries) {
        if (entry.value.isEmpty) continue;
        List<String> partes = entry.key.split('_');
        int gIdx = int.parse(partes[0]);
        int oIdx = int.parse(partes[1]);
        
        // OBTENEMOS EL NOMBRE DE LA VARIANTE 👇
        String nombreVar = "";
        try { nombreVar = _gruposVariantes[gIdx]['opciones'][oIdx]['nombre']; } catch(_) {}

        final fotoMap = {
          'producto_id': idActual,
          'grupo_index': gIdx,
          'opcion_index': oIdx,
          'variante_nombre': nombreVar, // 🔥 AHORA SE GUARDA EL NOMBRE
          'foto_base64': entry.value,
        };

        await db.insert('fotos_variantes', fotoMap);
        if (esPremium) ServicioNube.guardarFotoVarianteNube(fotoMap);
      }

      if (esPremium) ServicioNube.guardarProductoNube({...map, 'id': idActual});

      widget.onGuardar();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _estaGuardando = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    bool tieneVariantes = _gruposVariantes.isNotEmpty;
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    double pC = double.tryParse(_pCC.text) ?? 0;
    double pV = double.tryParse(_pVC.text) ?? 0;
    double descPct = double.tryParse(_descPctC.text) ?? 0;
    double precioFinal = pV - (pV * (descPct / 100));
    bool generaPerdida = pV > 0 && precioFinal < pC;

    // 🔥 Helper de diseño moderno para inputs (sin overscroll)
    InputDecoration _decoModerno(String label, IconData icon) {
      return InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: isOscuro ? Colors.white60 : Colors.black54, fontSize: 14),
        prefixIcon: Icon(icon, size: 20, color: isOscuro ? Colors.cyanAccent : Colors.blueAccent),
        filled: true,
        fillColor: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade50,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide(color: isOscuro ? Colors.white10 : Colors.grey.shade300)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: const BorderSide(color: Colors.blueAccent, width: 2)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 16)
      );
    }

    return Scaffold(
      backgroundColor: isOscuro ? const Color(0xFF0A0A0F) : const Color(0xFFF2F4F7),
      appBar: AppBar(
        title: Text(widget.producto == null ? 'Nuevo Producto' : 'Editar Producto', style: const TextStyle(fontWeight: FontWeight.bold)), 
        backgroundColor: isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1), 
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16), // Ligeramente reducido para pantallas estrechas
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children:[
            
            // FOTO PRINCIPAL
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: _estaGuardando ? null : () => showModalBottomSheet(context: context, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))), builder: (c) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children:[
                  ListTile(leading: const Icon(Icons.camera_alt, color: Colors.blue), title: const Text("Tomar Foto"), onTap: () async {
                    Navigator.pop(context);
                    String res = await _capturarImagenBase64(ImageSource.camera);
                    if(res.isNotEmpty && res != "error_size") setState(() => _imgData = res);
                  }),
                  ListTile(leading: const Icon(Icons.photo_library, color: Colors.blue), title: const Text("Elegir de Galería"), onTap: () async {
                    Navigator.pop(context);
                    String res = await _capturarImagenBase64(ImageSource.gallery);
                    if(res.isNotEmpty && res != "error_size") setState(() => _imgData = res);
                  }),
                  if (_imgData.isNotEmpty)
                    ListTile(leading: const Icon(Icons.delete_forever, color: Colors.red), title: const Text("Eliminar Foto", style: TextStyle(color: Colors.red)), onTap: () { setState(() => _imgData = ""); Navigator.pop(context); }),
                ]),
              )),
              child: Container(
                height: 200, width: double.infinity, 
                decoration: BoxDecoration(
                  color: isOscuro ? Colors.white.withOpacity(0.05) : Colors.white, 
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: isOscuro ? Colors.white24 : Colors.blue.withOpacity(0.3), width: 2, style: BorderStyle.solid),
                  image: _imgData.isEmpty ? null : DecorationImage(
                    image: _imgData.length > 500 ? MemoryImage(base64Decode(_imgData)) : FileImage(File(_imgData)) as ImageProvider, fit: BoxFit.cover
                  ),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 5))]
                ),
                child: _imgData.isEmpty 
                  ? Column(mainAxisAlignment: MainAxisAlignment.center, children:[
                      Icon(Icons.add_a_photo_rounded, size: 45, color: isOscuro ? Colors.white38 : Colors.blueAccent), 
                      const SizedBox(height: 12), 
                      Text("Añadir Foto Principal", style: TextStyle(color: isOscuro ? Colors.white38 : Colors.blueAccent, fontWeight: FontWeight.bold))
                    ])
                  : const SizedBox(),
              ),
            ),
            const SizedBox(height: 20),

            // INFORMACIÓN BÁSICA
            Text("Información General", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: isOscuro ? Colors.white : Colors.black87)),
            const SizedBox(height: 12),
            TextField(controller: _nC, decoration: _decoModerno('Nombre del Producto *', Icons.label_outline)),
            const SizedBox(height: 12),
            TextField(controller: _descC, maxLines: 2, decoration: _decoModerno('Descripción (Opcional)', Icons.notes_rounded)),
            const SizedBox(height: 20),

            // PRECIOS
            Text("Precios y Descuentos", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: isOscuro ? Colors.white : Colors.black87)),
            const SizedBox(height: 12),
            Row(
              children:[
                Expanded(child: TextField(controller: _pCC, onChanged: (v)=>setState((){}), keyboardType: TextInputType.number, decoration: _decoModerno('Costo', Icons.monetization_on_outlined))),
                const SizedBox(width: 10),
                Expanded(child: TextField(controller: _pVC, onChanged: (v)=>setState((){}), keyboardType: TextInputType.number, decoration: _decoModerno('Venta', Icons.sell_outlined))),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: TextField(controller: _descPctC, onChanged: (v)=>setState((){}), keyboardType: TextInputType.number, decoration: _decoModerno('Desc %', Icons.percent_rounded))),
                const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                    decoration: BoxDecoration(
                      color: generaPerdida ? Colors.red.withOpacity(0.15) : (descPct > 0 ? Colors.green.withOpacity(0.15) : (isOscuro ? Colors.white10 : Colors.grey.shade200)),
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(color: generaPerdida ? Colors.red : (descPct > 0 ? Colors.green : Colors.transparent))
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text("Precio Final:", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white54 : Colors.black54)),
                        // FittedBox previene la cinta de policia si el número es enorme
                        FittedBox(child: Text("\$${precioFinal.toStringAsFixed(0)}", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: generaPerdida ? Colors.redAccent : (isOscuro ? Colors.white : Colors.black87)))),
                      ],
                    ),
                  )
                )
              ],
            ),
            if (generaPerdida)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text("El descuento genera pérdidas.", style: TextStyle(color: Colors.redAccent.shade100, fontSize: 12, fontWeight: FontWeight.bold))),
                  ],
                ),
              ),

            const SizedBox(height: 25),
            
            // INVENTARIO BÁSICO
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10, offset: const Offset(0, 4))]
              ),
              child: Column(
                children: [
                  Text("Stock Global", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: isOscuro ? Colors.white : Colors.black87)),
                  const SizedBox(height: 15),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children:[
                    Container(
                      decoration: BoxDecoration(color: tieneVariantes ? Colors.grey.withOpacity(0.1) : Colors.red.withOpacity(0.1), shape: BoxShape.circle),
                      child: IconButton(
                        icon: Icon(Icons.remove, color: tieneVariantes ? Colors.grey : Colors.red, size: 25), 
                        onPressed: tieneVariantes ? null : () {
                          int val = int.tryParse(_sC.text) ?? 0;
                          setState(() => _sC.text = (val - 1).toString());
                        }
                      ),
                    ),
                    Flexible( // Flexible previene overscroll
                      child: Container(
                        width: 90, 
                        margin: const EdgeInsets.symmetric(horizontal: 10),
                        child: TextField(
                          controller: _sC, 
                          readOnly: tieneVariantes, 
                          textAlign: TextAlign.center, 
                          keyboardType: const TextInputType.numberWithOptions(signed: true), 
                          style: TextStyle(
                            fontSize: 26, 
                            fontWeight: FontWeight.w900,
                            color: tieneVariantes ? (isOscuro ? Colors.white38 : Colors.grey) : (isOscuro ? Colors.white : Colors.black), 
                          ),
                          decoration: const InputDecoration(border: InputBorder.none, isDense: true),
                        )
                      ),
                    ),
                    Container(
                      decoration: BoxDecoration(color: tieneVariantes ? Colors.grey.withOpacity(0.1) : Colors.green.withOpacity(0.1), shape: BoxShape.circle),
                      child: IconButton(
                        icon: Icon(Icons.add, color: tieneVariantes ? Colors.grey : Colors.green, size: 25), 
                        onPressed: tieneVariantes ? null : () => setState(() => _sC.text = ((int.tryParse(_sC.text) ?? 0) + 1).toString())
                      ),
                    ),
                  ]),
                  if(tieneVariantes)
                    const Padding(padding: EdgeInsets.only(top: 10), child: Text("Bloqueado: El stock se calcula sumando las variantes.", style: TextStyle(fontSize: 11, color: Colors.blueGrey), textAlign: TextAlign.center)),
                ],
              ),
            ),
            
            const SizedBox(height: 15),
            Card(
              elevation: 0,
              color: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade100,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              child: CheckboxListTile(
                title: Text("¿Es compra de reinversión?", style: TextStyle(fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : Colors.black87, fontSize: 14)),
                subtitle: Text("Descuenta el dinero del capital", style: TextStyle(color: isOscuro ? Colors.white54 : Colors.black54, fontSize: 12)),
                value: _esReinversion, 
                activeColor: Colors.blueAccent,
                onChanged: (v) => setState(() => _esReinversion = v!)
              ),
            ),
            const SizedBox(height: 25),

            // VARIANTES
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children:[
                Text("Variantes", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: isOscuro ? Colors.white : Colors.black87)),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: isOscuro ? Colors.blue.withOpacity(0.2) : Colors.blue.shade50, foregroundColor: isOscuro ? Colors.cyanAccent : Colors.blue.shade900, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                  onPressed: () {
                    setState(() {
                      _gruposVariantes.add({
                        'grupo': '', 
                        'opciones': <Map<String, dynamic>>[
                          <String, dynamic>{'nombre': '', 'stock': 1, 'foto_path': '', 'activo': true}
                        ]
                      });
                      _recalcularStockGlobal();
                    });
                  },
                  icon: const Icon(Icons.add, size: 18), label: const Text("Añadir Grupo")
                )
              ],
            ),
            const SizedBox(height: 10),
            
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _gruposVariantes.length,
              itemBuilder: (ctx, gIndex) {
                var grupo = _gruposVariantes[gIndex];
                List opciones = grupo['opciones'];

                return Card(
                  elevation: 2,
                  margin: const EdgeInsets.only(bottom: 20),
                  clipBehavior: Clip.antiAlias,
                  color: Theme.of(context).cardColor,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: isOscuro ? Colors.white10 : Colors.transparent)),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(color: isOscuro ? Colors.cyanAccent.withOpacity(0.1) : Colors.blue.withOpacity(0.08)),
                        child: Row(
                          children: [
                            Icon(Icons.category_rounded, color: isOscuro ? Colors.cyanAccent : Colors.blue, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextFormField(
                                initialValue: grupo['grupo'],
                                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: isOscuro ? Colors.white : Colors.blue.shade900),
                                decoration: InputDecoration(hintText: "Ej: Color, Talla...", hintStyle: TextStyle(color: isOscuro ? Colors.white38 : Colors.blue.shade200), border: InputBorder.none, isDense: true),
                                onChanged: (val) => grupo['grupo'] = val,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                              onPressed: () {
                                setState(() { 
                                  _gruposVariantes.removeAt(gIndex); 
                                  _fotosVariantes.removeWhere((key, value) => key.startsWith("${gIndex}_"));
                                  _recalcularStockGlobal(); 
                                });
                              }
                            )
                          ],
                        ),
                      ),
                      
                      Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          children: [
                            ...opciones.asMap().entries.map((entry) {
                              int oIndex = entry.key;
                              var o = entry.value;
                              String key = "${gIndex}_$oIndex";
                              String fotoBase64 = _fotosVariantes[key] ?? '';
                              _stockCtrls.putIfAbsent(key, () => TextEditingController(text: "${o['stock']}"));
                              
                              // 🔥 VERIFICADOR DE VARIANTE AGOTADA
                              bool varianteAgotada = (o['stock'] as int? ?? 0) <= 0;
                              
                              return Container(
                                padding: const EdgeInsets.all(10),
                                margin: const EdgeInsets.only(bottom: 12),
                                decoration: BoxDecoration(
                                  // 🔥 FONDO Y BORDES ROJOS SI ESTÁ AGOTADA
                                  color: varianteAgotada ? Colors.red.withOpacity(0.05) : (isOscuro ? Colors.white.withOpacity(0.03) : Colors.grey.shade50), 
                                  borderRadius: BorderRadius.circular(15), 
                                  border: Border.all(
                                    color: varianteAgotada ? Colors.red : (isOscuro ? Colors.white10 : Colors.grey.shade200),
                                    width: varianteAgotada ? 1.5 : 1.0 // Un poco más grueso si está en 0
                                  )
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    InkWell(
                                      onTap: () async {
                                        showModalBottomSheet(
                                          context: context,
                                          builder: (c) => SafeArea(
                                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                                              ListTile(leading: const Icon(Icons.camera_alt), title: const Text("Cámara"), onTap: () async {
                                                Navigator.pop(context);
                                                String res = await _capturarImagenBase64(ImageSource.camera);
                                                if (res.isNotEmpty && res != "error_size") setState(() => _fotosVariantes[key] = res); 
                                              }),
                                              ListTile(leading: const Icon(Icons.photo_library), title: const Text("Galería"), onTap: () async {
                                                Navigator.pop(context);
                                                String res = await _capturarImagenBase64(ImageSource.gallery);
                                                if (res.isNotEmpty && res != "error_size") setState(() => _fotosVariantes[key] = res); 
                                              }),
                                              if (fotoBase64.isNotEmpty)
                                                ListTile(leading: const Icon(Icons.delete_forever, color: Colors.red), title: const Text("Eliminar foto", style: TextStyle(color: Colors.red)), onTap: () { setState(() => _fotosVariantes[key] = ''); Navigator.pop(context); }),
                                            ]),
                                          ),
                                        );
                                      },
                                      child: Container(
                                        width: 55, height: 55,
                                        decoration: BoxDecoration(color: isOscuro ? Colors.black26 : Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: isOscuro ? Colors.white12 : Colors.grey.shade300)),
                                        clipBehavior: Clip.antiAlias,
                                        child: fotoBase64.isEmpty
                                            ? Icon(Icons.add_a_photo_rounded, color: isOscuro ? Colors.white38 : Colors.grey, size: 24)
                                            // 🔥 USO INTELIGENTE DEL CACHÉ PARA EVITAR PARPADEO
                                            : Builder(
                                                builder: (context) {
                                                  Uint8List bytes;
                                                  if (_inventarioImageCache.containsKey(fotoBase64)) {
                                                    bytes = _inventarioImageCache[fotoBase64]!;
                                                  } else {
                                                    bytes = base64Decode(fotoBase64);
                                                    if (_inventarioImageCache.length > 200) _inventarioImageCache.clear();
                                                    _inventarioImageCache[fotoBase64] = bytes;
                                                  }
                                                  return Image.memory(
                                                    bytes, 
                                                    fit: BoxFit.cover,
                                                    gaplessPlayback: true, // Crucial anti-parpadeo
                                                  );
                                                }
                                              ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    
                                    // EXPANDED PARA EVITAR OVERFLOW CINTA DE POLICIA
                                    Expanded(
                                      child: Column(
                                        children: [
                                          TextFormField(
                                            initialValue: o['nombre'],
                                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                            decoration: InputDecoration(
                                              hintText: "Ej: Rojo", 
                                              isDense: true, 
                                              contentPadding: const EdgeInsets.symmetric(vertical: 5),
                                              border: const UnderlineInputBorder(),
                                              errorText: varianteAgotada ? 'Sin stock' : null,
                                              errorStyle: const TextStyle(height: 0.5, fontSize: 10)
                                            ),
                                            onChanged: (val) => o['nombre'] = val,
                                          ),
                                          const SizedBox(height: 8),
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.start,
                                            children: [
                                              Container(
                                                decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                                                child: IconButton(icon: const Icon(Icons.remove, color: Colors.red, size: 18), constraints: const BoxConstraints(), padding: const EdgeInsets.all(4), onPressed: () {
                                                  setState(() { o['stock']--; _stockCtrls[key]?.text = "${o['stock']}"; _recalcularStockGlobal(); });
                                                }),
                                              ),
                                              // FLEXIBLE PARA EVITAR CINTA DE POLICIA
                                              Flexible(
                                                child: ConstrainedBox(
                                                  constraints: const BoxConstraints(maxWidth: 50, minWidth: 30),
                                                  child: TextField(
                                                    controller: _stockCtrls[key],
                                                    keyboardType: const TextInputType.numberWithOptions(signed: true),
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: varianteAgotada ? Colors.red : null),
                                                    decoration: const InputDecoration(border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero),
                                                    onChanged: (val) { o['stock'] = int.tryParse(val) ?? 0; _recalcularStockGlobal(); },
                                                  ),
                                                ),
                                              ),
                                              Container(
                                                decoration: BoxDecoration(color: Colors.green.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                                                child: IconButton(icon: const Icon(Icons.add, color: Colors.green, size: 18), constraints: const BoxConstraints(), padding: const EdgeInsets.all(4), onPressed: () {
                                                  setState(() { o['stock']++; _stockCtrls[key]?.text = "${o['stock']}"; _recalcularStockGlobal(); });
                                                }),
                                              ),
                                            ],
                                          )
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                    
                                    Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: Icon((o['activo'] ?? true) ? Icons.visibility : Icons.visibility_off, color: (o['activo'] ?? true) ? Colors.blue : Colors.grey, size: 20),
                                          padding: const EdgeInsets.only(bottom: 5),
                                          constraints: const BoxConstraints(),
                                          onPressed: () => setState(() => o['activo'] = !(o['activo'] ?? true))
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.close_rounded, color: Colors.grey, size: 20), 
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          onPressed: () {
                                            setState(() { opciones.removeAt(oIndex); _fotosVariantes[key] = ''; _recalcularStockGlobal(); });
                                          }
                                        ),
                                      ],
                                    )
                                  ],
                                ),
                              );
                            }),

                            TextButton.icon(
                              style: TextButton.styleFrom(foregroundColor: isOscuro ? Colors.cyanAccent : Colors.blue),
                              onPressed: () {
                                setState(() {
                                  opciones.add(<String, dynamic>{'nombre': '', 'stock': 1, 'foto_path': '', 'activo': true});
                                  _recalcularStockGlobal();
                                });
                              },
                              icon: const Icon(Icons.add_circle_outline, size: 20),
                              label: const Text("Añadir Opción", style: TextStyle(fontWeight: FontWeight.bold)),
                            )
                          ],
                        ),
                      )
                    ],
                  ),
                );
              },
            ),
            
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 5, vertical: 10),
              title: const Text("Producto Activo", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              subtitle: const Text("Mostrar en catálogo web y listado de ventas."),
              value: _estaActivo,
              activeColor: Colors.greenAccent.shade700,
              onChanged: (v) => setState(() => _estaActivo = v),
            ),
            
            const SizedBox(height: 10),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: generaPerdida ? Colors.redAccent : const Color(0xFF00C853), 
                minimumSize: const Size(double.infinity, 60), 
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                elevation: 4
              ), 
              onPressed: _estaGuardando ? null : _guardar,
              child: _estaGuardando 
                ? const CircularProgressIndicator(color: Colors.white)
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(generaPerdida ? Icons.warning_amber_rounded : Icons.save_rounded, color: Colors.white),
                      const SizedBox(width: 10),
                      Text(generaPerdida ? "GUARDAR CON PÉRDIDAS" : "GUARDAR CAMBIOS", style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 1)),
                    ],
                  ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

// 🔥 CONVERTIDO A STATEFUL PARA PODER CARGAR FOTOS DESDE LA BD
class PantallaDetalleProducto extends StatefulWidget {
  final Map<String, dynamic> producto;
  const PantallaDetalleProducto({super.key, required this.producto});

  @override
  State<PantallaDetalleProducto> createState() => _PantallaDetalleProductoState();
}

class _PantallaDetalleProductoState extends State<PantallaDetalleProducto> {
  final Map<String, String> _fotosVariantes = {};
  List<dynamic> _gruposVariantes = [];
  late Map<String, dynamic> _prodLocal; // Almacenará el producto completo

  @override
  void initState() {
    super.initState();
    // Inicializamos con los datos ligeros para evitar parpadeos
    _prodLocal = Map<String, dynamic>.from(widget.producto); 
    _cargarDatos();
  }

  Future<void> _cargarDatos() async {
    final db = await DBHelper.instance.database;

    // 🔥 1. Consultamos el producto COMPLETO (trae foto_path y variantes)
    final resProd = await db.query('productos', where: 'id = ?', whereArgs: [widget.producto['id']]);
    if (resProd.isNotEmpty) {
      _prodLocal = Map<String, dynamic>.from(resProd.first);
    }

    // 🔥 2. Decodificamos las variantes desde el producto completo
    if (_prodLocal['variantes'] != null && _prodLocal['variantes'].toString().length > 5) {
      try {
        var dec = jsonDecode(_prodLocal['variantes']);
        if (dec.isNotEmpty && !dec[0].containsKey('grupo')) {
          _gruposVariantes = [{'grupo': 'Opciones', 'opciones': dec}];
        } else {
          _gruposVariantes = dec;
        }
      } catch(e) {}
    }

    // 3. Traemos las fotos de las variantes
    final fotos = await db.query('fotos_variantes', where: 'producto_id = ?', whereArgs: [widget.producto['id']]);
    for (var f in fotos) {
      _fotosVariantes["${f['grupo_index']}_${f['opcion_index']}"] = f['foto_base64'] as String;
    }
    
    if (mounted) setState((){});
  }

  @override
  Widget build(BuildContext context) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    
    // Usamos _prodLocal en lugar de widget.producto
    double costo = (_prodLocal['precio_compra'] as num?)?.toDouble() ?? 0.0;
    double ventaOriginal = (_prodLocal['precio_venta'] as num?)?.toDouble() ?? 0.0;
    double descuentoPct = (_prodLocal['descuento'] ?? 0).toDouble();
    
    double ventaReal = descuentoPct > 0 ? ventaOriginal - (ventaOriginal * descuentoPct / 100) : ventaOriginal;
    double ganancia = ventaReal - costo;
    
    double markup = costo > 0 ? (ganancia / costo) * 100 : 0; 
    double margen = ventaReal > 0 ? (ganancia / ventaReal) * 100 : 0; 
    int stock = _prodLocal['stock'] ?? 0;

    return Scaffold(
      backgroundColor: isOscuro ? const Color(0xFF0A0A0F) : const Color(0xFFF8F9FA),
      body: CustomScrollView(
        slivers:[
          SliverAppBar(
            expandedHeight: 350,
            pinned: true,
            backgroundColor: isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1),
            flexibleSpace: FlexibleSpaceBar(
              title: Text(_prodLocal['nombre'] ?? 'Producto', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, shadows: [Shadow(blurRadius: 10, color: Colors.black54)])),
              background: Hero(tag: 'prod_${_prodLocal['id']}', child: _construirImagen(_prodLocal['foto_path'] ?? '')),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children:[
                  if (descuentoPct > 0)
                    Container(
                      margin: const EdgeInsets.only(bottom: 15),
                      padding: const EdgeInsets.all(12),
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: isOscuro ? const Color.fromARGB(255, 226, 85, 75).withOpacity(0.15) : Colors.red.shade100, 
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: isOscuro ? Colors.red.withOpacity(0.3) : Colors.transparent)
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.local_offer, color: isOscuro ? Colors.redAccent : Colors.red),
                          const SizedBox(width: 10),
                          Expanded(child: Text("Producto con $descuentoPct% de descuento. El precio original era \$${ventaOriginal.toStringAsFixed(2)}", 
                            style: TextStyle(color: isOscuro ? Colors.redAccent.shade100 : Colors.red, fontWeight: FontWeight.bold))),
                        ],
                      )
                    ),
                  
                  _cardPrincipal(costo, ventaReal, ganancia, isOscuro, context),
                  const SizedBox(height: 15),
                  _cardRentabilidad(markup, margen),
                  const SizedBox(height: 25),
                  
                  Text("Estado del Inventario", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white70 : const Color(0xFF2C3E50))),
                  const SizedBox(height: 12),
                  _infoTile(
                    context: context,
                    icon: Icons.inventory_2_rounded, 
                    color: stock > 5 ? (isOscuro ? Colors.cyanAccent : Colors.blue) : Colors.orange, 
                    label: "Stock General", 
                    value: "$stock unidades", 
                    subtext: stock <= 0 ? "¡No hay stock disponible!" : "Disponible para la venta",
                    isOscuro: isOscuro
                  ),
                  
                  const SizedBox(height: 25),

                  if (_gruposVariantes.isNotEmpty) ...[
                    Text("Variantes y Existencias", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white70 : const Color(0xFF2C3E50))),
                    const SizedBox(height: 12),
                    ..._gruposVariantes.asMap().entries.map((gEntry) {
                      int gIndex = gEntry.key;
                      var g = gEntry.value;
                      return Card(
                        elevation: 2,
                        margin: const EdgeInsets.only(bottom: 15),
                        color: isOscuro ? Colors.white.withOpacity(0.05) : Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: BorderSide(color: isOscuro ? Colors.white10 : Colors.transparent)),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: double.infinity,
                              color: isOscuro ? Colors.blue.withOpacity(0.1) : Colors.blue.shade50,
                              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
                              child: Text(g['grupo'].toString().toUpperCase(), style: TextStyle(fontWeight: FontWeight.bold, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1))),
                            ),
                            ListView.separated(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: (g['opciones'] as List).length,
                              separatorBuilder: (c, i) => Divider(height: 1, color: isOscuro ? Colors.white10 : Colors.black12),
                              itemBuilder: (c, oIndex) {
                                var o = g['opciones'][oIndex];
                                int s = o['stock'] ?? 0;
                                String foto = _fotosVariantes["${gIndex}_$oIndex"] ?? "";

                                return ListTile(
                                  leading: Container(
                                    width: 45, height: 45,
                                    decoration: BoxDecoration(color: isOscuro ? Colors.white10 : Colors.grey.shade200, borderRadius: BorderRadius.circular(8)),
                                    clipBehavior: Clip.antiAlias,
                                    child: foto.length > 500 
                                      ? Image.memory(base64Decode(foto), fit: BoxFit.cover)
                                      : Icon(Icons.style, color: isOscuro ? Colors.white24 : Colors.grey),
                                  ),
                                  title: Text(o['nombre'], style: TextStyle(fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : Colors.black87)),
                                  trailing: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: s < 0 ? Colors.red.withOpacity(0.1) : (s == 0 ? Colors.orange.withOpacity(0.1) : Colors.green.withOpacity(0.1)),
                                      borderRadius: BorderRadius.circular(10)
                                    ),
                                    child: Text("Cant: $s", style: TextStyle(fontWeight: FontWeight.bold, color: s < 0 ? Colors.redAccent : (s == 0 ? Colors.orange : Colors.greenAccent))),
                                  ),
                                );
                              },
                            )
                          ],
                        ),
                      );
                    })
                  ],
                  const SizedBox(height: 100),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cardPrincipal(double costo, double venta, double ganancia, bool isOscuro, BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor, 
        borderRadius: BorderRadius.circular(20), 
        border: Border.all(color: isOscuro ? Colors.white10 : Colors.transparent),
        boxShadow:[BoxShadow(color: Colors.black.withOpacity(isOscuro ? 0.2 : 0.05), blurRadius: 15, offset: const Offset(0, 5))]
      ),
      child: Column(
        children:[
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _columnaPrecio("Costo Compra", costo, isOscuro ? Colors.white38 : Colors.grey[700]!, isOscuro), 
            Container(width: 1, height: 40, color: isOscuro ? Colors.white10 : Colors.grey[200]), 
            _columnaPrecio("Precio Final", venta, isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1), isOscuro)
          ]),
          Padding(padding: const EdgeInsets.symmetric(vertical: 15), child: Divider(color: isOscuro ? Colors.white10 : Colors.black12)),
          Row(
            children:[
              CircleAvatar(
                backgroundColor: ganancia >= 0 ? (isOscuro ? Colors.green.withOpacity(0.1) : const Color(0xFFE8F5E9)) : Colors.red.withOpacity(0.1), 
                child: Icon(ganancia >= 0 ? Icons.trending_up : Icons.trending_down, color: ganancia >= 0 ? Colors.greenAccent : Colors.redAccent)
              ),
              const SizedBox(width: 15),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children:[
                Text("Ganancia Neta por unidad", style: TextStyle(color: isOscuro ? Colors.white38 : Colors.grey, fontSize: 13)), 
                Text("\$${ganancia.toStringAsFixed(2)}", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: ganancia >= 0 ? Colors.greenAccent : Colors.redAccent))
              ]),
            ],
          )
        ],
      ),
    );
  }

  Widget _columnaPrecio(String label, double monto, Color color, bool isOscuro) {
    return Column(children:[
      Text(label, style: TextStyle(color: isOscuro ? Colors.white38 : Colors.grey, fontSize: 12)), 
      const SizedBox(height: 4), 
      Text("\$${monto.toStringAsFixed(2)}", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color))
    ]);
  }

  Widget _infoTile({required BuildContext context, required IconData icon, required Color color, required String label, required String value, required String subtext, required bool isOscuro}) {
    return Container(
      padding: const EdgeInsets.all(15), 
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor, 
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: isOscuro ? Colors.white10 : Colors.transparent)
      ), 
      child: Row(children:[
        Icon(icon, color: color, size: 30), 
        const SizedBox(width: 15), 
        Column(crossAxisAlignment: CrossAxisAlignment.start, children:[
          Text(label, style: TextStyle(color: isOscuro ? Colors.white38 : Colors.grey, fontSize: 12)), 
          Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : Colors.black)), 
          Text(subtext, style: TextStyle(color: color, fontSize: 11))
        ])
      ])
    );
  }

  Widget _cardRentabilidad(double markup, double margen) {
    return Container(
      width: double.infinity, padding: const EdgeInsets.all(15), 
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: margen >= 40 
            ? [const Color(0xFF11998e), const Color(0xFF38ef7d)] 
            : (margen >= 0 ? [const Color(0xFF0D47A1), const Color(0xFF42A5F5)] : [Colors.red.shade900, Colors.redAccent])
        ), 
        borderRadius: BorderRadius.circular(15)
      ), 
      child: Column(
        children:[
          const Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.workspace_premium, color: Colors.white, size: 24), SizedBox(width: 8), Text("MÉTRICAS DE RENTABILIDAD", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))]),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Column(
                children: [
                  const Text("MARKUP", style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
                  Text("${markup.toStringAsFixed(1)}%", style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                  const Text("Sobre el costo", style: TextStyle(color: Colors.white70, fontSize: 10)),
                ],
              ),
              Container(width: 1, height: 40, color: Colors.white30),
              Column(
                children: [
                  const Text("MARGEN NETO", style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
                  Text("${margen.toStringAsFixed(1)}%", style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                  const Text("Sobre la venta", style: TextStyle(color: Colors.white70, fontSize: 10)),
                ],
              )
            ],
          )
        ]
      )
    );
  }

  Widget _construirImagen(String data) {
    if (data.isEmpty) return Container(color: Colors.grey[300], child: const Icon(Icons.image_not_supported, size: 100, color: Colors.white));
    try {
      if (data.length > 500) {
        return Image.memory(base64Decode(data), fit: BoxFit.cover, color: Colors.black.withOpacity(0.2), colorBlendMode: BlendMode.darken);
      }
      return Image.file(File(data), fit: BoxFit.cover, color: Colors.black.withOpacity(0.2), colorBlendMode: BlendMode.darken);
    } catch (e) {
      return Container(color: Colors.red[100], child: const Icon(Icons.broken_image, size: 100));
    }
  }
}

class ImagenInventario extends StatefulWidget {
  final int id;
  const ImagenInventario({super.key, required this.id});

  @override
  State<ImagenInventario> createState() => _ImagenInventarioState();
}

class _ImagenInventarioState extends State<ImagenInventario> {
  Future<String?>? _fotoFuture;

  @override
  void initState() {
    super.initState();
    _fotoFuture = _cargarFoto();
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
      future: _fotoFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return Container(color: Colors.grey.shade200, child: const Icon(Icons.image, color: Colors.grey, size: 30));
        }

        String data = snapshot.data!;
        try {
          if (data.length > 500) {
            Uint8List bytes;
            if (_inventarioImageCache.containsKey(data)) {
              bytes = _inventarioImageCache[data]!;
            } else {
              bytes = base64Decode(data);
              if (_inventarioImageCache.length > 200) _inventarioImageCache.clear();
              _inventarioImageCache[data] = bytes;
            }
            return Image.memory(bytes, fit: BoxFit.cover, width: double.infinity, height: double.infinity, gaplessPlayback: true, errorBuilder: (c,e,s) => const Icon(Icons.broken_image));
          }
          return Image.file(File(data), fit: BoxFit.cover, width: double.infinity, height: double.infinity, gaplessPlayback: true, errorBuilder: (c,e,s) => const Icon(Icons.broken_image));
        } catch (e) {
          return const Icon(Icons.broken_image, color: Colors.red);
        }
      }
    );
  }
}