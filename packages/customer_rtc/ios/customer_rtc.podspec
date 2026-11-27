#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint customer_rtc.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'customer_rtc'
  s.version          = '0.3.0'
  s.summary          = 'Native Agora RTC and video views for the customer video service.'
  s.description      = <<-DESC
Native Agora RTC and video views for the customer video service.
                       DESC
  s.homepage         = 'https://www.shengwang.cn/'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'Video customer service research'
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'AgoraRtcEngine_iOS/RtcBasic', '4.5.3'
  s.dependency 'AgoraRtcEngine_iOS/VideoCodecEnc', '4.5.3'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
  s.resource_bundles = {'customer_rtc_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
