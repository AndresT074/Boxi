import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'pantalla_bienvenida.dart';
import '../database/db_helper.dart'; 

class PantallaSplash extends StatefulWidget {
  const PantallaSplash({super.key});

  @override
  State<PantallaSplash> createState() => _PantallaSplashState();
}

class _PantallaSplashState extends State<PantallaSplash> {
  late VideoPlayerController _controllerVertical;
  late VideoPlayerController _controllerHorizontal;
  
  bool _videosInicializados = false;
  bool _yaNavego = false; 
  Orientation? _orientacionActual; // Rastrea la posición del celular

  @override
  void initState() {
    super.initState();
    _prepararCargaYVideos();
  }

  // --- LÓGICA DE CARGA ---
  Future<void> _prepararCargaYVideos() async {
    _controllerVertical = VideoPlayerController.asset('assets/videos/splash_vertical.mp4');
    _controllerHorizontal = VideoPlayerController.asset('assets/videos/splash_horizontal.mp4');

    try {
      // 1. Solo inicializamos la memoria, pero NO les damos Play todavía
      await Future.wait([
        _controllerVertical.initialize(),
        _controllerHorizontal.initialize(),
      ]);

      if (mounted) {
        setState(() {
          _videosInicializados = true;
        });
      }

      // 2. Esperamos a que la base de datos cargue Y que el tiempo del video pase
      await Future.wait([
        DBHelper.instance.database, 
        Future.delayed(_controllerVertical.value.duration), 
      ]);

      _irABienvenida();
    } catch (e) {
      debugPrint("Error en Splash: $e");
      await Future.delayed(const Duration(seconds: 2));
      _irABienvenida();
    }
  }

  void _irABienvenida() {
    if (mounted && !_yaNavego) {
      _yaNavego = true;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const PantallaBienvenida()),
      );
    }
  }

  @override
  void dispose() {
    _controllerVertical.dispose();
    _controllerHorizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: _videosInicializados
            ? OrientationBuilder(
                builder: (context, orientation) {
                  bool esVertical = orientation == Orientation.portrait;
                  
                  // Definimos cuál se debe ver y cuál se debe ocultar
                  VideoPlayerController controllerActivo = esVertical ? _controllerVertical : _controllerHorizontal;
                  VideoPlayerController controllerInactivo = esVertical ? _controllerHorizontal : _controllerVertical;

                  // MAGIA DE SINCRONIZACIÓN: Solo se ejecuta si giran el celular o si es la primera vez que arranca
                  if (_orientacionActual != orientation) {
                    _orientacionActual = orientation;
                    
                    // Pausamos el que ya no se ve para liberar el procesador
                    controllerInactivo.pause();
                    
                    // Le copiamos el tiempo exacto al nuevo y le damos Play
                    controllerActivo.seekTo(controllerInactivo.value.position).then((_) {
                      controllerActivo.play();
                    });
                  }

                  return SizedBox.expand(
                    child: FittedBox(
                      fit: BoxFit.cover, 
                      child: SizedBox(
                        width: controllerActivo.value.size.width,
                        height: controllerActivo.value.size.height,
                        child: VideoPlayer(controllerActivo),
                      ),
                    ),
                  );
                },
              )
            : const SizedBox.shrink(), 
      ),
    );
  }
}