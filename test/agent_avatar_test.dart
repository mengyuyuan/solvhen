import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solvhen/screens/agent_avatar.dart';

void main() {
  testWidgets('searching eye state mounts without integer overflow',
      (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: AgentAvatar(state: AgentState.searching, size: 32),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
