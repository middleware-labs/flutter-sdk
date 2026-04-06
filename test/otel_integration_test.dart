// Licensed under the Apache License, Version 2.0
// Copyright 2025, Michael Bushe, All rights reserved.

// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterrific_opentelemetry/flutterrific_opentelemetry.dart';
import 'package:go_router/go_router.dart';

import 'testing_utils/test_otel_helper.dart';

// Mock routes for testing
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('home_page'),
      appBar: AppBar(title: const Text('Home')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              key: const Key('to_profile_button'),
              onPressed: () {
                print('Going to /profile');
                GoRouter.of(context).go('/profile');
              },
              child: const Text('Go to Profile'),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              key: const Key('to_settings_button'),
              onPressed: () {
                print('Going to /settings');
                GoRouter.of(context).go('/settings');
              },
              child: const Text('Go to Settings'),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              key: const Key('custom_action_button'),
              onPressed: () {
                // Create a custom span for demonstration
                final span = FlutterOTel.tracer.startSpan(
                  'custom_interaction',
                  attributes:
                      {
                        'interaction.type': 'button_click',
                        'interaction.target': 'custom_action_button',
                      }.toAttributes(),
                );

                // End the span after action completes
                span.end();
              },
              child: const Text('Custom Action'),
            ),
          ],
        ),
      ),
    );
  }
}

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('profile_page'),
      appBar: AppBar(title: const Text('Profile')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              key: const Key('edit_profile_button'),
              onPressed: () {
                print('Going to /profile/edit');
                GoRouter.of(context).go('/profile/edit');
              },
              child: const Text('Edit Profile'),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              key: const Key('to_home_from_profile_button'),
              onPressed: () {
                print('Going to /');
                GoRouter.of(context).go('/');
              },
              child: const Text('Go Home'),
            ),
          ],
        ),
      ),
    );
  }
}

class EditProfilePage extends StatelessWidget {
  const EditProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('edit_profile_page'),
      appBar: AppBar(title: const Text('Edit Profile')),
      body: Center(
        child: ElevatedButton(
          key: const Key('back_to_profile_button'),
          onPressed: () {
            print('Going to /profile');
            GoRouter.of(context).go('/profile');
          },
          child: const Text('Back to Profile'),
        ),
      ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('settings_page'),
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              key: const Key('notifications_button'),
              onPressed: () {
                print('Going to /settings/notifications');
                GoRouter.of(context).go('/settings/notifications');
              },
              child: const Text('Notification Settings'),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              key: const Key('to_home_from_settings_button'),
              onPressed: () {
                print('Going to /');
                GoRouter.of(context).go('/');
              },
              child: const Text('Go Home'),
            ),
          ],
        ),
      ),
    );
  }
}

class NotificationSettingsPage extends StatelessWidget {
  const NotificationSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('notification_settings_page'),
      appBar: AppBar(title: const Text('Notification Settings')),
      body: Center(
        child: ElevatedButton(
          key: const Key('back_to_settings_button'),
          onPressed: () {
            print('Going to /settings');
            GoRouter.of(context).go('/settings');
          },
          child: const Text('Back to Settings'),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FlutterOTel Integration Tests', () {
    late GoRouter router;

    setUp(() async {
      await FlutterOTel.reset();
      await initializeFlutterOTelForTest(
        serviceName: 'ui-test-service',
        commonAttributesFunction: () {
          return {
            'test.user_id': 'test-user-123',
            'test.session_id': 'test-session-456',
          }.toAttributes();
        },
      );

      // Create router with FlutterOTel.routeObserver
      router = GoRouter(
        debugLogDiagnostics: true,
        observers: [FlutterOTel.routeObserver],
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            name: 'home',
            builder: (context, state) => const HomePage(),
          ),
          GoRoute(
            path: '/profile',
            name: 'profile',
            builder: (context, state) => const ProfilePage(),
            routes: [
              GoRoute(
                path: 'edit',
                name: 'edit_profile',
                builder: (context, state) => const EditProfilePage(),
              ),
            ],
          ),
          GoRoute(
            path: '/settings',
            name: 'settings',
            builder: (context, state) => const SettingsPage(),
            routes: [
              GoRoute(
                path: 'notifications',
                name: 'notification_settings',
                builder: (context, state) => const NotificationSettingsPage(),
              ),
            ],
          ),
        ],
      );
    });

    tearDown(() async {
      await FlutterOTel.reset();
    });

    testWidgets(
      'Should track both app lifecycle and navigation events',
      (tester) async {
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();

        // Verify home page is showing
        expect(find.byKey(const Key('home_page')), findsOneWidget);

        // Initial route should be tracked
        expect(
          FlutterOTel.routeObserver.currentRouteData?.routeSpanId,
          isNotNull,
        );
        expect(FlutterOTel.routeObserver.currentRouteData, isNotNull);

        // Navigate to profile page using direct router navigation
        router.go('/profile');
        await tester.pumpAndSettle();

        // Verify profile page is showing
        expect(find.byKey(const Key('profile_page')), findsOneWidget);

        // Verify navigation was tracked
        expect(
          FlutterOTel.routeObserver.currentRouteData?.routeName,
          contains('profile'),
        );

        // Simulate app lifecycle change
        final binding = tester.binding;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pump();

        // Verify lifecycle was tracked
        expect(
          FlutterOTel.lifecycleObserver.currentAppLifecycleState?.name,
          equals(AppLifecycleState.inactive.name),
        );

        // Return to active state
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();

        // Navigate to subroute (edit profile)
        router.go('/profile/edit');
        await tester.pumpAndSettle();

        // Verify edit profile page is showing
        expect(find.byKey(const Key('edit_profile_page')), findsOneWidget);

        // Verify subroute was tracked
        expect(
          FlutterOTel.routeObserver.currentRouteData?.routePath,
          contains('/profile/edit'),
        );

        // Navigate back to profile
        router.go('/profile');
        await tester.pumpAndSettle();

        // Navigate back to home
        router.go('/');
        await tester.pumpAndSettle();

        // Verify home page is showing again
        expect(find.byKey(const Key('home_page')), findsOneWidget);

        // Test custom span creation
        await tester.tap(find.byKey(const Key('custom_action_button')));
        await tester.pump();

        // No explicit verification for the custom span as it's internal to OTel
        // We're just ensuring it doesn't throw exceptions
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    testWidgets(
      'Should track app background and foreground transitions',
      (tester) async {
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();

        final binding = tester.binding;

        // App goes to background
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(
          FlutterOTel.lifecycleObserver.currentAppLifecycleState?.name,
          equals(AppLifecycleState.paused.name),
        );

        // App returns from background
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        expect(
          FlutterOTel.lifecycleObserver.currentAppLifecycleState?.name,
          equals(AppLifecycleState.resumed.name),
        );
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    testWidgets(
      'Should navigate between multiple subroutes',
      (tester) async {
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();

        // Go to Settings
        router.go('/settings');
        await tester.pumpAndSettle();

        // Verify settings page is showing
        expect(find.byKey(const Key('settings_page')), findsOneWidget);
        expect(
          FlutterOTel.routeObserver.currentRouteData?.routePath,
          contains('/settings'),
        );

        // Go to Notifications (subroute)
        router.go('/settings/notifications');
        await tester.pumpAndSettle();

        // Verify notifications page is showing
        expect(
          find.byKey(const Key('notification_settings_page')),
          findsOneWidget,
        );
        expect(
          FlutterOTel.routeObserver.currentRouteData?.routePath,
          contains('/settings/notifications'),
        );

        // Back to Settings
        router.go('/settings');
        await tester.pumpAndSettle();

        // Verify settings page is showing again
        expect(find.byKey(const Key('settings_page')), findsOneWidget);

        // Go to Home
        router.go('/');
        await tester.pumpAndSettle();

        // Verify home page is showing again
        expect(find.byKey(const Key('home_page')), findsOneWidget);

        // Now try a different path
        router.go('/profile');
        await tester.pumpAndSettle();

        // Verify profile page is showing
        expect(find.byKey(const Key('profile_page')), findsOneWidget);
        expect(
          FlutterOTel.routeObserver.currentRouteData?.routePath,
          contains('/profile'),
        );
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );
  });
}
