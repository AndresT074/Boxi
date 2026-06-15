import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:path_provider/path_provider.dart'; // Para directorio temporal
import 'package:share_plus/share_plus.dart'; // Para compartir

class ServicioPdf {
  // 1. MÉTODO INTERNO PRIVADO: Diseña la factura una sola vez (Evita duplicar código)
  static Future<pw.Document> _crearDocumentoPdf({
    required Map<String, dynamic> pedido,
    required List<Map<String, dynamic>> detalles,
    required String nombreNegocio,
    String? logoPath,
    bool mostrarLogo = true,
  }) async {
    final pdf = pw.Document();

    // Procesar Logo
    pw.Widget? logoWidget;
    if (mostrarLogo && logoPath != null && logoPath.isNotEmpty) {
      try {
        Uint8List? imageBytes;
        if (logoPath.length > 500) {
          imageBytes = base64Decode(logoPath);
        } else {
          final file = File(logoPath);
          if (await file.exists()) {
            imageBytes = await file.readAsBytes();
          }
        }
        if (imageBytes != null) {
          logoWidget = pw.Image(pw.MemoryImage(imageBytes), width: 70, height: 70);
        }
      } catch (e) {
        print("Error cargando logo: $e");
      }
    }

    // Procesar Firma
    Uint8List? firmaBytes;
    if (pedido['firma'] != null) {
      try {
        if (pedido['firma'] is Uint8List) {
          firmaBytes = pedido['firma'];
        } else if (pedido['firma'] is List<int>) {
          firmaBytes = Uint8List.fromList(pedido['firma'] as List<int>);
        }
      } catch (e) {
        print("Error procesando firma: $e");
      }
    }

    // Cálculos de pie de página
    double valorDomicilio = (pedido['valor_domicilio'] ?? 0).toDouble();
    double subtotalProductos = detalles.fold(0, (sum, item) => sum + (item['subtotal'] as num).toDouble());

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(35),
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // ENCABEZADO
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      if (logoWidget != null) logoWidget,
                      pw.SizedBox(height: 5),
                      pw.Text(nombreNegocio.toUpperCase(), 
                        style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: PdfColors.blueGrey900)),
                    ],
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      // 🔥 CORREGIDO: Removido "const" del estilo con color dinámico
                      pw.Text("COMPROBANTE DE VENTA", style: pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
                      pw.Text("No. ${pedido['id']}", 
                        style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
                      pw.Text("FECHA: ${pedido['fecha_hora'] ?? 'S/F'}", style: const pw.TextStyle(fontSize: 10)),
                    ],
                  ),
                ],
              ),
              pw.SizedBox(height: 20),
              pw.Divider(thickness: 1, color: PdfColors.grey300),
              
              // INFORMACIÓN DEL CLIENTE Y VENDEDOR
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text("DATOS DEL CLIENTE", 
                          style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.blueGrey700)),
                        pw.SizedBox(height: 4),
                        pw.Text(pedido['cliente_nombre'] ?? 'N/A', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                        pw.Text("Negocio: ${ (pedido['negocio_nombre']?.toString().trim().isEmpty ?? true) || pedido['negocio_nombre'] == "null" ? 'N/A' : pedido['negocio_nombre']}", style: const pw.TextStyle(fontSize: 9)),
                        pw.Text("Dirección: ${ (pedido['cliente_direccion']?.toString().trim().isEmpty ?? true) || pedido['cliente_direccion'] == "null" ? 'N/A' : pedido['cliente_direccion']}", style: const pw.TextStyle(fontSize: 9)),
                        pw.Text("Ciudad: ${ (pedido['cliente_ciudad']?.toString().trim().isEmpty ?? true) || pedido['cliente_ciudad'] == "null" ? 'N/A' : pedido['cliente_ciudad']}", style: const pw.TextStyle(fontSize: 9)),
                      ],
                    ),
                  ),
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text("VENDEDOR", 
                          style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.blueGrey700)),
                        pw.SizedBox(height: 4),
                        pw.Text(pedido['vendedor_nombre'] ?? 'N/A', style: const pw.TextStyle(fontSize: 9)),
                        pw.Text("Tel: ${pedido['vendedor_telefono'] ?? 'N/A'}", style: const pw.TextStyle(fontSize: 9)),
                      ],
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 20),

              // TABLA DE PRODUCTOS
              pw.TableHelper.fromTextArray(
                // 🔥 CORREGIDO: Removido "const" de la decoración con color dinámico
                headerDecoration: pw.BoxDecoration(color: PdfColors.blueGrey900),
                headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 9),
                cellStyle: const pw.TextStyle(fontSize: 9),
                columnWidths: {
                  0: const pw.FixedColumnWidth(40),
                  1: const pw.FlexColumnWidth(),
                  2: const pw.FixedColumnWidth(70),
                  3: const pw.FixedColumnWidth(70),
                },
                headers: ['CANT', 'PRODUCTO', 'UNITARIO', 'SUBTOTAL'],
                data: detalles.map((d) {
                  double desc = (d['descuento'] ?? 0).toDouble();
                  String nombreFinal = (d['nombre_snapshot'] ?? d['nombre'] ?? 'PRODUCTO').toString().toUpperCase();
                  
                  if (desc > 0) {
                    nombreFinal += " (-${desc.toStringAsFixed(0)}%)";
                  }

                  return [
                    d['cantidad'].toString(), 
                    nombreFinal, 
                    "\$${(d['precio_unitario'] as num).toStringAsFixed(0)}", 
                    "\$${(d['subtotal'] as num).toStringAsFixed(0)}"
                  ];
                }).toList(),
              ),

              pw.SizedBox(height: 15),

              // SECCIÓN DE TOTALES DESGLOSADOS
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.end,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Row(
                        children: [
                          pw.Text("Subtotal Productos: ", style: const pw.TextStyle(fontSize: 10)),
                          pw.Container(width: 70, alignment: pw.Alignment.centerRight, child: pw.Text("\$${subtotalProductos.toStringAsFixed(0)}", style: const pw.TextStyle(fontSize: 10))),
                        ],
                      ),
                      if (valorDomicilio > 0)
                        pw.Row(
                          children: [
                            pw.Text("Envío / Domicilio: ", style: const pw.TextStyle(fontSize: 10)),
                            pw.Container(width: 70, alignment: pw.Alignment.centerRight, child: pw.Text("\$${valorDomicilio.toStringAsFixed(0)}", style: const pw.TextStyle(fontSize: 10))),
                          ],
                        ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(vertical: 4),
                        child: pw.Container(width: 150, height: 1, color: PdfColors.grey400),
                      ),
                      pw.Row(
                        children: [
                          pw.Text("TOTAL A PAGAR: ", style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                          pw.Container(
                            width: 80, 
                            alignment: pw.Alignment.centerRight, 
                            child: pw.Text("\$${(pedido['total_venta'] as num).toStringAsFixed(0)}", 
                              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: PdfColors.green800))
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),

              pw.Spacer(),

              // FIRMA
              pw.Center(
                child: pw.Column(
                  children: [
                    if (firmaBytes != null)
                      pw.Padding(
                        padding: const pw.EdgeInsets.only(bottom: 5),
                        child: pw.Image(pw.MemoryImage(firmaBytes), width: 130, height: 60),
                      ),
                    pw.Container(
                      width: 180, 
                      decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(width: 1, color: PdfColors.black)))
                    ),
                    // 🔥 CORREGIDO: Removido "const" del estilo con color dinámico
                    pw.Text("FIRMA DE RECIBIDO (CLIENTE)", style: pw.TextStyle(fontSize: 7, color: PdfColors.grey700)),
                  ],
                ),
              ),
              pw.SizedBox(height: 10),
              pw.Center(
                child: pw.Text("Gracias por su compra", style: pw.TextStyle(fontSize: 8, fontStyle: pw.FontStyle.italic, color: PdfColors.grey600)),
              )
            ],
          );
        },
      ),
    );

    return pdf;
  }

  // 2. MÉTODO PARA IMPRIMIR FACTURA DIRECTAMENTE
  static Future<void> generarFactura({
    required Map<String, dynamic> pedido,
    required List<Map<String, dynamic>> detalles,
    required String nombreNegocio,
    String? logoPath,
    bool mostrarLogo = true,
  }) async {
    final pdf = await _crearDocumentoPdf(
      pedido: pedido,
      detalles: detalles,
      nombreNegocio: nombreNegocio,
      logoPath: logoPath,
      mostrarLogo: mostrarLogo,
    );

    await Printing.layoutPdf(
      onLayout: (format) async => pdf.save(), 
      name: 'Factura_${pedido['id']}_${pedido['cliente_nombre']}.pdf'
    );
  }

  // 3. MÉTODO PARA COMPARTIR FACTURA (WHATSAPP, CORREO, ETC)
  static Future<void> compartirFactura({
    required Map<String, dynamic> pedido,
    required List<Map<String, dynamic>> detalles,
    required String nombreNegocio,
    String? logoPath,
    bool mostrarLogo = true,
  }) async {
    final pdf = await _crearDocumentoPdf(
      pedido: pedido,
      detalles: detalles,
      nombreNegocio: nombreNegocio,
      logoPath: logoPath,
      mostrarLogo: mostrarLogo,
    );

    final bytes = await pdf.save();
    final dir = await getTemporaryDirectory();
    final file = File("${dir.path}/Factura_${pedido['id']}_${pedido['cliente_nombre'] ?? 'Cliente'}.pdf");
    
    await file.writeAsBytes(bytes);

    await Share.shareXFiles(
      [XFile(file.path)], 
      text: 'Hola ${pedido['cliente_nombre'] ?? 'Cliente'}, adjunto tu comprobante de venta de $nombreNegocio. 📦'
    );
  }

  // 4. NUEVO MÉTODO PREMIUM: Genera y comparte reportes con diseño de alta gama
  static Future<void> compartirReporte({
    required String titulo,
    required double totalCaja,
    required double totalUtilidad,
    required List<dynamic> ventas,
    required String nombreNegocio,
    String? logoPath,
    bool mostrarLogo = true,
    List<dynamic>? ajustes,             // 🔥 NUEVO: Recibe movimientos de capital por separado
    double? capitalReinversion,        // 🔥 NUEVO: Recibe capital global real independiente
  }) async {
    final pdf = pw.Document();

    // Procesar Logo
    pw.Widget? logoWidget;
    if (mostrarLogo && logoPath != null && logoPath.isNotEmpty) {
      try {
        Uint8List? imageBytes;
        if (logoPath.length > 500) {
          imageBytes = base64Decode(logoPath);
        } else {
          final file = File(logoPath);
          if (await file.exists()) {
            imageBytes = await file.readAsBytes();
          }
        }
        if (imageBytes != null) {
          logoWidget = pw.Image(pw.MemoryImage(imageBytes), width: 65, height: 65);
        }
      } catch (e) {
        print("Error cargando logo en reporte: $e");
      }
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(35),
        build: (pw.Context context) {
          return [
            // Barra superior de acento de color de alta gama
            pw.Container(
              height: 6,
              width: double.infinity,
              color: PdfColors.blueGrey900,
              margin: const pw.EdgeInsets.only(bottom: 20),
            ),
            
            // ENCABEZADO PRINCIPAL DEL REPORTE
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      nombreNegocio.toUpperCase(), 
                      style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: PdfColors.blueGrey900)
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      titulo.toUpperCase(), 
                      style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: PdfColors.orange800, letterSpacing: 0.5)
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      "Fecha de Emisión: ${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}", 
                      style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)
                    ),
                  ],
                ),
                if (logoWidget != null) logoWidget,
              ],
            ),
            
            pw.SizedBox(height: 20),
            pw.Divider(thickness: 1, color: PdfColors.grey300),
            pw.SizedBox(height: 10),

            // TÍTULO DE SECCIÓN: VENTAS
            pw.Text(
              "DESGLOSE DETALLADO DE VENTAS", 
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.blueGrey700, letterSpacing: 0.8)
            ),
            pw.SizedBox(height: 8),

            // TABLA 1: VENTAS (Estricta y Limpia)
            pw.TableHelper.fromTextArray(
              headerDecoration: pw.BoxDecoration(color: PdfColors.blueGrey900),
              headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 8),
              cellStyle: const pw.TextStyle(fontSize: 8),
              columnWidths: {
                0: const pw.FixedColumnWidth(65),
                1: const pw.FlexColumnWidth(),
                2: const pw.FixedColumnWidth(95),
                3: const pw.FixedColumnWidth(95),
              },
              headers: ['FECHA', 'CLIENTE / NEGOCIO', 'RECOGIDO TOTAL', 'GANANCIA REAL'],
              data: ventas.map((v) {
                String nom = (v['nombre_completo'] ?? 'Cliente Temporal').toString();
                String neg = (v['nombre_negocio'] != null && v['nombre_negocio'].toString().isNotEmpty && v['nombre_negocio'] != "null") 
                    ? " (${v['nombre_negocio']})" 
                    : "";
                String fechaRaw = v['fecha_hora']?.toString() ?? '';
                String fechaFmt = fechaRaw.length >= 10 ? fechaRaw.substring(0, 10) : fechaRaw;
                
                return [
                  fechaFmt,
                  "$nom$neg".toUpperCase(),
                  "\$${(v['total_venta'] as num? ?? 0).toStringAsFixed(0)}",
                  "\$${(v['ganancia_real'] as num? ?? 0).toStringAsFixed(0)}"
                ];
              }).toList(),
            ),

            // 🔥 TABLA 2: MOVIMIENTOS DE CAPITAL CON SALDO ANTES Y DESPUÉS
            if (ajustes != null && ajustes.isNotEmpty) ...[
              pw.SizedBox(height: 22),
              pw.Text(
                "MOVIMIENTOS DE CAPITAL (REINVERSIONES, INGRESOS Y EGRESOS)", 
                style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.blueGrey700, letterSpacing: 0.8)
              ),
              pw.SizedBox(height: 8),
              pw.TableHelper.fromTextArray(
                headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
                headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 8),
                cellStyle: const pw.TextStyle(fontSize: 8),
                columnWidths: {
                  0: const pw.FixedColumnWidth(60), // Fecha
                  1: const pw.FlexColumnWidth(),   // Movimiento
                  2: const pw.FixedColumnWidth(60), // Antes
                  3: const pw.FixedColumnWidth(65), // Monto (+ / -)
                  4: const pw.FixedColumnWidth(60), // Después
                },
                headers: ['FECHA', 'MOVIMIENTO / AJUSTE', 'ANTES', 'MONTO', 'DESPUÉS'],
                data: ajustes.map((a) {
                  double m = (a['monto'] as num? ?? 0).toDouble();
                  double antes = (a['antes'] as num? ?? 0).toDouble();
                  double despues = (a['despues'] as num? ?? 0).toDouble();
                  
                  String montoSigno = m >= 0 
                      ? "+\$${m.toStringAsFixed(0)}" 
                      : "-\$${m.abs().toStringAsFixed(0)}";
                  
                  String fechaRaw = a['fecha_hora']?.toString() ?? '';
                  String fechaFmt = fechaRaw.length >= 10 ? fechaRaw.substring(0, 10) : fechaRaw;
                  
                  return [
                    fechaFmt,
                    a['descripcion'].toString().toUpperCase(),
                    "\$${antes.toStringAsFixed(0)}",
                    montoSigno,
                    "\$${despues.toStringAsFixed(0)}"
                  ];
                }).toList(),
              ),
            ],

            pw.SizedBox(height: 20),

            // TARJETA DE RESUMEN METRICO DE VENTAS (Muestra totales lógicos de venta)
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.end,
              children: [
                pw.Container(
                  width: 220,
                  padding: const pw.EdgeInsets.all(10),
                  decoration: pw.BoxDecoration(
                    color: PdfColors.grey100,
                    borderRadius: pw.BorderRadius.circular(8),
                    border: pw.Border.all(color: PdfColors.grey300, width: 1),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text("Total Recaudado (Ventas):", style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
                          pw.Text("\$${totalCaja.toStringAsFixed(0)}", style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                        ],
                      ),
                      pw.SizedBox(height: 4),
                      pw.Container(height: 1, color: PdfColors.grey300),
                      pw.SizedBox(height: 4),
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text("Ganancia Ventas Final:", style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: PdfColors.green800)),
                          pw.Text("\$${totalUtilidad.toStringAsFixed(0)}", style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: PdfColors.green800)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // 🔥 TARJETA PREMIUM DE CAPITAL GLOBAL DE REINVERSIÓN REAL
            if (capitalReinversion != null) ...[
              pw.SizedBox(height: 15),
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  color: PdfColors.teal50,
                  borderRadius: pw.BorderRadius.circular(8),
                  border: pw.Border.all(color: PdfColors.teal200, width: 1),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text("CAPITAL DE REINVERSIÓN ACTUAL GLOBAL:", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9, color: PdfColors.teal800)),
                    pw.Text("\$${capitalReinversion.toStringAsFixed(0)}", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 13, color: PdfColors.teal900)),
                  ],
                ),
              ),
            ],

            pw.SizedBox(height: 30),
            pw.Center(
              child: pw.Text(
                "Reporte de centro financiero generado automáticamente por Boxi · Todos los derechos reservados", 
                style: pw.TextStyle(fontSize: 7, color: PdfColors.grey500, fontStyle: pw.FontStyle.italic)
              ),
            ),
          ];
        }
      )
    );

    final bytes = await pdf.save();
    final dir = await getTemporaryDirectory();
    final file = File("${dir.path}/${titulo.replaceAll(' ', '_')}.pdf");
    await file.writeAsBytes(bytes);

    // Comparte el reporte directamente en WhatsApp, Correo, etc.
    await Share.shareXFiles(
      [XFile(file.path)], 
      text: 'Adjunto el $titulo del negocio $nombreNegocio. 📊📈'
    );
  }
}