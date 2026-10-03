#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#
Pod::Spec.new do |s|
  s.name             = 'jpush_flutter'
  s.version          = '0.0.2'
  s.summary          = 'A new flutter plugin project.'
  s.description      = <<-DESC
A new flutter plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'xudong.rao' => 'xudong.rao@outlook.com' }
  s.source           = { :path => '.' }
  s.source_files = 'jpush_flutter/Sources/jpush_flutter/**/*'
  s.public_header_files = 'jpush_flutter/Sources/jpush_flutter/**/*.h'
  s.vendored_frameworks = 'jpush_flutter/Frameworks/jcore-ios-5.5.0.xcframework', 'jpush_flutter/Frameworks/jpush-ios-6.2.0.xcframework'
  s.dependency 'Flutter'
  s.frameworks = 'UIKit', 'CFNetwork', 'CoreFoundation', 'CoreTelephony', 'SystemConfiguration', 'CoreGraphics', 'Foundation', 'Security', 'WebKit'
  s.weak_frameworks = 'UserNotifications', 'AppTrackingTransparency', 'Network'
  s.libraries = 'z', 'resolv'

  s.ios.deployment_target = '13.0'
  s.static_framework = true
end
