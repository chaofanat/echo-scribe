import 'package:echo_scribe/library/recordings_repository.dart';
import 'package:echo_scribe/platform/recording_location.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('JSON round-trip keeps address', () {
    final location = RecordingLocation(lat: 39.9, lon: 116.4, address: '北京市海淀区');
    final restored = RecordingLocation.fromJson(location.toJson());
    expect(restored?.lat, 39.9);
    expect(restored?.lon, 116.4);
    expect(restored?.address, '北京市海淀区');
    expect(restored?.display, '北京市海淀区');
  });

  test('fromJson tolerates missing or invalid data', () {
    expect(RecordingLocation.fromJson(null), isNull);
    expect(RecordingLocation.fromJson('x'), isNull);
    expect(RecordingLocation.fromJson({'lat': 'a', 'lon': 1}), isNull);
  });

  test('display falls back to coordinates without address', () {
    const location = RecordingLocation(lat: 39.9042, lon: 116.4074);
    expect(location.display, '39.90420, 116.40740');
  });

  test('Recording.fromJson parses location from the sidecar', () {
    final recording = Recording.fromJson('rec-x.wav', {
      'title': 'x',
      'createdAt': '2026-11-21T10:00:00',
      'location': {'lat': 31.2, 'lon': 121.5, 'address': '上海市黄浦区'},
    });
    expect(recording.location?.address, '上海市黄浦区');

    final legacy = Recording.fromJson('rec-y.wav', {
      'title': 'y',
      'createdAt': '2026-11-21T10:00:00',
    });
    expect(legacy.location, isNull);
  });
}
