import 'dart:io'; // 🔥 Añadido para verificar plataforma
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart'; // 🔥 Import de AdMob
import '../database/db_helper.dart';
import 'servicio_anuncios.dart';
import 'servicio_nube.dart';
import 'pantalla_premium.dart'; // 🔥 Import de pantalla premium para el anuncio
import 'package:sqflite/sqflite.dart'; 
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

class PantallaVendedores extends StatefulWidget {
  const PantallaVendedores({super.key});
  @override
  State<PantallaVendedores> createState() => _PantallaVendedoresState();
}

class _PantallaVendedoresState extends State<PantallaVendedores> {
  StreamSubscription? _suscripcion;
  List<Map<String, dynamic>> _vendedores = [];
  List<Map<String, dynamic>> _filtrados = [];
  bool _esPremium = false; // 🔥 Variable local para controlar anuncios
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cargar();
    _activarTiempoReal();
  }

  @override
  void dispose() {
    _suscripcion?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _activarTiempoReal() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('es_premium') ?? false) {
      _suscripcion = ServicioNube.escucharVendedoresEnTiempoReal()?.listen((snapshot) async {
        final db = await DBHelper.instance.database;

        for (var change in snapshot.docChanges) {
          final data = change.doc.data() as Map<String, dynamic>;
          final int id = data['id'];

          if (change.type == DocumentChangeType.removed) {
            await db.delete('vendedores', where: 'id = ?', whereArgs: [id]);
          } else {
            Map<String, dynamic> localData = Map.from(data);
            
            localData.forEach((key, value) {
              if (value is Timestamp) {
                localData[key] = value.toDate().toIso8601String();
              }
            });
            const permitidas = ['id', 'nombre', 'telefono', 'email', 'ultima_modificacion'];
            localData.removeWhere((key, value) => !permitidas.contains(key));

            await db.insert('vendedores', localData, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
        if (mounted) _cargar();
      });
    }
  }

  Future<void> _cargar() async {
    final db = await DBHelper.instance.database;
    final data = await db.query('vendedores');
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _vendedores = data;
      _filtrados = data;
      _esPremium = prefs.getBool('es_premium') ?? false; // 🔥 Carga el estado de suscripción
    });
  }

  void _filtrar(String q) {
    setState(() {
      _filtrados = _vendedores
          .where((v) => v['nombre'].toLowerCase().contains(q.toLowerCase()))
          .toList();
    });
  }

  void _abrirFormulario({Map<String, dynamic>? vendedor}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => PantallaFormularioVendedor(
          vendedor: vendedor,
          onGuardar: () => _cargar(),
        ),
      ),
    );
  }

  void _eliminar(int id, String nombre) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠️ Eliminar Vendedor'),
        content: Text('¿Deseas eliminar a $nombre?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCELAR')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              final db = await DBHelper.instance.database;
              final prefs = await SharedPreferences.getInstance();

              await db.delete('vendedores', where: 'id = ?', whereArgs: [id]);
              
              _cargar();
              if (mounted) Navigator.pop(ctx);

              if (prefs.getBool('es_premium') ?? false) {
                ServicioNube.eliminarVendedorNube(id);
              }
            },
            child: const Text('ELIMINAR', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isOscuro ? const Color(0xFF0A0A0F) : const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1),
        iconTheme: const IconThemeData(color: Colors.white),
        title: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15),
          decoration: BoxDecoration(
            color: isOscuro ? Colors.white.withOpacity(0.05) : Colors.white24, 
            borderRadius: BorderRadius.circular(10)
          ),
          child: TextField(
            controller: _searchCtrl,
            onChanged: _filtrar,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'Buscar vendedor...',
              hintStyle: TextStyle(color: Colors.white70),
              border: InputBorder.none,
              icon: Icon(Icons.search, color: Colors.white),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _abrirFormulario(),
        backgroundColor: isOscuro ? Colors.cyanAccent.shade700 : const Color(0xFF0D47A1),
        icon: Icon(Icons.person_add, color: isOscuro ? Colors.black : Colors.white),
        label: Text("Nuevo Vendedor", style: TextStyle(color: isOscuro ? Colors.black : Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: _filtrados.isEmpty
          ? Center(child: Text('No hay vendedores registrados', style: TextStyle(color: isOscuro ? Colors.white38 : Colors.grey)))
          : ListView.builder(
              padding: const EdgeInsets.only(left: 10, right: 10, top: 10, bottom: 90), // Espacio extra para el botón flotante
              // 🔥 Si no es premium, agregamos 1 espacio extra para el anuncio al final
              itemCount: _filtrados.length + (!_esPremium ? 1 : 0),
              itemBuilder: (ctx, i) {
                // 🔥 Renderizamos el anuncio al llegar al final
                if (i == _filtrados.length) {
                  return const AnuncioNativoWidget(key: ValueKey('admob_vendor_list_ad'));
                }

                final v = _filtrados[i];
                return Card(
                  elevation: 2,
                  color: Theme.of(context).cardColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                    side: BorderSide(color: isOscuro ? Colors.white10 : Colors.transparent)
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: isOscuro ? Colors.cyanAccent.withOpacity(0.1) : const Color(0xFF0D47A1),
                      child: Icon(Icons.badge, color: isOscuro ? Colors.cyanAccent : Colors.white),
                    ),
                    title: Text(v['nombre'], style: TextStyle(fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : Colors.black87)),
                    subtitle: Text('📞 ${v['telefono']}', style: TextStyle(color: isOscuro ? Colors.white60 : Colors.black54)),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PantallaDetalleVendedor(vendedor: v))),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(Icons.edit_note, color: isOscuro ? Colors.blue.shade300 : Colors.blue, size: 28),
                          onPressed: () => _abrirFormulario(vendedor: v),
                        ),
                        IconButton(
                          icon: Icon(Icons.delete_outline, color: isOscuro ? Colors.redAccent.shade100 : Colors.red, size: 28),
                          onPressed: () => _eliminar(v['id'], v['nombre']),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
class PantallaDetalleVendedor extends StatelessWidget {
  final Map<String, dynamic> vendedor;
  const PantallaDetalleVendedor({super.key, required this.vendedor});

  @override
  Widget build(BuildContext context) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isOscuro ? const Color(0xFF0A0A0F) : const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: const Text("Rendimiento"), 
        backgroundColor: isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1), 
        foregroundColor: Colors.white
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(25),
        child: Column(
          children: [
            Icon(Icons.badge, size: 80, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)),
            const SizedBox(height: 15),
            Text(vendedor['nombre'], style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : Colors.black)),
            const SizedBox(height: 5),
            Text(vendedor['email'] ?? "Sin correo registrado", style: TextStyle(fontSize: 14, color: isOscuro ? Colors.white38 : Colors.blueGrey)),
            const SizedBox(height: 5),
            Text("Teléfono: ${vendedor['telefono']}", style: TextStyle(fontSize: 16, color: isOscuro ? Colors.white60 : Colors.grey)),
            const SizedBox(height: 30),
            FutureBuilder<List<Map<String, dynamic>>>(
                future: DBHelper.instance.database.then((db) => db.query('pedidos', where: 'vendedor_id = ?', whereArgs: [vendedor['id']])),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

                  double totalVentas = snapshot.data!.fold(0, (sum, it) => sum + (it['total_venta'] as double));
                  double totalGanancia = snapshot.data!.fold(0, (sum, it) => sum + (it['ganancia_total'] as double));

                  return Column(
                    children: [
                      _cardMeta("PEDIDOS REALIZADOS", snapshot.data!.length.toString(), Icons.shopping_cart, Colors.blue, isOscuro),
                      const SizedBox(height: 15),
                      _cardMeta("TOTAL RECAUDADO", "\$${totalVentas.toStringAsFixed(0)}", Icons.attach_money, Colors.greenAccent, isOscuro),
                      const SizedBox(height: 15),
                      _cardMeta("GANANCIA GENERADA", "\$${totalGanancia.toStringAsFixed(0)}", Icons.trending_up, Colors.orangeAccent, isOscuro),
                    ],
                  );
                })
          ],
        ),
      ),
    );
  }

  Widget _cardMeta(String t, String v, IconData i, Color c, bool isOscuro) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: isOscuro ? c.withOpacity(0.05) : c.withOpacity(0.1), 
          borderRadius: BorderRadius.circular(15), 
          border: Border.all(color: isOscuro ? c.withOpacity(0.2) : c.withOpacity(0.3))
        ),
        child: Row(
          children: [
            Icon(i, color: c, size: 30),
            const SizedBox(width: 20),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isOscuro ? c.withOpacity(0.7) : c)),
              Text(v, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : c.withOpacity(0.9))),
            ])
          ],
        ),
      );
}

class PantallaFormularioVendedor extends StatefulWidget {
  final Map<String, dynamic>? vendedor;
  final VoidCallback onGuardar;

  const PantallaFormularioVendedor({super.key, this.vendedor, required this.onGuardar});

  @override
  State<PantallaFormularioVendedor> createState() => _PantallaFormularioVendedorState();
}

class _PantallaFormularioVendedorState extends State<PantallaFormularioVendedor> {
  final _nCtrl = TextEditingController(), 
        _tCtrl = TextEditingController(),
        _eCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.vendedor != null) {
      _nCtrl.text = widget.vendedor!['nombre'];
      _tCtrl.text = widget.vendedor!['telefono'];
      _eCtrl.text = widget.vendedor!['email'] ?? '';
    }
  }

  @override
  void dispose() {
    _nCtrl.dispose();
    _tCtrl.dispose();
    _eCtrl.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    String tel = _tCtrl.text.trim();
    
    // VALIDACIONES
    if (_nCtrl.text.trim().isEmpty || tel.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('⚠️ Nombre y Teléfono son obligatorios')));
      return;
    }

    if (tel.length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('⚠️ El teléfono debe tener al menos 10 dígitos')));
      return;
    }

    final db = await DBHelper.instance.database;
    final prefs = await SharedPreferences.getInstance();
    
    final datos = {
      'nombre': _nCtrl.text.trim(), 
      'telefono': tel,
      'email': _eCtrl.text.trim() // Campo Correo
    };
    
    bool esNuevo = widget.vendedor == null;

    int idActual;
    if (esNuevo) {
      idActual = await db.insert('vendedores', datos);
    } else {
      idActual = widget.vendedor!['id'];
      await db.update('vendedores', datos, where: 'id = ?', whereArgs: [idActual]);
    }

    widget.onGuardar();

    if (prefs.getBool('es_premium') ?? false) {
      ServicioNube.guardarVendedorNube({...datos, 'id': idActual});
    }

    if (mounted) {
      if (esNuevo) {
        ServicioAnuncios.mostrarAnuncioIntersticial(() {
          if (mounted) Navigator.pop(context);
        });
      } else {
        Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isOscuro ? const Color(0xFF0A0A0F) : Colors.white,
      appBar: AppBar(
        title: Text(widget.vendedor == null ? 'Nuevo Vendedor' : 'Editar Vendedor'),
        backgroundColor: isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1), 
        foregroundColor: Colors.white
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Icon(Icons.account_box, size: 80, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)),
            const SizedBox(height: 25),
            _buildInput(_nCtrl, 'Nombre Completo', Icons.person, isOscuro),
            const SizedBox(height: 15),
            _buildInput(_eCtrl, 'Correo Electrónico (Opcional)', Icons.email, isOscuro, keyboard: TextInputType.emailAddress),
            const SizedBox(height: 15),
            _buildInput(_tCtrl, 'Teléfono', Icons.phone, isOscuro, keyboard: TextInputType.phone, hint: 'Mínimo 10 dígitos'),
            const SizedBox(height: 40),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isOscuro ? Colors.cyanAccent.shade700 : const Color(0xFF0D47A1), 
                foregroundColor: isOscuro ? Colors.black : Colors.white, 
                minimumSize: const Size(double.infinity, 55),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
              ),
              onPressed: _guardar,
              child: const Text("GUARDAR VENDEDOR", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInput(TextEditingController ctrl, String label, IconData icon, bool isOscuro, {TextInputType keyboard = TextInputType.text, String? hint}) {
    return TextField(
      controller: ctrl,
      keyboardType: keyboard,
      style: TextStyle(color: isOscuro ? Colors.white : Colors.black),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: isOscuro ? Colors.white60 : Colors.black54),
        hintStyle: TextStyle(color: isOscuro ? Colors.white24 : Colors.black26),
        prefixIcon: Icon(icon, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)),
        filled: true,
        fillColor: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade50,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: isOscuro ? Colors.white10 : Colors.black12)
        ),
      ),
    );
  }
}

// 🔥 CLASE DEL ANUNCIO HÍBRIDO E INMUNE A BLOQUEOS DE ADMOB (RECTÁNGULO MEDIANO)
class AnuncioNativoWidget extends StatefulWidget {
  const AnuncioNativoWidget({super.key});

  @override
  State<AnuncioNativoWidget> createState() => _AnuncioNativoWidgetState();
}

class _AnuncioNativoWidgetState extends State<AnuncioNativoWidget> {
  BannerAd? _bannerAd;
  bool _isLoaded = false;

  // 🔥 ID de bloque de tipo Banner de AdMob real
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
      size: AdSize.largeBanner, // 📐 320x100 - Totalmente estable
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (mounted) setState(() => _isLoaded = true);
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
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
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
          
          // 🖥️ CUERPO (Carga el Ad de AdMob, o diseño Premium alternativo)
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
                              Text("Sincroniza tus vendedores y ventas en tiempo real.", style: TextStyle(color: isOscuro ? Colors.white54 : Colors.black54, fontSize: 10)),
                            ],
                          ),
                        )
                      ],
                    ),
                  ),
          ),
          
          // 🔘 ACCESO PREMIUM
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
                    "QUITAR PUBLICIDAD (HAZTE PRO)", 
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