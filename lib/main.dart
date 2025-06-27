import 'dart:async';
import 'dart:math';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';

// --- Modelos de Dados ---

enum AircraftStatus { normal, selected, fail, tcasAlert, deviating }
enum FlightDirection { east, west }

class Aeronave {
  final String id;
  final String callsign;
  int fl;
  final bool isRvsm;
  final FlightDirection direction;
  AircraftStatus status;
  double x, y;
  int? targetFL;
  final double baseSpeed;
  bool hasBeenHandedOver = false;

  Aeronave({
    required this.id,
    required this.callsign,
    required this.fl,
    required this.isRvsm,
    required this.x,
    required this.y,
    this.status = AircraftStatus.normal,
  }) : direction = (fl ~/ 10) % 2 != 0 ? FlightDirection.east : FlightDirection.west,
       baseSpeed = (Random().nextDouble() * 1.5) + 2.0;

  void updatePosition(BoxConstraints constraints, Function getVerticalPosition, double speedMultiplier) {
    int finalTargetFL = targetFL ?? fl;
    final targetY = getVerticalPosition(finalTargetFL);

    if ((y - targetY).abs() > 1.0) {
      y += (targetY - y) * 0.05;
    } else if (targetFL != null) {
      fl = targetFL!;
      targetFL = null;
      if (status == AircraftStatus.tcasAlert || status == AircraftStatus.deviating) {
        status = AircraftStatus.normal;
      }
    }

    final double dir = (direction == FlightDirection.east) ? 1.0 : -1.0;
    x += (baseSpeed * speedMultiplier) * dir;
    final double margin = 50;
    if (dir > 0 && x > constraints.maxWidth + margin) {
      x = -margin;
      hasBeenHandedOver = false;
    } else if (dir < 0 && x < -margin) {
      x = constraints.maxWidth + margin;
      hasBeenHandedOver = false;
    }
  }
}

class WeatherCell {
  final Rect rect;
  final int startFl;
  final int endFl;
  WeatherCell({required this.rect, required this.startFl, required this.endFl});
}

// --- Aplicação Principal ---

void main() { runApp(const RVSMApp()); }

class RVSMApp extends StatelessWidget {
  const RVSMApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Test-RVSM',
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
      home: const SimulationScreen(),
    );
  }
}

class SimulationScreen extends StatefulWidget {
  const SimulationScreen({super.key});
  @override
  State<SimulationScreen> createState() => _SimulationScreenState();
}

class _SimulationScreenState extends State<SimulationScreen> with SingleTickerProviderStateMixin {
  final List<int> conventionalFlightLevels = [290, 310, 330, 350, 370, 390, 410];
  final List<int> rvsmFlightLevels = [290, 300, 310, 320, 330, 340, 350, 360, 370, 380, 390, 400, 410];
  List<Aeronave> activeAircraft = [];
  Aeronave? selectedAircraft;
  WeatherCell? weatherCell;
  final Queue<String> atcMessages = Queue();
  Timer? _spawnTimer, _contingencyTimer, _tcasTimer, _weatherTimer;
  AnimationController? _animationController;
  bool isPaused = false;
  final AudioPlayer audioPlayer = AudioPlayer();
  double _speedMultiplier = 1.0;
  final List<double> _speedOptions = [1.0, 2.0, 0.5];
  int _currentSpeedIndex = 0;
  final List<String> airlineCallsigns = ["GOL", "TAM", "AZU", "VOE"];
  bool isAudioEnabled = true;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(vsync: this, duration: const Duration(days: 1))
      ..addListener(() {
        if (!isPaused) {
          _updateGameLogic();
          setState(() {}); 
        }
      });
    _animationController?.repeat();
    _startTimers();
  }
  
  void _startTimers() {
    _spawnTimer = Timer.periodic(const Duration(seconds: 2), (timer) { if (!isPaused) _spawnAircraft(); });
    _contingencyTimer = Timer.periodic(const Duration(seconds: 15), (timer) { if (!isPaused) _triggerRandomContingency(); });
    _tcasTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) { if (!isPaused) _checkForTcasAlerts(); });
    _weatherTimer = Timer.periodic(const Duration(seconds: 20), (timer) { if(!isPaused) _spawnWeatherCell(); });
  }

  void _stopTimers() {
    _spawnTimer?.cancel(); _contingencyTimer?.cancel(); _tcasTimer?.cancel(); _weatherTimer?.cancel();
  }

  @override
  void dispose() {
    _stopTimers(); _animationController?.dispose(); audioPlayer.dispose();
    super.dispose();
  }

  void _updateGameLogic() {
    if (!mounted) return;
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final columnConstraints = BoxConstraints(maxWidth: screenWidth / 2 - 20);

    for (var ac in activeAircraft) {
      ac.updatePosition(columnConstraints, (fl) => _getVerticalPositionForFL(fl, screenHeight), _speedMultiplier);
      
      final boundaryX = columnConstraints.maxWidth / 2;
      if (!ac.hasBeenHandedOver && ((ac.direction == FlightDirection.east && ac.x > boundaryX) || (ac.direction == FlightDirection.west && ac.x < boundaryX))) {
        ac.hasBeenHandedOver = true;
        final nextCenter = ac.isRvsm ? "Amazónico" : "Recife";
        _addAtcMessage("${ac.callsign}, contacte Centro ${nextCenter} em 135.9.");
      }

      if(weatherCell != null && ac.status == AircraftStatus.normal) {
        final acRect = Rect.fromCenter(center: Offset(ac.x, ac.y), width: 50, height: 25);
        final weatherRectInColumn = ac.isRvsm 
          ? weatherCell!.rect.translate(-screenWidth / 2, 0) 
          : weatherCell!.rect;
        if(weatherRectInColumn.overlaps(acRect.inflate(ac.direction == FlightDirection.east ? 80 : -80))) {
          ac.status = AircraftStatus.deviating;
          ac.targetFL = ac.fl + (weatherCell!.rect.center.dy > ac.y ? -20 : 20);
          _addAtcMessage("${ac.callsign} a desviar p/ FL${ac.targetFL}.");
        }
      }
    }
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

  void _spawnAircraft() {
    if (!mounted || MediaQuery.of(context).size.width == 0) return;
    final random = Random();
    final bool isRvsm = random.nextBool();
    final List<int> availableLevels = isRvsm ? rvsmFlightLevels : conventionalFlightLevels;
    final int flightLevel = availableLevels[random.nextInt(availableLevels.length)];
    if (activeAircraft.any((ac) => ac.fl == flightLevel && ac.isRvsm == isRvsm && (ac.x > 0 && ac.x < MediaQuery.of(context).size.width/2))) return;
    
    final bool isFlyingEast = (flightLevel ~/ 10) % 2 != 0;
    final double initialX = isFlyingEast ? -50 : MediaQuery.of(context).size.width / 2 + 50;

    final String airline = airlineCallsigns[random.nextInt(airlineCallsigns.length)];
    final String flightNumber = (random.nextInt(8999) + 1000).toString();

    final newAircraft = Aeronave(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      callsign: "$airline$flightNumber",
      fl: flightLevel, isRvsm: isRvsm, x: initialX, y: -100, 
    );
    setState(() => activeAircraft.add(newAircraft));
    _addAtcMessage("${newAircraft.callsign} entrou no FL${newAircraft.fl}.");
  }
  
  void _spawnWeatherCell() {
    if (!mounted) return;
    final random = Random();
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final startFl = rvsmFlightLevels[random.nextInt(rvsmFlightLevels.length - 4)];
    final endFl = startFl + random.nextInt(20) + 20;
    final isRightColumn = random.nextBool();
    final x = isRightColumn ? screenWidth * 0.75 : screenWidth * 0.25;
    final y1 = _getVerticalPositionForFL(startFl, screenHeight);
    final y2 = _getVerticalPositionForFL(endFl, screenHeight);
    
    setState(() {
      weatherCell = WeatherCell(
        rect: Rect.fromCenter(center: Offset(x, (y1+y2)/2), width: 100, height: y1-y2),
        startFl: startFl,
        endFl: endFl,
      );
    });
    _addAtcMessage("ATC: ALERTA METEOROLÓGICO entre FL$startFl e FL$endFl.");
    Timer(const Duration(seconds: 15), () => setState(() => weatherCell = null));
  }

  void _checkForTcasAlerts() {
    for (int i = 0; i < activeAircraft.length; i++) {
      for (int j = i + 1; j < activeAircraft.length; j++) {
        Aeronave ac1 = activeAircraft[i];
        Aeronave ac2 = activeAircraft[j];
        if (ac1.isRvsm == ac2.isRvsm && ac1.status != AircraftStatus.tcasAlert && ac2.status != AircraftStatus.tcasAlert && ac1.status != AircraftStatus.deviating && ac2.status != AircraftStatus.deviating) {
          if ((ac1.fl - ac2.fl).abs() < 10 && (ac1.x - ac2.x).abs() < 70) {
            
            Aeronave climbAircraft = ac1.y > ac2.y ? ac1 : ac2;
            Aeronave descendAircraft = ac1.y <= ac2.y ? ac1 : ac2;

            _addAtcMessage("TCAS RA: ${climbAircraft.callsign} SUBA. ${descendAircraft.callsign} DESÇA.");
            
            if(isAudioEnabled) {
              audioPlayer.play(AssetSource('sounds/climb.mp3'));
              Future.delayed(const Duration(milliseconds: 800), () {
                if(isAudioEnabled) audioPlayer.play(AssetSource('sounds/descend.mp3'));
              });
            }
            
            setState(() {
              climbAircraft.status = AircraftStatus.tcasAlert; 
              descendAircraft.status = AircraftStatus.tcasAlert;
              climbAircraft.targetFL = climbAircraft.fl + 10;
              descendAircraft.targetFL = descendAircraft.fl - 10;
            });
            return;
          }
        }
      }
    }
  }

  void _triggerRandomContingency() {
    final rvsmAircraft = activeAircraft.where((ac) => ac.isRvsm && ac.status == AircraftStatus.normal).toList();
    if (rvsmAircraft.isNotEmpty && Random().nextDouble() < 0.1) {
      final target = rvsmAircraft[Random().nextInt(rvsmAircraft.length)];
      _handleContingency(target);
    }
  }

  void _handleContingency(Aeronave targetAircraft) {
    if (!targetAircraft.isRvsm || targetAircraft.status == AircraftStatus.fail) return;
    setState(() {
      targetAircraft.status = AircraftStatus.fail;
      _addAtcMessage("ATC: ${targetAircraft.callsign}, RVSM indisponível.");
      final flFail = targetAircraft.fl;
      activeAircraft.removeWhere((ac) => ac.isRvsm && (ac.fl == flFail + 10 || ac.fl == flFail - 10));
    });
  }

  void _handleAircraftTap(Aeronave tappedAircraft) {
    setState(() {
      if (selectedAircraft != null && selectedAircraft!.status == AircraftStatus.selected) {
        selectedAircraft!.status = AircraftStatus.normal;
      }
      if (selectedAircraft?.id == tappedAircraft.id) {
        selectedAircraft = null;
      } else {
        if (tappedAircraft.status == AircraftStatus.normal) {
          tappedAircraft.status = AircraftStatus.selected;
        }
        selectedAircraft = tappedAircraft;
      }
    });
  }
  
  void _togglePause() {
    setState(() {
      isPaused = !isPaused;
    });
  }

  void _cycleSpeed() {
    setState(() {
      _currentSpeedIndex = (_currentSpeedIndex + 1) % _speedOptions.length;
      _speedMultiplier = _speedOptions[_currentSpeedIndex];
    });
  }

  void _toggleAudio() {
    setState(() {
      isAudioEnabled = !isAudioEnabled;
      if (!isAudioEnabled) {
        audioPlayer.stop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Test-RVSM'),
        backgroundColor: const Color(0xFF000032),
        actions: <Widget>[
          TextButton(
            onPressed: _cycleSpeed,
            child: Text("Vel: ${_speedMultiplier}x", style: const TextStyle(color: Colors.white)),
          ),
          IconButton(
            icon: Icon(isPaused ? Icons.play_arrow : Icons.pause),
            tooltip: isPaused ? 'Retomar' : 'Pausar',
            onPressed: _togglePause,
          ),
          IconButton(
            icon: Icon(isAudioEnabled ? Icons.volume_up : Icons.volume_off),
            tooltip: 'Ativar/Desativar Áudio',
            onPressed: _toggleAudio,
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'force_fail' && selectedAircraft != null) {
                _handleContingency(selectedAircraft!);
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(
                value: 'force_fail',
                child: Row(
                  children: [
                    Icon(Icons.warning, color: Colors.orange),
                    SizedBox(width: 8),
                    Text('Forçar Falha'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          Row(
            children: [
              _buildAirspaceColumn(title: 'Non-RVSM', flightLevels: conventionalFlightLevels, isRvsmColumn: false),
              const VerticalDivider(color: Colors.white, thickness: 2, indent: 10, endIndent: 10),
              _buildAirspaceColumn(title: 'RVSM', flightLevels: rvsmFlightLevels, isRvsmColumn: true),
            ],
          ),
          if (weatherCell != null) WeatherCellWidget(weatherCell: weatherCell!),
          const Positioned(top: 10, right: 10, child: LegendPanel()),
          Positioned(bottom: 125, left: 10, child: AtcLogPanel(messages: atcMessages)),
          if (selectedAircraft != null)
            Align(alignment: Alignment.bottomCenter, child: InfoPanel(aircraft: selectedAircraft!)),
        ],
      ),
    );
  }

  Widget _buildAirspaceColumn({required String title, required List<int> flightLevels, required bool isRvsmColumn}) {
    final aircraftInThisColumn = activeAircraft.where((ac) => ac.isRvsm == isRvsmColumn).toList();
    return Expanded(
      child: Container(
        margin: const EdgeInsets.all(8.0),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16.0),
              child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF000032))),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        top: 0, bottom: 0, left: constraints.maxWidth / 2,
                        child: const DashedLineVerticalPainter(),
                      ),
                      ..._buildFlightLevelWidgets(flightLevels, constraints.maxHeight),
                      ..._buildAircraftWidgets(aircraftInThisColumn, constraints),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildFlightLevelWidgets(List<int> levels, double availableHeight) {
    return levels.map((fl) {
      final topPosition = _getVerticalPositionForFL(fl, availableHeight);
      return Positioned(
        top: topPosition, left: 0, right: 0,
        child: Row(
          children: [
            Padding(padding: const EdgeInsets.only(left: 8.0), child: Text('FL$fl', style: const TextStyle(fontSize: 12))),
            Expanded(child: Container(margin: const EdgeInsets.symmetric(horizontal: 8.0), height: 1, color: Colors.black.withOpacity(0.5))),
          ],
        ),
      );
    }).toList();
  }

  List<Widget> _buildAircraftWidgets(List<Aeronave> aircraftList, BoxConstraints constraints) {
    return aircraftList.map((ac) {
      if (ac.y < 0) ac.y = _getVerticalPositionForFL(ac.fl, constraints.maxHeight);
      return Positioned(
        left: ac.x - 15, top: ac.y - 15,
        child: GestureDetector(
          onTap: () => _handleAircraftTap(ac),
          child: AircraftWidget(aeronave: ac),
        ),
      );
    }).toList();
  }

  double _getVerticalPositionForFL(int fl, double availableHeight) {
    const double baseFL = 290.0, maxFL = 410.0, topMargin = 20.0, bottomMargin = 20.0;
    final double drawingAreaHeight = availableHeight - topMargin - bottomMargin;
    final double normalizedFL = (fl - baseFL) / (maxFL - baseFL);
    return (1 - normalizedFL) * drawingAreaHeight + topMargin;
  }
}

class AircraftWidget extends StatelessWidget {
  final Aeronave aeronave;
  const AircraftWidget({super.key, required this.aeronave});

  Color _getColorForStatus() {
    switch (aeronave.status) {
      case AircraftStatus.normal: return Colors.white;
      case AircraftStatus.selected: return Colors.yellow;
      case AircraftStatus.fail: return Colors.orange;
      case AircraftStatus.tcasAlert: return Colors.red;
      case AircraftStatus.deviating: return Colors.lightBlueAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Transform(
      alignment: Alignment.center,
      transform: aeronave.direction == FlightDirection.west ? (Matrix4.rotationY(pi)) : Matrix4.identity(),
      child: Icon(Icons.send, color: _getColorForStatus(), size: 30, shadows: const [Shadow(color: Colors.black, blurRadius: 4.0)]),
    );
  }
}

class InfoPanel extends StatelessWidget {
  final Aeronave aircraft;
  const InfoPanel({super.key, required this.aircraft});

  @override
  Widget build(BuildContext context) {
    String statusText;
    switch(aircraft.status) {
      case AircraftStatus.fail: statusText = 'FALHA RVSM'; break;
      case AircraftStatus.tcasAlert: statusText = 'ALERTA TCAS'; break;
      case AircraftStatus.deviating: statusText = 'A DESVIAR'; break;
      default: statusText = aircraft.isRvsm ? 'Aprovado RVSM' : 'Não Aprovado';
    }
    return Container(
      height: 120, // Aumenta a altura para caber o novo texto
      width: double.infinity,
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface.withOpacity(0.85)),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8), // Ajusta o padding inferior
      child: Stack(
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Voo Selecionado: ${aircraft.callsign}", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 8),
              Text("Nível: FL${aircraft.fl} | Status: $statusText", style: const TextStyle(fontSize: 16, color: Colors.white70)),
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
          Icon(Icons.send, color: color, size: 18),
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

class WeatherCellWidget extends StatelessWidget {
  final WeatherCell weatherCell;
  const WeatherCellWidget({super.key, required this.weatherCell});

  @override
  Widget build(BuildContext context) {
    return Positioned.fromRect(
      rect: weatherCell.rect,
      child: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            colors: [Colors.red.withOpacity(0.4), Colors.orange.withOpacity(0.0)],
            stops: const [0.3, 1.0],
          ),
          shape: BoxShape.rectangle,
        ),
      ),
    );
  }
}

class DashedLineVerticalPainter extends StatelessWidget {
  const DashedLineVerticalPainter({super.key});
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final boxHeight = constraints.maxHeight;
        const dashHeight = 5.0;
        const dashSpace = 3.0;
        final dashCount = (boxHeight / (dashHeight + dashSpace)).floor();
        return Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(dashCount, (_) {
            return const SizedBox(
              height: dashHeight,
              width: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.white54),
              ),
            );
          }),
        );
      },
    );
  }
}