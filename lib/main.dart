// main.dart - VERSÃO FINAL INTEGRADA COM ADS-B REAL NO MAPA, SELEÇÃO DE MAPA, BUSCA, RASTROS E DADOS ADICIONAIS

import 'dart:async';
import 'dart:collection';
import 'dart:math'; // Usado para Random e cálculo de PI
import 'dart:convert'; // Necessário para jsonDecode

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http; // Para requisições HTTP
import 'package:audioplayers/audioplayers.dart'; // Para reprodução de áudio

import 'package:flutter_map/flutter_map.dart'; // Para o componente de mapa
import 'package:latlong2/latlong.dart'; // Para LatLng e cálculos de distância geográfica

// --- Funções Auxiliares para Parse de Números Seguros ---
// Colocadas no topo para fácil acesso e uso em Aircraft.fromJson
int? _safeParseInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is double) return value.toInt(); // Converte double para int
  if (value is String) return int.tryParse(value); // Tenta parsear string para int
  return null; // Retorna null se o tipo não for esperado
}

double? _safeParseDouble(dynamic value) {
  if (value == null) return null;
  if (value is int) return value.toDouble(); // Converte int para double
  if (value is double) return value;
  if (value is String) return double.tryParse(value); // Tenta parsear string para double
  return null;
}

// --- MODELO DE DADOS DA AERONAVE REAL (do ADS-B) ---
class Aircraft {
  final String hex; // Código ICAO da aeronave
  final String? flight; // Número do voo/Callsign (pode ser nulo)
  final double? lat; // Latitude
  final double? lon; // Longitude
  final int? altitude; // Altitude em pés (alt_baro)
  final int? vertRate; // Razão vertical em pés/min (baro_rate)
  final int? track; // Rumo em graus
  final int? speed; // Velocidade no solo em nós (gs)
  final int? squawk; // Código Squawk
  final int messages; // Quantidade de mensagens recebidas
  final double seen; // Há quanto tempo a aeronave foi vista pela última vez em segundos
  
  // --- NOVOS CAMPOS ADICIONADOS ---
  final int? tas; // True Airspeed (Velocidade Verdadeira no Ar)
  final double? altGeom; // Geometric Altitude (Altitude Geométrica via GPS)
  final List<LatLng> trailPoints; // Lista para o rastro histórico
  final int? _previousAltitude; // Campo privado para a altitude anterior
  final String? category; // <<-- NOVO: Categoria da aeronave (ex: "A0", "A3")
  final double? rssi; // <<-- NOVO: Força do sinal recebido
  // --------------------------------

  AircraftStatus status; // Estado visual (normal, selecionado, alerta, etc.)
  int? targetFL; // Para manobras de TCAS/Desvio
  String displayId; // Pode ser callsign ou hex, para exibição no UI

  Aircraft({
    required this.hex,
    this.flight,
    this.lat,
    this.lon,
    this.altitude,
    this.vertRate,
    this.track,
    this.speed,
    this.squawk,
    required this.messages,
    required this.seen,
    this.tas,
    this.altGeom,
    this.trailPoints = const [],
    this.status = AircraftStatus.normal,
    this.targetFL,
    int? previousAltitude,
    this.category, // <<-- Incluindo no construtor
    this.rssi, // <<-- Incluindo no construtor
  }) : _previousAltitude = previousAltitude,
       displayId = flight ?? hex;

  factory Aircraft.fromJson(Map<String, dynamic> json) {
    return Aircraft(
      hex: json['hex'] as String,
      flight: (json['flight'] as String?)?.trim(),
      lat: _safeParseDouble(json['lat']),
      lon: _safeParseDouble(json['lon']),
      altitude: _safeParseInt(json['alt_baro']),
      vertRate: _safeParseInt(json['baro_rate']),
      track: _safeParseInt(json['track']),
      speed: _safeParseInt(json['gs']),
      squawk: _safeParseInt(json['squawk']),
      messages: _safeParseInt(json['messages']) ?? 0,
      seen: _safeParseDouble(json['seen']) ?? 0.0,
      tas: _safeParseInt(json['tas']),
      altGeom: _safeParseDouble(json['alt_geom']),
      trailPoints: const [],
      previousAltitude: null,
      category: json['category'] as String?, // <<-- Lendo 'category' como String
      rssi: _safeParseDouble(json['rssi']), // <<-- Lendo 'rssi' como double
    );
  }

  Aircraft copyWith({
    String? hex,
    String? flight,
    double? lat,
    double? lon,
    int? altitude,
    int? vertRate,
    int? track,
    int? speed,
    int? squawk,
    int? messages,
    double? seen,
    int? tas,
    double? altGeom,
    List<LatLng>? trailPoints,
    AircraftStatus? status,
    int? targetFL,
    int? previousAltitude,
    String? category, // <<-- Incluindo no copyWith
    double? rssi, // <<-- Incluindo no copyWith
  }) {
    return Aircraft(
      hex: hex ?? this.hex,
      flight: flight ?? this.flight,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      altitude: altitude ?? this.altitude,
      vertRate: vertRate ?? this.vertRate,
      track: track ?? this.track,
      speed: speed ?? this.speed,
      squawk: squawk ?? this.squawk,
      messages: messages ?? this.messages,
      seen: seen ?? this.seen,
      tas: tas ?? this.tas,
      altGeom: altGeom ?? this.altGeom,
      trailPoints: trailPoints ?? this.trailPoints,
      status: status ?? this.status,
      targetFL: targetFL ?? this.targetFL,
      previousAltitude: previousAltitude ?? this._previousAltitude,
      category: category ?? this.category, // Copia a categoria
      rssi: rssi ?? this.rssi, // Copia o RSSI
    );
  }
}

// --- SERVIÇO DE DADOS ADS-B ---
class AdsbService {
  final String _flightFeederUrl;

  AdsbService(this._flightFeederUrl);

  Future<List<Aircraft>> fetchAircraftData() async {
    final baseUri = Uri.parse(_flightFeederUrl.split('?').first);

    try {
      final response = await http.get(baseUri);

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final List<dynamic> aircraftListJson = data['aircraft'];

        return aircraftListJson
            .map((json) => Aircraft.fromJson(json as Map<String, dynamic>))
            .where((a) => a.lat != null && a.lon != null && a.altitude != null && (a.flight != null || a.hex != null))
            .toList();
      } else {
        print('Erro HTTP ao carregar dados do ADS-B: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      print('Erro ao conectar ao FlightFeeder ou processar dados: $e');
      return [];
    }
  }
}

// --- Outros Enums e Modelos ---

enum AircraftStatus { normal, selected, fail, tcasAlert, deviating }

class WeatherCell {
  final LatLngBounds bounds;
  final int startFl;
  final int endFl;
  WeatherCell({required this.bounds, required this.startFl, required this.endFl});
}

// --- Aplicação Principal ---

void main() { runApp(const RVSMApp()); }

class RVSMApp extends StatelessWidget {
  const RVSMApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RVSM / ADS-B',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF87CEEB),
        colorScheme: const ColorScheme.dark(primary: Colors.white, onPrimary: Colors.black, surface: Color(0xFF000032)),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Color(0xFF000032)),
          titleLarge: TextStyle(color: Color(0xFF000032), fontWeight: FontWeight.bold),
        ),
      ),
      home: const AdsbMonitorScreen(),
    );
  }
}

// --- Nova Tela Principal: Monitor ADS-B ---

class AdsbMonitorScreen extends StatefulWidget {
  const AdsbMonitorScreen({super.key});
  @override
  State<AdsbMonitorScreen> createState() => _AdsbMonitorScreenState();
}

class _AdsbMonitorScreenState extends State<AdsbMonitorScreen> with SingleTickerProviderStateMixin {
  final List<int> rvsmFlightLevels = [290, 300, 310, 320, 330, 340, 350, 360, 370, 380, 390, 400, 410];
  
  // --- URLs dos Tipos de Mapa ---
  static const String _osmUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String _esriSatelliteUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
  // -----------------------------

  // --- Variável para controlar o tipo de mapa ---
  String _currentMapUrl = _osmUrl;
  bool _isSatelliteMode = false;
  // ---------------------------------------------

  // --- Variáveis de estado para dados ADS-B ---
  final AdsbService _adsbService = AdsbService('http://192.168.10.100:8080/data/aircraft.json'); // SEU IP AQUI
  List<Aircraft> _rvsmAircrafts = []; // Aeronaves reais, filtradas por RVSM
  Aircraft? _selectedAircraft; // Aeronave selecionada no mapa
  Timer? _adsbFetchTimer; // Timer para buscar dados ADS-B periodicamente
  bool _isAdsbLoading = true;
  
  // --- NOVAS VARIÁVEIS DE ESTADO PARA MENSAGENS REAIS ---
  Map<String, int?> _lastKnownSquawks = {}; // Armazena o último squawk conhecido por HEX
  Set<String> _previousRVSMHexes = {}; // Armazena HEXes da última lista RVSM para detectar entrada/saída
  // ---------------------------------------------------

  // --- BUSCA E FILTRO DE AERONAVES ---
  bool _isSearching = false; // Controla a visibilidade do campo de busca
  TextEditingController _searchController = TextEditingController(); // Controlador para o texto de busca
  String _searchQuery = ''; // A query de busca atual
  
  // --- NOVAS VARIÁVEIS DE ESTADO PARA FILTROS ---
  double _minAltitudeFilter = 29000; // Altitude mínima em pés
  double _maxAltitudeFilter = 41000; // Altitude máxima em pés
  double _minSpeedFilter = 0; // Velocidade mínima em nós
  double _maxSpeedFilter = 1000; // Velocidade máxima em nós (valor alto para incluir tudo)
  Set<AircraftStatus> _selectedStatusFilters = AircraftStatus.values.toSet(); // Todos os status selecionados por padrão
  // -----------------------------------


  // --- Áudio ---
  final AudioPlayer audioPlayer = AudioPlayer(); // Player para sons gerais
  final AudioPlayer climbAudioPlayer = AudioPlayer(); // Player para som de subida
  final AudioPlayer descendAudioPlayer = AudioPlayer(); // Player para som de descida
  final AudioPlayer tcasAlertAudioPlayer = AudioPlayer(); // Player para alerta TCAS inicial
  bool isAudioEnabled = true;
  // ------------------------------------

  // --- Lógica de Eventos / ATC Log (adaptada) ---
  final Queue<String> atcMessages = Queue();
  Timer? _contingencyTimer, _tcasTimer, _weatherTimer; // _spawnTimer removido
  AnimationController? _animationController; // Mantido para o "tick" de atualização lógica
  bool isPaused = false;
  // -----------------------------------------------

  // --- Variáveis de UI e Controle ---
  final MapController _mapController = MapController();
  WeatherCell? weatherCell;
  List<Polyline> _projectedPaths = []; // Lista para trajetórias projetadas
  List<Polyline> _aircraftTrails = []; // Lista para os rastros históricos
  // --------------------------------------------------------

  @override
  void initState() {
    super.initState();
    // Listener para o campo de busca
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text;
      });
    });

    _animationController = AnimationController(vsync: this, duration: const Duration(days: 1))
      ..addListener(() {
        if (!isPaused) {
          _updateLogicForRealData();
          setState(() {});
        }
      });
    _animationController?.repeat();
    
    _startAdsbFetching();
    _startEventTimers();
  }

  // Inicia a busca de dados ADS-B
  void _startAdsbFetching() {
    _fetchAndFilterRealAircraft(); // Busca inicial imediatamente
    _adsbFetchTimer = Timer.periodic(const Duration(seconds: 5), (timer) { // Busca a cada 5 segundos
      if (!isPaused) { 
        _fetchAndFilterRealAircraft();
      }
    });
  }

  // Para a busca de dados ADS-B
  void _stopAdsbFetching() {
    _adsbFetchTimer?.cancel();
  }

  // Função para buscar e filtrar as aeronaves ADS-B
  Future<void> _fetchAndFilterRealAircraft() async {
    if (!mounted) return;
    
    print('--- ${DateTime.now().toLocal()} - Iniciando busca de aeronaves ADS-B ---'); 

    setState(() {
      _isAdsbLoading = true;
    });

    List<Aircraft> fetchedAircrafts = [];
    try {
      fetchedAircrafts = await _adsbService.fetchAircraftData();
      print('Busca concluída. Total de aeronaves recebidas (antes do filtro RVSM): ${fetchedAircrafts.length}');
      if (fetchedAircrafts.isNotEmpty) {
        print('Exemplo de aeronave (primeira): Hex: ${fetchedAircrafts.first.hex}, Alt: ${fetchedAircrafts.first.altitude}, Lat: ${fetchedAircrafts.first.lat}, Lon: ${fetchedAircrafts.first.lon}');
      } else {
        print('Nenhuma aeronave recebida na busca atual (lista vazia).');
      }
    } catch (e) {
      print('ERRO DURANTE A BUSCA OU PROCESSAMENTO DO ADS-B: $e');
    }

    setState(() {
      List<Aircraft> newRVSMAircrafts = [];
      for (var newAc in fetchedAircrafts) {
        final existingAc = _rvsmAircrafts.firstWhereOrNull((ac) => ac.hex == newAc.hex);
        if (existingAc != null) {
          // Copia dados novos, mas mantém status, targetFL e TRAIL POINTS EXISTENTES
          // E também a altitude anterior para a lógica de transição RVSM
          newRVSMAircrafts.add(newAc.copyWith(status: existingAc.status, targetFL: existingAc.targetFL, trailPoints: existingAc.trailPoints, previousAltitude: existingAc._previousAltitude)); 
        } else {
          newRVSMAircrafts.add(newAc.copyWith(previousAltitude: newAc.altitude)); // Nova aeronave, previousAltitude é a altitude atual
        }
      }
      
      // --- FILTRO RVSM ATIVO ---
      // Esta linha mostra APENAS as aeronaves com altitude entre FL290-FL410.
      // Para mostrar TODAS as aeronaves para depurar, você pode comentar esta linha
      // e usar a linha de baixo (_rvsmAircrafts = newRVSMAircrafts.where((a) => a.lat != null && a.lon != null && a.altitude != null).toList();)
      _rvsmAircrafts = newRVSMAircrafts
          .where((a) => a.altitude != null && a.altitude! >= 29000 && a.altitude! <= 41000) 
          .toList();
      // ------------------------

      // --- LÓGICA DE DETECÇÃO DE ENTRADA/SAÍDA E SQUAWK DE EMERGÊNCIA NO ESPAÇO RVSM ---
      Set<String> currentRVSMHexesInFilteredList = _rvsmAircrafts.map((a) => a.hex).toSet();

      for (String hex in _previousRVSMHexes) { // Iterar sobre os hexes da busca ANTERIOR
        if (!currentRVSMHexesInFilteredList.contains(hex)) {
          final Aircraft? exitedAc = _rvsmAircrafts.firstWhereOrNull((ac) => ac.hex == hex); // Tenta pegar da lista atual (se ainda estiver lá mas fora do filtro)
          if (exitedAc != null) {
             _addAtcMessage("ATC: Aeronave ${exitedAc.displayId} saiu da área de cobertura RVSM."); // Ou refine para "saiu da área" ou "saiu do espaço RVSM"
             _lastKnownSquawks.remove(exitedAc.hex);
          } else { // Se não está nem na lista atual, então saiu de cobertura
              // Precisamos do objeto da aeronave que saiu para displayId. 
              // Melhor rastrear todos os Aircrafts para a mensagem de saída.
              // Por agora, o filtro atual de _previousRVSMHexes vs _rvsmAircrafts já implica saída RVSM.
          }
        }
      }

      for (Aircraft currentAc in _rvsmAircrafts) {
        // --- Detecção de Entrada no Espaço RVSM ---
        bool wasInRVSM = currentAc._previousAltitude != null && currentAc._previousAltitude! >= 29000 && currentAc._previousAltitude! <= 41000;
        bool isInRVSM = currentAc.altitude != null && currentAc.altitude! >= 29000 && currentAc.altitude! <= 41000;

        if (!wasInRVSM && isInRVSM) {
            _addAtcMessage("ATC: Aeronave ${currentAc.displayId} entrou no espaço aéreo RVSM (FL${(currentAc.altitude! / 100).toInt()}).");
        } else if (wasInRVSM && !isInRVSM) {
            _addAtcMessage("ATC: Aeronave ${currentAc.displayId} saiu do espaço aéreo RVSM (FL${(currentAc.altitude! / 100).toInt()}).");
        }
        // --- Fim da Detecção de Transição ---

        // Verificar Squawk de Emergência
        final int? lastSquawk = _lastKnownSquawks[currentAc.hex];
        if (currentAc.squawk != null && lastSquawk != currentAc.squawk) {
          if (currentAc.squawk == 7500) {
            _addAtcMessage("ATC: EMERGÊNCIA! Aeronave ${currentAc.displayId} SQUAWK 7500 (Sequestro)!");
          } else if (currentAc.squawk == 7600) {
            _addAtcMessage("ATC: EMERGÊNCIA! Aeronave ${currentAc.displayId} SQUAWK 7600 (Falha de Comunicação)!");
          } else if (currentAc.squawk == 7700) {
            _addAtcMessage("ATC: EMERGÊNCIA! Aeronave ${currentAc.displayId} SQUAWK 7700 (Emergência Geral)!");
          }
        }
        _lastKnownSquawks[currentAc.hex] = currentAc.squawk;
      }

      _previousRVSMHexes = currentRVSMHexesInFilteredList;
      // --- FIM DA LÓGICA DE DETECÇÃO DE ENTRADA/SAÍDA E SQUAWK DE EMERGÊNCIA ---

      _isAdsbLoading = false;
      print('Aeronaves RVSM após filtro: ${_rvsmAircrafts.length}');
      print('--- ${DateTime.now().toLocal()} - Fim do ciclo de busca ADS-B ---');
    });
  }

  void _updateLogicForRealData() {
    setState(() {
      _rvsmAircrafts.removeWhere((ac) => ac.seen > 30); // Remove aeronaves não vistas por mais de 30s

      // --- Cálculo das Trajetórias Projetadas e Rastros ---
      _projectedPaths.clear(); 
      _aircraftTrails.clear(); 
      
      final Distance distanceCalculator = const Distance(); 
      const int maxTrailPoints = 20; 
      const int projectionTimeSeconds = 60; 

      for (var ac in _rvsmAircrafts) { 
        // Adicionar ponto atual ao rastro histórico
        if (ac.lat != null && ac.lon != null) {
          List<LatLng> currentTrail = List.from(ac.trailPoints);
          currentTrail.add(LatLng(ac.lat!, ac.lon!));
          if (currentTrail.length > maxTrailPoints) {
            currentTrail.removeAt(0);
          }
          final int index = _rvsmAircrafts.indexOf(ac);
          if (index != -1) {
            _rvsmAircrafts[index] = ac.copyWith(trailPoints: currentTrail);
          }
          
          if (currentTrail.length >= 2) {
            _aircraftTrails.add(
              Polyline(
                points: currentTrail,
                color: Colors.white.withOpacity(0.4),
                strokeWidth: 1.5,
              ),
            );
          }
        }

        // Calcular Trajetória Projetada
        if (ac.lat != null && ac.lon != null && ac.track != null && ac.speed != null && ac.speed! > 0) {
          final LatLng startPoint = LatLng(ac.lat!, ac.lon!);
          final double speedMetersPerSecond = ac.speed! * 0.514444; 
          final double projectionDistanceMeters = speedMetersPerSecond * projectionTimeSeconds;

          final LatLng endPoint = distanceCalculator.offset(
            startPoint,
            projectionDistanceMeters,
            ac.track!,
          );

          _projectedPaths.add(
            Polyline(
              points: [startPoint, endPoint],
              color: ac.status == AircraftStatus.selected ? Colors.yellow : Colors.cyan.withOpacity(0.6), 
              strokeWidth: 2.0,
              isDotted: true,
            ),
          );
        }
      }
    });
  }

  void _startEventTimers() {
    _contingencyTimer = Timer.periodic(const Duration(seconds: 15), (timer) { if (!isPaused) _triggerRandomContingency(); });
    _tcasTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) { if (!isPaused) _checkForTcasAlerts(); });
    _weatherTimer = Timer.periodic(const Duration(seconds: 20), (timer) { if(!isPaused) _spawnWeatherCell(); });
  }

  void _stopEventTimers() {
    _contingencyTimer?.cancel(); _tcasTimer?.cancel(); _weatherTimer?.cancel();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _stopAdsbFetching(); 
    _stopEventTimers();
    _animationController?.dispose();
    audioPlayer.dispose();
    climbAudioPlayer.dispose();
    descendAudioPlayer.dispose();
    tcasAlertAudioPlayer.dispose();
    super.dispose();
  }

  void _addAtcMessage(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if(mounted) {
        setState(() {
          atcMessages.addFirst(message);
          if (atcMessages.length > 10) atcMessages.removeLast();
        });
      }
    });
  }

  void _spawnWeatherCell() {
    if (!mounted) return;
    final random = Random();
    
    const LatLng palmasCenter = LatLng(-10.16076, -48.31123); 
    final double latOffset = (random.nextDouble() * 0.5 - 0.25);
    final double lonOffset = (random.nextDouble() * 0.5 - 0.25);

    final LatLng center = LatLng(palmasCenter.latitude + latOffset, palmasCenter.longitude + lonOffset);
    
    final double sizeDegrees = 0.1 + random.nextDouble() * 0.2;

    final LatLngBounds newBounds = LatLngBounds(
      LatLng(center.latitude - sizeDegrees / 2, center.longitude - sizeDegrees / 2),
      LatLng(center.latitude + sizeDegrees / 2, center.longitude + sizeDegrees / 2),
    );

    final startFl = rvsmFlightLevels[random.nextInt(rvsmFlightLevels.length - 4)];
    final endFl = startFl + random.nextInt(2) * 10 + 20;
    
    setState(() {
      weatherCell = WeatherCell(
        bounds: newBounds,
        startFl: startFl,
        endFl: endFl,
      );
    });
    _addAtcMessage("ATC: ALERTA METEOROLÓGICO entre FL$startFl e FL$endFl.");
    Timer(const Duration(seconds: 15), () => setState(() => weatherCell = null));
  }

  void _checkForTcasAlerts() {
    for (int i = 0; i < _rvsmAircrafts.length; i++) {
      for (int j = i + 1; j < _rvsmAircrafts.length; j++) {
        Aircraft ac1 = _rvsmAircrafts[i];
        Aircraft ac2 = _rvsmAircrafts[j];

        if (ac1.lat == null || ac1.lon == null || ac1.altitude == null ||
            ac2.lat == null || ac2.lon == null || ac2.altitude == null) {
          continue;
        }

        if (ac1.status != AircraftStatus.tcasAlert && ac2.status != AircraftStatus.tcasAlert &&
            ac1.status != AircraftStatus.deviating && ac2.status != AircraftStatus.deviating) {
          
          final Distance distance = const Distance();
          final double horizontalDistanceMeters = distance(
            LatLng(ac1.lat!, ac1.lon!),
            LatLng(ac2.lat!, ac2.lon!),
          );
          final double horizontalDistanceNauticalMiles = horizontalDistanceMeters / 1852;

          final int verticalSeparationFeet = (ac1.altitude! - ac2.altitude!).abs();

          if (horizontalDistanceNauticalMiles < 5 && verticalSeparationFeet < 1000) { 
            
            Aircraft climbAircraft = ac1.altitude! < ac2.altitude! ? ac1 : ac2;
            Aircraft descendAircraft = ac1.altitude! >= ac2.altitude! ? ac1 : ac2;

            _addAtcMessage("TCAS RA: ${climbAircraft.displayId} SUBA. ${descendAircraft.displayId} DESÇA.");
            
            if(isAudioEnabled) {
              tcasAlertAudioPlayer.play(AssetSource('sounds/tcas_alert.mp3'));
              Future.delayed(const Duration(milliseconds: 1500), () {
                 if(isAudioEnabled) {
                    climbAudioPlayer.play(AssetSource('sounds/climb.mp3'));
                    descendAudioPlayer.play(AssetSource('sounds/descend.mp3'));
                 }
              });
            }
            
            setState(() {
              final int climbIndex = _rvsmAircrafts.indexOf(climbAircraft);
              final int descendIndex = _rvsmAircrafts.indexOf(descendAircraft);
              
              if (climbIndex != -1) {
                _rvsmAircrafts[climbIndex] = _rvsmAircrafts[climbIndex].copyWith(
                  status: AircraftStatus.tcasAlert,
                  targetFL: (climbAircraft.altitude! + 1000)
                );
              }
              if (descendIndex != -1) {
                _rvsmAircrafts[descendIndex] = _rvsmAircrafts[descendIndex].copyWith(
                  status: AircraftStatus.tcasAlert,
                  targetFL: (descendAircraft.altitude! - 1000)
                );
              }
            });
            return; 
          }
        }
      }
    }
  }

  void _triggerRandomContingency() {
    final rvsmAircraftsInNormalStatus = _rvsmAircrafts.where((ac) => ac.status == AircraftStatus.normal).toList();
    if (rvsmAircraftsInNormalStatus.isNotEmpty && Random().nextDouble() < 0.1) {
      final target = rvsmAircraftsInNormalStatus[Random().nextInt(rvsmAircraftsInNormalStatus.length)];
      _handleContingency(target);
    }
  }

  void _handleContingency(Aircraft targetAircraft) {
    if (targetAircraft.status == AircraftStatus.fail) return;

    setState(() {
      final int targetIndex = _rvsmAircrafts.indexOf(targetAircraft);
      if (targetIndex != -1) {
        _rvsmAircrafts[targetIndex] = _rvsmAircrafts[targetIndex].copyWith(
          status: AircraftStatus.fail,
        );
      }
      _addAtcMessage("ATC: ${targetAircraft.displayId}, RVSM indisponível.");
    });
  }

  void _handleAircraftTap(Aircraft tappedAircraft) {
    setState(() {
      if (_selectedAircraft != null && _selectedAircraft!.status == AircraftStatus.selected) {
        final int prevSelectedIndex = _rvsmAircrafts.indexWhere((ac) => ac.hex == _selectedAircraft!.hex);
        if (prevSelectedIndex != -1) {
          _rvsmAircrafts[prevSelectedIndex] = _rvsmAircrafts[prevSelectedIndex].copyWith(status: AircraftStatus.normal);
        }
      }
      
      if (_selectedAircraft?.hex == tappedAircraft.hex) {
        _selectedAircraft = null;
      } else {
        final int tappedIndex = _rvsmAircrafts.indexWhere((ac) => ac.hex == tappedAircraft.hex);
        if (tappedIndex != -1) { // Verifica se a aeronave ainda existe na lista antes de tentar acessar
          if (_rvsmAircrafts[tappedIndex].status == AircraftStatus.normal) {
            _rvsmAircrafts[tappedIndex] = _rvsmAircrafts[tappedIndex].copyWith(status: AircraftStatus.selected);
          }
          _selectedAircraft = _rvsmAircrafts[tappedIndex];
        } else {
          _selectedAircraft = null;
        }
      }
    });
  }
  
  void _togglePause() {
    setState(() {
      isPaused = !isPaused;
      if (isPaused) {
        _stopEventTimers();
        _stopAdsbFetching();
      } else {
        _startEventTimers();
        _startAdsbFetching();
      }
    });
  }

  void _toggleAudio() {
    setState(() {
      isAudioEnabled = !isAudioEnabled;
      if (!isAudioEnabled) {
        audioPlayer.stop();
        climbAudioPlayer.stop();
        descendAudioPlayer.stop();
        tcasAlertAudioPlayer.stop();
      }
    });
  }

  void _toggleMapType() {
    setState(() {
      _isSatelliteMode = !_isSatelliteMode;
      _currentMapUrl = _isSatelliteMode ? _esriSatelliteUrl : _osmUrl;
    });
  }

  // --- Função para abrir o painel de filtros ---
  void _toggleFilterPanel() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true, // Permite que o bottom sheet ocupe mais espaço
      builder: (BuildContext context) {
        // Usamos um StatefulBuilder para gerenciar o estado interno do bottom sheet
        // sem reconstruir a tela principal inteira.
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.75, // Ocupa 75% da altura da tela
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16.0)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // --- Título e Botão de Fechar ---
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Filtros de Aeronaves',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white54),
                  const SizedBox(height: 10),

                  // --- Filtro de Altitude ---
                  Text('Altitude (FL): ${(_minAltitudeFilter / 1000).toInt()} - ${(_maxAltitudeFilter / 1000).toInt()}',
                      style: const TextStyle(color: Colors.white, fontSize: 16)),
                  RangeSlider(
                    values: RangeValues(_minAltitudeFilter, _maxAltitudeFilter),
                    min: 0, // Pode ajustar o mínimo conforme necessário
                    max: 60000, // Pode ajustar o máximo conforme necessário
                    divisions: 600, // Para passos de 100 pés
                    labels: RangeLabels(
                      (_minAltitudeFilter / 1000).toInt().toString(),
                      (_maxAltitudeFilter / 1000).toInt().toString(),
                    ),
                    onChanged: (RangeValues newValues) {
                      setModalState(() {
                        _minAltitudeFilter = newValues.start.roundToDouble();
                        _maxAltitudeFilter = newValues.end.roundToDouble();
                      });
                    },
                    activeColor: Colors.cyan,
                    inactiveColor: Colors.cyan.withOpacity(0.3),
                  ),
                  const SizedBox(height: 10),

                  // --- Filtro de Velocidade ---
                  Text('Velocidade (kts): ${_minSpeedFilter.toInt()} - ${_maxSpeedFilter.toInt()}',
                      style: const TextStyle(color: Colors.white, fontSize: 16)),
                  RangeSlider(
                    values: RangeValues(_minSpeedFilter, _maxSpeedFilter),
                    min: 0,
                    max: 1000, // Velocidade máxima razoável em nós
                    divisions: 100, // Para passos de 10 nós
                    labels: RangeLabels(
                      _minSpeedFilter.toInt().toString(),
                      _maxSpeedFilter.toInt().toString(),
                    ),
                    onChanged: (RangeValues newValues) {
                      setModalState(() {
                        _minSpeedFilter = newValues.start.roundToDouble();
                        _maxSpeedFilter = newValues.end.roundToDouble();
                      });
                    },
                    activeColor: Colors.cyan,
                    inactiveColor: Colors.cyan.withOpacity(0.3),
                  ),
                  const SizedBox(height: 10),

                  // --- Filtro por Status ---
                  const Text('Status:', style: TextStyle(color: Colors.white, fontSize: 16)),
                  Wrap(
                    spacing: 8.0,
                    children: AircraftStatus.values.map((status) {
                      return FilterChip(
                        label: Text(_getStatusText(status)),
                        selected: _selectedStatusFilters.contains(status),
                        onSelected: (bool selected) {
                          setModalState(() {
                            if (selected) {
                              _selectedStatusFilters.add(status);
                            } else {
                              _selectedStatusFilters.remove(status);
                            }
                          });
                        },
                        selectedColor: Colors.cyan.withOpacity(0.6),
                        backgroundColor: Colors.grey.shade800,
                        labelStyle: TextStyle(color: _selectedStatusFilters.contains(status) ? Colors.white : Colors.white70),
                        checkmarkColor: Colors.white,
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 20),

                  // --- Botão Aplicar Filtros ---
                  ElevatedButton(
                    onPressed: () {
                      setState(() {}); // Chama setState no widget pai para reconstruir o mapa com os novos filtros
                      Navigator.pop(context); // Fecha o bottom sheet
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text(
                      'Aplicar Filtros',
                      style: TextStyle(fontSize: 18, color: Colors.white),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // Helper para obter texto do status
  String _getStatusText(AircraftStatus status) {
    switch (status) {
      case AircraftStatus.normal: return 'Normal';
      case AircraftStatus.selected: return 'Selecionada';
      case AircraftStatus.fail: return 'Falha RVSM';
      case AircraftStatus.tcasAlert: return 'Alerta TCAS';
      case AircraftStatus.deviating: return 'A Desviar';
      default: return '';
    }
  }


  List<Aircraft> get _filteredAircraftsForDisplay {
    // Começa com a lista completa de aeronaves RVSM (filtrada por RVSM na busca)
    Iterable<Aircraft> filtered = _rvsmAircrafts;

    // Aplica filtro de busca por texto (flight ou hex)
    if (_searchQuery.isNotEmpty) {
      final String query = _searchQuery.toLowerCase();
      filtered = filtered.where((ac) {
        return (ac.displayId.toLowerCase().contains(query) ||
                ac.hex.toLowerCase().contains(query));
      });
    }

    // Aplica filtro de altitude
    filtered = filtered.where((ac) {
      return ac.altitude != null &&
             ac.altitude! >= _minAltitudeFilter &&
             ac.altitude! <= _maxAltitudeFilter;
    });

    // Aplica filtro de velocidade
    filtered = filtered.where((ac) {
      return ac.speed != null &&
             ac.speed! >= _minSpeedFilter &&
             ac.speed! <= _maxSpeedFilter;
    });

    // Aplica filtro de status
    filtered = filtered.where((ac) {
      // Se _selectedStatusFilters estiver vazio, mostra TODAS as aeronaves.
      // Se algum status estiver selecionado, mostra apenas os que correspondem.
      return _selectedStatusFilters.isEmpty || _selectedStatusFilters.contains(ac.status);
    });

    return filtered.toList();
  }
  
  @override 
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Buscar Voo ou HEX...',
                  hintStyle: TextStyle(color: Colors.white54),
                  border: InputBorder.none,
                ),
                style: const TextStyle(color: Colors.white),
                cursorColor: Colors.white,
              )
            : const Text('RVSM / ADS-B'),
        backgroundColor: const Color(0xFF000032),
        actions: <Widget>[
          // --- ÚNICO BOTÃO NA APPBAR: O MENU DE 3 PONTINHOS ---
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white, size: 20.0), // Ícone de 3 pontinhos
            onSelected: (value) {
              switch (value) {
                case 'search':
                  setState(() {
                    _isSearching = true; // Abre o campo de busca
                  });
                  break;
                case 'pause_play':
                  _togglePause();
                  break;
                case 'toggle_audio':
                  _toggleAudio();
                  break;
                case 'refresh_adsb':
                  _fetchAndFilterRealAircraft();
                  break;
                case 'toggle_map_type':
                  _toggleMapType();
                  break;
                case 'open_filters':
                  _toggleFilterPanel(); // Chama a função para abrir o BottomSheet
                  break;
                case 'force_fail':
                  if (_selectedAircraft != null) {
                    _handleContingency(_selectedAircraft!);
                  }
                  break;
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              // Opção de Busca
              PopupMenuItem<String>(
                value: 'search',
                child: Row(
                  children: [
                    const Icon(Icons.search, color: Colors.white),
                    const SizedBox(width: 8),
                    const Text('Buscar', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              // Opção de Pausar/Retomar
              PopupMenuItem<String>(
                value: 'pause_play',
                child: Row(
                  children: [
                    Icon(isPaused ? Icons.play_arrow : Icons.pause, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(isPaused ? 'Retomar' : 'Pausar', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              // Opção de Áudio
              PopupMenuItem<String>(
                value: 'toggle_audio',
                child: Row(
                  children: [
                    Icon(isAudioEnabled ? Icons.volume_up : Icons.volume_off, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(isAudioEnabled ? 'Desativar Áudio' : 'Ativar Áudio', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              // Opção de Recarregar Dados
              PopupMenuItem<String>(
                value: 'refresh_adsb',
                child: Row(
                  children: [
                    const Icon(Icons.refresh, color: Colors.white),
                    const SizedBox(width: 8),
                    const Text('Recarregar Dados', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              // Opção de Tipo de Mapa
              PopupMenuItem<String>(
                value: 'toggle_map_type',
                child: Row(
                  children: [
                    Icon(_isSatelliteMode ? Icons.map : Icons.satellite, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(_isSatelliteMode ? 'Ver Mapa de Ruas' : 'Ver Satélite', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              // Opção de Abrir Filtros
              PopupMenuItem<String>(
                value: 'open_filters',
                child: Row(
                  children: [
                    const Icon(Icons.filter_list, color: Colors.white),
                    const SizedBox(width: 8),
                    const Text('Filtros', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              // Separador (opcional)
              const PopupMenuDivider(),
              // Opção de Forçar Falha
              const PopupMenuItem<String>(
                value: 'force_fail',
                child: Row(
                  children: [
                    Icon(Icons.warning, color: Colors.orange),
                    SizedBox(width: 8),
                    Text('Forçar Falha', style: TextStyle(color: Colors.orange)),
                  ],
                ),
              ),
            ],
          ),
          // --- FIM DO ÚNICO BOTÃO NA APPBAR ---
        ],
      ),
      body: Stack(
        children: [
          // O mapa é sempre renderizado aqui (após o loading inicial)
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: LatLng(-10.16076, -48.31123),
              initialZoom: 7.0,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
              onTap: (_, __) {
                if (_selectedAircraft != null) {
                  setState(() {
                    final int prevSelectedIndex = _rvsmAircrafts.indexWhere((ac) => ac.hex == _selectedAircraft!.hex);
                    if (prevSelectedIndex != -1) {
                      _rvsmAircrafts[prevSelectedIndex] = _rvsmAircrafts[prevSelectedIndex].copyWith(status: AircraftStatus.normal);
                    }
                    _selectedAircraft = null;
                  });
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: _currentMapUrl,
                userAgentPackageName: 'com.yourcompany.rvsm_monitor',
              ),
              // --- RASTROS DAS AERONAVES ---
              PolylineLayer(
                polylines: _aircraftTrails,
              ),
              // --- FIM DOS RASTROS ---
              MarkerLayer(
                markers: _filteredAircraftsForDisplay.map((ac) {
                  if (ac.lat == null || ac.lon == null) return Marker(point: LatLng(0,0), child: Container());
                  return Marker(
                    width: 60.0,
                    height: 60.0,
                    point: LatLng(ac.lat!, ac.lon!),
                    child: GestureDetector(
                      onTap: () => _handleAircraftTap(ac),
                      child: AircraftMarkerWidget(aircraft: ac),
                    ),
                  );
                }).toList(),
              ),
              // --- TRAJETÓRIAS PROJETADAS ---
              PolylineLayer(
                polylines: _projectedPaths,
              ),
              // --- FIM DAS TRAJETÓRIAS PROJETADAS ---
              if (weatherCell != null)
                PolygonLayer(
                  polygons: [
                    Polygon(
                      points: [
                        weatherCell!.bounds.northWest,
                        weatherCell!.bounds.northEast,
                        weatherCell!.bounds.southEast,
                        weatherCell!.bounds.southWest,
                      ],
                      color: Colors.red.withOpacity(0.4),
                      borderStrokeWidth: 2,
                      borderColor: Colors.red,
                      isFilled: true,
                    ),
                  ],
                ),
            ],
          ),

          // Indicador de carregamento em tela cheia
          if (_isAdsbLoading)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.black54,
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
          
          // Overlay para a mensagem "Nenhuma aeronave encontrada"
          if (!_isAdsbLoading && _filteredAircraftsForDisplay.isEmpty)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.5),
                child: Center(
                  child: Text(
                    _searchQuery.isEmpty
                        ? 'Nenhuma aeronave RVSM detectada no momento.'
                        : 'Nenhuma aeronave encontrada para a busca: "$_searchQuery"',
                    style: TextStyle(color: Colors.white, fontSize: 18),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),

          const Positioned(top: 10, right: 10, child: LegendPanel()),
          Positioned(bottom: 125, left: 10, child: AtcLogPanel(messages: atcMessages)),
          if (_selectedAircraft != null)
            Align(alignment: Alignment.bottomCenter, child: InfoPanel(aircraft: _selectedAircraft!)),
        ],
      ),
    );
  }
}

// --- NOVO Widget para Marcador de Aeronave no Mapa ---
class AircraftMarkerWidget extends StatelessWidget {
  final Aircraft aircraft;
  const AircraftMarkerWidget({super.key, required this.aircraft});

  Color _getColorForStatus() {
    switch (aircraft.status) {
      case AircraftStatus.normal: return Colors.white;
      case AircraftStatus.selected: return Colors.yellow;
      case AircraftStatus.fail: return Colors.orange;
      case AircraftStatus.tcasAlert: return Colors.red;
      case AircraftStatus.deviating: return Colors.lightBlueAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: (aircraft.track ?? 0) * (pi / 180),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.navigation,
            color: _getColorForStatus(),
            size: 25,
            shadows: const [Shadow(color: Colors.black, blurRadius: 4.0)],
          ),
          Text(
            '${aircraft.displayId}\nFL${aircraft.altitude ?? '?' }' +
                (aircraft.vertRate != null
                    ? (aircraft.vertRate! > 0 ? ' ▲' : (aircraft.vertRate! < 0 ? ' ▼' : ''))
                    : ''),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 8,
              fontWeight: FontWeight.bold,
              color: _getColorForStatus(),
              shadows: const [Shadow(color: Colors.black, blurRadius: 2.0)],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Painéis e Widgets Auxiliares (adaptados para usar Aircraft) ---

class InfoPanel extends StatelessWidget {
  final Aircraft aircraft;
  const InfoPanel({super.key, required this.aircraft});

  @override
  Widget build(BuildContext context) {
    String statusText;
    switch(aircraft.status) {
      case AircraftStatus.fail: statusText = 'FALHA RVSM'; break;
      case AircraftStatus.tcasAlert: statusText = 'ALERTA TCAS'; break;
      case AircraftStatus.deviating: statusText = 'A DESVIAR'; break;
      default: statusText = (aircraft.altitude != null && aircraft.altitude! >= 29000 && aircraft.altitude! <= 41000) ? 'Em RVSM' : 'Fora RVSM';
    }
    return Container(
      height: 160,
      width: double.infinity,
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface.withOpacity(0.85)),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Stack(
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Voo: ${aircraft.displayId}", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 4),
              Text("Hex: ${aircraft.hex} | Alt: FL${aircraft.altitude ?? '?' } (Geom: ${aircraft.altGeom ?? '?'})", style: const TextStyle(fontSize: 14, color: Colors.white70)),
              Text("Vel: ${aircraft.speed ?? '?'} kts (TAS: ${aircraft.tas ?? '?'} kts) | Rumo: ${aircraft.track ?? '?'}°", style: const TextStyle(fontSize: 12, color: Colors.white70)),
              Text("Status: $statusText", style: TextStyle(fontSize: 12, color: _getColorForStatus(aircraft.status))),
              const SizedBox(height: 4),
              Text("V_Rate: ${aircraft.vertRate ?? '?'} ft/min | Squawk: ${aircraft.squawk ?? '?'}", style: const TextStyle(fontSize: 10, color: Colors.white54)),
            ],
          ),
          const Positioned(
            bottom: 0,
            right: 0,
            child: Text(
              "Desenvolvido por Eng. Software Ricardo Azevedo",
              style: TextStyle(fontSize: 10, color: Colors.white54, fontStyle: FontStyle.italic),
            ),
          )
        ],
      ),
    );
  }
   Color _getColorForStatus(AircraftStatus status) {
    switch (status) {
      case AircraftStatus.normal: return Colors.white;
      case AircraftStatus.selected: return Colors.yellow;
      case AircraftStatus.fail: return Colors.orange;
      case AircraftStatus.tcasAlert: return Colors.red;
      case AircraftStatus.deviating: return Colors.lightBlueAccent;
    }
  }
}

class LegendPanel extends StatelessWidget {
  const LegendPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6.0),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withOpacity(0.5),
        borderRadius: BorderRadius.circular(6.0),
        border: Border.all(color: Colors.white54),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Legenda:",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
          ),
          const SizedBox(height: 2),
          _buildLegendItem(Colors.white, "Normal"),
          _buildLegendItem(Colors.yellow, "Selecionada"),
          _buildLegendItem(Colors.orange, "Falha RVSM"),
          _buildLegendItem(Colors.red, "Alerta TCAS"),
          _buildLegendItem(Colors.lightBlueAccent, "A Desviar"),
        ],
      ),
    );
  }

  Widget _buildLegendItem(Color color, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.0),
      child: Row(
        children: [
          Icon(Icons.navigation, color: color, size: 18),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }
}

class AtcLogPanel extends StatelessWidget {
  final Queue<String> messages;
  const AtcLogPanel({super.key, required this.messages});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 400, height: 120,
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withOpacity(0.75),
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(color: Colors.white54),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Log ATC:", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Expanded(
            child: ListView(
              reverse: true,
              children: messages.map((msg) {
                final color = msg.startsWith("TCAS") ? Colors.redAccent : const Color(0xFFC8FFC8);
                return Text(msg, style: TextStyle(color: color, fontFamily: 'monospace'));
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

// Extensão para `firstWhereOrNull` (necessária)
extension IterableExtension<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T element) test) {
    for (final element in this) {
      if (test(element)) {
        return element;
      }
    }
    return null;
  }
}