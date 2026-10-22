import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:rummikub_assistant/widgets/auth_brand.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('wordmark renders Rummikub and Helper together', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: RummikubHelperWordmark())),
      ),
    );
    await tester.pump();

    expect(find.text('Rummikub'), findsWidgets);
    expect(find.text('Helper'), findsOneWidget);
  });
}
