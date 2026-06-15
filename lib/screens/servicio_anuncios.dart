import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ServicioAnuncios {
  static InterstitialAd? _anuncioPantallaCompleta;
  static bool _cargandoAnuncio = false;

  // anuncios de abmod 
  static const String _adUnitId = 'ca-app-pub-2754846263403564/1692633493'; 
  // ID de prueba de AdMob ca-app-pub-3940256099942544/1033173712
  static Future<void> iniciar() async {
    await MobileAds.instance.initialize();
    
    RequestConfiguration configuration = RequestConfiguration(
        testDeviceIds:[
          "9429C0EA3E575F262DDCCA7961A764E5", // Mi celular
          "DB4D4DE07471DF5616645D832696C7AA"  // Mi tablet
        ]
      );
    await MobileAds.instance.updateRequestConfiguration(configuration);
    
    cargarAnuncio();
  }

  static void cargarAnuncio() async {
    final prefs = await SharedPreferences.getInstance();
    bool esPremium = prefs.getBool('es_premium') ?? false;

    // Si es premium, o ya está cargando, o ya hay un anuncio listo, no hacemos nada.
    if (esPremium || _cargandoAnuncio || _anuncioPantallaCompleta != null) return;

    _cargandoAnuncio = true;
    
    InterstitialAd.load(
      adUnitId: _adUnitId, 
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _anuncioPantallaCompleta = ad;
          _cargandoAnuncio = false;
        },
        onAdFailedToLoad: (error) {
          _anuncioPantallaCompleta = null;
          _cargandoAnuncio = false;
          
          // SOLUCIÓN 1: Si falla la carga (ej. no hay internet), reintenta en 15 segundos.
          Future.delayed(const Duration(seconds: 15), () {
            cargarAnuncio();
          });
        },
      ),
    );
  }

  static Future<void> mostrarAnuncioIntersticial(VoidCallback alTerminar) async {
    final prefs = await SharedPreferences.getInstance();
    bool esPremium = prefs.getBool('es_premium') ?? false;

    if (esPremium) {
      alTerminar();
      return;
    }

    // SOLUCIÓN 2: Si el anuncio no cargó, realizamos la acción pero OBLIGAMOS a cargar uno para el futuro.
    if (_anuncioPantallaCompleta == null) {
      alTerminar();
      cargarAnuncio(); 
      return;
    }

    _anuncioPantallaCompleta!.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _anuncioPantallaCompleta = null;
        cargarAnuncio(); // Carga el siguiente después de cerrar
        alTerminar();
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        _anuncioPantallaCompleta = null;
        
        // SOLUCIÓN 3: Si por algún motivo falló al mostrarse en pantalla, obligamos a recargar.
        cargarAnuncio(); 
        alTerminar();
      },
    );

    _anuncioPantallaCompleta!.show();
  }
}