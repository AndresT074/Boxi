import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../database/db_helper.dart';
import 'servicio_anuncios.dart';
import 'servicio_nube.dart';
import 'package:sqflite/sqflite.dart'; 
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

class PantallaClientes extends StatefulWidget {
  const PantallaClientes({super.key});
  @override
  State<PantallaClientes> createState() => _PantallaClientesState();
}

class _PantallaClientesState extends State<PantallaClientes> {
  StreamSubscription? _suscripcion;
  List<Map<String, dynamic>> _clientes = [];
  List<Map<String, dynamic>> _filtrados = [];
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
      _suscripcion = ServicioNube.escucharClientesEnTiempoReal()?.listen((snapshot) async {
        final db = await DBHelper.instance.database;

        for (var change in snapshot.docChanges) {
          final data = change.doc.data() as Map<String, dynamic>;
          final int id = data['id'];

          if (change.type == DocumentChangeType.removed) {
            await db.delete('clientes', where: 'id = ?', whereArgs: [id]);
          } else {
            Map<String, dynamic> localData = Map.from(data);
            
            localData.forEach((key, value) {
              if (value is Timestamp) {
                localData[key] = value.toDate().toIso8601String();
              }
            });

            const permitidas = [
              'id', 'nombre_completo', 'nombre_negocio', 'direccion', 
              'telefono', 'departamento', 'ciudad', 'firma', 'ultima_modificacion'
            ];
            localData.removeWhere((key, value) => !permitidas.contains(key));

            await db.insert('clientes', localData, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
        if (mounted) _cargar();
      });
    }
  }

  Future<void> _cargar() async {
    final db = await DBHelper.instance.database;
    final data = await db.query('clientes', orderBy: 'nombre_completo ASC');
    if (!mounted) return;
    setState(() {
      _clientes = data;
      _filtrados = data;
    });
  }

  void _filtrar(String q) {
    setState(() {
      _filtrados = _clientes
          .where((c) =>
              c['nombre_completo'].toString().toLowerCase().contains(q.toLowerCase()) ||
              (c['nombre_negocio'] ?? '').toString().toLowerCase().contains(q.toLowerCase()))
          .toList();
    });
  }

  void _abrirFormulario({Map<String, dynamic>? cliente}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => PantallaFormularioCliente(
          cliente: cliente,
          onGuardar: () => _cargar(),
        ),
      ),
    );
  }

  void _eliminar(int id, String nombre) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠️ Eliminar Cliente'),
        content: Text('¿Deseas eliminar a $nombre?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCELAR')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              final db = await DBHelper.instance.database;
              final prefs = await SharedPreferences.getInstance();
              await db.delete('clientes', where: 'id = ?', whereArgs: [id]);
              _cargar();
              if (mounted) Navigator.pop(ctx);
              if (prefs.getBool('es_premium') ?? false) {
                ServicioNube.eliminarClienteNube(id);
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
        title: TextField(
          controller: _searchCtrl,
          onChanged: _filtrar,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Buscar cliente...',
            hintStyle: TextStyle(color: Colors.white70),
            border: InputBorder.none,
            icon: Icon(Icons.search, color: Colors.white),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _abrirFormulario(),
        backgroundColor: isOscuro ? Colors.cyanAccent.shade700 : const Color(0xFF0D47A1),
        icon: Icon(Icons.person_add_alt_1, color: isOscuro ? Colors.black : Colors.white),
        label: Text("Nuevo Cliente", style: TextStyle(color: isOscuro ? Colors.black : Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: _filtrados.isEmpty
          ? Center(child: Text('No hay clientes registrados', style: TextStyle(color: isOscuro ? Colors.white38 : Colors.grey)))
          : ListView.builder(
              padding: const EdgeInsets.all(10),
              itemCount: _filtrados.length,
              itemBuilder: (ctx, i) {
                final c = _filtrados[i];
                String sub = "${c['nombre_negocio'] ?? 'S/N'} • ${c['ciudad']}";
                return Card(
                  elevation: 2,
                  color: Theme.of(context).cardColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                    side: BorderSide(color: isOscuro ? Colors.white10 : Colors.transparent)
                  ),
                  child: ListTile(
                    leading: Container(
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
                        child: Text(
                          c['nombre_completo'][0].toUpperCase(), 
                          style: TextStyle(
                            color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1), 
                            fontWeight: FontWeight.bold
                          )
                        ),
                      ),
                    ),
                    title: Text(c['nombre_completo'], 
                      style: TextStyle(fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : Colors.black87)),
                    subtitle: Text(sub, style: TextStyle(color: isOscuro ? Colors.white60 : Colors.black54)),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PantallaDetalleCliente(cliente: c))),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(icon: Icon(Icons.edit_note, color: isOscuro ? Colors.blue.shade300 : Colors.blue, size: 26), onPressed: () => _abrirFormulario(cliente: c)),
                        IconButton(icon: Icon(Icons.delete_outline, color: isOscuro ? Colors.redAccent.shade100 : Colors.red, size: 26), onPressed: () => _eliminar(c['id'], c['nombre_completo'])),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class PantallaDetalleCliente extends StatelessWidget {
  final Map<String, dynamic> cliente;
  const PantallaDetalleCliente({super.key, required this.cliente});

  @override
  Widget build(BuildContext context) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isOscuro ? const Color(0xFF0A0A0F) : Colors.white,
      appBar: AppBar(
        title: const Text("Detalle del Cliente"), 
        backgroundColor: isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1), 
        foregroundColor: Colors.white
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(25),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: isOscuro 
                      ? [Colors.cyanAccent, Colors.blueAccent] 
                      : [const Color(0xFF0D47A1), Colors.blue],
                ),
              ),
              child: CircleAvatar(
                radius: 50, 
                backgroundColor: isOscuro ? const Color(0xFF0A0A0F) : Colors.white, 
                child: Icon(Icons.person, size: 60, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1))
              ),
            ),
            const SizedBox(height: 20),
            Text(cliente['nombre_completo'], style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : Colors.black)),
            Text(cliente['nombre_negocio'] ?? "Sin Negocio", style: TextStyle(fontSize: 16, color: isOscuro ? Colors.white38 : Colors.blueGrey, fontWeight: FontWeight.w500)),
            Divider(height: 40, color: isOscuro ? Colors.white10 : Colors.black12),
            _infoRow(Icons.phone, "Teléfono", cliente['telefono'] ?? "N/A", isOscuro),
            _infoRow(Icons.map, "Dirección", cliente['direccion'] ?? "N/A", isOscuro),
            _infoRow(Icons.location_city, "Ubicación", "${cliente['ciudad']}, ${cliente['departamento']}", isOscuro),
            const SizedBox(height: 30),
            
            // 🔥 METRICA FILTRADA: Ahora solo cuenta y suma pedidos en estado 'Completado'
            FutureBuilder<List<Map<String, dynamic>>>(
                future: DBHelper.instance.database.then((db) => db.query(
                  'pedidos', 
                  where: 'cliente_id = ? AND estado = ?', // 🔥 Filtro Completado
                  whereArgs: [cliente['id'], 'Completado']
                )),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) return const CircularProgressIndicator();
                  double total = snapshot.data!.fold(0.0, (sum, item) => sum + (item['total_venta'] as num).toDouble());
                  return Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: isOscuro ? Colors.white.withOpacity(0.04) : Colors.blue.shade50.withOpacity(0.3), 
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: isOscuro ? Colors.white10 : Colors.blue.shade100)
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _stats("Pedidos Completados", snapshot.data!.length.toString(), isOscuro),
                        _stats("Total Compras", "\$${total.toStringAsFixed(0)}", isOscuro),
                      ],
                    ),
                  );
                })
          ],
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value, bool isOscuro) => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Row(
          children: [
            Icon(icon, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)),
            const SizedBox(width: 15),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(color: isOscuro ? Colors.white38 : Colors.grey, fontSize: 12)),
              Text(value.isEmpty ? "N/A" : value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: isOscuro ? Colors.white70 : Colors.black87)),
            ])
          ],
        ),
      );

  Widget _stats(String l, String v, bool isOscuro) => Column(children: [
        Text(l, style: TextStyle(fontSize: 11, color: isOscuro ? Colors.white38 : Colors.blueGrey, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(v, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isOscuro ? Colors.greenAccent : const Color(0xFF0D47A1))),
      ]);
}

class PantallaFormularioCliente extends StatefulWidget {
  final Map<String, dynamic>? cliente;
  final VoidCallback onGuardar;
  const PantallaFormularioCliente({super.key, this.cliente, required this.onGuardar});

  @override
  State<PantallaFormularioCliente> createState() => _PantallaFormularioClienteState();
}

class _PantallaFormularioClienteState extends State<PantallaFormularioCliente> {
  final _n = TextEditingController(), _neg = TextEditingController(), _d = TextEditingController(), _t = TextEditingController();
  final _deptoC = TextEditingController(), _ciuC = TextEditingController();

  List<String> _deptosExistentes = [];
  List<String> _ciudadesExistentes = [];
  List<String> _deptosFiltrados = [];
  List<String> _ciudadesFiltradas = [];

  @override
  void initState() {
    super.initState();
    _cargarSugerencias();
    if (widget.cliente != null) {
      _n.text = widget.cliente!['nombre_completo'] ?? '';
      _neg.text = widget.cliente!['nombre_negocio'] ?? '';
      _d.text = widget.cliente!['direccion'] ?? '';
      _t.text = widget.cliente!['telefono'] ?? '';
      _deptoC.text = widget.cliente!['departamento'] ?? '';
      _ciuC.text = widget.cliente!['ciudad'] ?? '';
    }
  }

  Future<void> _cargarSugerencias() async {
    final db = await DBHelper.instance.database;
    final dRaw = await db.rawQuery('SELECT DISTINCT departamento FROM clientes WHERE departamento != ""');
    final cRaw = await db.rawQuery('SELECT DISTINCT ciudad FROM clientes WHERE ciudad != ""');
    setState(() {
      _deptosExistentes = dRaw.map((e) => e['departamento'].toString()).toList();
      _ciudadesExistentes = cRaw.map((e) => e['ciudad'].toString()).toList();
    });
  }

  void _filtrarDeptos(String q) {
    setState(() {
      _deptosFiltrados = q.isEmpty ? [] : _deptosExistentes.where((d) => d.toLowerCase().contains(q.toLowerCase())).toList();
    });
  }

  void _filtrarCiudades(String q) {
    setState(() {
      _ciudadesFiltradas = q.isEmpty ? [] : _ciudadesExistentes.where((c) => c.toLowerCase().contains(q.toLowerCase())).toList();
    });
  }

  Future<void> _guardar() async {
    if (_n.text.trim().isEmpty || _t.text.trim().isEmpty || _deptoC.text.trim().isEmpty || _ciuC.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('⚠️ Llene los campos obligatorios (Nombre, Teléfono, Ubicación)'), backgroundColor: Colors.orange));
      return;
    }
    if (_t.text.trim().length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('⚠️ El teléfono debe tener al menos 10 dígitos'), backgroundColor: Colors.red));
      return;
    }

    final db = await DBHelper.instance.database;
    final prefs = await SharedPreferences.getInstance();
    final map = {
      'nombre_completo': _n.text.trim(),
      'nombre_negocio': _neg.text.trim(),
      'direccion': _d.text.trim(),
      'telefono': _t.text.trim(),
      'departamento': _deptoC.text.trim(),
      'ciudad': _ciuC.text.trim()
    };

    int idActual;
    if (widget.cliente == null) {
      idActual = await db.insert('clientes', map);
    } else {
      idActual = widget.cliente!['id'];
      await db.update('clientes', map, where: 'id = ?', whereArgs: [idActual]);
    }

    widget.onGuardar();
    if (prefs.getBool('es_premium') ?? false) {
      ServicioNube.guardarClienteNube({...map, 'id': idActual});
    }

    if (mounted) {
      if (widget.cliente == null) {
        ServicioAnuncios.mostrarAnuncioIntersticial(() { if (mounted) Navigator.pop(context); });
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
        title: Text(widget.cliente == null ? 'Nuevo Cliente' : 'Editar Cliente'), 
        backgroundColor: isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1), 
        foregroundColor: Colors.white
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            _buildInput(_n, 'Nombre Completo *', Icons.person, isOscuro),
            const SizedBox(height: 15),
            _buildInput(_t, 'Teléfono *', Icons.phone, isOscuro, keyboard: TextInputType.phone),
            const SizedBox(height: 15),
            _buildBuscador(_deptoC, 'Departamento *', Icons.map, _filtrarDeptos, isOscuro),
            _listaSugerencias(_deptosFiltrados, (val) { _deptoC.text = val; setState(() => _deptosFiltrados = []); }, isOscuro),
            const SizedBox(height: 15),
            _buildBuscador(_ciuC, 'Ciudad / Municipio *', Icons.location_city, _filtrarCiudades, isOscuro),
            _listaSugerencias(_ciudadesFiltradas, (val) { _ciuC.text = val; setState(() => _ciudadesFiltradas = []); }, isOscuro),
            const SizedBox(height: 15),
            _buildInput(_neg, 'Nombre del Negocio (Opcional)', Icons.store, isOscuro),
            const SizedBox(height: 15),
            _buildInput(_d, 'Dirección (Opcional)', Icons.map_outlined, isOscuro),
            const SizedBox(height: 40),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isOscuro ? Colors.cyanAccent.shade700 : const Color(0xFF0D47A1), 
                foregroundColor: isOscuro ? Colors.black : Colors.white, 
                minimumSize: const Size(double.infinity, 55), 
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)) // 🔥 Esquinas de 15
              ),
              onPressed: _guardar,
              child: const Text("GUARDAR CLIENTE", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInput(TextEditingController c, String l, IconData i, bool isOscuro, {TextInputType keyboard = TextInputType.text}) => TextField(
    controller: c, keyboardType: keyboard,
    style: TextStyle(color: isOscuro ? Colors.white : Colors.black),
    decoration: InputDecoration(
      labelText: l, 
      labelStyle: TextStyle(color: isOscuro ? Colors.white60 : Colors.black54),
      prefixIcon: Icon(i, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)), 
      filled: true,
      fillColor: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade50,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(15)), // 🔥 Esquinas de 15
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide(color: isOscuro ? Colors.white10 : Colors.black12)), // 🔥 Esquinas de 15
      isDense: true
    )
  );

  Widget _buildBuscador(TextEditingController c, String l, IconData i, Function(String) onCh, bool isOscuro) => TextField(
    controller: c, onChanged: onCh,
    style: TextStyle(color: isOscuro ? Colors.white : Colors.black),
    decoration: InputDecoration(
      labelText: l, 
      labelStyle: TextStyle(color: isOscuro ? Colors.white60 : Colors.black54),
      prefixIcon: Icon(i, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)), 
      filled: true,
      fillColor: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade50,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(15)), // 🔥 Esquinas de 15
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide(color: isOscuro ? Colors.white10 : Colors.black12)), // 🔥 Esquinas de 15
      isDense: true, 
      suffixIcon: Icon(Icons.search, size: 20, color: isOscuro ? Colors.white38 : Colors.grey)
    )
  );

  Widget _listaSugerencias(List<String> lista, Function(String) onTap, bool isOscuro) {
    if (lista.isEmpty) return const SizedBox.shrink();
    return Card(
      color: isOscuro ? const Color(0xFF1A1A2E) : Colors.white,
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), // 🔥 Esquinas más finas
      child: Column(children: lista.map((s) => ListTile(
        title: Text(s, style: TextStyle(color: isOscuro ? Colors.white70 : Colors.black87)), 
        dense: true, 
        onTap: () => onTap(s)
      )).toList()),
    );
  }
}