import 'package:customer_video_service/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CallRequest validation', () {
    test('allows omitted fields and 128 Unicode characters', () {
      expect(const CallRequest().validate, returnsNormally);
      expect(CallRequest(businessId: 'a' * 128, scene: '😀' * 128).validate,
          returnsNormally);
    });

    test('rejects empty or whitespace-only optional fields', () {
      for (final value in ['', '  ', '\n\t']) {
        expect(CallRequest(businessId: value).validate, throwsArgumentError);
        expect(CallRequest(scene: value).validate, throwsArgumentError);
      }
    });

    test('rejects more than 128 characters without disclosing the value', () {
      final privateValue = 'private-business-data' * 7;
      for (final request in [
        CallRequest(businessId: privateValue),
        CallRequest(scene: privateValue),
      ]) {
        expect(
          request.validate,
          throwsA(isA<ArgumentError>().having(
            (error) => error.toString(),
            'safe validation message',
            isNot(contains(privateValue)),
          )),
        );
      }
    });
  });
}
