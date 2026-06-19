import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart'; 
import 'servicio_auth.dart';

class PantallaLogin extends StatefulWidget {
  const PantallaLogin({super.key});
  @override
  State<PantallaLogin> createState() => _PantallaLoginState();
}

class _PantallaLoginState extends State<PantallaLogin> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _esRegistro = false;
  bool _cargando = false;
  bool _ocultarPass = true; 

  void _procesar() async {
    if (_emailCtrl.text.isEmpty || _passCtrl.text.isEmpty) return;
    setState(() => _cargando = true);
    try {
      if (_esRegistro) {
        await ServicioAuth.registrarUsuario(_emailCtrl.text.trim(), _passCtrl.text.trim());
        _snack("📧 Registro casi listo. Revisa tu correo (y el Spam) para verificar.", Colors.blue);
        setState(() => _esRegistro = false);
      } else {
        final user = await ServicioAuth.loginUsuario(_emailCtrl.text.trim(), _passCtrl.text.trim());
        if (user != null) Navigator.pop(context, true);
      }
    } catch (e) {
      if (e.toString().contains("EMAIL_NOT_VERIFIED")) {
        _mostrarAlertaVerificacion(); 
      } else {
        _snack("❌ Datos incorrectos", Colors.red);
      }
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  void _procesarGoogle() async {
    setState(() => _cargando = true);
    try {
      await GoogleSignIn().signOut(); 
      
      final user = await ServicioAuth.loginConGoogle();
      if (user != null) Navigator.pop(context, true);
    } catch (e) {
      _snack("❌ Error con Google", Colors.red);
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  void _mostrarAlertaVerificacion() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF041E42),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: const BorderSide(color: Colors.orangeAccent)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange),
            SizedBox(width: 10),
            Text("Cuenta Inactiva", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: const Text(
          "Tu cuenta aún no ha sido verificada. Debes hacer clic en el enlace que te enviamos al correo cuando te registraste.\n\nRevisa tu carpeta de Spam o Correo no deseado.",
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _reenviarCorreoSeguro(); 
            }, 
            child: const Text("REENVIAR CORREO", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold))
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orangeAccent),
            onPressed: () => Navigator.pop(ctx), 
            child: const Text("ENTENDIDO", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold))
          ),
        ],
      )
    );
  }

  void _recuperarPassword() async {
    String email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      _snack("⚠️ Escribe tu correo en el campo de arriba para enviarte el link.", Colors.orange);
      return;
    }
    setState(() => _cargando = true);
    bool enviado = await ServicioAuth.enviarRecuperacionPassword(email);
    setState(() => _cargando = false);

    if (enviado) {
      _snack("📧 Link de recuperación enviado a $email.", Colors.green);
    } else {
      _snack("❌ No se encontró una cuenta con ese correo.", Colors.red);
    }
  }

  void _reenviarCorreoSeguro() async {
    String email = _emailCtrl.text.trim();
    String pass = _passCtrl.text.trim();

    if (email.isEmpty || pass.isEmpty) {
      _snack("⚠️ Escribe tu correo y contraseña para poder reenviarlo.", Colors.orange);
      return;
    }
    setState(() => _cargando = true);
    try {
      UserCredential userCredential = await FirebaseAuth.instance.signInWithEmailAndPassword(email: email, password: pass);
      User? user = userCredential.user;

      if (user != null && !user.emailVerified) {
        await user.sendEmailVerification();
        await FirebaseAuth.instance.signOut(); 
        _snack("📧 ¡Listo! Te enviamos un NUEVO correo de verificación (Revisa el Spam).", Colors.green);
      }
    } catch (e) {
      bool enviado = await ServicioAuth.enviarRecuperacionPassword(email);
      if (enviado) {
        _snack("📧 Te enviamos un correo de Recuperación (Revisa Spam). Cámbiala y tu cuenta se verificará automáticamente.", Colors.green);
      } else {
        _snack("❌ Error: No se encontró una cuenta con ese correo.", Colors.red);
      }
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  void _snack(String m, Color c) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: c, behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // FONDO DE GRADIENTE AZUL MARINO
          Container(decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF041E42), Color(0xFF0D47A1)]))),
          
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 30),
              child: Column(
                children: [
                  const SizedBox(height: 50),
                  // LOGO CIRCULAR
                  Container(
                    width: 100, height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withOpacity(0.08),
                      border: Border.all(color: Colors.white24)
                    ),
                    child: const Icon(Icons.shopping_cart_rounded, size: 50, color: Colors.orangeAccent),
                  ),
                  const SizedBox(height: 15),
                  const Text("Administra Pedidos", style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                  const Text("Administra tus pedidos fácilmente", style: TextStyle(color: Colors.white60, fontSize: 13)),
                  
                  const SizedBox(height: 30),

                  // TARJETA DE LOGIN OSCURA TRANSLÚCIDA (GLASSMORPHISM)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: Container(
                        padding: const EdgeInsets.all(25),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0D1B2A).withOpacity(0.8), // Color oscuro con opacidad
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(color: Colors.white.withOpacity(0.12)), // Borde brillante de cristal
                        ),
                        child: Column(
                          children: [
                            Text(
                              _esRegistro ? "Crear Cuenta" : "Bienvenido", 
                              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.cyanAccent)
                            ),
                            const SizedBox(height: 25),
                            _campo(_emailCtrl, "Correo electrónico", Icons.email_outlined, false),
                            const SizedBox(height: 15),
                            _campo(_passCtrl, "Contraseña", Icons.lock_outline, true),
                            
                            // RECUPERAR CONTRASEÑA (Texto adaptado a claro)
                            if (!_esRegistro)
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: _recuperarPassword, 
                                  child: const Text("¿Olvidaste tu contraseña?", style: TextStyle(color: Colors.white60, fontSize: 12))
                                )
                              )
                            else
                              const SizedBox(height: 25),
                            
                            if (_cargando) 
                              const CircularProgressIndicator(color: Colors.cyanAccent)
                            else ...[
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF4A89F3),
                                  minimumSize: const Size(double.infinity, 55),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                                  elevation: 0
                                ),
                                onPressed: _procesar,
                                child: Text(_esRegistro ? "Registrarse" : "Iniciar Sesión", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(double.infinity, 50),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                                  side: const BorderSide(color: Colors.white24), // Borde blanco sutil
                                ),
                                onPressed: () => setState(() => _esRegistro = !_esRegistro),
                                child: Text(_esRegistro ? "Ya tengo cuenta" : "Crear Cuenta", style: const TextStyle(color: Colors.white70)),
                              ),
                            ],
                            
                            // NO LLEGÓ EL CORREO
                            if (_esRegistro)
                              TextButton(
                                onPressed: _reenviarCorreoSeguro, 
                                child: const Text("¿No te llegó el correo de verificación?", style: TextStyle(color: Colors.cyanAccent, fontSize: 11, decoration: TextDecoration.underline))
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 30),
                  const Row(
                    children: [
                      Expanded(child: Divider(color: Colors.white12, thickness: 1)),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 15),
                        child: Text("O", style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold)),
                      ),
                      Expanded(child: Divider(color: Colors.white12, thickness: 1)),
                    ],
                  ),
                  const SizedBox(height: 25),

                  // BOTÓN DE GOOGLE
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      minimumSize: const Size(double.infinity, 55),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                    ),
                    onPressed: _procesarGoogle,
                    icon: Image.network(
                      'https://upload.wikimedia.org/wikipedia/commons/thumb/c/c1/Google_%22G%22_logo.svg/120px-Google_%22G%22_logo.svg.png', 
                      height: 22,
                      errorBuilder: (context, error, stackTrace) => const Icon(Icons.g_mobiledata, color: Colors.blue, size: 30),
                    ),
                    label: const Text("Continuar con Google", style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  
                  const SizedBox(height: 25),
                  const Text("Al continuar, aceptas nuestros Términos y Condiciones", style: TextStyle(color: Colors.white38, fontSize: 10)),
                  const SizedBox(height: 10),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text("VOLVER AL INICIO", style: TextStyle(color: Colors.white38))),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _campo(TextEditingController ctrl, String hint, IconData icon, bool pass) {
    return TextField(
      controller: ctrl,
      obscureText: pass ? _ocultarPass : false,
      // Color de la letra que se escribe (blanco brillante y grosor medio)
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        // Letra del hint/placeholder en color gris claro para que se lea perfectamente
        hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
        prefixIcon: Icon(icon, color: Colors.orangeAccent), // Iconos naranja adaptativos
        suffixIcon: pass 
            ? IconButton(
                icon: Icon(_ocultarPass ? Icons.visibility : Icons.visibility_off, color: Colors.white54), 
                onPressed: () => setState(() => _ocultarPass = !_ocultarPass)
              ) 
            : null,
        filled: true, 
        fillColor: const Color(0xFF07111E), // Cuadro azul-negro oscuro profundo
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
      ),
    );
  }
}