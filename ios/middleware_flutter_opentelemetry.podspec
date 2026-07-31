Pod::Spec.new do |s|
  s.name             = 'middleware_flutter_opentelemetry'
  s.version          = '1.2.0'
  s.summary          = 'Middleware Flutter RUM native bridge'
  s.description      = <<-DESC
Native bridge for the Middleware Flutter SDK: links the Dart-owned session and
screen names into the stable MiddlewareRum iOS SDK, which provides crash
reporting and v3 session recording.
                       DESC
  s.homepage         = 'https://middleware.io'
  s.license          = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author           = { 'Middleware' => 'dev@middleware.io' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.platform         = :ios, '13.0'

  s.dependency 'Flutter'
  # Stable native SDK (2.1+ adds setNativeSession); static_framework pod,
  # brings PLCrashReporter/DeviceKit/SwiftProtobuf/SWCompression/Reachability.
  s.dependency 'MiddlewareRum', '~> 2.2'

  s.swift_version = '5.0'
  # MiddlewareRum is a static framework; this pod must be static too so apps
  # using `use_frameworks!` (dynamic) don't hit the transitive-static rule.
  s.static_framework = true
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
