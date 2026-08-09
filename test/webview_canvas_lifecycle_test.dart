import 'package:flutter_test/flutter_test.dart';
import 'package:solvhen/screens/webview_canvas.dart';

void main() {
  test('clearCanvas invalidates pending session content', () async {
    final canvas = WebViewCanvasController();
    await canvas.renderHtml('<canvas id="session-only"></canvas>');
    final renderedRevision = canvas.revision.value;

    expect(canvas.hasContent.value, isTrue);

    await canvas.clearCanvas();

    expect(canvas.hasContent.value, isFalse);
    expect(canvas.revision.value, greaterThan(renderedRevision));
  });
}
