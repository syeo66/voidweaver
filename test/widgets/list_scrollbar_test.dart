import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:voidweaver/widgets/list_scrollbar.dart';

void main() {
  Widget list() => MaterialApp(
    home: Scaffold(
      body: ListScrollbar(
        builder: (context, controller) => ListView.builder(
          controller: controller,
          itemCount: 2000,
          itemBuilder: (context, index) =>
              SizedBox(height: 56, child: Text('Item $index')),
        ),
      ),
    ),
  );

  testWidgets('drags the thumb to jump through a long list', (tester) async {
    await tester.pumpWidget(list());
    expect(find.text('Item 0'), findsOneWidget);

    // The thumb shows while scrolling, and can then be grabbed
    await tester.fling(find.byType(ListView), const Offset(0, -100), 100);
    await tester.pump();
    final thumb =
        tester.getTopLeft(find.byType(Scrollbar)) +
        Offset(
          tester.view.physicalSize.width / tester.view.devicePixelRatio - 4,
          20,
        );
    await tester.dragFrom(thumb, const Offset(0, 400));
    await tester.pumpAndSettle();

    expect(find.text('Item 0'), findsNothing);
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    // Hundreds of items in one drag, not the few a swipe of that length
    // would scroll
    expect(scrollable.position.pixels, greaterThan(10000));
  });

  testWidgets('lists side by side each get their own controller', (
    tester,
  ) async {
    // As the home screen's album and artist lists in an IndexedStack
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IndexedStack(
            children: [
              for (var i = 0; i < 2; i++)
                ListScrollbar(
                  builder: (context, controller) => ListView.builder(
                    controller: controller,
                    itemCount: 100,
                    itemBuilder: (context, index) =>
                        SizedBox(height: 56, child: Text('Item $index')),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.fling(find.byType(ListView).first, const Offset(0, -300), 500);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
