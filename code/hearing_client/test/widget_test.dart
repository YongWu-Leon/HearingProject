// Smoke test: the app builds and renders the main screen.
//
// Before any node has registered, every expected board must still be on screen
// as an offline card -- a board that is switched off should look switched off,
// not missing. The phone is the hub now, so there is no "pick a board to
// connect to" step any more.
import 'package:flutter_test/flutter_test.dart';

import 'package:hearing_client/main.dart';
import 'package:hearing_client/models/node_session.dart';

void main() {
  testWidgets('App builds and shows every expected node as offline',
      (WidgetTester tester) async {
    await tester.pumpWidget(const HearingApp());
    await tester.pump();

    expect(find.text('Hearing Screener'), findsWidgets);

    // Every expected board shows up front as an offline card, so a board that is
    // switched off looks switched off rather than missing.
    for (final id in kExpectedNodes) {
      expect(find.text(id), findsOneWidget, reason: '$id should have a card');
    }
    expect(find.text('Offline - not set up yet'),
        findsNWidgets(kExpectedNodes.length));
  });
}
