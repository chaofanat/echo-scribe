import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Where a recording was made, captured once at record start (Android).
/// [address] is a best-effort reverse geocode; null when offline or the
/// device geocoder has no data.
class RecordingLocation {
  const RecordingLocation({
    required this.lat,
    required this.lon,
    this.address,
  });

  final double lat;
  final double lon;
  final String? address;

  /// Address when the reverse geocode worked, coordinates otherwise.
  String get display =>
      (address == null || address!.isEmpty)
          ? '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}'
          : address!;

  Map<String, Object?> toJson() =>
      {'lat': lat, 'lon': lon, if (address != null) 'address': address};

  /// Tolerant parser for sidecar data (old recordings have no location).
  static RecordingLocation? fromJson(Object? json) {
    if (json is! Map) return null;
    final lat = json['lat'];
    final lon = json['lon'];
    if (lat is! num || lon is! num) return null;
    return RecordingLocation(
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      address: json['address'] as String?,
    );
  }
}

/// One-shot location tag for a new recording. Never blocks or fails the
/// recording: no permission / no fix simply returns null. Android only.
Future<RecordingLocation?> captureRecordingLocation() async {
  if (!Platform.isAndroid) return null;
  const channel = MethodChannel('echo_scribe/location');
  try {
    final granted = await channel.invokeMethod<bool>('requestPermission');
    if (granted != true) return null;
    final raw = await channel.invokeMethod<Object?>('getLocation');
    return RecordingLocation.fromJson(raw);
  } on PlatformException catch (e) {
    debugPrint('location capture failed: $e');
    return null;
  }
}

/// Opens the coordinates in the system map app. Android only.
Future<void> openLocationInMap(RecordingLocation location) async {
  if (!Platform.isAndroid) return;
  try {
    await const MethodChannel('echo_scribe/location').invokeMethod<void>(
      'openMap',
      {'lat': location.lat, 'lon': location.lon},
    );
  } on PlatformException catch (e) {
    debugPrint('open map failed: $e');
  }
}
