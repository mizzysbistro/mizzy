import 'package:flutter_test/flutter_test.dart';
import 'package:mizzy/main.dart';

void main() {
  testWidgets('foundation screen explains current setup state', (tester) async {
    await tester.pumpWidget(const MizzyApp());

    expect(find.text('Mizzy POS'), findsOneWidget);
    expect(find.text('Your restaurant, connected.'), findsOneWidget);
    expect(find.text('Local persistence'), findsOneWidget);
    expect(find.text('Supabase client'), findsOneWidget);
    expect(find.textContaining('not a finished POS'), findsOneWidget);
  });
}
