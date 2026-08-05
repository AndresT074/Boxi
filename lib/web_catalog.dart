import 'dart:ui'; 
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb; // Nuevo
import 'package:universal_html/js.dart' as js; 
import 'package:http/http.dart' as http; 
import 'package:firebase_database/firebase_database.dart';

// 🔥 FUNCIÓN DE COMPRESIÓN DE ANCHO DE BANDA PARA LA WEB
String optimizarUrlCloudinary(String urlOriginal, {int width = 400}) {
  if (urlOriginal.isEmpty) return urlOriginal;
  if (!urlOriginal.contains('cloudinary.com') || urlOriginal.contains('q_auto')) {
    return urlOriginal;
  }
  return urlOriginal.replaceFirst(
    '/upload/', 
    '/upload/c_limit,w_$width,q_auto,f_auto/'
  );
}

class CatalogoWeb extends StatefulWidget {
  final String adminId;
  const CatalogoWeb({super.key, required this.adminId});

  @override
  State<CatalogoWeb> createState() => _CatalogoWebState();
}

class _CatalogoWebState extends State<CatalogoWeb> {
  bool mostrarBannerBoxi = true;
  Map<String, Map<String, dynamic>> carrito = {};
  String busqueda = "";
  bool estaBuscando = false;
  final TextEditingController _searchCtrl = TextEditingController();
  
  List<Map<String, dynamic>> _productos = [];
  List<String> _categoriasOrdenadas = [];
  Map<String, dynamic>? _negocioData;
  String? adminEmail;
  bool _estaCargando = true; 
  bool _enviandoPedido = false;

  // 🔥 CONTROLADORES DE ANIMACIÓN Y SCROLL
  final ScrollController _mainScrollCtrl = ScrollController();
  final ScrollController _categoryBarScrollCtrl = ScrollController(); 
  final Map<String, GlobalKey> _categoriaKeys = {};
  String _categoriaSeleccionada = "";
  Timer? _tickerTimer;
  bool _userIsDragging = false; // 🔥 Pausa el movimiento automático mientras el usuario arrastra

  @override
  void initState() {
    super.initState();
    _iniciarCargaProgresiva();
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
    _searchCtrl.dispose();
    _mainScrollCtrl.dispose();
    _categoryBarScrollCtrl.dispose();
    super.dispose();
  }

  String _fmtDesc(dynamic val) {
    double d = (val as num? ?? 0).toDouble();
    if (d <= 0) return "0";
    return d == d.roundToDouble() ? d.toInt().toString() : d.toStringAsFixed(1);
  }

  // 🔥 Movimiento Ultra Fluido a 60 FPS (16 ms)
  void _iniciarTickerCategorias() {
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (_categoryBarScrollCtrl.hasClients && !_estaCargando && !_userIsDragging) {
        double nextOffset = _categoryBarScrollCtrl.offset + 0.4; // Micro-paso imperceptible
        if (nextOffset >= _categoryBarScrollCtrl.position.maxScrollExtent) {
          _categoryBarScrollCtrl.jumpTo(0);
        } else {
          _categoryBarScrollCtrl.jumpTo(nextOffset);
        }
      }
    });
  }

  Future<void> _iniciarCargaProgresiva() async {
    setState(() => _estaCargando = true);
    
    debugPrint("🚀 [DIAGNOSIS] Iniciando carga progresiva...");
    debugPrint("🚀 [DIAGNOSIS] ID del Admin recibido en la URL: '${widget.adminId}'");

    if (widget.adminId.isEmpty || widget.adminId == "null") {
      debugPrint("❌ [DIAGNOSIS] ERROR: El adminId está vacío o es null. La URL no está pasando el ID correctamente.");
      setState(() => _estaCargando = false);
      return;
    }

    try {
      DatabaseReference ref = FirebaseDatabase.instance.ref("catalogos_web/${widget.adminId}");
      debugPrint("🚀 [DIAGNOSIS] Consultando ruta en RTDB: catalogos_web/${widget.adminId}");
      
      final snapshot = await ref.get();
      debugPrint("🚀 [DIAGNOSIS] ¿Existe el nodo en la base de datos?: ${snapshot.exists}");

      if (snapshot.exists) {
        Map<String, dynamic> datos = {};
        final rawValue = snapshot.value;
        debugPrint("🚀 [DIAGNOSIS] Tipo de dato recibido de Firebase: ${rawValue.runtimeType}");

        if (rawValue is String) {
          datos = jsonDecode(rawValue);
        } else if (rawValue is Map) {
          datos = Map<String, dynamic>.from(rawValue);
        }
        
        debugPrint("🚀 [DIAGNOSIS] Claves principales encontradas en el JSON: ${datos.keys.toList()}");

        if (datos['negocio'] != null) {
          _negocioData = Map<String, dynamic>.from(datos['negocio']);
          adminEmail = _negocioData?['email'];
          debugPrint("🚀 [DIAGNOSIS] Negocio cargado: ${_negocioData?['nombre_negocio']}");
        }

        if (datos['categorias'] != null) {
          List<Map<String, dynamic>> listaCats = [];
          
          // 🔥 Evitar crasheo si Firebase RTDB metió un 'null' en la lista
          for (var e in (datos['categorias'] as List)) {
            if (e != null) {
              listaCats.add(Map<String, dynamic>.from(e));
            }
          }
          listaCats.sort((a, b) {
            int oA = int.tryParse(a['orden']?.toString() ?? '0') ?? 0;
            int oB = int.tryParse(b['orden']?.toString() ?? '0') ?? 0;
            return oA.compareTo(oB);
          });
          _categoriasOrdenadas = listaCats.map((c) => c['nombre'].toString()).toList();
          for (var cat in _categoriasOrdenadas) {
            _categoriaKeys[cat] = GlobalKey();
          }
          _categoriaKeys['Otros Productos'] = GlobalKey();
          debugPrint("🚀 [DIAGNOSIS] Categorías ordenadas cargadas: $_categoriasOrdenadas");
        }

        if (datos['productos'] != null) {
          _productos = (datos['productos'] as List)
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          debugPrint("🚀 [DIAGNOSIS] Cantidad de productos cargados: ${_productos.length}");
        }

        setState(() {
          _estaCargando = false;
        });
        _iniciarTickerCategorias(); // 🔥 Arranca el tren infinito al cargar las categorías
      } else {
        debugPrint("⚠️ [DIAGNOSIS] No se encontraron datos en esa ruta de Realtime Database (snapshot.exists es falso).");
        setState(() => _estaCargando = false);
      }

      if (kIsWeb) {
        try { js.context.callMethod('quitarLoader'); } catch (_) {}
      }

    } catch (e, stack) {
      debugPrint("❌ [DIAGNOSIS] ERROR CRÍTICO CAPTURADO: $e");
      debugPrint("❌ [DIAGNOSIS] DETALLE DEL CRASH: $stack");
      if (kIsWeb) {
        try { js.context.callMethod('quitarLoader'); } catch (_) {}
      }
      if (mounted) setState(() => _estaCargando = false);
    }
  }

  double get totalPedido => carrito.values.fold(
      0, (sum, item) => sum + ((item['precio_final'] as num) * (item['cantidad'] as num)));

  void _actualizarCantidad(Map<String, dynamic> producto, int cambio, {String? cartId, Map<String, dynamic>? variantData}) {
    setState(() {
      String idKey = cartId ?? producto['id'].toString();

      double precioBase = (producto['precio_venta'] as num).toDouble();
      double descPct = (producto['descuento'] ?? 0).toDouble();
      double precioCalculado = precioBase - (precioBase * (descPct / 100));

      if (!carrito.containsKey(idKey) && cambio > 0) {
        carrito[idKey] = {
          'id': producto['id'],
          'nombre': variantData != null ? variantData['nombre'] : producto['nombre'],
          'precio_venta': precioBase,
          'precio_final': precioCalculado,
          'descuento': descPct,
          'cantidad': cambio,
          if (variantData != null) 'es_variante': true,
          if (variantData != null) 'g_index': variantData['g_index'],
          if (variantData != null) 'o_index': variantData['o_index'],
        };
      } else if (carrito.containsKey(idKey)) {
        carrito[idKey]!['cantidad'] += cambio;
        if (carrito[idKey]!['cantidad'] <= 0) carrito.remove(idKey);
      }
    });
  }

  // 🔥 Centrado perfecto relativo a la posición actual del tren infinito
  void _scrollToCategoria(String catNombre, int catIdx) {
    setState(() => _categoriaSeleccionada = catNombre);

    if (_categoryBarScrollCtrl.hasClients) {
      double currentOffset = _categoryBarScrollCtrl.offset;
      List<String> todasLasCategorias = List.from(_categoriasOrdenadas);
      if (_productos.any((p) => p['categoria'] == null || p['categoria'].toString().isEmpty)) {
        todasLasCategorias.add("Otros Productos");
      }

      int totalCats = todasLasCategorias.length;
      if (totalCats <= 0) totalCats = 1;

      double aproxItemWidth = 145.0; // Ancho aproximado de cada chip
      int currentItemIdx = (currentOffset / aproxItemWidth).round();
      int currentCycle = (currentItemIdx / totalCats).floor();
      
      int targetIdx = (currentCycle * totalCats) + catIdx;
      
      // Si la meta quedó atrás de la posición actual del scroll, avanzamos al ciclo más cercano
      if ((targetIdx * aproxItemWidth) < currentOffset - (aproxItemWidth * 2)) {
        targetIdx += totalCats;
      }

      double targetOffset = (targetIdx * aproxItemWidth) - (MediaQuery.of(context).size.width / 2) + (aproxItemWidth / 2);
      if (targetOffset < 0) targetOffset = 0;

      _categoryBarScrollCtrl.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    }

    // 2. Desliza suavemente la página principal hasta la sección de la categoría
    final key = _categoriaKeys[catNombre];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  // 🔥 Barra Deslizante con Arrastre Libre y Tren Infinito
  Widget _barraCategoriasHorizontal() {
    if (_categoriasOrdenadas.isEmpty || _estaCargando) return const SizedBox.shrink();

    List<String> todasLasCategorias = List.from(_categoriasOrdenadas);
    if (_productos.any((p) => p['categoria'] == null || p['categoria'].toString().isEmpty)) {
      todasLasCategorias.add("Otros Productos");
    }

    return Listener(
      // 🔥 Al tocar o hacer clic, pausa el movimiento automático para dejar arrastrar libremente
      onPointerDown: (_) => _userIsDragging = true,
      onPointerUp: (_) {
        // 🔥 2 segundos después de soltar, reanuda el movimiento automático suave
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) _userIsDragging = false;
        });
      },
      child: Container(
        height: 48,
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: ScrollConfiguration(
          behavior: MyCustomScrollBehavior(),
          child: ListView.builder(
            controller: _categoryBarScrollCtrl,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: 10000,
            itemBuilder: (context, index) {
              String cat = todasLasCategorias[index % todasLasCategorias.length];
              bool esSeleccionada = _categoriaSeleccionada == cat;

              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  onTap: () => _scrollToCategoria(cat, index % todasLasCategorias.length), 
                  borderRadius: BorderRadius.circular(25),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      gradient: esSeleccionada
                          ? const LinearGradient(colors: [Color(0xFF0D47A1), Color(0xFF1976D2)])
                          : null,
                      color: esSeleccionada ? null : Colors.white,
                      borderRadius: BorderRadius.circular(25),
                      border: Border.all(
                        color: esSeleccionada ? Colors.transparent : Colors.grey.shade300,
                      ),
                      boxShadow: [
                        if (esSeleccionada)
                          BoxShadow(
                            color: const Color(0xFF0D47A1).withOpacity(0.3),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          )
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.category_rounded,
                          size: 15,
                          color: esSeleccionada ? Colors.white : const Color(0xFF0D47A1),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          cat,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: esSeleccionada ? FontWeight.w900 : FontWeight.bold,
                            color: esSeleccionada ? Colors.white : Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _irABoxi() async {
    const url = 'https://play.google.com/store/apps/details?id=com.andres074.boxi';
    final Uri uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

 @override
  Widget build(BuildContext context) {
    final docsFiltrados = _productos.where((p) {
      bool estaActivo = p['activo'] == null || p['activo'] == true || p['activo'] == 1;
      return estaActivo && p['nombre'].toString().toLowerCase().contains(busqueda.toLowerCase());
    }).toList();
    // 🔥 Agrupar productos
    Map<String, List<Map<String, dynamic>>> grupos = {};
    for (String cat in _categoriasOrdenadas) grupos[cat] = [];
    grupos['_sin_categoria'] = [];

    for (var p in docsFiltrados) {
      String? cat = p['categoria'];
      if (cat != null && grupos.containsKey(cat)) {
        grupos[cat]!.add(p);
      } else {
        grupos['_sin_categoria']!.add(p);
      }
    }
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FA),
      appBar: AppBar(
        automaticallyImplyLeading: false, 
        leading: const SizedBox.shrink(),
        leadingWidth: 0, 
        toolbarHeight: estaBuscando ? 80 : 120,
        backgroundColor: const Color(0xFF0D47A1),
        elevation: 10,
        shadowColor: Colors.black38,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(35)),
        ),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(35)),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1A237E), Color(0xFF0D47A1), Color(0xFF1976D2)],
            ),
          ),
        ),
        title: estaBuscando ? _barraBusqueda() : _infoNegocioBanner(),
        actions: [
          if (!estaBuscando) ...[
            IconButton(
              icon: const Icon(Icons.search, color: Colors.white, size: 26),
              onPressed: () => setState(() => estaBuscando = true),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 15, left: 5),
              child: InkWell(
                onTap: _irABoxi,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 6, offset: const Offset(0, 3))
                    ],
                  ),
                  child: Image.asset('assets/icon.png', width: 28, height: 28),
                ),
              ),
            ),
          ]
        ],
      ),

      body: Column(
        children: [
          const SizedBox(height: 10),
          _bannerDescargaBoxi(),
          _barraCategoriasHorizontal(), // 🔥 BARRA DE CATEGORÍAS DESLIZANTE SUPERIOR
          Expanded(
            child: _estaCargando
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFF0D47A1)),
                  )
                : LayoutBuilder(builder: (context, constraints) {
                    int columnas = constraints.maxWidth > 1200 ? 5 : (constraints.maxWidth > 800 ? 3 : 2);
                    bool esCelular = constraints.maxWidth < 600;
                    // 🔥 SingleChildScrollView garantiza que todas las llaves existan en memoria para el scroll suave
                    return SingleChildScrollView(
                      controller: _mainScrollCtrl,
                      physics: const BouncingScrollPhysics(),
                      child: Column(
                        children: [
                          if (docsFiltrados.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(50),
                              child: Center(child: Text("No se encontraron productos")),
                            ),
                          ..._categoriasOrdenadas.map((cat) {
                            return _construirBloqueCategoria(cat, grupos[cat]!, columnas, esCelular);
                          }).toList(),

                          _construirBloqueCategoria(
                            _categoriasOrdenadas.isEmpty ? "" : "Otros Productos", 
                            grupos['_sin_categoria']!, 
                            columnas, 
                            esCelular
                          ),
                          _boxiFooter(),
                        ],
                      ),
                    );
                  }),
          ),
        ],
      ),

      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: carrito.isNotEmpty
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              height: 65,
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _btnAccion(
                      label: "Ver Pedido",
                      icon: Icons.shopping_bag_outlined,
                      color: Colors.orange.shade900,
                      onTap: _verResumenPedido,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: _btnAccion(
                      label: "Enviar solicitud \$${totalPedido.toStringAsFixed(0)}",
                      icon: Icons.check_circle_outline_rounded,
                      color: const Color(0xFF2E7D32),
                      onTap: _abrirFinalizar,
                    ),
                  ),
                ],
              ),
            )
          : null,
    );
  }

  Widget _btnAccion({required String label, required IconData icon, required Color color, required VoidCallback onTap}) {
    return Container(
      decoration: BoxDecoration(
        boxShadow: [BoxShadow(color: color.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 5))],
      ),
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 60),
          shape: const StadiumBorder(),
          elevation: 0,
        ),
        onPressed: onTap,
        icon: Icon(icon, size: 20),
        label: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900))
        ),
      ),
    );
  }

  Widget _infoNegocioBanner() {
    String nombre = "Tienda Online";
    String? logoB64;

    if (_negocioData != null) {
      nombre = _negocioData?['nombre_negocio'] ?? nombre;
      logoB64 = _negocioData?['logo_base64'] ?? _negocioData?['logo_path'] ?? _negocioData?['logo_url'];
    }

    double ancho = MediaQuery.of(context).size.width;
    double size = ancho < 400 ? 22 : 30; 

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(3),
          decoration: const BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [Colors.white, Colors.white24])),
          child: CircleAvatar(
            radius: size,
            backgroundColor: Colors.white,
            child: logoB64 != null && logoB64.isNotEmpty
                ? ClipOval(
                    child: logoB64.startsWith('http')
                        ? Image.network(logoB64, width: size * 2, height: size * 2, fit: BoxFit.cover)
                        : (logoB64.length > 500 
                            ? Image.memory(base64Decode(logoB64), width: size * 2, height: size * 2, fit: BoxFit.cover, gaplessPlayback: true)
                            : Icon(Icons.store, color: const Color(0xFF0D47A1), size: size)) // Fallback si es ruta local en la web
                  )
                : Icon(Icons.store, color: const Color(0xFF0D47A1), size: size),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(nombre.toUpperCase(), maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Colors.white, letterSpacing: 0.8)),
              ),
              const SizedBox(height: 2),
              Row(
                children: const [
                  Icon(Icons.verified, size: 14, color: Colors.white70),
                  SizedBox(width: 4),
                  Flexible(child: Text("CATÁLOGO OFICIAL", overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10, color: Colors.white70, fontWeight: FontWeight.bold, letterSpacing: 1))),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _barraBusqueda() {
    return Container(
      height: 50,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: TextField(
        controller: _searchCtrl,
        autofocus: true,
        onChanged: (v) => setState(() => busqueda = v),
        style: const TextStyle(fontWeight: FontWeight.w600),
        decoration: InputDecoration(
          hintText: "Buscar productos...",
          hintStyle: TextStyle(color: Colors.grey.shade500),
          prefixIcon: const Icon(Icons.search, color: Color(0xFF0D47A1)),
          suffixIcon: IconButton(
            icon: const Icon(Icons.close, color: Colors.grey),
            onPressed: () => setState(() {
              estaBuscando = false;
              busqueda = "";
              _searchCtrl.clear();
            }),
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  Widget _bannerDescargaBoxi() {
    if (!mostrarBannerBoxi) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      padding: const EdgeInsets.fromLTRB(15, 10, 15, 15),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF0D47A1), Color(0xFF1976D2)]),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: Colors.blue.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 5))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min, // 🔥 LIMITA LA ALTURA PARA QUE NUNCA SE ESTIRE
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Align(
            alignment: Alignment.topRight,
            child: InkWell(
              onTap: () => setState(() => mostrarBannerBoxi = false),
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), shape: BoxShape.circle),
                child: const Icon(Icons.close, size: 16, color: Colors.white),
              ),
            ),
          ),
          const Text("¿Quieres un catálogo como este?", textAlign: TextAlign.center, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: Colors.white)),
          const SizedBox(height: 6),
          const Text("Crea el tuyo GRATIS con Boxi", textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.white70)),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _irABoxi,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white, foregroundColor: const Color(0xFF0D47A1),
              padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
            ),
            child: const Text("Descargar App", textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold)),
          )
        ],
      ),
    );
  }

  Widget _boxiFooter() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.symmetric(vertical: 50, horizontal: 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [Color(0xFF0D47A1), Color(0xFF1976D2)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 10, offset: const Offset(0, 5))]),
            child: Image.asset('assets/icon.png', width: 50, height: 50),
          ),
          const SizedBox(height: 15),
          const Text("BOXI", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 22, color: Colors.white, letterSpacing: 3)),
          const SizedBox(height: 6),
          Text("Crea catálogos digitales para tu negocio", textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(0.85))),
          const SizedBox(height: 25),
          ElevatedButton(
            onPressed: _irABoxi,
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: const Color(0xFF0D47A1), padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)), elevation: 6),
            child: const Text("Crear catálogo gratis", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          ),
          const SizedBox(height: 25),
          Container(width: 80, height: 2, color: Colors.white.withOpacity(0.3)),
          const SizedBox(height: 15),
          Text("© ${DateTime.now().year} Boxi · Todos los derechos reservados", style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.6))),
        ],
      ),
    );
  }

  Widget _tarjetaProducto(Map<String, dynamic> p) {
    double precioOriginal = (p['precio_venta'] as num).toDouble();
    double descPct = (p['descuento'] ?? 0).toDouble();
    double precioOferta = descPct > 0 ? precioOriginal - (precioOriginal * (descPct / 100)) : precioOriginal;
    double ahorro = precioOriginal - precioOferta;

    bool tieneVariantes = (p['variantes'] != null && p['variantes'].toString().length > 5);
    List<dynamic> grps = [];
    if (tieneVariantes) {
      try {
        var dec = p['variantes'];
        // 🔥 SOLUCIÓN: Si viene como String lo decodifica, si no, lo usa como List directamente
        if (dec is String) {
          dec = jsonDecode(dec);
        }
        
        grps = (dec is List && dec.isNotEmpty && !dec[0].containsKey('grupo')) 
            ? [{'grupo': 'Opciones', 'opciones': dec}] : List<dynamic>.from(dec);
      } catch(e){
        debugPrint("Error decodificando variantes del producto ${p['nombre']}: $e");
      }
    }

    int cantTotalProd = 0;
    carrito.forEach((key, item) { if (item['id'] == p['id']) cantTotalProd += (item['cantidad'] as int); });

    // Detectamos dinámicamente si es pantalla de celular
    double anchoPantalla = MediaQuery.of(context).size.width;
    bool esCelular = anchoPantalla < 600;

    return Container(
      key: ValueKey("prod_${p['id']}"), 
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(25),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 15, offset: const Offset(0, 8))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack( 
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(25)),
                  child: p['foto_path'] != null && p['foto_path'].toString().isNotEmpty
                      ? p['foto_path'].toString().startsWith('http')
                          ? Image.network(optimizarUrlCloudinary(p['foto_path'], width: 400), fit: BoxFit.cover, width: double.infinity, height: double.infinity)
                          : Image.memory(base64Decode(p['foto_path']), fit: BoxFit.cover, width: double.infinity, height: double.infinity, gaplessPlayback: true)
                      : Container(color: Colors.grey.shade100, width: double.infinity, height: double.infinity, child: const Icon(Icons.image, size: 40, color: Colors.grey)),
                ),
                
                if (descPct > 0)
                  Positioned(
                    top: 12, left: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(colors: [Colors.orange, Colors.redAccent]),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 4)],
                      ),
                      child: Text("-${_fmtDesc(descPct)}%", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14)), // 🔥 1 decimal máx
                    ),
                  ),

                Positioned(
                  top: 8, right: 8,
                  child: InkWell(
                    onTap: () => _mostrarDetalleProductoWeb(p, tieneVariantes, grps),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
                      child: const Icon(Icons.remove_red_eye, color: Colors.white, size: 20),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: esCelular ? 8 : 15, 
              vertical: esCelular ? 6 : 15
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p['nombre'], 
                  maxLines: esCelular ? 1 : 2, 
                  overflow: TextOverflow.ellipsis, 
                  style: TextStyle(
                    fontWeight: FontWeight.bold, 
                    fontSize: esCelular ? 11 : 14, 
                    color: Colors.black87
                  )
                ),
                SizedBox(height: esCelular ? 2 : 6),
                
                if (descPct > 0) ...[
                   Text(
                     "\$${precioOriginal.toStringAsFixed(0)}", 
                     style: TextStyle(
                       color: Colors.red, 
                       fontSize: esCelular ? 9 : 12, 
                       decoration: TextDecoration.lineThrough, 
                       fontWeight: FontWeight.bold
                     )
                   ),
                   Row(
                     children: [
                       Text(
                         "\$${precioOferta.toStringAsFixed(0)}", 
                         style: TextStyle(
                           color: const Color(0xFF1B5E20), 
                           fontWeight: FontWeight.w900, 
                           fontSize: esCelular ? 15 : 20
                         )
                       ),
                       const Spacer(),
                       if (!esCelular)
                         Container(
                           padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                           decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(5)),
                           child: Text("Ahorras \$${ahorro.toStringAsFixed(0)}", style: TextStyle(color: Colors.green.shade700, fontSize: 9, fontWeight: FontWeight.bold)),
                         )
                     ],
                   ),
                ] else
                   Text(
                     "\$${precioOriginal.toStringAsFixed(0)}", 
                     style: TextStyle(
                       color: const Color(0xFF0D47A1), 
                       fontWeight: FontWeight.w900, 
                       fontSize: esCelular ? 15 : 20
                     )
                   ),
                if (tieneVariantes) 
                  _buildVariantesPills(grps, esCelular),

                SizedBox(height: esCelular ? 6 : 12),
                _buildBotonesAccion(p, tieneVariantes, grps, cantTotalProd),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildBotonesAccion(p, tieneVariantes, grps, cantTotalProd) {
    // 🔥 CORREGIDO: Muestra el botón unificado "Añadir" para variantes y abre la pantalla al tocarlo
    if (tieneVariantes) {
      return SizedBox(
        width: double.infinity, height: 42,
        child: ElevatedButton.icon(
          onPressed: () => _abrirOpcionesVariantes(p, grps),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF0D47A1), 
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)), 
            elevation: 0
          ),
          icon: const Icon(Icons.add_shopping_cart, size: 16, color: Colors.white),
          label: Text(
            cantTotalProd > 0 ? "Añadir ($cantTotalProd)" : "Añadir", 
            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13)
          ),
        ),
      );
    }
    
    if (cantTotalProd == 0) {
      return SizedBox(
        width: double.infinity, height: 42,
        child: ElevatedButton.icon(
          onPressed: () => _actualizarCantidad(p, 1),
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0D47A1), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)), elevation: 0),
          icon: const Icon(Icons.add_shopping_cart, size: 16, color: Colors.white),
          label: const Text("Añadir", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        ),
      );
    }

    return Container(
      height: 42,
      decoration: BoxDecoration(color: Colors.blue.shade50, borderRadius: BorderRadius.circular(15)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(icon: const Icon(Icons.remove_circle_outline, color: Colors.red, size: 22), onPressed: () => _actualizarCantidad(p, -1)),
          Text("$cantTotalProd", style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Colors.black87)),
          IconButton(icon: const Icon(Icons.add_circle_outline, color: Colors.green, size: 22), onPressed: () => _actualizarCantidad(p, 1)),
        ],
      ),
    );
  }

  void _mostrarDetalleProductoWeb(Map<String, dynamic> p, bool tieneVariantes, List<dynamic> grps) {
    double precioOriginal = (p['precio_venta'] as num).toDouble();
    double descPct = (p['descuento'] ?? 0).toDouble();
    double precioOferta = precioOriginal - (precioOriginal * (descPct / 100));

    showDialog(
      context: context,
      builder: (ctx) => Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 500, maxHeight: 750),
          child: Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      p['foto_path'] != null && p['foto_path'].toString().isNotEmpty
                          ? Container(
                              color: Colors.black, 
                              width: double.infinity,
                              height: 300,
                              child: p['foto_path'].toString().startsWith('http')
                                ? Image.network(optimizarUrlCloudinary(p['foto_path'], width: 800), fit: BoxFit.contain)
                                : Image.memory(base64Decode(p['foto_path']), fit: BoxFit.contain, gaplessPlayback: true)
                            )
                          : Container(height: 250, width: double.infinity, color: Colors.grey.shade200, child: const Icon(Icons.image, size: 60, color: Colors.grey)),
                      if (descPct > 0)
                        Positioned(
                          top: 20, left: 20,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(10)),
                            child: Text("OFERTA -${_fmtDesc(descPct)}%", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), // 🔥 1 decimal máx
                          ),
                        )
                    ],
                  ),
                  
                  Padding(
                    padding: const EdgeInsets.all(25),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p['nombre'], style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                        const SizedBox(height: 10),
                        
                        if (descPct > 0)
                          Text("Antes: \$${precioOriginal.toStringAsFixed(0)}", style: const TextStyle(fontSize: 16, color: Colors.red, decoration: TextDecoration.lineThrough)),
                        
                        Text("\$${precioOferta.toStringAsFixed(0)}", style: const TextStyle(fontSize: 28, color: Color(0xFF1B5E20), fontWeight: FontWeight.w900)),
                        
                        const SizedBox(height: 20),
                        const Text("Descripción:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.blueGrey)),
                        const SizedBox(height: 8),
                        Text(
                          p['descripcion'] != null && p['descripcion'].toString().trim().isNotEmpty 
                              ? p['descripcion'] 
                              : "No hay descripción disponible para este producto.",
                          style: const TextStyle(fontSize: 15, color: Colors.black87, height: 1.4),
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
    );
  }

  Widget _buildVariantesPills(List<dynamic> grps, bool esCelular) {
    List<Widget> pills = [];
    for (var g in grps) {
      var opciones = g['opciones'] as List? ?? [];
      for (var o in opciones) {
        bool activo = o['activo'] == null || o['activo'] == true || o['activo'] == 1;
        if (!activo) continue;

        String foto = o['foto_path']?.toString() ?? '';
        bool esCloudinary = foto.startsWith('http');
        bool esBase64 = foto.length > 500;
        bool tieneFoto = esCloudinary || esBase64;

        pills.add(
          Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              border: Border.all(color: Colors.grey.shade200),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (tieneFoto) ...[
                  ClipOval(
                    child: esCloudinary
                        ? Image.network(optimizarUrlCloudinary(foto, width: 50), width: 18, height: 18, fit: BoxFit.cover)
                        : Image.memory(base64Decode(foto), width: 18, height: 18, fit: BoxFit.cover, gaplessPlayback: true),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  o['nombre'].toString(),
                  style: TextStyle(fontSize: esCelular ? 9 : 11, fontWeight: FontWeight.bold, color: Colors.grey.shade800),
                ),
              ],
            ),
          ),
        );
      }
    }

    if (pills.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: 8),
      height: esCelular ? 26 : 30,
      // 🔥 CORREGIDO: Envolvemos en un ScrollConfiguration para permitir el arrastre con clic de mouse en PC
      child: ScrollConfiguration(
        behavior: MyCustomScrollBehavior(),
        child: ListView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          children: pills,
        ),
      ),
    );
  }

  void _abrirOpcionesVariantes(Map<String, dynamic> p, List<dynamic> grps) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _DialogoVariantesWeb(
        producto: p,
        gruposVariantes: grps,
        cantidadesIniciales: carrito,
        onAceptar: (cantidadesNuevas) {
          int pId = p['id'];
          for (var entry in cantidadesNuevas.entries) {
            List<String> partes = entry.key.split('_');
            int gIndex = int.parse(partes[0]);
            int oIndex = int.parse(partes[1]);
            var g = grps[gIndex];
            var o = g['opciones'][oIndex];
            
            String nombreVar = "${p['nombre']} - ${g['grupo']}: ${o['nombre']}";
            String cartId = "${pId}_${entry.key}";

            int cantidadPrevia = carrito.containsKey(cartId) ? carrito[cartId]!['cantidad'] : 0;
            int cambio = entry.value - cantidadPrevia;

            if (cambio != 0) {
              _actualizarCantidad(
                p, 
                cambio, 
                cartId: cartId, 
                variantData: {
                  'nombre': nombreVar,
                  'g_index': gIndex,
                  'o_index': oIndex
                }
              );
            }
          }
        },
      )
    );
  }

  void _verResumenPedido() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          constraints: const BoxConstraints(maxWidth: 600), 
          decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
          padding: const EdgeInsets.all(25),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 50, height: 5, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(10))),
              const SizedBox(height: 20),
              const Text("TU PEDIDO", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF0D47A1))),
              const SizedBox(height: 15),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: carrito.entries.map((entry) {
                    var item = entry.value;
                    double pFinal = (item['precio_final'] as num).toDouble();
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      // 🔥 Nombre en gris muy oscuro
                      title: Text(item['nombre'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87)),
                      // 🔥 Verde más oscuro y legible
                      subtitle: Text("${item['cantidad']} x \$${pFinal.toStringAsFixed(0)}", style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.bold)),
                      // 🔥 Total en negro absoluto
                      trailing: Text("\$${(item['cantidad'] * pFinal).toStringAsFixed(0)}", style: const TextStyle(fontWeight: FontWeight.w900, color: Colors.black, fontSize: 16)),
                    );
                  }).toList(),
                ),
              ),
              const Divider(height: 30),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // 🔥 Etiqueta TOTAL más oscura
                  const Text("TOTAL:", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Colors.black87)),
                  Text("\$${totalPedido.toStringAsFixed(0)}", style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFF2E7D32))),
                ],
              ),
              const Divider(height: 30),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("TOTAL:", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  Text("\$${totalPedido.toStringAsFixed(0)}", style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFF2E7D32))),
                ],
              ),
              const SizedBox(height: 25),
            ],
          ),
        ),
      ),
    );
  }

  void _abrirFinalizar() async {
    final prefs = await SharedPreferences.getInstance();
    final nC = TextEditingController(text: prefs.getString('cache_nombre') ?? "");
    final negC = TextEditingController(text: prefs.getString('cache_negocio') ?? "");
    final deptoC = TextEditingController(text: prefs.getString('cache_depto') ?? "");
    final cC = TextEditingController(text: prefs.getString('cache_ciudad') ?? "");
    final dC = TextEditingController(text: prefs.getString('cache_direccion') ?? "");

    String cachedFull = prefs.getString('cache_telefono') ?? "";
    String cachedInd = prefs.getString('cache_telefono_indicativo') ?? "";
    String cachedNum = prefs.getString('cache_telefono_numero') ?? "";

    // Migración automática del número si ya existía uno completo guardado
    if (cachedInd.isEmpty && cachedNum.isEmpty && cachedFull.isNotEmpty) {
      if (cachedFull.startsWith('57') && cachedFull.length > 2) {
        cachedInd = '57';
        cachedNum = cachedFull.substring(2);
      } else if (cachedFull.startsWith('52') && cachedFull.length > 2) {
        cachedInd = '52';
        cachedNum = cachedFull.substring(2);
      } else if (cachedFull.startsWith('34') && cachedFull.length > 2) {
        cachedInd = '34';
        cachedNum = cachedFull.substring(2);
      } else {
        cachedNum = cachedFull;
      }
    }

    final indC = TextEditingController(text: cachedInd);
    final tC = TextEditingController(text: cachedNum);

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder( // 🔥 Añadido para actualizar el botón de envío
        builder: (ctx, setModalState) => Center(
          child: Container(
          constraints: const BoxConstraints(maxWidth: 600), 
          decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(35))),
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom + 20, left: 25, right: 25, top: 20),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children:[
                Center(child: Container(width: 60, height: 6, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(10)))),
                const SizedBox(height: 25),
                const Text("DATOS DE ENVÍO", style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFF0D47A1))),
                const SizedBox(height: 25),
        
                _field(nC, "Tu Nombre y Apellido *", Icons.person_outline),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6, left: 4),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: Text(
                          "Indicativo *", 
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey.shade700)
                        ),
                      ),
                      const SizedBox(width: 15),
                      Expanded(
                        flex: 5,
                        child: Text(
                          "Número de WhatsApp *", 
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey.shade700)
                        ),
                      ),
                    ],
                  ),
                ),

                // 2. Fila con los campos de entrada sin etiqueta interna para que se vean amplios y limpios
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: _field(
                        indC, 
                        "", // 👈 Etiqueta interna vacía para que no se amontone
                        Icons.public, // 👈 Cambiado a icono de globo terráqueo para evitar doble "+"
                        keyboard: TextInputType.number, 
                        prefijo: "+"
                      ),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      flex: 5,
                      child: _field(
                        tC, 
                        "", // 👈 Etiqueta interna vacía
                        Icons.phone_android_rounded, 
                        keyboard: TextInputType.phone,
                        hint: "ej: 3123456789"
                      ),
                    ),
                  ],
                ),
                _field(negC, "Nombre de tu negocio (Opcional)", Icons.store_outlined, obligatorio: false),
                const Divider(height: 30),
                Row(
                  children:[
                    Expanded(child: _field(deptoC, "Dpto (Opcional)", Icons.map_outlined, obligatorio: false)),
                    const SizedBox(width: 15),
                    Expanded(child: _field(cC, "Ciudad (Opcional)", Icons.location_city_rounded, obligatorio: false)),
                  ],
                ),
                _field(dC, "Dirección exacta (Opcional)", Icons.home_work_outlined, obligatorio: false),
        
                const SizedBox(height: 30),
        
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0D47A1),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 60),
                    shape: const StadiumBorder(),
                    elevation: 5,
                  ),
                  // 🔥 Si ya está enviando, deshabilitamos el botón físicamente (null)
                  onPressed: _enviandoPedido ? null : () async {
                    String indClean = indC.text.trim().replaceAll(RegExp(r'\D'), '');
                    String numClean = tC.text.trim().replaceAll(RegExp(r'\D'), '');
                    String numeroCompleto = "$indClean$numClean";

                    if (nC.text.isEmpty || indClean.isEmpty || numClean.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("⚠️ Completa tu nombre, indicativo y WhatsApp para poder contactarte.")));
                      return;
                    }
        
                    // 🔥 Bloqueamos clics adicionales inmediatamente
                    setState(() => _enviandoPedido = true);
                    setModalState(() {}); // Actualiza el modal para mostrar la animación de carga

                    try {
                      await prefs.setString('cache_nombre', nC.text.trim());
                      await prefs.setString('cache_negocio', negC.text.trim());
                      await prefs.setString('cache_depto', deptoC.text.trim());
                      await prefs.setString('cache_ciudad', cC.text.trim());
                      await prefs.setString('cache_direccion', dC.text.trim());
                      
                      await prefs.setString('cache_telefono_indicativo', indClean);
                      await prefs.setString('cache_telefono_numero', numClean);
                      await prefs.setString('cache_telefono', numeroCompleto);
          
                      final DateTime ahora = DateTime.now();
                      final DateTime fechaExpiracion = ahora.add(const Duration(days: 7));
          
                      StringBuffer sb = StringBuffer();
                      sb.writeln("📦 *¡Hola! Acabo de hacer un pedido en tu catálogo web*\n");
                      sb.writeln("*Cliente:* ${nC.text.trim()}");
                      sb.writeln("*Mi pedido es:*");
                      for (var item in carrito.values) {
                        double pFinal = (item['precio_final'] as num).toDouble();
                        sb.writeln("▪️ ${item['cantidad']}x ${item['nombre']} (\$${(pFinal * item['cantidad']).toStringAsFixed(0)})");
                      }
                      sb.writeln("\n*TOTAL:* \$${totalPedido.toStringAsFixed(0)}");
                      sb.writeln("\nQuedo atento a la confirmación.");

                      String mensajeCodificado = Uri.encodeComponent(sb.toString());

                      // Enviamos la orden
                      await FirebaseFirestore.instance.collection('solicitudes').add({
                        'adminId': widget.adminId,
                        'adminEmail': adminEmail ?? "desconocido",
                        'cliente': {
                          'nombre': nC.text.trim(),
                          'negocio': negC.text.trim(),
                          'direccion': dC.text.trim(),
                          'departamento': deptoC.text.trim(),
                          'ciudad': cC.text.trim(),
                          'telefono': numeroCompleto,
                        },
                        'productos': carrito.values.toList(), 
                        'total': totalPedido,
                        'estado': 'pendiente',
                        'fecha': ahora.toIso8601String(),
                        'expireAt': Timestamp.fromDate(fechaExpiracion),
                      });

                      // Notificar por API
                      await http.post(
                        Uri.parse('https://boxi-api.vercel.app/api/notificar'),
                        headers: {'Content-Type': 'application/json'},
                        body: jsonEncode({
                          'adminId': widget.adminId,
                          'nombreCliente': nC.text.trim(),
                        }),
                      );

                      Navigator.pop(ctx);
                      setState(() => carrito.clear());
                      _mostrarDialogoExito(mensajeCodificado); 
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("❌ Error al procesar tu pedido: $e")));
                    } finally {
                      // 🔥 Liberamos el cerrojo de envíos al terminar (éxito o error)
                      setState(() => _enviandoPedido = false);
                    }
                  },
                  // 🔥 Si está procesando, mostramos la animación de carga, de lo contrario el texto.
                  child: _enviandoPedido
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                        )
                      : const Text("ENVIAR SOLICITUD", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                ), 
                const SizedBox(height: 10),
              ], 
            ), 
          ), 
        ), 
      ), 
    ),
  ); 
} 

  void _mostrarDialogoExito(String mensajeWhatsapp) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_rounded, color: Colors.green, size: 80),
            const SizedBox(height: 20),
            const Text("¡Pedido Recibido!", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text("El negocio procesará tu pedido pronto.", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w500)),
            ),
            
            Builder(
              builder: (context) {
                if (_negocioData == null) return const SizedBox();
                final String? wa = _negocioData?['whatsapp_admin'];
                if (wa == null || wa.trim().isEmpty) return const SizedBox();

                return Padding(
                  padding: const EdgeInsets.only(top: 15),
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15)
                    ),
                    onPressed: () async {
                      String num = wa.replaceAll(RegExp(r'\D'), '');
                      final Uri url = Uri.parse("https://wa.me/$num?text=$mensajeWhatsapp");
                      if (await canLaunchUrl(url)) {
                        await launchUrl(url, mode: LaunchMode.externalApplication);
                      }
                    },
                    icon: const Icon(Icons.message),
                    label: const Text("Hablar con el Vendedor"),
                  ),
                );
              }
            ),

            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green, minimumSize: const Size(double.infinity, 50), shape: const StadiumBorder()),
              onPressed: () => Navigator.pop(context), 
              child: const Text("Listo", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, IconData icon, {TextInputType keyboard = TextInputType.text, bool obligatorio = true, String? prefijo, String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: TextField(
        controller: c,
        keyboardType: keyboard,
        style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.black87, fontSize: 16),
        decoration: InputDecoration(
          labelText: label.isNotEmpty ? label : null, // 👈 Evita dibujar espacio para etiquetas vacías
          labelStyle: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w500),
          floatingLabelStyle: const TextStyle(color: Color(0xFF0D47A1), fontWeight: FontWeight.bold),
          prefixText: prefijo,
          prefixStyle: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 16),
          
          // Modificaciones para reducir el espacio del icono:
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 10, right: 6), // 👈 Espacio controlado alrededor del icono
            child: Icon(icon, color: const Color(0xFF0D47A1), size: 18), // 👈 Icono levemente más compacto
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 32, // 👈 Reduce el ancho de 48px a 32px para liberar espacio horizontal
            minHeight: 20,
          ),
          
          hintText: hint,
          hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
          filled: true,
          fillColor: Colors.grey.shade200,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14), // 👈 Margen interno balanceado
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: const BorderSide(color: Color(0xFF0D47A1), width: 2)),
        ),
      ),
    );
  }
  
  Widget _construirBloqueCategoria(String titulo, List<Map<String, dynamic>> prods, int columnas, bool esCelular) {
    if (prods.isEmpty) return const SizedBox.shrink();
    return Column(
      key: _categoriaKeys[titulo], // 🔥 Asigna la clave para permitir el scroll automático a esta categoría
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (titulo.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(15, 25, 15, 10),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF0D47A1), Color(0xFF42A5F5)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0D47A1).withOpacity(0.3),
                  blurRadius: 10,
                  offset: const Offset(0, 5),
                )
              ]
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.local_offer_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Text(
                  titulo.toUpperCase(), 
                  style: const TextStyle(
                    fontSize: 16, 
                    fontWeight: FontWeight.w900, 
                    color: Colors.white, 
                    letterSpacing: 1.2
                  )
                ),
              ],
            ),
          ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(15),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columnas,
            childAspectRatio: esCelular ? 0.68 : (columnas == 5 ? 0.70 : 0.72), 
            crossAxisSpacing: 15,
            mainAxisSpacing: 15,
          ),
          itemCount: prods.length,
          itemBuilder: (context, index) => _tarjetaProducto(prods[index]),
        ),
      ],
    );
  }
}

class _DialogoVariantesWeb extends StatefulWidget {
  final Map<String, dynamic> producto;
  final List<dynamic> gruposVariantes;
  final Map<String, Map<String, dynamic>> cantidadesIniciales;
  final Function(Map<String, int>) onAceptar;

  const _DialogoVariantesWeb({
    required this.producto, 
    required this.gruposVariantes, 
    required this.cantidadesIniciales,
    required this.onAceptar,
  });

  @override
  State<_DialogoVariantesWeb> createState() => _DialogoVariantesWebState();
}

class _DialogoVariantesWebState extends State<_DialogoVariantesWeb> {
  final Map<String, int> _cantidades = {};
  final Map<String, TextEditingController> _controllers = {};
  
  @override
  void initState() {
    super.initState();
    int pId = widget.producto['id'];

    for (int g = 0; g < widget.gruposVariantes.length; g++) {
      var opciones = widget.gruposVariantes[g]['opciones'] ?? [];
      for (int o = 0; o < opciones.length; o++) {
        String shortKey = "${g}_$o"; 
        String cartKey = "${pId}_$shortKey";
        
        int valorInicial = 0;
        if (widget.cantidadesIniciales.containsKey(cartKey)) {
          valorInicial = widget.cantidadesIniciales[cartKey]!['cantidad'];
        }
        
        _cantidades[shortKey] = valorInicial;
        _controllers[shortKey] = TextEditingController(text: valorInicial.toString());
      }
    }
  }

  @override
  void dispose() {
    for (var c in _controllers.values) { c.dispose(); }
    super.dispose();
  }

  void _actualizarCant(String key, int nuevaCant) {
    if (nuevaCant < 0) nuevaCant = 0;
    setState(() {
      _cantidades[key] = nuevaCant;
      _controllers[key]?.text = nuevaCant.toString();
    });
  }

  void _ampliarImagen(String b64, String nombre) {
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
                child: b64.startsWith('http')
                    ? Image.network(b64, fit: BoxFit.contain)
                    : (b64.length > 500 
                        ? Image.memory(base64Decode(b64), fit: BoxFit.contain, gaplessPlayback: true)
                        : const Icon(Icons.broken_image, size: 50, color: Colors.grey)),
              ),
            ),
            Positioned(
              top: 10,
              right: 10,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 35),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
            Positioned(
              bottom: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  nombre,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 500, maxHeight: 600), 
          decoration: BoxDecoration(
            color: Colors.white, 
            borderRadius: BorderRadius.circular(25),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 20)]
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(25, 25, 25, 15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Opciones Disponibles", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF0D47A1))),
                    Text(widget.producto['nombre'], style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  itemCount: widget.gruposVariantes.length,
                  itemBuilder: (context, gIndex) {
                    var grupo = widget.gruposVariantes[gIndex];
                    List<dynamic> opciones = grupo['opciones'] ?? [];

                    // Salvavidas estético para grupos sin nombre
                    String tituloGrupo = grupo['grupo']?.toString() ?? "";
                    if (tituloGrupo.trim().isEmpty) tituloGrupo = "Opciones";

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 10),
                          child: Text(tituloGrupo.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 12, letterSpacing: 1)),
                        ),
                        ...opciones.asMap().entries.where((entry) {
                          var val = entry.value['activo'];
                          return val == null || val == true || val == 1;
                        }).map((entry) {
                          int oIndex = entry.key;
                          var o = entry.value;
                          String key = "${gIndex}_$oIndex";

                          String foto = o['foto_path']?.toString() ?? '';
                          bool esCloudinary = foto.startsWith('http');
                          bool esBase64 = foto.length > 500;
                          bool tieneFotoWeb = esCloudinary || esBase64;

                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 25, vertical: 5),
                            leading: GestureDetector(
                              onTap: () {
                                if (tieneFotoWeb) _ampliarImagen(foto, o['nombre']);
                              },
                              child: Stack(
                                children: [
                                  Container(
                                    width: 55, height: 55,
                                    decoration: BoxDecoration(
                                      color: Colors.grey[100],
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: Colors.blue.shade100)
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: tieneFotoWeb
                                        ? (esCloudinary
                                            ? Image.network(optimizarUrlCloudinary(foto, width: 150), fit: BoxFit.cover, gaplessPlayback: true)
                                            : Image.memory(base64Decode(foto), fit: BoxFit.cover, gaplessPlayback: true))
                                        : const Icon(Icons.image, color: Colors.grey),
                                  ),
                                  if (tieneFotoWeb)
                                    Positioned(
                                      bottom: 0, right: 0,
                                      child: Container(
                                        decoration: const BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.only(topLeft: Radius.circular(5))),
                                        child: const Icon(Icons.zoom_in, color: Colors.white, size: 14),
                                      ),
                                    )
                                ],
                              ),
                            ),
                            title: Text(o['nombre'], style: const TextStyle(fontWeight: FontWeight.bold)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                                  onPressed: () => _actualizarCant(key, _cantidades[key]! - 1)
                                ),
                                SizedBox(
                                  width: 40,
                                  child: Text(_cantidades[key].toString(), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.add_circle_outline, color: Colors.green),
                                  onPressed: () => _actualizarCant(key, _cantidades[key]! + 1)
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                        const Divider(indent: 25, endIndent: 25),
                      ],
                    );
                  }
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text("CANCELAR", style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.bold)),
                      )
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0D47A1),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 0
                        ),
                        onPressed: () {
                          widget.onAceptar(_cantidades);
                          Navigator.pop(context);
                        },
                        child: const Text("GUARDAR", style: TextStyle(fontWeight: FontWeight.bold)),
                      )
                    )
                  ],
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}

class _VisorFotosVariantes extends StatefulWidget {
  final List<dynamic> gruposVariantes;
  final int grupoInicial;
  final int opcionInicial;
  final String nombreProducto;
  final Map<String, String> fotosResueltas;

  const _VisorFotosVariantes({
    required this.gruposVariantes,
    required this.grupoInicial,
    required this.opcionInicial,
    required this.nombreProducto,
    required this.fotosResueltas, 
  });

  @override
  State<_VisorFotosVariantes> createState() => _VisorFotosVariantesState();
}

class _VisorFotosVariantesState extends State<_VisorFotosVariantes> {
  late PageController _pageController;
  final List<Map<String, dynamic>> _todasLasFotos = [];
  int _indiceActual = 0;

  @override
  void initState() {
    super.initState();
    for (int gIdx = 0; gIdx < widget.gruposVariantes.length; gIdx++) {
      var g = widget.gruposVariantes[gIdx];
      if (g['opciones'] == null) continue;
      for (int oIdx = 0; oIdx < g['opciones'].length; oIdx++) {
        var o = g['opciones'][oIdx];
        String clave = '${gIdx}_$oIdx';
        String foto = widget.fotosResueltas[clave] ?? '';
        if (foto.isNotEmpty && foto.length > 50) {
          _todasLasFotos.add({
            'nombre': "${g['grupo']}: ${o['nombre']}",
            'foto': foto,
            'grupo_real': gIdx,
            'opcion_real': oIdx,
          });
        }
      }
    }

    int indiceArranque = _todasLasFotos.indexWhere((item) => 
      item['grupo_real'] == widget.grupoInicial && item['opcion_real'] == widget.opcionInicial
    );

    if (indiceArranque == -1) indiceArranque = 0;
    _indiceActual = indiceArranque;
    _pageController = PageController(initialPage: indiceArranque);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _cambiarImagen(int offset) {
    int nuevoIndice = _indiceActual + offset;
    if (nuevoIndice >= 0 && nuevoIndice < _todasLasFotos.length) {
      _pageController.animateToPage(
        nuevoIndice,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_todasLasFotos.isEmpty) return const SizedBox.shrink();

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(10),
      child: RawKeyboardListener(
        focusNode: FocusNode()..requestFocus(),
        onKey: (RawKeyEvent event) {
          if (event is RawKeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              _cambiarImagen(-1);
            } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              _cambiarImagen(1);
            }
          }
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            PageView.builder(
              controller: _pageController,
              onPageChanged: (idx) => setState(() => _indiceActual = idx),
              itemCount: _todasLasFotos.length,
              itemBuilder: (context, index) {
                var item = _todasLasFotos[index];
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(20)),
                      child: Text(
                        item['nombre'],
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 15),
                    InteractiveViewer(
                      panEnabled: true,
                      minScale: 1,
                      maxScale: 4,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Image.memory(
                          base64Decode(item['foto']),
                          width: MediaQuery.of(context).size.width * 0.9,
                          height: MediaQuery.of(context).size.height * 0.6,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),

            if (_indiceActual > 0)
              Positioned(
                left: 0,
                child: IconButton(
                  icon: const Icon(Icons.arrow_circle_left, color: Colors.white, size: 50),
                  onPressed: () => _cambiarImagen(-1),
                ),
              ),
            
            if (_indiceActual < _todasLasFotos.length - 1)
              Positioned(
                right: 0,
                child: IconButton(
                  icon: const Icon(Icons.arrow_circle_right, color: Colors.white, size: 50),
                  onPressed: () => _cambiarImagen(1),
                ),
              ),

            Positioned(
              top: 0, right: 0,
              child: IconButton(
                icon: const Icon(Icons.cancel, color: Colors.white, size: 40),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MyCustomScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
  };
}