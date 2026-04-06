// Licensed under the Apache License, Version 2.0
// Copyright 2025, Michael Bushe, All rights reserved.

// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterrific_opentelemetry/flutterrific_opentelemetry.dart';
import 'package:go_router/go_router.dart';

import 'testing_utils/test_otel_helper.dart';

// Mock routes for testing
class FirstPage extends StatelessWidget {
  const FirstPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('first_page'),
      appBar: AppBar(title: const Text('First Page')),
      body: Center(
        child: ElevatedButton(
          key: const Key('second_page_button'),
          onPressed: () {
            print('Going to /second page');
            GoRouter.of(context).go('/second');
          },
          child: const Text('Go to Second Page'),
        ),
      ),
    );
  }
}

class SecondPage extends StatelessWidget {
  const SecondPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('second_page'),
      appBar: AppBar(title: const Text('Second Page')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              key: const Key('third_page_button'),
              onPressed: () {
                print('Going to /third/123');
                GoRouter.of(context).go('/third/123');
              },
              child: const Text('Go to Third Page'),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              key: const Key('details_button'),
              onPressed: () {
                print('Going to /second/details');
                GoRouter.of(context).go('/second/details');
              },
              child: const Text('Go to Details Subroute'),
            ),
          ],
        ),
      ),
    );
  }
}

class ThirdPage extends StatelessWidget {
  final String id;

  const ThirdPage({super.key, required this.id});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('third_page'),
      appBar: AppBar(title: Text('Third Page - ID: $id')),
      body: Center(
        child: ElevatedButton(
          key: const Key('home_button'),
          onPressed: () {
            print('Going to /');
            GoRouter.of(context).go('/');
          },
          child: const Text('Go back to First Page'),
        ),
      ),
    );
  }
}

class SecondDetailsPage extends StatelessWidget {
  const SecondDetailsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('second_details_page'),
      appBar: AppBar(title: const Text('Second Page Details')),
      body: Center(
        child: ElevatedButton(
          key: const Key('to_second_button'),
          onPressed: () {
            print('Going back to /second');
            GoRouter.of(context).go('/second');
          },
          child: const Text('Go back to Second Page'),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OTelNavigatorObserver Tests with GoRouter', () {
    late GoRouter router;
    late OTelNavigatorObserver navigatorObserver;

    setUp(() async {
      await FlutterOTel.reset();
      await initializeFlutterOTelForTest(
        serviceName: 'ui-test-service',
      );

      navigatorObserver = OTelNavigatorObserver();

      // Create router with subroutes
      router = GoRouter(
        debugLogDiagnostics: true,
        observers: [navigatorObserver],
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            name: 'home',
            builder: (context, state) => const FirstPage(),
          ),
          GoRoute(
            path: '/second',
            name: 'second',
            builder: (context, state) => const SecondPage(),
            routes: [
              // Subroute of /second
              GoRoute(
                path: 'details',
                name: 'second_details',
                builder: (context, state) => const SecondDetailsPage(),
              ),
            ],
          ),
          GoRoute(
            path: '/third/:id',
            name: 'third',
            builder: (context, state) {
              final id = state.pathParameters['id'] ?? 'unknown';
              return ThirdPage(id: id);
            },
          ),
        ],
      );
    });

    tearDown(() async {
      await FlutterOTel.reset();
    });

    testWidgets('Should track initial route', (tester) async {
      // First page will be the initial route
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      // Verify initial page is showing
      expect(find.byKey(const Key('first_page')), findsOneWidget);

      // Initial route should be tracked
      expect(navigatorObserver.currentRouteData?.routeSpanId, isNotNull);
      expect(navigatorObserver.currentRouteData?.timestamp, isNotNull);
      expect(navigatorObserver.currentRouteData, isNotNull);
      expect(navigatorObserver.currentRouteData?.routeName, isNotEmpty);
      print(
        'Initial route path: ${navigatorObserver.currentRouteData?.routePath}',
      );
    }, timeout: const Timeout(Duration(seconds: 10)));

    testWidgets(
      'Should track navigation between routes',
      (tester) async {
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();

        // Save initial route data
        final initialRouteId = navigatorObserver.currentRouteData?.routeSpanId;
        final initialRouteData = navigatorObserver.currentRouteData;

        // Use direct router navigation instead of tapping the button
        print('Navigating to /second');
        router.go('/second');
        await tester.pumpAndSettle();

        // Print the current route for debugging
        print(
          'Current route path: ${navigatorObserver.currentRouteData?.routePath}',
        );
        print(
          'Current route name: ${navigatorObserver.currentRouteData?.routeName}',
        );

        // Verify second page is showing
        expect(find.byKey(const Key('second_page')), findsOneWidget);

        // Route data should be updated
        expect(
          navigatorObserver.currentRouteData?.routeSpanId,
          isNot(equals(initialRouteId)),
        );
        expect(
          navigatorObserver.currentRouteData?.routeName,
          isNot(equals(initialRouteData?.routeName)),
        );
        expect(
          navigatorObserver.currentRouteData?.routePath,
          contains('/second'),
        );

        // Save second route data
        final secondRouteId = navigatorObserver.currentRouteData?.routeSpanId;

        // Navigate to third page with parameter
        print('Navigating to /third/123');
        router.go('/third/123');
        await tester.pumpAndSettle();

        // Verify third page is showing
        expect(find.byKey(const Key('third_page')), findsOneWidget);

        // Route data should be updated again
        expect(
          navigatorObserver.currentRouteData?.routeSpanId,
          isNot(equals(secondRouteId)),
        );
        expect(navigatorObserver.currentRouteData?.routeName, isNotEmpty);
        expect(
          navigatorObserver.currentRouteData?.routePath,
          contains('/third/'),
        );

        // Navigate back to first page
        print('Navigating to /');
        router.go('/');
        await tester.pumpAndSettle();

        // Verify first page is showing again
        expect(find.byKey(const Key('first_page')), findsOneWidget);

        // We should be back at first page
        expect(navigatorObserver.currentRouteData?.routePath, contains('/'));
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    testWidgets(
      'Should handle route replacements',
      (tester) async {
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();

        // Save initial route data
        final initialRouteId = navigatorObserver.currentRouteData?.routeSpanId;

        // Navigate to second page
        router.go('/second');
        await tester.pumpAndSettle();

        // Replace the current route with third page
        router.replace('/third/456');
        await tester.pumpAndSettle();

        // Route data should be updated
        expect(
          navigatorObserver.currentRouteData?.routeSpanId,
          isNot(equals(initialRouteId)),
        );
        expect(navigatorObserver.currentRouteData?.routeName, isNotEmpty);
        expect(
          navigatorObserver.currentRouteData?.routePath,
          contains('/third/'),
        );
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    testWidgets(
      'Should handle subroutes correctly',
      (tester) async {
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();

        // Navigate to second page
        router.go('/second');
        await tester.pumpAndSettle();

        // Save second route data
        final secondRouteId = navigatorObserver.currentRouteData?.routeSpanId;

        // Navigate to second page's details subroute
        router.go('/second/details');
        await tester.pumpAndSettle();

        // Print the current route for debugging
        print(
          'Subroute path: ${navigatorObserver.currentRouteData?.routePath}',
        );
        print(
          'Subroute name: ${navigatorObserver.currentRouteData?.routeName}',
        );

        // Verify details page is showing
        expect(find.byKey(const Key('second_details_page')), findsOneWidget);

        // Route data should be updated and should contain subroute info
        expect(
          navigatorObserver.currentRouteData?.routeSpanId,
          isNot(equals(secondRouteId)),
        );
        expect(
          navigatorObserver.currentRouteData?.routePath,
          contains('/second/details'),
        );

        // Navigate back to second page from subroute
        router.go('/second');
        await tester.pumpAndSettle();

        // We should be back at second page
        expect(find.byKey(const Key('second_page')), findsOneWidget);
        expect(
          navigatorObserver.currentRouteData?.routePath,
          contains('second'),
        );
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );
  });

  group('OTelNavigatorObserver with MaterialApp (non-GoRouter)', () {
    late OTelNavigatorObserver navigatorObserver;

    setUp(() async {
      await FlutterOTel.reset();
      await initializeFlutterOTelForTest(
        serviceName: 'ui-test-service',
      );

      navigatorObserver = OTelNavigatorObserver();
    });

    tearDown(() async {
      await FlutterOTel.reset();
    });

    testWidgets(
      'Should track navigation with standard Navigator',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            initialRoute: '/',
            navigatorObservers: [navigatorObserver],
            routes: {
              '/':
                  (context) => Scaffold(
                    key: const Key('home_page'),
                    appBar: AppBar(title: const Text('Home')),
                    body: Center(
                      child: ElevatedButton(
                        key: const Key('go_to_details'),
                        onPressed: () {
                          print('Pushing named route /details');
                          Navigator.pushNamed(context, '/details');
                        },
                        child: const Text('Go to Details'),
                      ),
                    ),
                  ),
              '/details':
                  (context) => Scaffold(
                    key: const Key('details_page'),
                    appBar: AppBar(title: const Text('Details')),
                    body: Center(
                      child: ElevatedButton(
                        key: const Key('go_back'),
                        onPressed: () {
                          print('Popping to /');
                          Navigator.pop(context);
                        },
                        child: const Text('Go Back'),
                      ),
                    ),
                  ),
            },
          ),
        );
        await tester.pumpAndSettle();

        // Save initial route data
        final initialRouteId = navigatorObserver.currentRouteData?.routeSpanId;
        final initialRouteData = navigatorObserver.currentRouteData;

        print('Initial route: ${initialRouteData?.routeName}');

        // Push route using Navigator
        await tester.tap(find.byKey(const Key('go_to_details')));
        await tester.pumpAndSettle();

        print(
          'After navigation, route: ${navigatorObserver.currentRouteData?.routeName}',
        );
        print(
          'After navigation, path: ${navigatorObserver.currentRouteData?.routePath}',
        );

        // Verify details page is showing
        expect(find.byKey(const Key('details_page')), findsOneWidget);

        // Route data should be updated
        expect(
          navigatorObserver.currentRouteData?.routeSpanId,
          isNot(equals(initialRouteId)),
        );
        expect(
          navigatorObserver.currentRouteData?.routeName,
          isNot(equals(initialRouteData?.routeName)),
        );
        expect(
          navigatorObserver.currentRouteData?.routePath,
          contains('details'),
        );

        // Save details route data
        final detailsRouteId = navigatorObserver.currentRouteData?.routeSpanId;

        // Navigate back to home
        await tester.tap(find.byKey(const Key('go_back')));
        await tester.pumpAndSettle();

        // Verify home page is showing again
        expect(find.byKey(const Key('home_page')), findsOneWidget);

        // We should be back at home
        expect(
          navigatorObserver.currentRouteData?.routeSpanId,
          isNot(equals(detailsRouteId)),
        );
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );
  });
}
